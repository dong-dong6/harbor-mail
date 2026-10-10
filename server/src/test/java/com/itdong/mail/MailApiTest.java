package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.net.URI;
import java.net.http.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "spring.datasource.url=${TEST_DATABASE_URL:jdbc:h2:mem:mailtest;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1}",
      "spring.datasource.username=${TEST_DATABASE_USER:sa}",
      "spring.datasource.password=${TEST_DATABASE_PASSWORD:}",
      "mail.worker-enabled=false"
    })
@ActiveProfiles("demo")
class MailApiTest {
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired MailService mail;
  @Autowired JobWorker worker;
  final HttpClient http = HttpClient.newHttpClient();
  String token;

  @BeforeEach
  void reset() throws Exception {
    store.write(
        () -> {
          for (String t :
              List.of(
                  "remote_attachment",
                  "attachment",
                  "job",
                  "draft",
                  "mail_message",
                  "mail_account",
                  "change_log",
                  "access_token",
                  "oauth_state")) store.db.update("DELETE FROM " + t);
          return null;
        });
    security.attempts.clear();
    mail.seed();
    token =
        (String)
            json(call(
                    "POST",
                    "/auth/login",
                    Json.map("username", "demo", "password", "demo-local-only"),
                    null,
                    null))
                .get("accessToken");
  }

  HttpResponse<String> call(String method, String path, Object body, String bearer, String key)
      throws Exception {
    var builder =
        HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1" + path))
            .header("Content-Type", "application/json");
    if (bearer != null) builder.header("Authorization", "Bearer " + bearer);
    if (key != null) builder.header("Idempotency-Key", key);
    return http.send(
        builder
            .method(
                method,
                body == null
                    ? HttpRequest.BodyPublishers.noBody()
                    : HttpRequest.BodyPublishers.ofString(Json.encode(body)))
            .build(),
        HttpResponse.BodyHandlers.ofString());
  }

  Map<String, Object> json(HttpResponse<String> r) {
    return Json.decode(r.body());
  }

  @SuppressWarnings("unchecked")
  List<Map<String, Object>> items(HttpResponse<String> r) {
    return (List<Map<String, Object>>) json(r).get("items");
  }

  Map<String, Object> draft() throws Exception {
    return json(
        call(
            "POST",
            "/drafts",
            Json.map(
                "accountId",
                "demo-gmail",
                "to",
                List.of(Json.map("address", "recipient@example.invalid")),
                "subject",
                "Test",
                "bodyText",
                "Original frozen body"),
            token,
            null));
  }

  @Test
  void publicHealthAndProtectedMail() throws Exception {
    var health = call("GET", "/health", null, null, null);
    assertEquals(200, health.statusCode());
    assertEquals("DENY", health.headers().firstValue("X-Frame-Options").orElse(""));
    assertEquals(
        "default-src 'none'; frame-ancestors 'none'",
        health.headers().firstValue("Content-Security-Policy").orElse(""));
    assertEquals(401, call("GET", "/messages", null, null, null).statusCode());
    assertEquals(401, call("GET", "/accounts", null, "wrong", null).statusCode());
    assertEquals(5, items(call("GET", "/accounts", null, token, null)).size());
  }

  @Test
  void demoOAuthSettingsAreReadOnlyAndRejectEveryMutation() throws Exception {
    var listing = call("GET", "/settings/oauth", null, token, null);
    assertEquals(200, listing.statusCode(), listing.body());
    assertEquals(true, json(listing).get("demoMode"));
    assertEquals(true, json(listing).get("readOnly"));
    assertEquals(3, items(listing).size());
    assertFalse(listing.body().contains("\"clientSecret\""));
    for (String provider : List.of("GMAIL", "OUTLOOK", "EXCHANGE")) {
      var save = call("PUT", "/settings/oauth/" + provider,
          Json.map("revision", 0, "clientId", "synthetic-client", "clientSecret", "synthetic-secret",
              "redirectUri", "https://mail.example.test/api/v1/oauth/" + provider + "/callback",
              "tenant", ""), token, null);
      assertEquals(409, save.statusCode(), save.body());
      assertEquals("DEMO_MODE", ((Map<?, ?>) json(save).get("error")).get("code"));
      var reset = call("POST", "/settings/oauth/" + provider + "/reset",
          Json.map("revision", 0), token, null);
      assertEquals(409, reset.statusCode(), reset.body());
      assertEquals("DEMO_MODE", ((Map<?, ?>) json(reset).get("error")).get("code"));
      assertEquals(0L, store.db.queryForObject(
          "SELECT revision FROM oauth_provider_settings WHERE provider=?", Long.class, provider));
    }
  }

  @Test
  void opaqueTokensAreHashedExpiringAndRevocable() throws Exception {
    var row = store.one("SELECT * FROM access_token WHERE token_hash=?", Security.hash(token));
    assertNotEquals(token, row.get("token_hash"));
    assertEquals(204, call("POST", "/auth/logout", null, token, null).statusCode());
    assertEquals(401, call("GET", "/accounts", null, token, null).statusCode());
  }

  @Test
  void expiredTokenFails() throws Exception {
    store.db.update("UPDATE access_token SET expires_at=0");
    assertEquals(401, call("GET", "/accounts", null, token, null).statusCode());
  }

  @Test
  void invalidLoginIsRateLimitedAndLongPasswordSafe() throws Exception {
    assertEquals(
        401,
        call(
                "POST",
                "/auth/login",
                Json.map("username", "demo", "password", "x".repeat(200)),
                null,
                null)
            .statusCode());
    for (int i = 0; i < 8; i++)
      assertEquals(
          401,
          call("POST", "/auth/login", Json.map("username", "demo", "password", "wrong"), null, null)
              .statusCode());
    assertEquals(
        429,
        call("POST", "/auth/login", Json.map("username", "demo", "password", "wrong"), null, null)
            .statusCode());
  }

  @Test
  void passwordStoredAsBcryptNotPlaintext() {
    String hash = (String) store.one("SELECT password_hash FROM owner_user").get("password_hash");
    assertTrue(hash.startsWith("$2"));
    assertNotEquals("demo-local-only", hash);
  }

  @Test
  void encryptedSecretsUseRandomAuthenticatedEncryption() {
    String a = security.encrypt("private"), b = security.encrypt("private");
    assertNotEquals(a, b);
    assertFalse(a.contains("private"));
    assertEquals("private", security.decrypt(a));
    assertThrows(
        IllegalStateException.class,
        () -> security.decrypt(a.substring(0, a.length() - 3) + "bad"));
  }

  @Test
  void paginationStableAndFilterBound() throws Exception {
    var first = json(call("GET", "/messages?limit=3", null, token, null));
    assertEquals(true, first.get("hasMore"));
    assertFalse(items(call("GET", "/messages?folder=INBOX&limit=1", null, token, null))
        .get(0).containsKey("to"));
    String c = (String) first.get("nextCursor");
    var second = json(call("GET", "/messages?limit=3&cursor=" + c, null, token, null));
    assertNotEquals(first.get("items"), second.get("items"));
    assertEquals(
        400, call("GET", "/messages?folder=SENT&cursor=" + c, null, token, null).statusCode());
    assertEquals(400, call("GET", "/messages?limit=1000", null, token, null).statusCode());
  }

  @Test
  void detailDoesNotMarkReadAndHtmlNeverReturned() throws Exception {
    var d = json(call("GET", "/messages/demo-0-0", null, token, null));
    assertEquals(false, d.get("isRead"));
    assertEquals("", d.get("bodyHtml"));
    assertEquals(false, json(call("GET", "/messages/demo-0-0", null, token, null)).get("isRead"));
  }

  @Test
  void commandIdempotencyAndOptimisticConcurrency() throws Exception {
    var b = Json.map("type", "SET_READ", "messageId", "demo-0-0", "baseRevision", 1, "value", true);
    var one = json(call("POST", "/commands", b, token, "same"));
    var two = json(call("POST", "/commands", b, token, "same"));
    assertEquals(one, two);
    b.put("value", false);
    assertEquals(409, call("POST", "/commands", b, token, "same").statusCode());
    worker.runOne();
    assertEquals(
        "SUCCEEDED",
        json(call("GET", "/commands/" + one.get("id"), null, token, null)).get("status"));
    assertEquals(true, json(call("GET", "/messages/demo-0-0", null, token, null)).get("isRead"));
    assertEquals(409, call("POST", "/commands", b, token, "new-key").statusCode());
  }

  @Test
  void trashAndRestoreAreReversible() throws Exception {
    call(
        "POST",
        "/commands",
        Json.map("type", "TRASH", "messageId", "demo-0-0", "baseRevision", 1),
        token,
        "trash");
    worker.runOne();
    assertEquals("TRASH", mail.detail("demo-0-0").get("folder"));
    call(
        "POST",
        "/commands",
        Json.map("type", "RESTORE", "messageId", "demo-0-0", "baseRevision", 2),
        token,
        "restore");
    worker.runOne();
    assertEquals("INBOX", mail.detail("demo-0-0").get("folder"));
  }

  @Test
  void draftRevisionConflictAndValidation() throws Exception {
    var d = draft();
    assertEquals(1, ((Number) d.get("revision")).intValue());
    String id = (String) d.get("id");
    assertEquals(
        200,
        call("PATCH", "/drafts/" + id, Json.map("revision", 1, "subject", "Edited"), token, null)
            .statusCode());
    assertEquals(
        409,
        call("PATCH", "/drafts/" + id, Json.map("revision", 1, "subject", "Stale"), token, null)
            .statusCode());
    assertEquals(
        400,
        call(
                "PATCH",
                "/drafts/" + id,
                Json.map("revision", 2, "subject", "bad\r\nBcc: x"),
                token,
                null)
            .statusCode());
  }

  @Test
  void sendFreezesSnapshotAndSurvivesDraftDeletion() throws Exception {
    var d = draft();
    String id = (String) d.get("id");
    var sent =
        json(call("POST", "/drafts/" + id + "/send", Json.map("revision", 1), token, "send-key"));
    call(
        "PATCH",
        "/drafts/" + id,
        Json.map("revision", 1, "bodyText", "Edited afterwards"),
        token,
        null);
    call("DELETE", "/drafts/" + id, null, token, null);
    worker.runOne();
    assertEquals(
        "SENT_COPY_CONFIRMED",
        json(call("GET", "/send-intents/" + sent.get("id"), null, token, null)).get("status"));
    assertEquals("Original frozen body", mail.detail("sent-" + sent.get("id")).get("bodyText"));
    var sentRows = items(call("GET", "/messages?folder=SENT", null, token, null));
    assertEquals(1, sentRows.size());
    assertEquals(d.get("to"), sentRows.get(0).get("to"));
    var legacySummary = new java.util.LinkedHashMap<>(sentRows.get(0));
    legacySummary.remove("to");
    store.db.update("UPDATE mail_message SET summary=? WHERE id=?",
        Json.encode(legacySummary), "sent-" + sent.get("id"));
    assertEquals(d.get("to"), items(call("GET", "/messages?folder=SENT", null, token, null))
        .get(0).get("to"));
    // An off-page legacy row must not hydrate or decode its body during this page request.
    var older = new java.util.LinkedHashMap<>(mail.detail("sent-" + sent.get("id")));
    older.put("id", "older-sent");
    older.put("receivedAt", "2000-01-01T00:00:00Z");
    mail.insertMessage("older-sent", Json.string(older, "accountId"), "older-sent", older);
    var olderSummary = mail.summary(older);
    olderSummary.remove("to");
    store.db.update("UPDATE mail_message SET summary=?,data=? WHERE id='older-sent'",
        Json.encode(olderSummary), "off-page-body-must-not-be-decoded");
    var boundedPage = items(call("GET", "/messages?folder=SENT&limit=1", null, token, null));
    assertEquals(1, boundedPage.size());
    assertEquals(d.get("to"), boundedPage.get(0).get("to"));
    for (String privateField : List.of("bodyText", "bodyHtml", "bcc", "cc", "attachments")) {
      assertFalse(sentRows.get(0).containsKey(privateField));
    }
    var duplicate =
        json(call("POST", "/drafts/" + id + "/send", Json.map("revision", 1), token, "send-key"));
    assertEquals(sent.get("id"), duplicate.get("id"));
    assertFalse(worker.runOne());
  }

  @Test
  void staleSendAndDifferentIdempotencyPayloadRejected() throws Exception {
    var d = draft();
    String path = "/drafts/" + d.get("id") + "/send";
    assertEquals(409, call("POST", path, Json.map("revision", 99), token, "bad").statusCode());
    assertEquals(202, call("POST", path, Json.map("revision", 1), token, "key").statusCode());
    assertEquals(409, call("POST", path, Json.map("revision", 2), token, "key").statusCode());
  }

  @Test
  void submittingAfterRestartBecomesUnknownAndNeverRetries() throws Exception {
    var d = draft();
    var sent =
        json(
            call(
                "POST",
                "/drafts/" + d.get("id") + "/send",
                Json.map("revision", 1),
                token,
                "interrupted"));
    store.db.update("UPDATE job SET status='SUBMITTING' WHERE id=?", sent.get("id"));
    mail.seed();
    assertEquals("UNKNOWN", mail.job((String) sent.get("id"), "SEND").get("status"));
    assertFalse(worker.runOne());
    assertEquals(0, items(call("GET", "/messages?folder=SENT", null, token, null)).size());
  }

  @Test
  void duplicateSyncJobsCoalesceAndComplete() throws Exception {
    var a = json(call("POST", "/accounts/demo-gmail/sync", null, token, null));
    var b = json(call("POST", "/accounts/demo-gmail/sync", null, token, null));
    assertEquals(a, b);
    worker.runOne();
    assertEquals(
        "SUCCEEDED",
        json(call("GET", "/sync-jobs/" + a.get("jobId"), null, token, null)).get("status"));
  }

  @Test
  void realAccountsAndOauthDisabledInDemo() throws Exception {
    assertEquals(
        409,
        call(
                "POST",
                "/accounts/imap",
                Json.map("provider", "QQ", "email", "user@qq.com", "authorizationCode", "not-real"),
                token,
                null)
            .statusCode());
    assertEquals(409, call("POST", "/oauth/GMAIL/start", Json.map(), token, null).statusCode());
  }

  @Test
  void changesAreMonotonicAndOldGenerationExpires() throws Exception {
    var response = json(call("GET", "/changes", null, token, null));
    @SuppressWarnings("unchecked")
    var changes = (List<Map<String, Object>>) response.get("items");
    long previous = 0;
    for (var c : changes) {
      assertTrue(((Number) c.get("seq")).longValue() > previous);
      previous = ((Number) c.get("seq")).longValue();
    }
    assertEquals(410, call("GET", "/changes?after=old:20", null, token, null).statusCode());
    assertEquals(
        0,
        items(call("GET", "/changes?after=" + response.get("nextCursor"), null, token, null))
            .size());
  }

  @Test
  void attachmentUploadDownloadAndFrozenSnapshot() throws Exception {
    var d = draft();
    String boundary = "mail-boundary";
    String data =
        "--"
            + boundary
            + "\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n"
            + "Content-Type: text/plain\r\n\r\n"
            + "synthetic attachment\r\n"
            + "--"
            + boundary
            + "--\r\n";
    var req =
        HttpRequest.newBuilder(
                URI.create(
                    "http://127.0.0.1:" + port + "/api/v1/drafts/" + d.get("id") + "/attachments"))
            .header("Authorization", "Bearer " + token)
            .header("Content-Type", "multipart/form-data; boundary=" + boundary)
            .POST(HttpRequest.BodyPublishers.ofString(data))
            .build();
    var upload = http.send(req, HttpResponse.BodyHandlers.ofString());
    assertEquals(200, upload.statusCode());
    String aid = (String) json(upload).get("id");
    assertEquals(
        "synthetic attachment",
        call("GET", "/attachments/" + aid + "/content", null, token, null).body());
    assertEquals(
        2, ((Number) mail.store.data("draft", (String) d.get("id")).get("revision")).intValue());
    call("POST", "/drafts/" + d.get("id") + "/send", Json.map("revision", 2), token, "with-file");
    call("DELETE", "/drafts/" + d.get("id"), null, token, null);
    assertTrue(worker.runOne());
    assertEquals(
        "synthetic attachment",
        call("GET", "/attachments/" + aid + "/content", null, token, null).body());
  }

  @Test
  void apiHeadersAndStaticDoNotRequireAuth() throws Exception {
    var health = call("GET", "/health", null, null, null);
    assertEquals("nosniff", health.headers().firstValue("X-Content-Type-Options").orElse(""));
    var root =
        http.send(
            HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/")).GET().build(),
            HttpResponse.BodyHandlers.ofString());
    assertNotEquals(401, root.statusCode());
    assertEquals(
        "frame-ancestors 'none'; object-src 'none'; base-uri 'self'",
        root.headers().firstValue("Content-Security-Policy").orElse(""));
    assertEquals("DENY", root.headers().firstValue("X-Frame-Options").orElse(""));
  }

  @Test
  void missingAttachmentReturnsNotFound() throws Exception {
    assertEquals(404, call("GET", "/attachments/missing/content", null, token, null).statusCode());
  }

  @Test
  void concurrentCommandsShareOneDurableIntent() throws Exception {
    var body =
        Json.map("type", "SET_STAR", "messageId", "demo-0-0", "baseRevision", 1, "value", true);
    try (var executor = java.util.concurrent.Executors.newFixedThreadPool(4)) {
      var futures = new ArrayList<java.util.concurrent.Future<String>>();
      for (int i = 0; i < 4; i++)
        futures.add(
            executor.submit(
                () -> {
                  var response = call("POST", "/commands", body, token, "concurrent");
                  assertEquals(202, response.statusCode());
                  return (String) json(response).get("id");
                }));
      String id = futures.getFirst().get();
      for (var f : futures) assertEquals(id, f.get());
      assertEquals(
          1,
          store.db.queryForObject("SELECT COUNT(*) FROM job WHERE kind='COMMAND'", Integer.class));
    }
  }

  @Test
  void preparingSendCanResumeWithoutResubmittingAmbiguousWork() throws Exception {
    var d = draft();
    var intent =
        json(
            call(
                "POST",
                "/drafts/" + d.get("id") + "/send",
                Json.map("revision", 1),
                token,
                "preparing"));
    store.db.update("UPDATE job SET status='PREPARING' WHERE id=?", intent.get("id"));
    mail.seed();
    assertEquals("QUEUED", mail.job((String) intent.get("id"), "SEND").get("status"));
    assertTrue(worker.runOne());
    assertEquals("SENT_COPY_CONFIRMED", mail.job((String) intent.get("id"), "SEND").get("status"));
  }

  @Test
  void oversizedLoginBodyRejectedBeforeParsing() throws Exception {
    assertEquals(
        413,
        call(
                "POST",
                "/auth/login",
                Json.map("username", "demo", "password", "x".repeat(5000)),
                null,
                null)
            .statusCode());
  }
}
