package com.itdong.mail;

import java.net.URI;
import java.time.Clock;
import java.util.*;
import org.jsoup.Jsoup;
import org.springframework.stereotype.Service;

/** Every manifest and cached read is bound to an existing account and the current stored body.
 * This application has exactly one owner (owner_user id=1); Security authenticates every API. */
@Service
public class MailImageService {
  static final int MAX_IMAGES = 32, MAX_CACHE_ENTRIES = 16;
  static final long CACHE_MILLIS = 600_000;
  // Keep in sync with client/web/mail_renderer.js: these elements drop their
  // entire subtree. Opt-in must not fetch images the reader will never display.
  private static final Set<String> DROPPED = Set.of(
      "script", "style", "iframe", "frame", "frameset", "object", "embed", "svg", "math",
      "form", "input", "button", "textarea", "select", "option", "link", "meta", "base",
      "template", "noscript", "audio", "video", "source", "track");
  final Store store;
  final SafeImageFetcher fetcher;
  final Clock clock;
  final Map<String, Cached> cache = new LinkedHashMap<>();
  record Item(String id, String source, String url) {}
  record Cached(byte[] png, long expiresAt) {}

  @org.springframework.beans.factory.annotation.Autowired
  public MailImageService(Store store, SafeImageFetcher fetcher) { this(store, fetcher, Clock.systemUTC()); }
  MailImageService(Store store, SafeImageFetcher fetcher, Clock clock) {
    this.store = store; this.fetcher = fetcher; this.clock = clock;
  }
  public Object manifest(String messageId, String accountId) {
    return store.write(() -> {
      cleanup();
      return Json.map("items", current(messageId, accountId).stream()
          .map(i -> Json.map("id", i.id(), "source", i.source())).toList());
    });
  }
  public byte[] image(String messageId, String accountId, String imageId) {
    if (imageId == null || !imageId.matches("[a-f0-9]{64}")) throw ApiError.missing();
    String key = accountId + ":" + messageId + ":" + imageId;
    Item selected = store.write(() -> {
      cleanup();
      return find(current(messageId, accountId), imageId);
    });
    byte[] existing = store.write(() -> {
      // Validate immediately before the cache read, under the same mutation lock as account deletion.
      find(current(messageId, accountId), imageId);
      synchronized (cache) { Cached c = cache.get(key); return c != null && c.expiresAt() > clock.millis() ? c.png().clone() : null; }
    });
    if (existing != null) return existing;
    byte[] fetched = fetcher.fetch(selected.url());
    return store.write(() -> {
      // A body change, message move, or deletion while the network request ran invalidates this result.
      find(current(messageId, accountId), imageId);
      synchronized (cache) {
        cleanup();
        while (cache.size() >= MAX_CACHE_ENTRIES) cache.remove(cache.keySet().iterator().next());
        cache.put(key, new Cached(fetched.clone(), clock.millis() + CACHE_MILLIS));
      }
      return fetched;
    });
  }
  private Item find(List<Item> items, String id) {
    return items.stream().filter(i -> i.id().equals(id)).findFirst().orElseThrow(ApiError::missing);
  }
  private List<Item> current(String messageId, String accountId) {
    if (accountId == null || accountId.isBlank() || accountId.length() > 80
        || messageId == null || messageId.length() > 80) throw ApiError.missing();
    var row = store.one("SELECT m.data FROM mail_message m JOIN mail_account a ON a.id=m.account_id WHERE m.id=? AND m.account_id=?", messageId, accountId);
    return extract(Json.string(Json.decode((String) row.get("data")), "bodyHtml"));
  }
  static List<Item> extract(String body) {
    if (body == null || body.length() > 2_097_152) return List.of();
    LinkedHashMap<String, Item> images = new LinkedHashMap<>();
    for (var image : Jsoup.parseBodyFragment(body).select("img[src]")) {
      if (image.parents().stream().anyMatch(parent -> DROPPED.contains(parent.normalName())))
        continue;
      String source = image.attr("src").trim();
      try {
        URI uri = SafeImageFetcher.parseUrl(source);
        String url = uri.toASCIIString();
        // The key also binds the original attribute. Different body encodings cannot reuse an old grant.
        String id = Security.hash(source + "\n" + url);
        images.putIfAbsent(id, new Item(id, source, url));
      } catch (ApiError ignored) { /* Unsupported images remain placeholders. */ }
      if (images.size() >= MAX_IMAGES) break;
    }
    return List.copyOf(images.values());
  }
  void cleanup() {
    synchronized (cache) { cache.entrySet().removeIf(e -> e.getValue().expiresAt() <= clock.millis()); }
  }
}
