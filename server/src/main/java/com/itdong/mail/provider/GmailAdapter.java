package com.itdong.mail.provider;

import static com.itdong.mail.provider.ProviderGateway.*;

import com.fasterxml.jackson.databind.*;
import java.net.URI;
import java.time.Instant;
import java.util.*;

final class GmailAdapter implements ProviderGateway {
  final HttpTransport http;
  final String base;

  GmailAdapter(ObjectMapper mapper, String base) {
    http = new HttpTransport(mapper);
    this.base = base;
  }

  JsonNode call(Credentials c, String method, String path, Object body, boolean send) {
    return http.request(method, URI.create(base + path), c.accessToken(), body, send, Map.of());
  }

  public List<Folder> folders(Credentials c) {
    List<Folder> out = new ArrayList<>();
    for (JsonNode n : call(c, "GET", "/labels", null, false).path("labels"))
      out.add(new Folder(n.path("id").asText(), n.path("name").asText(), n.path("id").asText(), 0));
    return out;
  }

  public SyncPage sync(Credentials c, String folder, String cursor, int limit) {
    String query = "/messages?maxResults=" + Math.max(1, Math.min(100, limit));
    if ("ARCHIVE".equals(folder))
      query += "&q=" + HttpTransport.enc("-in:inbox -in:trash -in:spam newer_than:90d");
    else
      query +=
          "&labelIds="
              + HttpTransport.enc(folder == null ? "INBOX" : folder)
              + "&q=newer_than%3A90d";
    if (cursor != null && !cursor.isBlank()) query += "&pageToken=" + HttpTransport.enc(cursor);
    JsonNode page = call(c, "GET", query, null, false);
    List<Mail> result = new ArrayList<>();
    for (JsonNode n : page.path("messages"))
      result.add(
          parse(
              call(
                  c,
                  "GET",
                  "/messages/" + HttpTransport.enc(n.path("id").asText()) + "?format=metadata",
                  null,
                  false),
              false));
    String next = page.path("nextPageToken").asText(null);
    return new SyncPage(result, next, next != null, "RECENT");
  }

  public Mail body(Credentials c, String id) {
    return parse(
        call(c, "GET", "/messages/" + HttpTransport.enc(id) + "?format=full", null, false), true);
  }

  Mail parse(JsonNode n, boolean full) {
    JsonNode payload = n.path("payload");
    Map<String, String> h = new HashMap<>();
    for (JsonNode v : payload.path("headers"))
      h.put(v.path("name").asText().toLowerCase(Locale.ROOT), v.path("value").asText());
    List<Address> from = addresses(h.get("from"));
    Set<String> labels = new HashSet<>();
    n.path("labelIds").forEach(v -> labels.add(v.asText()));
    StringBuilder text = new StringBuilder();
    List<Attachment> att = new ArrayList<>();
    parts(payload, text, att, full, 0);
    return new Mail(
        n.path("id").asText(),
        labels.contains("TRASH")
            ? "TRASH"
            : labels.contains("INBOX") ? "INBOX" : labels.contains("SENT") ? "SENT" : "ARCHIVE",
        from.isEmpty() ? "" : from.get(0).name(),
        from.isEmpty() ? "" : from.get(0).address(),
        addresses(h.get("to")),
        addresses(h.get("cc")),
        h.getOrDefault("subject", ""),
        n.path("snippet").asText(),
        Instant.ofEpochMilli(n.path("internalDate").asLong()),
        !labels.contains("UNREAD"),
        labels.contains("STARRED"),
        !att.isEmpty(),
        text.toString(),
        "",
        att);
  }

  static List<Address> addresses(String value) {
    try {
      return value == null
          ? List.of()
          : MimeSupport.addresses(jakarta.mail.internet.InternetAddress.parseHeader(value, false));
    } catch (Exception e) {
      return List.of();
    }
  }

  void parts(JsonNode p, StringBuilder text, List<Attachment> att, boolean full, int depth) {
    if (depth > 20) throw new ProviderException("MIME_LIMIT", false);
    if (!p.path("filename").asText().isBlank())
      att.add(
          new Attachment(
              p.path("body").hasNonNull("attachmentId")
                  ? p.path("body").path("attachmentId").asText()
                  : "inline:" + p.path("partId").asText(),
              p.path("filename").asText(),
              p.path("mimeType").asText(),
              p.path("body").path("size").asLong()));
    else if (full && p.path("mimeType").asText().startsWith("text/")) {
      String data = p.path("body").path("data").asText();
      if (data.length() > 3 * 1024 * 1024) throw new ProviderException("BODY_TOO_LARGE", false);
      String s =
          new String(Base64.getUrlDecoder().decode(data), java.nio.charset.StandardCharsets.UTF_8);
      if (text.length() + s.length() > 2 * 1024 * 1024)
        throw new ProviderException("BODY_TOO_LARGE", false);
      text.append(p.path("mimeType").asText().equals("text/html") ? MimeSupport.safeText(s) : s)
          .append('\n');
    }
    for (JsonNode child : p.path("parts")) parts(child, text, att, full, depth + 1);
  }

  public MutationResult mutate(Credentials c, String id, String action, Boolean value) {
    String path = "/messages/" + HttpTransport.enc(id);
    if (action.equals("TRASH") || action.equals("RESTORE")) {
      call(c, "POST", path + (action.equals("TRASH") ? "/trash" : "/untrash"), Map.of(), false);
      return new MutationResult(id);
    }
    List<String> add = new ArrayList<>(), remove = new ArrayList<>();
    switch (action) {
      case "SET_READ" -> (Boolean.TRUE.equals(value) ? remove : add).add("UNREAD");
      case "SET_STAR" -> (Boolean.TRUE.equals(value) ? add : remove).add("STARRED");
      case "ARCHIVE" -> remove.add("INBOX");
      default -> throw new ProviderException("NOT_SUPPORTED", false);
    }
    call(c, "POST", path + "/modify", Map.of("addLabelIds", add, "removeLabelIds", remove), false);
    return new MutationResult(id);
  }

  JsonNode inlineBody(JsonNode p, String partId, int depth) {
    if (depth > 20) throw new ProviderException("MIME_LIMIT", false);
    if (p.path("partId").asText().equals(partId)) return p.path("body");
    for (JsonNode child : p.path("parts")) {
      JsonNode found = inlineBody(child, partId, depth + 1);
      if (found != null) return found;
    }
    return null;
  }

  public Download attachment(Credentials c, String id, String attachmentId) {
    Mail m = body(c, id);
    Attachment a =
        m.attachments().stream()
            .filter(v -> v.id().equals(attachmentId))
            .findFirst()
            .orElseThrow(() -> new ProviderException("NOT_FOUND", false));
    if (a.size() > 10 * 1024 * 1024) throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
    JsonNode n =
        attachmentId.startsWith("inline:")
            ? inlineBody(
                call(c, "GET", "/messages/" + HttpTransport.enc(id) + "?format=full", null, false)
                    .path("payload"),
                attachmentId.substring(7),
                0)
            : call(
                c,
                "GET",
                "/messages/"
                    + HttpTransport.enc(id)
                    + "/attachments/"
                    + HttpTransport.enc(attachmentId),
                null,
                false);
    if (n == null) throw new ProviderException("NOT_FOUND", false);
    byte[] bytes;
    try {
      bytes = Base64.getUrlDecoder().decode(n.path("data").asText());
    } catch (Exception e) {
      throw new ProviderException("INVALID_ATTACHMENT", false);
    }
    if (bytes.length > 10 * 1024 * 1024) throw new ProviderException("ATTACHMENT_TOO_LARGE", false);
    return new Download(bytes, a.contentType(), a.fileName());
  }

  public SendResult send(Credentials c, Outgoing o) {
    String raw;
    try {
      raw = MimeSupport.raw(MimeSupport.compose(c, o));
    } catch (ProviderException e) {
      throw e;
    } catch (Exception e) {
      throw new ProviderException("INVALID_MESSAGE", false);
    }
    JsonNode n = call(c, "POST", "/messages/send", Map.of("raw", raw), true);
    return new SendResult("ACCEPTED", n.path("id").asText(null));
  }
}
