package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.itdong.mail.provider.ProviderGateway;
import java.net.URI;
import java.net.http.*;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Isolated synthetic HTTP/database fixtures; no real mailbox or provider access. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {"mail.worker-enabled=false"})
@ActiveProfiles("demo")
class AccountSettingsApiTest {
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired MailService mail;
  final HttpClient http = HttpClient.newHttpClient();
  String token;

  @DynamicPropertySource
  static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "account_settings_test");
  }

  @BeforeEach void reset() throws Exception {
    store.write(() -> {
      for (String table : List.of("remote_attachment", "attachment", "job", "draft",
          "mail_message", "mail_account", "change_log", "access_token", "oauth_state"))
        store.db.update("DELETE FROM " + table);
      return null;
    });
    security.attempts.clear();
    mail.seed();
    token = (String) Json.decode(call("POST", "/auth/login",
        Json.map("username", "demo", "password", "demo-local-only"), null).body()).get("accessToken");
  }

  HttpResponse<String> call(String method, String path, Object body, String bearer) throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1" + path))
        .header("Content-Type", "application/json");
    if (bearer != null) request.header("Authorization", "Bearer " + bearer);
    return http.send(request.method(method, body == null ? HttpRequest.BodyPublishers.noBody()
        : HttpRequest.BodyPublishers.ofString(Json.encode(body))).build(), HttpResponse.BodyHandlers.ofString());
  }

  String error(HttpResponse<String> response) {
    return (String) ((Map<?, ?>) Json.decode(response.body()).get("error")).get("code");
  }

  Map<String, Object> draft(String account) {
    return mail.saveDraft(null, Json.map("accountId", account, "to",
        List.of(Json.map("address", "recipient@example.invalid")), "subject", "Synthetic", "bodyText", "Fixture"));
  }

  String upload(String draft) {
    return (String) mail.upload(draft,
        new MockMultipartFile("file", "fixture.txt", "text/plain", new byte[] {1, 2, 3})).get("id");
  }

  void job(String kind, String status, String code) {
    store.write(() -> {
      mail.insertJob("fixture-job", kind, "demo-gmail", "fixture-key", "fixture-hash", status, Json.map());
      store.db.update("UPDATE job SET error_code=? WHERE id='fixture-job'", code);
      return null;
    });
  }

  MailService connected(ProviderGateway gateway) {
    return new MailService(store, new Security(store, false, "", "", "", "127.0.0.1", ""), null, gateway) {
      @Override ProviderGateway.Credentials credentials(String id) {
        return new ProviderGateway.Credentials("GMAIL", "owner@example.invalid", "synthetic-token", null);
      }
    };
  }

  @Test void managementRequiresAuthenticationAndMissingAccountsAre404() throws Exception {
    assertEquals(401, call("GET", "/accounts", null, null).statusCode());
    assertEquals(401, call("PATCH", "/accounts/demo-gmail", Json.map("displayName", "New"), null).statusCode());
    assertEquals(401, call("DELETE", "/accounts/demo-gmail", null, null).statusCode());
    assertEquals(404, call("PATCH", "/accounts/missing", Json.map("displayName", "New"), token).statusCode());
    assertEquals(404, call("DELETE", "/accounts/missing", null, token).statusCode());
    assertNotNull(mail.account("demo-gmail"));
  }

  @Test void safeProjectionAndRenamePreserveCredentials() throws Exception {
    var stored = mail.account("demo-gmail");
    stored.put("accessToken", "synthetic-private-token");
    stored.put("authorizationCode", "synthetic-private-code");
    store.db.update("UPDATE mail_account SET data=? WHERE id='demo-gmail'", Json.encode(stored));
    String encrypted = (String) store.one("SELECT secret FROM mail_account WHERE id='demo-gmail'").get("secret");
    var response = call("PATCH", "/accounts/demo-gmail", Json.map("displayName", "  我的工作邮箱  "), token);
    assertEquals(200, response.statusCode());
    var metadata = Json.decode(response.body());
    assertEquals("我的工作邮箱", metadata.get("displayName"));
    assertEquals(true, metadata.get("canDisconnect"));
    assertNull(metadata.get("disconnectBlockedReason"));
    assertEquals(Set.of("id", "provider", "email", "displayName", "status", "lastSyncAt",
        "unreadCount", "errorCode", "canDisconnect", "disconnectBlockedReason"), metadata.keySet());
    assertFalse(response.body().contains("synthetic-private"));
    assertFalse(call("GET", "/accounts", null, token).body().contains("synthetic-private"));
    assertEquals(encrypted, store.one("SELECT secret FROM mail_account WHERE id='demo-gmail'").get("secret"));
    assertEquals(stored.get("email"), metadata.get("email"));
    assertEquals(stored.get("status"), metadata.get("status"));
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM change_log WHERE type='ACCOUNT' AND entity_id='demo-gmail'", Integer.class));
  }

  @Test void renameRejectsSecretsUnknownFieldsWrongTypesAndInvalidNames() throws Exception {
    var invalid = new ArrayList<Map<String, Object>>(List.of(Json.map(),
        Json.map("displayName", ""), Json.map("displayName", " \t "), Json.map("displayName", 123),
        Json.map("displayName", true), Json.map("displayName", List.of("x")),
        Json.map("displayName", "x".repeat(101)), Json.map("displayName", "a\nb"),
        Json.map("displayName", "a\rb"), Json.map("displayName", "a\u0000b"),
        Json.map("displayName", "a\u2028b"), Json.map("displayName", "ok", "email", "changed@example.invalid"),
        Json.map("displayName", "ok", "secret", "new-secret"), Json.map("displayName", "ok", "provider", "QQ")));
    invalid.add(Json.map("displayName", null));
    for (var body : invalid) {
      var response = call("PATCH", "/accounts/demo-gmail", body, token);
      assertEquals(400, response.statusCode(), body.toString());
      assertEquals("INVALID_REQUEST", error(response));
    }
    assertEquals("个人 Gmail", mail.account("demo-gmail").get("displayName"));
    assertEquals(200, call("PATCH", "/accounts/demo-gmail", Json.map("displayName", "x".repeat(100)), token).statusCode());
  }

  @ParameterizedTest
  @CsvSource({"SEND,QUEUED,", "SEND,PREPARING,", "SEND,SUBMITTING,", "SEND,UNKNOWN,",
      "SEND,RUNNING,", "SEND,FUTURE_STATE,", "SYNC,QUEUED,", "SYNC,RUNNING,", "SYNC,UNKNOWN,",
      "COMMAND,QUEUED,", "COMMAND,RUNNING,", "COMMAND,UNKNOWN,",
      "COMMAND,FAILED,RECONCILIATION_REQUIRED", "FUTURE_KIND,SUCCEEDED,"})
  void unsafeWorkBlocksDisconnectWithoutRemovingAnything(String kind, String status, String code) throws Exception {
    job(kind, status, code);
    var draft = draft("demo-gmail");
    String attachment = upload((String) draft.get("id"));
    var metadata = mail.accounts().stream().filter(a -> "demo-gmail".equals(a.get("id"))).findFirst().orElseThrow();
    assertEquals(false, metadata.get("canDisconnect"));
    assertEquals(MailService.ACCOUNT_BUSY_MESSAGE, metadata.get("disconnectBlockedReason"));
    var response = call("DELETE", "/accounts/demo-gmail", null, token);
    assertEquals(409, response.statusCode());
    assertEquals("ACCOUNT_BUSY", error(response));
    assertNotNull(mail.account("demo-gmail"));
    assertEquals(4, store.db.queryForObject("SELECT COUNT(*) FROM mail_message WHERE account_id='demo-gmail'", Integer.class));
    assertNotNull(store.data("draft", (String) draft.get("id")));
    assertArrayEquals(new byte[] {1, 2, 3}, mail.download(attachment).bytes());
    assertEquals(status, mail.job("fixture-job", kind).get("status"));
  }

  @ParameterizedTest
  @CsvSource({"SEND,ACCEPTED", "SEND,SENT_COPY_CONFIRMED", "SEND,FAILED", "SYNC,SUCCEEDED",
      "SYNC,FAILED", "COMMAND,SUCCEEDED", "COMMAND,FAILED"})
  void settledWorkAllowsDisconnect(String kind, String status) throws Exception {
    job(kind, status, null);
    assertEquals(204, call("DELETE", "/accounts/demo-gmail", null, token).statusCode());
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM job WHERE account_id='demo-gmail'", Integer.class));
  }

  @Test void disconnectRemovesOnlyLocalAccountDataAndDeletedDraftUploads() throws Exception {
    var current = draft("demo-gmail"); String currentUpload = upload((String) current.get("id"));
    var deleted = draft("demo-gmail"); String orphanUpload = upload((String) deleted.get("id"));
    mail.deleteDraft((String) deleted.get("id"));
    var other = draft("demo-outlook"); String otherUpload = upload((String) other.get("id"));
    store.db.update("INSERT INTO remote_attachment VALUES(?,?,?,?,?,?)", "remote-fixture", "demo-0-0",
        "provider-fixture", "remote.txt", "application/octet-stream", 3);
    job("SEND", "ACCEPTED", null);
    var response = call("DELETE", "/accounts/demo-gmail", null, token);
    assertEquals(204, response.statusCode()); assertEquals("", response.body());
    for (String table : List.of("mail_message", "draft", "job"))
      assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE account_id='demo-gmail'", Integer.class));
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM remote_attachment WHERE id='remote-fixture'", Integer.class));
    for (String id : List.of(currentUpload, orphanUpload))
      assertEquals(404, call("GET", "/attachments/" + id + "/content", null, token).statusCode());
    assertEquals(404, call("GET", "/messages/demo-0-0", null, token).statusCode());
    assertEquals(404, call("DELETE", "/accounts/demo-gmail", null, token).statusCode());
    assertEquals(404, call("POST", "/accounts/demo-gmail/sync", null, token).statusCode());
    assertEquals(4, mail.accounts().size());
    assertNotNull(store.data("draft", (String) other.get("id")));
    assertArrayEquals(new byte[] {1, 2, 3}, mail.download(otherUpload).bytes());
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM change_log WHERE type='ACCOUNT_DELETED' AND entity_id='demo-gmail'", Integer.class));
  }

  @Test void sharedUploadsTransferOwnershipAndSurviveUntilTheirLastAccountIsRemoved() {
    var draft = draft("demo-gmail"); String id = (String) draft.get("id"); String upload = upload(id);
    var latest = store.data("draft", id);
    String send = (String) mail.send(id, "send-fixture", Json.map("revision", latest.get("revision"))).get("id");
    store.db.update("UPDATE job SET status='ACCEPTED' WHERE id=?", send);
    store.db.update("DELETE FROM attachment_owner WHERE attachment_id=?", upload);
    mail.saveDraft(id, Json.map("accountId", "demo-outlook", "revision", latest.get("revision")));
    mail.disconnectAccount("demo-gmail");
    assertArrayEquals(new byte[] {1, 2, 3}, mail.download(upload).bytes());
    assertEquals("demo-outlook", store.one("SELECT account_id FROM attachment_owner WHERE attachment_id=?", upload).get("account_id"));
    mail.deleteDraft(id);
    mail.disconnectAccount("demo-outlook");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment WHERE id=?", Integer.class, upload));
  }

  @Test void aLegacyFrozenSnapshotRetainsOwnershipAfterItsDraftWasDeletedByOldCode() {
    var draft = draft("demo-gmail"); String id = (String) draft.get("id"); String upload = upload(id);
    var latest = store.data("draft", id);
    String send = (String) mail.send(id, "send-fixture", Json.map("revision", latest.get("revision"))).get("id");
    store.db.update("UPDATE job SET status='ACCEPTED' WHERE id=?", send);
    store.db.update("DELETE FROM attachment_owner WHERE attachment_id=?", upload);
    store.db.update("DELETE FROM draft WHERE id=?", id);
    mail.disconnectAccount("demo-gmail");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment WHERE id=?", Integer.class, upload));
  }

  @Test void concurrentSyncEnqueueAndDisconnectCannotLeaveAnOrphanJob() throws Exception {
    var barrier = new CyclicBarrier(2);
    try (var executor = Executors.newFixedThreadPool(2)) {
      var enqueue = executor.submit(() -> {
        barrier.await(); try { mail.sync("demo-gmail"); return 202; } catch (ApiError error) { return error.status; }
      });
      var remove = executor.submit(() -> {
        barrier.await(); try { mail.disconnectAccount("demo-gmail"); return 204; } catch (ApiError error) { return error.status; }
      });
      int syncStatus = enqueue.get(5, TimeUnit.SECONDS), deleteStatus = remove.get(5, TimeUnit.SECONDS);
      assertTrue((syncStatus == 202 && deleteStatus == 409) || (syncStatus == 404 && deleteStatus == 204));
      assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM job WHERE account_id NOT IN (SELECT id FROM mail_account)", Integer.class));
    }
  }

  @Test void runningProviderSyncBlocksDisconnectUntilSettledWithoutProviderCallsOnRemoval() throws Exception {
    var gateway = mock(ProviderGateway.class); var service = connected(gateway);
    var started = new CountDownLatch(1); var release = new CountDownLatch(1);
    when(gateway.sync(any(), anyString(), isNull(), eq(100))).thenAnswer(invocation -> {
      started.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS));
      return new ProviderGateway.SyncPage(List.of(), null, false, "PARTIAL");
    });
    service.sync("demo-gmail");
    try (var executor = Executors.newSingleThreadExecutor()) {
      var work = executor.submit(() -> new JobWorker(service, false).runOne());
      try { assertTrue(started.await(5, TimeUnit.SECONDS));
        assertEquals(409, call("DELETE", "/accounts/demo-gmail", null, token).statusCode());
      } finally { release.countDown(); }
      assertTrue(work.get(5, TimeUnit.SECONDS));
    }
    clearInvocations(gateway); service.disconnectAccount("demo-gmail"); verifyNoInteractions(gateway);
  }

  @Test void pollingSkipsAccountsRemovedAfterTheSnapshot() {
    var gateway = mock(ProviderGateway.class);
    var service = new MailService(store, new Security(store, false, "", "", "", "127.0.0.1", ""), null, gateway) {
      @Override List<Map<String, Object>> accounts() {
        var snapshot = List.of(Json.map("id", "demo-gmail", "status", "CONNECTED"),
            Json.map("id", "demo-outlook", "status", "CONNECTED"));
        disconnectAccount("demo-gmail"); return snapshot;
      }
    };
    assertDoesNotThrow(() -> new JobWorker(service, true).pollConnectedAccounts());
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM job WHERE account_id='demo-gmail'", Integer.class));
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM job WHERE account_id='demo-outlook' AND status='QUEUED'", Integer.class));
    verifyNoInteractions(gateway);
  }

  @Test void unownedUnreferencedLegacyOrphansAreNeverGuessedToBelongToAnAccount() {
    store.db.update("INSERT INTO attachment VALUES(?,?,?,?,?)", "unattributable", "legacy-deleted-draft",
        "legacy.txt", "application/octet-stream", new byte[] {4});
    mail.disconnectAccount("demo-gmail");
    assertArrayEquals(new byte[] {4}, mail.download("unattributable").bytes());
  }

  @Test void failedSyncSettlesAccountStatusBeforeDisconnectCanDeleteIt() throws Exception {
    var gateway = mock(ProviderGateway.class); var service = connected(gateway);
    when(gateway.sync(any(), anyString(), isNull(), eq(100)))
        .thenThrow(new com.itdong.mail.provider.ProviderException("FIXTURE_FAILED", false));
    var settled = new CountDownLatch(1); var release = new CountDownLatch(1);
    var worker = new JobWorker(service, false) {
      @Override void finish(String id, String status, String error) {
        super.finish(id, status, error); settled.countDown();
        try { assertTrue(release.await(5, TimeUnit.SECONDS)); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new RuntimeException(e); }
      }
    };
    service.sync("demo-gmail");
    try (var executor = Executors.newFixedThreadPool(2)) {
      var work = executor.submit(worker::runOne);
      try {
        assertTrue(settled.await(5, TimeUnit.SECONDS)); var deleting = new CountDownLatch(1);
        var deletion = executor.submit(() -> { deleting.countDown(); service.disconnectAccount("demo-gmail"); return true; });
        assertTrue(deleting.await(5, TimeUnit.SECONDS));
        assertThrows(TimeoutException.class, () -> deletion.get(150, TimeUnit.MILLISECONDS));
        release.countDown(); assertTrue(work.get(5, TimeUnit.SECONDS)); assertTrue(deletion.get(5, TimeUnit.SECONDS));
      } finally { release.countDown(); }
    }
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM mail_account WHERE id='demo-gmail'", Integer.class));
  }

  @Test void populatedMigrationPreservesFiveColumnUploadsAndOldFlywayStartup() throws Exception {
    String url = System.getenv().getOrDefault("TEST_DATABASE_URL",
        "jdbc:h2:mem:attachmentmigration;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1");
    String user = System.getenv().getOrDefault("TEST_DATABASE_USER", "sa");
    String password = System.getenv().getOrDefault("TEST_DATABASE_PASSWORD", "");
    String schema = url.startsWith("jdbc:postgresql:")
        ? "attachment_migration_" + UUID.randomUUID().toString().replace("-", "") : "public";
    if (url.startsWith("jdbc:postgresql:")) url += (url.contains("?") ? "&" : "?") + "currentSchema=" + schema;
    org.flywaydb.core.Flyway.configure().dataSource(url, user, password).schemas(schema).defaultSchema(schema)
        .locations("classpath:db/migration").target("4").load().migrate();
    try (var db = java.sql.DriverManager.getConnection(url, user, password); var statement = db.createStatement()) {
      statement.executeUpdate("INSERT INTO mail_account VALUES('legacy-account','{}','synthetic-encrypted')");
      statement.executeUpdate("INSERT INTO draft VALUES('legacy-draft','legacy-account','{}',1)");
      try (var insert = db.prepareStatement("INSERT INTO attachment VALUES(?,?,?,?,?)")) {
        for (String draft : List.of("legacy-draft", "deleted-draft")) {
          insert.setString(1, "upload-" + draft); insert.setString(2, draft); insert.setString(3, "fixture.txt");
          insert.setString(4, "application/octet-stream"); insert.setBytes(5, new byte[] {1, 2}); insert.executeUpdate();
        }
      }
      org.flywaydb.core.Flyway.configure().dataSource(url, user, password).schemas(schema).defaultSchema(schema)
          .locations("classpath:db/migration").load().migrate();
      try (var rows = statement.executeQuery("SELECT attachment_owner.account_id,attachment.content FROM attachment"
          + " JOIN attachment_owner ON attachment_owner.attachment_id=attachment.id WHERE attachment.id='upload-legacy-draft'")) {
        assertTrue(rows.next()); assertEquals("legacy-account", rows.getString(1));
        assertArrayEquals(new byte[] {1, 2}, rows.getBytes(2));
      }
      try (var rows = statement.executeQuery("SELECT account_id FROM attachment_owner WHERE attachment_id='upload-deleted-draft'")) {
        assertFalse(rows.next());
      }
      try (var insert = db.prepareStatement("INSERT INTO attachment VALUES(?,?,?,?,?)")) {
        insert.setString(1, "rollback-upload"); insert.setString(2, "legacy-draft"); insert.setString(3, "rollback.txt");
        insert.setString(4, "application/octet-stream"); insert.setBytes(5, new byte[] {3, 4});
        assertEquals(1, insert.executeUpdate());
      }
      try (var rows = statement.executeQuery("SELECT * FROM attachment WHERE id='rollback-upload'")) {
        assertEquals(5, rows.getMetaData().getColumnCount()); assertTrue(rows.next());
        assertArrayEquals(new byte[] {3, 4}, rows.getBytes("content"));
      }
      var oldMigrations = Files.createTempDirectory("old-mail-migrations-");
      try {
        for (String migration : List.of("V1__initial.sql", "V2__remote_attachments.sql",
            "V3__message_list_projection.sql", "V4__oauth_provider_settings.sql")) {
          try (var input = getClass().getResourceAsStream("/db/migration/" + migration)) {
            assertNotNull(input); Files.copy(input, oldMigrations.resolve(migration));
          }
        }
        var rollback = org.flywaydb.core.Flyway.configure().dataSource(url, user, password)
            .schemas(schema).defaultSchema(schema).locations("filesystem:" + oldMigrations).load();
        assertTrue(rollback.validateWithResult().validationSuccessful);
        assertEquals(0, rollback.migrate().migrationsExecuted);
      } finally {
        try (var files = Files.list(oldMigrations)) { for (var file : files.toList()) Files.delete(file); }
        Files.delete(oldMigrations);
      }
    }
  }

  @Test void rollbackUploadWithoutOwnershipIsRemovedThroughItsLiveDraft() {
    var draft = draft("demo-gmail");
    store.db.update("INSERT INTO attachment VALUES(?,?,?,?,?)", "rollback-live", draft.get("id"),
        "rollback.txt", "application/octet-stream", new byte[] {3});
    mail.disconnectAccount("demo-gmail");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment WHERE id='rollback-live'", Integer.class));
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment_owner WHERE account_id='demo-gmail'", Integer.class));
  }

  @Test void deletingRollbackDraftCapturesItsKnownOwnership() {
    var draft = draft("demo-gmail"); String id = (String) draft.get("id");
    store.db.update("INSERT INTO attachment VALUES(?,?,?,?,?)", "rollback-deleted", id,
        "rollback.txt", "application/octet-stream", new byte[] {3});
    mail.deleteDraft(id);
    assertEquals("demo-gmail", store.one("SELECT account_id FROM attachment_owner WHERE attachment_id='rollback-deleted'").get("account_id"));
    mail.disconnectAccount("demo-gmail");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment WHERE id='rollback-deleted'", Integer.class));
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM attachment_owner WHERE attachment_id='rollback-deleted'", Integer.class));
  }
}
