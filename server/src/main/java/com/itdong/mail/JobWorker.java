package com.itdong.mail;

import com.itdong.mail.provider.*;
import java.time.Instant;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class JobWorker {
  final MailService mail;
  final Store store;
  final boolean enabled;

  JobWorker(MailService mail, @Value("${mail.worker-enabled:true}") boolean enabled) {
    this.mail = mail;
    this.store = mail.store;
    this.enabled = enabled;
  }

  @Scheduled(fixedDelay = 1000, initialDelay = 1500)
  public synchronized void tick() {
    if (!enabled) return;
    runOne();
  }

  @Scheduled(fixedDelayString = "${mail.poll-interval-ms:120000}", initialDelay = 120000)
  public void pollConnectedAccounts() {
    if (!enabled || mail.security.demo) return;
    for (var account : mail.accounts())
      if ("CONNECTED".equals(account.get("status"))) mail.sync((String) account.get("id"));
  }

  public synchronized boolean runOne() {
    var selected =
        store.write(
            () -> {
              var rows =
                  store.db.queryForList(
                      "SELECT * FROM job WHERE status='QUEUED' ORDER BY created_at,id LIMIT 1");
              if (rows.isEmpty()) return null;
              var row = rows.getFirst();
              store.db.update(
                  "UPDATE job SET status=? WHERE id=?",
                  row.get("kind").equals("SEND") ? "PREPARING" : "RUNNING",
                  row.get("id"));
              return row;
            });
    if (selected == null) return false;
    String id = (String) selected.get("id"),
        kind = (String) selected.get("kind"),
        account = (String) selected.get("account_id");
    var p = Json.decode((String) selected.get("payload"));
    try {
      switch (kind) {
        case "SYNC" -> sync(id, account);
        case "COMMAND" -> command(id, account, p);
        case "SEND" -> send(id, account, p);
        default -> throw new ApiError(400, "NOT_SUPPORTED", "Unknown job type");
      }
    } catch (Exception e) {
      boolean submitting =
          "SUBMITTING".equals(store.one("SELECT status FROM job WHERE id=?", id).get("status"));
      String code =
          e instanceof ProviderException pe
              ? pe.code()
              : e instanceof ApiError ae ? ae.code : "OPERATION_FAILED";
      boolean ambiguous =
          (e instanceof ProviderException pe && pe.ambiguous())
              || (kind.equals("SEND") && submitting && !(e instanceof ProviderException));
      String status = ambiguous ? "UNKNOWN" : "FAILED";
      finish(id, status, code);
      if (kind.equals("SYNC"))
        store.write(
            () -> {
              var a = mail.account(account);
              a.put("status", "ERROR");
              a.put("errorCode", code);
              store.db.update("UPDATE mail_account SET data=? WHERE id=?", Json.encode(a), account);
              store.changed("ACCOUNT", account, 1);
              return null;
            });
    }
    return true;
  }

  void finish(String id, String status, String error) {
    store.write(
        () -> {
          store.db.update("UPDATE job SET status=?,error_code=? WHERE id=?", status, error, id);
          store.changed("JOB", id, 1);
          return null;
        });
  }

  void sync(String id, String account) {
    List<ProviderGateway.Mail> messages = new ArrayList<>();
    if (!mail.security.demo) {
      var credentials = mail.credentials(account);
      for (String folder : List.of("INBOX", "SENT", "TRASH", "ARCHIVE")) {
        try {
          messages.addAll(mail.providers.sync(credentials, folder, null, 100).items());
        } catch (ProviderException e) {
          if (Set.of("FOLDER_NOT_FOUND", "FOLDER_NOT_SUPPORTED", "NOT_SUPPORTED").contains(e.code())
              && !folder.equals("INBOX")) continue;
          throw e;
        }
      }
    }
    store.write(
        () -> {
          for (var remote : messages) {
            var rows =
                store.db.queryForList(
                    "SELECT id,data,revision FROM mail_message WHERE account_id=? AND remote_id=?",
                    account,
                    remote.remoteId());
            String mid = rows.isEmpty() ? Store.id() : (String) rows.getFirst().get("id");
            long revision =
                rows.isEmpty() ? 1 : ((Number) rows.getFirst().get("revision")).longValue() + 1;
            var m = normalize(mid, account, remote, revision);
            if (rows.isEmpty()) mail.insertMessage(mid, account, remote.remoteId(), m);
            else {
              store.db.update(
                  "UPDATE mail_message SET data=?,revision=?,received_at=?,folder=?,summary=? WHERE"
                      + " id=?",
                  Json.encode(m),
                  revision,
                  m.get("receivedAt"),
                  m.get("folder"),
                  Json.encode(mail.summary(m)),
                  mid);
              store.changed("MESSAGE", mid, revision);
            }
          }
          var a = mail.account(account);
          a.put("status", mail.security.demo ? "DEMO" : "CONNECTED");
          a.put("lastSyncAt", Instant.now().toString());
          a.put("errorCode", null);
          store.db.update("UPDATE mail_account SET data=? WHERE id=?", Json.encode(a), account);
          store.changed("ACCOUNT", account, 1);
          store.db.update("UPDATE job SET status='SUCCEEDED' WHERE id=?", id);
          return null;
        });
  }

  static Map<String, Object> normalize(
      String id, String account, ProviderGateway.Mail m, long rev) {
    return Json.map(
        "id",
        id,
        "accountId",
        account,
        "fromName",
        Objects.toString(m.fromName(), ""),
        "fromAddress",
        Objects.toString(m.fromAddress(), ""),
        "to",
        m.to(),
        "cc",
        m.cc(),
        "subject",
        Objects.toString(m.subject(), ""),
        "snippet",
        Objects.toString(m.snippet(), ""),
        "receivedAt",
        MailService.sortTime(Objects.requireNonNullElse(m.receivedAt(), Instant.EPOCH)),
        "isRead",
        m.isRead(),
        "isStarred",
        m.isStarred(),
        "hasAttachments",
        m.hasAttachments(),
        "revision",
        rev,
        "folder",
        m.folder(),
        "bodyText",
        Objects.toString(m.bodyText(), ""),
        "bodyHtml",
        "",
        "attachments",
        m.attachments() == null ? List.of() : m.attachments());
  }

  void command(String id, String account, Map<String, Object> p) {
    String mid = Json.string(p, "messageId");
    var m = store.data("mail_message", mid);
    if (Json.number(m, "revision") != Json.number(p, "baseRevision"))
      throw ApiError.conflict("Revision changed before provider operation");
    String type = Json.string(p, "type");
    String remoteId =
        (String) store.one("SELECT remote_id FROM mail_message WHERE id=?", mid).get("remote_id");
    final String updatedRemoteId =
        mail.security.demo
            ? remoteId
            : mail.providers
                .mutate(mail.credentials(account), remoteId, type, (Boolean) p.get("value"))
                .remoteId();
    store.write(
        () -> {
          var latest = store.data("mail_message", mid);
          switch (type) {
            case "SET_READ" -> latest.put("isRead", p.get("value"));
            case "SET_STAR" -> latest.put("isStarred", p.get("value"));
            case "TRASH", "ARCHIVE" -> {
              if (!Set.of("TRASH", "ARCHIVE").contains(Json.string(latest, "folder")))
                latest.put("previousFolder", latest.get("folder"));
              latest.put("folder", type);
            }
            case "RESTORE" -> latest.put("folder", "INBOX");
          }
          if (!mail.security.demo && Set.of("TRASH", "ARCHIVE", "RESTORE").contains(type)) {
            store.db.update("DELETE FROM remote_attachment WHERE message_id=?", mid);
            latest.put("bodyFetched", false);
            latest.put("attachments", List.of());
          }
          long rev = Json.number(latest, "revision") + 1;
          latest.put("revision", rev);
          store.db.update(
              "UPDATE mail_message SET data=?,revision=?,folder=?,remote_id=?,summary=? WHERE id=?",
              Json.encode(latest),
              rev,
              latest.get("folder"),
              updatedRemoteId,
              Json.encode(mail.summary(latest)),
              mid);
          store.db.update("UPDATE job SET status='SUCCEEDED' WHERE id=?", id);
          store.changed("MESSAGE", mid, rev);
          return null;
        });
  }

  void send(String id, String account, Map<String, Object> snapshot) {
    var outgoing = outgoing(snapshot);
    ProviderGateway.Credentials credentials = mail.security.demo ? null : mail.credentials(account);
    store.write(
        () -> {
          store.db.update("UPDATE job SET status='SUBMITTING' WHERE id=?", id);
          return null;
        });
    if (mail.security.demo) {
      store.write(
          () -> {
            String mid = "sent-" + id;
            var m = new LinkedHashMap<>(snapshot);
            var a = mail.account(account);
            m.put("id", mid);
            m.put("fromName", a.get("displayName"));
            m.put("fromAddress", a.get("email"));
            m.put("receivedAt", Instant.now().toString());
            m.put("folder", "SENT");
            m.put("revision", 1L);
            m.put(
                "snippet",
                Json.string(snapshot, "bodyText")
                    .substring(0, Math.min(150, Json.string(snapshot, "bodyText").length())));
            m.put("isRead", true);
            m.put("isStarred", false);
            m.put("hasAttachments", !outgoing.attachments().isEmpty());
            m.put("bodyHtml", "");
            m.remove("bcc");
            mail.insertMessage(mid, account, mid, m);
            store.db.update("UPDATE job SET status='SENT_COPY_CONFIRMED' WHERE id=?", id);
            store.changed("SEND_INTENT", id, 1);
            return null;
          });
    } else {
      var result = mail.providers.send(credentials, outgoing);
      if (!Set.of("ACCEPTED", "SENT_COPY_CONFIRMED").contains(result.status()))
        throw new ProviderException("INVALID_SEND_RESULT", true);
      finish(id, result.status(), null);
    }
  }

  @SuppressWarnings("unchecked")
  ProviderGateway.Outgoing outgoing(Map<String, Object> p) {
    var uploads = new ArrayList<ProviderGateway.Upload>();
    for (var a : (List<Map<String, Object>>) p.getOrDefault("attachments", List.of())) {
      var row = store.one("SELECT * FROM attachment WHERE id=?", a.get("id"));
      uploads.add(
          new ProviderGateway.Upload(
              (String) row.get("file_name"),
              (String) row.get("content_type"),
              (byte[]) row.get("content")));
    }
    return new ProviderGateway.Outgoing(
        addresses(p.get("to")),
        addresses(p.get("cc")),
        addresses(p.get("bcc")),
        Json.string(p, "subject"),
        Json.string(p, "bodyText"),
        uploads,
        Json.string(p, "messageId"));
  }

  static List<ProviderGateway.Address> addresses(Object value) {
    return MailService.recipients(value).stream()
        .map(a -> new ProviderGateway.Address(Json.string(a, "name"), Json.string(a, "address")))
        .toList();
  }
}
