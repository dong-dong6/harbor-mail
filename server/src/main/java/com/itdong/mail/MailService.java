package com.itdong.mail;

import com.itdong.mail.provider.*;
import jakarta.annotation.PostConstruct;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

@Service
public class MailService {
  final Store store;
  final Security security;
  final ProviderGateway providers;
  final OAuthService oauth;
  public static final long MAX_ATTACHMENT = 10 * 1024 * 1024;

  MailService(Store store, Security security, OAuthService oauth) {
    this.store = store;
    this.security = security;
    this.oauth = oauth;
    this.providers = new DefaultProviderGateway(Json.MAPPER);
  }

  @PostConstruct
  void seed() {
    store.write(
        () -> {
          // A submitting job may already have reached the provider. Never automatically resubmit
          // it.
          store.db.update(
              "UPDATE job SET status='UNKNOWN',error_code='PROCESS_INTERRUPTED' WHERE kind='SEND'"
                  + " AND status='SUBMITTING'");
          store.db.update(
              "UPDATE job SET status='QUEUED' WHERE kind='SEND' AND status='PREPARING'");
          store.db.update(
              "UPDATE job SET status='FAILED',error_code='RECONCILIATION_REQUIRED' WHERE"
                  + " kind='COMMAND' AND status='RUNNING'");
          store.db.update("UPDATE job SET status='QUEUED' WHERE kind='SYNC' AND status='RUNNING'");
          if ("v1"
              .equals(
                  store.db.queryForObject(
                      "SELECT generation FROM app_state WHERE id=1", String.class)))
            store.db.update("UPDATE app_state SET generation=? WHERE id=1", Store.id());
          if (security.demo
              && store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class) == 0) {
            String[] ps = {"GMAIL", "OUTLOOK", "QQ", "NETEASE", "EXCHANGE"};
            String[] names = {"个人 Gmail", "Outlook", "QQ 邮箱", "163 邮箱", "工作 Exchange"};
            for (int i = 0; i < ps.length; i++) {
              String id = "demo-" + ps[i].toLowerCase();
              var a =
                  Json.map(
                      "id",
                      id,
                      "provider",
                      ps[i],
                      "email",
                      "demo" + i + "@example.invalid",
                      "displayName",
                      names[i],
                      "status",
                      "DEMO",
                      "lastSyncAt",
                      Instant.now().toString(),
                      "unreadCount",
                      0,
                      "errorCode",
                      null);
              store.db.update(
                  "INSERT INTO mail_account VALUES(?,?,?)",
                  id,
                  Json.encode(a),
                  security.encrypt("{}"));
              for (int j = 0; j < 4; j++) {
                String mid = "demo-" + i + "-" + j;
                var m =
                    Json.map(
                        "id",
                        mid,
                        "accountId",
                        id,
                        "fromName",
                        j == 0 ? "欢迎来到云邮" : "演示发件人 " + j,
                        "fromAddress",
                        "sender" + j + "@example.invalid",
                        "to",
                        List.of(Json.map("name", "Demo", "address", a.get("email"))),
                        "cc",
                        List.of(),
                        "subject",
                        j == 0
                            ? "欢迎使用个人邮箱 · 这是一封合成演示邮件"
                            : new String[] {"", "项目进展与本周安排", "你的阅读清单", "周末出行计划"}[j],
                        "snippet",
                        "这里展示跨账户统一收件箱。所有内容均为本地合成数据，不会连接或发送真实邮件。",
                        "receivedAt",
                        Instant.now().minusSeconds(i * 3600 + j * 18000).toString(),
                        "isRead",
                        j > 1,
                        "isStarred",
                        j == 1,
                        "hasAttachments",
                        false,
                        "revision",
                        1L,
                        "folder",
                        "INBOX",
                        "bodyText",
                        "你好！\n\n"
                            + "这是本地演示模式的合成邮件。\n"
                            + "你可以尝试切换账号、搜索、星标、已读、归档，以及保存草稿和模拟发送。\n\n"
                            + "演示发送只保存到本地，不会向任何外部邮箱投递。\n\n"
                            + "云邮",
                        "bodyHtml",
                        "",
                        "attachments",
                        List.of());
                insertMessage(mid, id, mid, m);
              }
            }
          }
          return null;
        });
  }

  void insertMessage(String id, String accountId, String remote, Map<String, Object> m) {
    m.put("receivedAt", sortTime(Instant.parse(Json.string(m, "receivedAt"))));
    store.db.update(
        "INSERT INTO mail_message"
            + " (id,account_id,remote_id,data,revision,received_at,folder,summary)"
            + " VALUES(?,?,?,?,?,?,?,?)",
        id,
        accountId,
        remote,
        Json.encode(m),
        Json.number(m, "revision"),
        Json.string(m, "receivedAt"),
        Json.string(m, "folder"),
        Json.encode(summary(m)));
    store.changed("MESSAGE", id, Json.number(m, "revision"));
  }

  static String sortTime(Instant time) {
    return new java.time.format.DateTimeFormatterBuilder()
        .appendInstant(3)
        .toFormatter()
        .format(time);
  }

  Map<String, Object> account(String id) {
    return store.data("mail_account", id);
  }

  List<Map<String, Object>> accounts() {
    return store.db.queryForList("SELECT data FROM mail_account ORDER BY id").stream()
        .map(
            r -> {
              var a = Json.decode((String) r.get("data"));
              long unread =
                  store
                      .db
                      .queryForList(
                          "SELECT COALESCE(summary,data) AS data FROM mail_message WHERE"
                              + " account_id=? AND folder='INBOX'",
                          a.get("id"))
                      .stream()
                      .map(x -> Json.decode((String) x.get("data")))
                      .filter(x -> !Boolean.TRUE.equals(x.get("isRead")))
                      .count();
              a.put("unreadCount", unread);
              return a;
            })
        .toList();
  }

  Map<String, Object> addImap(Map<String, Object> b) {
    if (security.demo)
      throw new ApiError(409, "DEMO_MODE", "Real accounts are disabled in demo mode");
    String p = Json.string(b, "provider");
    if (!Set.of("QQ", "NETEASE").contains(p)) throw ApiError.bad("Choose QQ or NETEASE");
    String email = address(Json.string(b, "email"));
    String secret = Json.string(b, "authorizationCode");
    if (secret.isBlank() || secret.length() > 256)
      throw ApiError.bad("Authorization code required");
    return store.write(
        () -> {
          String id = Store.id();
          var a =
              Json.map(
                  "id",
                  id,
                  "provider",
                  p,
                  "email",
                  email,
                  "displayName",
                  bounded(Json.string(b, "displayName"), 100),
                  "status",
                  "NOT_SYNCED",
                  "lastSyncAt",
                  null,
                  "unreadCount",
                  0,
                  "errorCode",
                  null);
          store.db.update(
              "INSERT INTO mail_account VALUES(?,?,?)",
              id,
              Json.encode(a),
              security.encrypt(Json.encode(Json.map("secret", secret))));
          store.changed("ACCOUNT", id, 1);
          return a;
        });
  }

  ProviderGateway.Credentials credentials(String id) {
    return oauth.credentials(id);
  }

  List<Map<String, Object>> folders(String id) {
    account(id);
    if (!security.demo)
      return providers.folders(credentials(id)).stream()
          .filter(f -> Set.of("INBOX", "SENT", "TRASH", "ARCHIVE", "STARRED").contains(f.role()))
          .map(
              f ->
                  Json.map(
                      "id",
                      f.role(),
                      "name",
                      f.name(),
                      "role",
                      f.role(),
                      "unreadCount",
                      f.unreadCount()))
          .toList();
    return List.of("INBOX", "SENT", "TRASH", "ARCHIVE", "STARRED").stream()
        .map(role -> Json.map("id", role, "name", role, "role", role, "unreadCount", 0))
        .toList();
  }

  Map<String, Object> messages(
      String accountId, String folder, String query, boolean unread, String cursor, int limit) {
    if (limit < 1 || limit > 100) throw ApiError.bad("limit must be 1..100");
    if (!Set.of("INBOX", "SENT", "TRASH", "ARCHIVE", "STARRED").contains(folder))
      throw ApiError.bad("Unknown folder");
    if (query.length() > 200) throw ApiError.bad("Search too long");
    String cursorDate = "", cursorId = "";
    if (!cursor.isBlank()) {
      try {
        String decoded = new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8);
        String[] c = decoded.split("\\|", -1);
        if (c.length != 3
            || !c[0].equals(Security.hash(accountId + "|" + folder + "|" + query + "|" + unread)))
          throw new Exception();
        Instant.parse(c[1]);
        cursorDate = c[1];
        cursorId = c[2];
      } catch (Exception e) {
        throw ApiError.bad("Invalid cursor or changed filters");
      }
    }
    String sql = "SELECT COALESCE(summary,data) AS data, folder AS message_folder FROM mail_message WHERE 1=1";
    List<Object> args = new ArrayList<>();
    if (!accountId.isBlank()) {
      account(accountId);
      sql += " AND account_id=?";
      args.add(accountId);
    }
    if (!folder.equals("STARRED")) {
      sql += " AND folder=?";
      args.add(folder);
    }
    if (!cursorDate.isBlank()) {
      sql += " AND (received_at<? OR (received_at=? AND id<?))";
      args.add(cursorDate);
      args.add(cursorDate);
      args.add(cursorId);
    }
    sql += " ORDER BY received_at DESC,id DESC";
    // v0.1 bounded local read-model search; no claim of full provider search.
    var filtered =
        store.db.queryForList(sql, args.toArray()).stream()
            .map(r -> {
              var message = Json.decode((String) r.get("data"));
              // Persisted summaries omit folder; only trust the indexed SQL value.
              message.put("folder", r.get("message_folder"));
              return message;
            })
            .filter(m -> !folder.equals("STARRED") || Boolean.TRUE.equals(m.get("isStarred")))
            .filter(m -> !unread || !Boolean.TRUE.equals(m.get("isRead")))
            .filter(
                m ->
                    query.isBlank()
                        || (Json.string(m, "subject")
                                + " "
                                + Json.string(m, "fromName")
                                + " "
                                + Json.string(m, "fromAddress")
                                + " "
                                + Json.string(m, "snippet"))
                            .toLowerCase(Locale.ROOT)
                            .contains(query.toLowerCase(Locale.ROOT)))
            .limit(limit + 1L)
            .toList();
    boolean more = filtered.size() > limit;
    var page = filtered.subList(0, Math.min(limit, filtered.size()));
    // Hydrate only visible legacy SENT rows. Never load every SENT body before pagination.
    var missingRecipients = page.stream()
        .filter(m -> "SENT".equals(m.get("folder")) && !m.containsKey("to"))
        .map(m -> Json.string(m, "id"))
        .toList();
    if (!missingRecipients.isEmpty()) {
      var recipientsById = new HashMap<String, Object>();
      String placeholders = String.join(",", Collections.nCopies(missingRecipients.size(), "?"));
      for (var row : store.db.queryForList(
          "SELECT id,data FROM mail_message WHERE id IN (" + placeholders + ")",
          missingRecipients.toArray())) {
        var full = Json.decode((String) row.get("data"));
        recipientsById.put((String) row.get("id"), full.getOrDefault("to", List.of()));
      }
      page.stream().filter(m -> missingRecipients.contains(Json.string(m, "id")))
          .forEach(m -> m.put("to", recipientsById.getOrDefault(Json.string(m, "id"), List.of())));
    }
    String next = null;
    if (more) {
      var m = page.getLast();
      next =
          Base64.getUrlEncoder()
              .withoutPadding()
              .encodeToString(
                  (Security.hash(accountId + "|" + folder + "|" + query + "|" + unread)
                          + "|"
                          + m.get("receivedAt")
                          + "|"
                          + m.get("id"))
                      .getBytes(StandardCharsets.UTF_8));
    }
    return Json.map(
        "items",
        page.stream().map(this::summary).toList(),
        "nextCursor",
        next,
        "hasMore",
        more,
        "coverage",
        security.demo ? "DEMO" : "PARTIAL");
  }

  Map<String, Object> summary(Map<String, Object> m) {
    var copy = new LinkedHashMap<>(m);
    List.of(
            "bodyText",
            "bodyHtml",
            "to",
            "cc",
            "attachments",
            "folder",
            "previousFolder",
            "bodyFetched",
            "bcc",
            "replyToMessageId",
            "messageId",
            "updatedAt")
        .forEach(copy::remove);
    // Sent-list rows identify recipients without exposing bodies, Bcc or attachments.
    if ("SENT".equals(m.get("folder"))) {
      copy.put("to", m.getOrDefault("to", List.of()));
    }
    return copy;
  }

  Map<String, Object> detail(String id) {
    var m = store.data("mail_message", id);
    if (!security.demo && !Boolean.TRUE.equals(m.get("bodyFetched"))) {
      var row = store.one("SELECT * FROM mail_message WHERE id=?", id);
      var remote =
          providers.body(credentials(Json.string(m, "accountId")), (String) row.get("remote_id"));
      return store.write(
          () -> {
            var latest = store.data("mail_message", id);
            latest.put("bodyText", bounded(remote.bodyText(), 2_000_000));
            latest.put("bodyHtml", "");
            latest.put("bodyFetched", true);
            var metadata = new ArrayList<Map<String, Object>>();
            for (var a :
                remote.attachments() == null
                    ? List.<ProviderGateway.Attachment>of()
                    : remote.attachments()) {
              var existing =
                  store.db.queryForList(
                      "SELECT id FROM remote_attachment WHERE message_id=? AND provider_id=?",
                      id,
                      a.id());
              String aid = existing.isEmpty() ? Store.id() : (String) existing.getFirst().get("id");
              String name =
                  Objects.toString(a.fileName(), "attachment")
                      .replaceAll("[\\\\/\\r\\n\\x00]", "_");
              if (name.length() > 200) name = name.substring(0, 200);
              if (existing.isEmpty())
                store.db.update(
                    "INSERT INTO remote_attachment VALUES(?,?,?,?,?,?)",
                    aid,
                    id,
                    a.id(),
                    name,
                    "application/octet-stream",
                    a.size());
              metadata.add(
                  Json.map(
                      "id",
                      aid,
                      "fileName",
                      name,
                      "contentType",
                      "application/octet-stream",
                      "size",
                      a.size()));
            }
            latest.put("attachments", metadata);
            store.db.update("UPDATE mail_message SET data=? WHERE id=?", Json.encode(latest), id);
            return latest;
          });
    }
    return m;
  }

  ProviderGateway.Download download(String id) {
    var local = store.db.queryForList("SELECT * FROM attachment WHERE id=?", id);
    if (!local.isEmpty()) {
      var a = local.getFirst();
      return new ProviderGateway.Download(
          (byte[]) a.get("content"), "application/octet-stream", (String) a.get("file_name"));
    }
    var a = store.one("SELECT * FROM remote_attachment WHERE id=?", id);
    var m = store.one("SELECT * FROM mail_message WHERE id=?", a.get("message_id"));
    if (((Number) a.get("size_bytes")).longValue() > MAX_ATTACHMENT)
      throw new ApiError(413, "ATTACHMENT_TOO_LARGE", "Remote attachment exceeds 10 MiB");
    var result =
        providers.attachment(
            credentials((String) m.get("account_id")),
            (String) m.get("remote_id"),
            (String) a.get("provider_id"));
    if (result.bytes().length > MAX_ATTACHMENT)
      throw new ApiError(413, "ATTACHMENT_TOO_LARGE", "Remote attachment exceeds 10 MiB");
    return new ProviderGateway.Download(
        result.bytes(), "application/octet-stream", (String) a.get("file_name"));
  }

  Map<String, Object> sync(String id) {
    account(id);
    return store.write(
        () -> {
          var existing =
              store.db.queryForList(
                  "SELECT id,status FROM job WHERE kind='SYNC' AND account_id=? AND status IN"
                      + " ('QUEUED','RUNNING')",
                  id);
          if (!existing.isEmpty())
            return Json.map(
                "jobId",
                existing.getFirst().get("id"),
                "status",
                existing.getFirst().get("status"));
          String job = Store.id();
          insertJob(job, "SYNC", id, null, null, "QUEUED", Json.map());
          return Json.map("jobId", job, "status", "QUEUED");
        });
  }

  void insertJob(
      String id,
      String kind,
      String account,
      String key,
      String hash,
      String status,
      Map<String, Object> payload) {
    store.db.update(
        "INSERT INTO job VALUES(?,?,?,?,?,?,?,?,?)",
        id,
        kind,
        account,
        key,
        hash,
        status,
        Json.encode(payload),
        null,
        Instant.now().toString());
  }

  Map<String, Object> duplicate(String kind, String key, String hash) {
    if (key == null || key.isBlank() || key.length() > 160)
      throw ApiError.bad("Idempotency-Key required, maximum 160 characters");
    var rows =
        store.db.queryForList("SELECT * FROM job WHERE kind=? AND idempotency_key=?", kind, key);
    if (rows.isEmpty()) return null;
    var row = rows.getFirst();
    if (!hash.equals(row.get("request_hash")))
      throw new ApiError(409, "IDEMPOTENCY_CONFLICT", "This key was used with a different request");
    return Json.map("id", row.get("id"), "status", row.get("status"));
  }

  Map<String, Object> command(String key, Map<String, Object> b) {
    String hash = Security.hash(Json.encode(new TreeMap<>(b)));
    return store.write(
        () -> {
          var prior = duplicate("COMMAND", key, hash);
          if (prior != null) return prior;
          String type = Json.string(b, "type");
          if (!Set.of("SET_READ", "SET_STAR", "TRASH", "ARCHIVE", "RESTORE").contains(type))
            throw ApiError.bad("Unsupported command");
          if (type.startsWith("SET_") && !(b.get("value") instanceof Boolean))
            throw ApiError.bad("Boolean value required");
          var m = store.data("mail_message", Json.string(b, "messageId"));
          if (Json.number(m, "revision") != Json.number(b, "baseRevision"))
            throw ApiError.conflict("Message revision changed");
          String id = Store.id();
          insertJob(id, "COMMAND", Json.string(m, "accountId"), key, hash, "QUEUED", b);
          return Json.map("id", id, "status", "QUEUED");
        });
  }

  Map<String, Object> job(String id, String kind) {
    var j = store.one("SELECT * FROM job WHERE id=? AND kind=?", id, kind);
    var p = Json.decode((String) j.get("payload"));
    return Json.map(
        "id",
        id,
        "accountId",
        j.get("account_id"),
        "subject",
        p.getOrDefault("subject", ""),
        "status",
        j.get("status"),
        "createdAt",
        j.get("created_at"),
        "errorCode",
        j.get("error_code"),
        "messageId",
        p.get("messageId"));
  }

  List<Map<String, Object>> jobs(String kind) {
    return store
        .db
        .queryForList("SELECT id FROM job WHERE kind=? ORDER BY created_at DESC", kind)
        .stream()
        .map(r -> job((String) r.get("id"), kind))
        .toList();
  }

  List<Map<String, Object>> drafts() {
    return store.db.queryForList("SELECT data FROM draft ORDER BY id").stream()
        .map(r -> Json.decode((String) r.get("data")))
        .toList();
  }

  @SuppressWarnings("unchecked")
  static List<Map<String, Object>> recipients(Object obj) {
    if (obj == null) return List.of();
    if (!(obj instanceof List<?> list) || list.size() > 50)
      throw ApiError.bad("Invalid recipients (maximum 50 per field)");
    List<Map<String, Object>> out = new ArrayList<>();
    for (Object item : list) {
      if (!(item instanceof Map<?, ?> m)) throw ApiError.bad("Recipient object required");
      out.add(
          Json.map(
              "name",
              bounded(Objects.toString(m.get("name"), ""), 200),
              "address",
              address(Objects.toString(m.get("address"), ""))));
    }
    return out;
  }

  static String address(String a) {
    if (a.length() > 254 || !a.matches("[^\\s<>@,;]+@[^\\s<>@,;]+\\.[^\\s<>@,;]+"))
      throw ApiError.bad("Invalid email address");
    return a;
  }

  static String bounded(String s, int max) {
    if (s == null) return "";
    if (s.length() > max || s.indexOf('\0') >= 0) throw ApiError.bad("Text exceeds allowed length");
    return s;
  }

  Map<String, Object> saveDraft(String id, Map<String, Object> b) {
    return store.write(
        () -> {
          var old = id == null ? Json.map() : store.data("draft", id);
          String accountId =
              b.containsKey("accountId")
                  ? Json.string(b, "accountId")
                  : Json.string(old, "accountId");
          account(accountId);
          if (id != null && Json.number(old, "revision") != Json.number(b, "revision"))
            throw ApiError.conflict("Draft changed on another device");
          var d = new LinkedHashMap<>(old);
          d.put("id", id == null ? Store.id() : id);
          d.put("accountId", accountId);
          for (String field : List.of("to", "cc", "bcc"))
            d.put(field, recipients(b.containsKey(field) ? b.get(field) : old.get(field)));
          d.put(
              "subject",
              bounded(
                  b.containsKey("subject")
                      ? Json.string(b, "subject")
                      : Json.string(old, "subject"),
                  998));
          if (Json.string(d, "subject").contains("\n") || Json.string(d, "subject").contains("\r"))
            throw ApiError.bad("Subject must be one line");
          d.put(
              "bodyText",
              bounded(
                  b.containsKey("bodyText")
                      ? Json.string(b, "bodyText")
                      : Json.string(old, "bodyText"),
                  1_000_000));
          d.put(
              "replyToMessageId", b.getOrDefault("replyToMessageId", old.get("replyToMessageId")));
          d.put("revision", id == null ? 1L : Json.number(old, "revision") + 1);
          d.put("updatedAt", Instant.now().toString());
          d.putIfAbsent("attachments", List.of());
          if (id == null)
            store.db.update(
                "INSERT INTO draft VALUES(?,?,?,?)",
                d.get("id"),
                accountId,
                Json.encode(d),
                d.get("revision"));
          else
            store.db.update(
                "UPDATE draft SET account_id=?,data=?,revision=? WHERE id=?",
                accountId,
                Json.encode(d),
                d.get("revision"),
                id);
          store.changed("DRAFT", (String) d.get("id"), (long) d.get("revision"));
          return d;
        });
  }

  void deleteDraft(String id) {
    store.write(
        () -> {
          store.data("draft", id);
          store.db.update(
              "DELETE FROM draft WHERE id=?",
              id); /* Snapshot attachment references survive deletion. */
          store.changed("DRAFT_DELETED", id, 0);
          return null;
        });
  }

  Map<String, Object> upload(String id, MultipartFile file) {
    if (file.isEmpty() || file.getSize() > MAX_ATTACHMENT)
      throw new ApiError(413, "ATTACHMENT_TOO_LARGE", "File must be 1 byte to 10 MiB");
    try {
      byte[] bytes = file.getBytes();
      return store.write(
          () -> {
            var d = store.data("draft", id);
            @SuppressWarnings("unchecked")
            var old = (List<Map<String, Object>>) d.get("attachments");
            long total = old.stream().mapToLong(a -> ((Number) a.get("size")).longValue()).sum();
            if (total + bytes.length > MAX_ATTACHMENT || old.size() >= 10)
              throw new ApiError(
                  413, "MESSAGE_TOO_LARGE", "Total raw attachments maximum 10 MiB and 10 files");
            String aid = Store.id();
            String name =
                Objects.toString(file.getOriginalFilename(), "attachment")
                    .replaceAll("[\\\\/\\r\\n\\x00]", "_");
            name = bounded(name, 200);
            String type = "application/octet-stream";
            var a =
                Json.map("id", aid, "fileName", name, "contentType", type, "size", bytes.length);
            store.db.update("INSERT INTO attachment VALUES(?,?,?,?,?)", aid, id, name, type, bytes);
            var attached = new ArrayList<>(old);
            attached.add(a);
            d.put("attachments", attached);
            d.put("revision", Json.number(d, "revision") + 1);
            d.put("updatedAt", Instant.now().toString());
            store.db.update(
                "UPDATE draft SET data=?,revision=? WHERE id=?",
                Json.encode(d),
                d.get("revision"),
                id);
            store.changed("DRAFT", id, Json.number(d, "revision"));
            return a;
          });
    } catch (java.io.IOException e) {
      throw ApiError.bad("Upload could not be read");
    }
  }

  Map<String, Object> send(String id, String key, Map<String, Object> b) {
    String hash = Security.hash(id + ":" + Json.encode(new TreeMap<>(b)));
    return store.write(
        () -> {
          var prior = duplicate("SEND", key, hash);
          if (prior != null) return prior;
          var d = store.data("draft", id);
          if (Json.number(d, "revision") != Json.number(b, "revision"))
            throw ApiError.conflict("Draft revision changed");
          if (recipients(d.get("to")).isEmpty()
              && recipients(d.get("cc")).isEmpty()
              && recipients(d.get("bcc")).isEmpty())
            throw ApiError.bad("At least one recipient required");
          String jid = Store.id();
          d.put("messageId", "<" + jid + "@personal-mail.invalid>");
          insertJob(jid, "SEND", Json.string(d, "accountId"), key, hash, "QUEUED", d);
          store.changed("SEND_INTENT", jid, 1);
          return Json.map("id", jid, "status", "QUEUED");
        });
  }

  Map<String, Object> changes(String after) {
    String generation =
        store.db.queryForObject("SELECT generation FROM app_state WHERE id=1", String.class);
    long seq = 0;
    if (!after.isBlank()) {
      if (!after.startsWith(generation + ":"))
        throw new ApiError(410, "CURSOR_EXPIRED", "Reload all lists");
      try {
        seq = Long.parseLong(after.substring(generation.length() + 1));
      } catch (Exception e) {
        throw ApiError.bad("Invalid change cursor");
      }
      if (seq < 0) throw ApiError.bad("Invalid change cursor");
      if (seq > store.db.queryForObject("SELECT seq FROM app_state WHERE id=1", Long.class))
        throw new ApiError(410, "CURSOR_EXPIRED", "Server history changed; reload all lists");
    }
    var rows =
        store.db.queryForList("SELECT * FROM change_log WHERE seq>? ORDER BY seq LIMIT 201", seq);
    boolean more = rows.size() > 200;
    var page = rows.subList(0, Math.min(200, rows.size()));
    var items =
        page.stream()
            .map(
                r ->
                    Json.map(
                        "seq",
                        r.get("seq"),
                        "type",
                        r.get("type"),
                        "entityId",
                        r.get("entity_id"),
                        "revision",
                        r.get("revision")))
            .toList();
    return Json.map(
        "items",
        items,
        "nextCursor",
        generation + ":" + (page.isEmpty() ? seq : page.getLast().get("seq")),
        "hasMore",
        more);
  }
}
