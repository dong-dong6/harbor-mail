package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import com.itdong.mail.provider.OAuthClient;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.net.URI;
import java.net.URLDecoder;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Real HTTP/auth/filter/controller/database path, with synthetic non-demo credentials only. */
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "mail.demo=false",
      "server.address=127.0.0.1",
      "mail.admin-username=oauth-test-admin",
      "mail.admin-password=synthetic-test-password-not-for-use",
      "mail.encryption-key=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=",
      "mail.allowed-origin=https://mail.example.test",
      "mail.worker-enabled=false",
      "MAIL_OAUTH_GMAIL_CLIENT_ID=environment-gmail-client",
      "MAIL_OAUTH_GMAIL_CLIENT_SECRET=environment-gmail-secret-fixture",
      "MAIL_OAUTH_GMAIL_REDIRECT_URI=https://mail.example.test/api/v1/oauth/GMAIL/callback",
      "MAIL_OAUTH_GMAIL_TENANT=",
      "MAIL_OAUTH_OUTLOOK_CLIENT_ID=environment-outlook-client",
      "MAIL_OAUTH_OUTLOOK_CLIENT_SECRET=environment-outlook-secret-fixture",
      "MAIL_OAUTH_OUTLOOK_REDIRECT_URI=https://mail.example.test/api/v1/oauth/OUTLOOK/callback",
      "MAIL_OAUTH_OUTLOOK_TENANT=consumers",
      "MAIL_OAUTH_EXCHANGE_CLIENT_ID=",
      "MAIL_OAUTH_EXCHANGE_CLIENT_SECRET=",
      "MAIL_OAUTH_EXCHANGE_REDIRECT_URI=",
      "MAIL_OAUTH_EXCHANGE_TENANT=organizations"
    })
class OAuthSettingsApiTest {
  private static final String SCHEMA = "oauth_settings_test";
  static final String ENV_SECRET = "environment-gmail-secret-fixture";
  static final String DB_SECRET = "database-secret-fixture-rotate-me";
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired OAuthSettings settings;
  @Autowired OAuthService oauth;
  @Autowired org.springframework.core.env.Environment environment;
  final HttpClient http = HttpClient.newHttpClient();
  String token;

  @DynamicPropertySource
  static void database(DynamicPropertyRegistry registry) {
    // Keep the real-mode owner and encryption key isolated from MailApiTest's demo database.
    // PostgreSQL accepts a not-yet-created currentSchema; Flyway creates it before application init.
    String external = System.getenv("TEST_DATABASE_URL");
    String url = external == null || external.isBlank()
        ? "jdbc:h2:mem:oauthsettings;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1"
        : external;
    if (url.startsWith("jdbc:postgresql:")) {
      url = url.replaceAll("([?&])currentSchema=[^&]*&?", "$1");
      url += (url.contains("?") ? "&" : "?") + "currentSchema=" + SCHEMA;
      registry.add("spring.flyway.schemas", () -> SCHEMA);
      registry.add("spring.flyway.default-schema", () -> SCHEMA);
    } else if (external != null && !external.isBlank() && url.startsWith("jdbc:h2:")) {
      // An explicit H2 URL can also be shared with the demo suite without sharing tables.
      url += ";INIT=CREATE SCHEMA IF NOT EXISTS " + SCHEMA + "\\;SET SCHEMA " + SCHEMA;
      registry.add("spring.flyway.schemas", () -> SCHEMA);
      registry.add("spring.flyway.default-schema", () -> SCHEMA);
    }
    String finalUrl = url;
    registry.add("spring.datasource.url", () -> finalUrl);
    registry.add("spring.datasource.username", () -> System.getenv().getOrDefault("TEST_DATABASE_USER", "sa"));
    registry.add("spring.datasource.password", () -> System.getenv().getOrDefault("TEST_DATABASE_PASSWORD", ""));
  }

  @BeforeEach
  void reset() throws Exception {
    store.write(() -> {
      for (String table : List.of("remote_attachment", "attachment", "job", "draft", "mail_message",
          "mail_account", "change_log", "access_token", "oauth_state"))
        store.db.update("DELETE FROM " + table);
      store.db.update("UPDATE oauth_provider_settings SET source='ENVIRONMENT',revision=0,"
          + "client_id='',redirect_uri='',tenant='',client_secret=NULL");
      return null;
    });
    security.attempts.clear();
    var login = call("POST", "/auth/login", Json.map("username", "oauth-test-admin",
        "password", "synthetic-test-password-not-for-use"), null);
    assertEquals(200, login.statusCode(), login.body());
    token = (String) json(login).get("accessToken");
    assertFalse(security.demo);
  }

  HttpRequest request(String method, String path, Object body, String bearer) {
    var builder = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1" + path))
        .timeout(java.time.Duration.ofSeconds(10))
        .header("Content-Type", "application/json");
    if (bearer != null) builder.header("Authorization", "Bearer " + bearer);
    return builder.method(method, body == null ? HttpRequest.BodyPublishers.noBody()
        : HttpRequest.BodyPublishers.ofString(Json.encode(body))).build();
  }

  HttpResponse<String> call(String method, String path, Object body, String bearer) throws Exception {
    return http.send(request(method, path, body, bearer), HttpResponse.BodyHandlers.ofString());
  }

  Map<String, Object> json(HttpResponse<String> response) { return Json.decode(response.body()); }

  @SuppressWarnings("unchecked")
  List<Map<String, Object>> items(HttpResponse<String> response) {
    return (List<Map<String, Object>>) json(response).get("items");
  }

  Map<String, Object> metadata(String provider) throws Exception {
    var result = call("GET", "/settings/oauth", null, token);
    assertEquals(200, result.statusCode(), result.body());
    return items(result).stream().filter(i -> provider.equals(i.get("provider"))).findFirst().orElseThrow();
  }

  Map<String, Object> body(String provider, long revision) {
    return Json.map("revision", revision, "clientId", "database-" + provider.toLowerCase(Locale.ROOT) + "-client",
        "redirectUri", "https://mail.example.test/api/v1/oauth/" + provider + "/callback",
        "tenant", switch (provider) { case "OUTLOOK" -> "consumers"; case "EXCHANGE" -> "organizations"; default -> ""; });
  }

  HttpResponse<String> save(String provider, Map<String, Object> body) throws Exception {
    return call("PUT", "/settings/oauth/" + provider, body, token);
  }

  void assertError(HttpResponse<String> response, int status, String code) {
    assertEquals(status, response.statusCode(), response.body());
    assertEquals(code, ((Map<?, ?>) json(response).get("error")).get("code"), response.body());
    assertFalse(response.body().contains(ENV_SECRET));
    assertFalse(response.body().contains(DB_SECRET));
  }

  void assertNoSecrets(HttpResponse<String> response) {
    assertFalse(response.body().contains(ENV_SECRET), response.body());
    assertFalse(response.body().contains(DB_SECRET), response.body());
    assertFalse(response.body().contains("environment-outlook-secret-fixture"), response.body());
    assertFalse(response.body().contains("\"clientSecret\""), response.body());
    assertFalse(response.body().contains("client_secret"), response.body());
    assertFalse(response.body().contains("configFingerprint"), response.body());
  }

  String encryptedSecret(String provider) {
    return (String) store.one("SELECT client_secret FROM oauth_provider_settings WHERE provider=?", provider)
        .get("client_secret");
  }

  @Test
  void adminSettingsRequireUnexpiredUnrevokedBearerForEveryOperation() throws Exception {
    for (String bearer : Arrays.asList(null, "not-a-valid-token")) {
      assertError(call("GET", "/settings/oauth", null, bearer), 401, "UNAUTHORIZED");
      assertError(call("PUT", "/settings/oauth/GMAIL", body("GMAIL", 0), bearer), 401, "UNAUTHORIZED");
      assertError(call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 0), bearer), 401, "UNAUTHORIZED");
    }
    store.db.update("UPDATE access_token SET expires_at=0 WHERE token_hash=?", Security.hash(token));
    assertError(call("GET", "/settings/oauth", null, token), 401, "UNAUTHORIZED");
    store.db.update("UPDATE access_token SET expires_at=? WHERE token_hash=?", System.currentTimeMillis() + 60_000, Security.hash(token));
    assertEquals(204, call("POST", "/auth/logout", null, token).statusCode());
    assertError(call("GET", "/settings/oauth", null, token), 401, "UNAUTHORIZED");
    assertEquals(0L, ((Number) settings.effective("GMAIL").metadata().get("revision")).longValue());
  }

  @Test
  void environmentMetadataIsUsefulAndNeverDisclosesSecrets() throws Exception {
    var result = call("GET", "/settings/oauth", null, token);
    assertEquals(200, result.statusCode(), result.body());
    assertEquals(false, json(result).get("demoMode"));
    assertEquals(false, json(result).get("readOnly"));
    assertEquals(Set.of("GMAIL", "OUTLOOK", "EXCHANGE"),
        new HashSet<>(items(result).stream().map(i -> i.get("provider")).toList()));
    var gmail = metadata("GMAIL");
    assertEquals("ENVIRONMENT", gmail.get("source"));
    assertEquals(0, ((Number) gmail.get("revision")).intValue());
    assertEquals("environment-gmail-client", gmail.get("clientId"));
    assertEquals(true, gmail.get("hasClientSecret"));
    assertEquals(true, gmail.get("configured"));
    assertEquals(List.of(), gmail.get("validationErrors"));
    assertEquals("consumers", metadata("OUTLOOK").get("tenant"));
    assertEquals(false, metadata("EXCHANGE").get("configured"));
    assertEquals(false, metadata("EXCHANGE").get("hasClientSecret"));
    assertFalse(((List<?>) metadata("EXCHANGE").get("validationErrors")).isEmpty());
    assertEquals("no-store", result.headers().firstValue("Cache-Control").orElse(""));
    assertNoSecrets(result);
    assertNoSecrets(call("GET", "/settings/capabilities", null, token));
    assertNull(encryptedSecret("GMAIL"), "Reading env settings must not copy secrets into the DB");
    assertFalse(settings.effective("GMAIL").toString().contains(ENV_SECRET));
  }

  @Test
  void savedSecretIsAuthenticatedEncryptionAndNeverReturned() throws Exception {
    var body = body("GMAIL", 0);
    body.put("clientSecret", DB_SECRET);
    var saved = save("GMAIL", body);
    assertEquals(200, saved.statusCode(), saved.body());
    assertEquals("DATABASE", json(saved).get("source"));
    assertEquals(1, ((Number) json(saved).get("revision")).intValue());
    assertEquals(true, json(saved).get("hasClientSecret"));
    assertNoSecrets(saved);
    assertNoSecrets(call("GET", "/settings/oauth", null, token));
    String ciphertext = encryptedSecret("GMAIL");
    assertNotEquals(DB_SECRET, ciphertext);
    assertFalse(ciphertext.contains(DB_SECRET));
    assertEquals(DB_SECRET, security.decrypt(ciphertext));
    assertEquals(DB_SECRET, oauth.config("GMAIL").clientSecret());
    body.put("revision", 1);
    var again = save("GMAIL", body);
    assertEquals(200, again.statusCode(), again.body());
    assertNotEquals(ciphertext, encryptedSecret("GMAIL"), "Encryption must use a new nonce per save");
    assertFalse(store.db.queryForList("SELECT * FROM change_log").toString().contains(DB_SECRET));
  }

  @Test
  void omittedAndBlankSecretPreserveEffectiveSecretButClearNeverFallsBackToEnvironment() throws Exception {
    var body = body("GMAIL", 0);
    assertEquals(200, save("GMAIL", body).statusCode());
    assertEquals(ENV_SECRET, security.decrypt(encryptedSecret("GMAIL")));
    body.put("revision", 1);
    body.put("clientSecret", DB_SECRET);
    assertEquals(200, save("GMAIL", body).statusCode());
    for (String blank : List.of("", "   ")) {
      body.put("revision", ((Number) metadata("GMAIL").get("revision")).longValue());
      body.put("clientSecret", blank);
      assertEquals(200, save("GMAIL", body).statusCode());
      assertEquals(DB_SECRET, security.decrypt(encryptedSecret("GMAIL")));
    }
    body.put("revision", ((Number) metadata("GMAIL").get("revision")).longValue());
    body.put("clearClientSecret", true);
    var cleared = save("GMAIL", body);
    assertEquals(200, cleared.statusCode(), cleared.body());
    assertEquals("DATABASE", json(cleared).get("source"));
    assertEquals(false, json(cleared).get("hasClientSecret"));
    assertEquals(false, json(cleared).get("configured"));
    assertNull(encryptedSecret("GMAIL"));
    assertError(call("POST", "/oauth/GMAIL/start", null, token), 409, "PROVIDER_NOT_CONFIGURED");
    body.remove("clearClientSecret");
    body.remove("clientSecret");
    body.put("revision", ((Number) metadata("GMAIL").get("revision")).longValue());
    assertEquals(200, save("GMAIL", body).statusCode());
    assertNull(encryptedSecret("GMAIL"), "An omitted secret must not resurrect an explicitly cleared secret");
  }

  @Test
  void resetRestoresEnvironmentAndRevisionCannotBeReused() throws Exception {
    var body = body("GMAIL", 0);
    body.put("clientSecret", DB_SECRET);
    assertEquals(200, save("GMAIL", body).statusCode());
    assertError(call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 0), token),
        409, "CONFIG_REVISION_CONFLICT");
    var reset = call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 1), token);
    assertEquals(200, reset.statusCode(), reset.body());
    assertEquals("ENVIRONMENT", json(reset).get("source"));
    assertEquals(2, ((Number) json(reset).get("revision")).intValue());
    assertEquals("environment-gmail-client", json(reset).get("clientId"));
    assertEquals(ENV_SECRET, oauth.config("GMAIL").clientSecret());
    assertNull(encryptedSecret("GMAIL"));
    assertNoSecrets(reset);
    assertError(save("GMAIL", body), 409, "CONFIG_REVISION_CONFLICT");
    assertError(call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 1), token),
        409, "CONFIG_REVISION_CONFLICT");
  }

  @Test
  void concurrentEditorsCannotBothSaveTheSameRevision() throws Exception {
    var first = body("GMAIL", 0);
    first.put("clientId", "first-editor");
    var second = body("GMAIL", 0);
    second.put("clientId", "second-editor");
    var a = http.sendAsync(request("PUT", "/settings/oauth/GMAIL", first, token), HttpResponse.BodyHandlers.ofString());
    var b = http.sendAsync(request("PUT", "/settings/oauth/GMAIL", second, token), HttpResponse.BodyHandlers.ofString());
    var replies = List.of(a.get(15, TimeUnit.SECONDS), b.get(15, TimeUnit.SECONDS));
    assertEquals(List.of(200, 409), replies.stream().map(HttpResponse::statusCode).sorted().toList());
    assertError(replies.stream().filter(r -> r.statusCode() == 409).findFirst().orElseThrow(),
        409, "CONFIG_REVISION_CONFLICT");
    var winner = json(replies.stream().filter(r -> r.statusCode() == 200).findFirst().orElseThrow());
    assertEquals(winner.get("clientId"), metadata("GMAIL").get("clientId"));
    assertEquals(1, ((Number) metadata("GMAIL").get("revision")).intValue());
  }

  @ParameterizedTest
  @ValueSource(strings = {"QQ", "NETEASE", "gmail", "UNKNOWN"})
  void nonOAuthAndUnknownProvidersAreRejected(String provider) throws Exception {
    assertError(save(provider, body("GMAIL", 0)), 400, "INVALID_REQUEST");
    assertError(call("POST", "/settings/oauth/" + provider + "/reset", Json.map("revision", 0), token),
        400, "INVALID_REQUEST");
  }

  @ParameterizedTest
  @ValueSource(strings = {
    "http://mail.example.test/api/v1/oauth/GMAIL/callback",
    "https://mail.example.test/callback",
    "https://mail.example.test/api/v1/oauth/OUTLOOK/callback",
    "https://mail.example.test/api/v1/oauth/GMAIL/callback/",
    "https://mail.example.test/api/v1/oauth/GMAIL/%63allback",
    "https://mail.example.test/api/v1/oauth/GMAIL/../GMAIL/callback",
    "https://user:password@mail.example.test/api/v1/oauth/GMAIL/callback",
    "https://mail.example.test/api/v1/oauth/GMAIL/callback?x=1",
    "https://mail.example.test/api/v1/oauth/GMAIL/callback#fragment",
    "https://mail.example.test:99999/api/v1/oauth/GMAIL/callback",
    "javascript:alert(1)", "not a URI"
  })
  void callbackMustBeHttpsAndExactProviderPath(String redirect) throws Exception {
    var body = body("GMAIL", 0);
    body.put("redirectUri", redirect);
    assertError(save("GMAIL", body), 400, "INVALID_REQUEST");
    assertEquals(0, ((Number) metadata("GMAIL").get("revision")).intValue());
  }

  @Test
  void missingFieldsWrongTypesControlCharactersAndAmbiguousSecretsAreRejected() throws Exception {
    var bad = new ArrayList<Map<String, Object>>();
    for (String field : List.of("revision", "clientId", "redirectUri")) {
      var body = body("GMAIL", 0); body.remove(field); bad.add(body);
    }
    for (Object invalid : Arrays.asList(-1, 1.25, "0", true, null, Long.MAX_VALUE)) {
      var body = body("GMAIL", 0); body.put("revision", invalid); bad.add(body);
    }
    for (var entry : List.of(
        Map.entry("clientId", (Object) "bad\nclient"), Map.entry("clientId", (Object) "x".repeat(1025)),
        Map.entry("clientId", (Object) 42), Map.entry("clientSecret", (Object) "bad\rsecret"),
        Map.entry("clientSecret", (Object) "x".repeat(8193)), Map.entry("clearClientSecret", (Object) "true"),
        Map.entry("unexpected", (Object) "should-not-be-accepted"))) {
      var body = body("GMAIL", 0); body.put(entry.getKey(), entry.getValue()); bad.add(body);
    }
    var both = body("GMAIL", 0); both.put("clientSecret", DB_SECRET); both.put("clearClientSecret", true); bad.add(both);
    for (var invalid : bad) assertError(save("GMAIL", invalid), 400, "INVALID_REQUEST");
    assertError(call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 0, "clientSecret", DB_SECRET), token),
        400, "INVALID_REQUEST");
    assertEquals(0, ((Number) metadata("GMAIL").get("revision")).intValue());
    assertNull(encryptedSecret("GMAIL"));
  }

  @Test
  void providerTenantsAreStrictAndExchangeTenantCanBeDomainOrUuid() throws Exception {
    for (String provider : List.of("GMAIL", "OUTLOOK", "EXCHANGE")) {
      for (String invalid : List.of("common", "../../evil", "evil.test/path", "bad\ntenant")) {
        var body = body(provider, 0); body.put("tenant", invalid);
        assertError(save(provider, body), 400, "INVALID_REQUEST");
      }
    }
    var gmail = body("GMAIL", 0); gmail.put("tenant", "consumers");
    assertError(save("GMAIL", gmail), 400, "INVALID_REQUEST");
    var outlook = body("OUTLOOK", 0); outlook.put("tenant", "organizations");
    assertError(save("OUTLOOK", outlook), 400, "INVALID_REQUEST");
    var exchange = body("EXCHANGE", 0); exchange.put("clientSecret", DB_SECRET);
    for (String valid : List.of("organizations", "EXAMPLE.onmicrosoft.com", "a0b1c2d3-4444-5555-6666-777788889999")) {
      exchange.put("tenant", valid);
      exchange.put("revision", ((Number) metadata("EXCHANGE").get("revision")).longValue());
      var saved = save("EXCHANGE", exchange);
      assertEquals(200, saved.statusCode(), saved.body());
      assertEquals(valid.toLowerCase(Locale.ROOT), json(saved).get("tenant"));
      assertEquals(true, json(saved).get("configured"));
    }
  }

  @Test
  void allowedOriginCanPreflightPutButOtherOriginsCannot() throws Exception {
    var preflight = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1/settings/oauth/GMAIL"))
        .header("Origin", "https://mail.example.test")
        .header("Access-Control-Request-Method", "PUT")
        .header("Access-Control-Request-Headers", "authorization,content-type")
        .method("OPTIONS", HttpRequest.BodyPublishers.noBody()).build();
    var result = http.send(preflight, HttpResponse.BodyHandlers.ofString());
    assertEquals(204, result.statusCode());
    assertEquals("https://mail.example.test", result.headers().firstValue("Access-Control-Allow-Origin").orElse(""));
    assertTrue(Arrays.asList(result.headers().firstValue("Access-Control-Allow-Methods").orElse("").split(",")).contains("PUT"));
    var rejected = HttpRequest.newBuilder(preflight.uri()).header("Origin", "https://untrusted.example.test")
        .header("Access-Control-Request-Method", "PUT").method("OPTIONS", HttpRequest.BodyPublishers.noBody()).build();
    var denied = http.send(rejected, HttpResponse.BodyHandlers.ofString());
    assertEquals(403, denied.statusCode());
    assertTrue(denied.headers().firstValue("Access-Control-Allow-Origin").isEmpty());
  }

  @Test
  void savedSettingsImmediatelyDriveCapabilitiesAndPkceAuthorization() throws Exception {
    var body = body("EXCHANGE", 0);
    body.put("tenant", "example.onmicrosoft.com");
    body.put("clientSecret", DB_SECRET);
    assertEquals(200, save("EXCHANGE", body).statusCode());
    var start = call("POST", "/oauth/EXCHANGE/start", null, token);
    assertEquals(200, start.statusCode(), start.body());
    assertNoSecrets(start);
    URI url = URI.create((String) json(start).get("authorizationUrl"));
    assertEquals("login.microsoftonline.com", url.getHost());
    assertEquals("/example.onmicrosoft.com/oauth2/v2.0/authorize", url.getPath());
    var query = query(url);
    assertEquals(body.get("clientId"), query.get("client_id"));
    assertEquals(body.get("redirectUri"), query.get("redirect_uri"));
    assertEquals("S256", query.get("code_challenge_method"));
    assertFalse(query.containsKey("client_secret"));
    String state = query.get("state");
    var stored = store.one("SELECT * FROM oauth_state WHERE state_hash=?", Security.hash(state));
    assertFalse(stored.toString().contains(state));
    var stateData = Json.decode(security.decrypt((String) stored.get("payload")));
    assertFalse(Json.string(stateData, "verifier").isBlank());
    assertFalse(Json.string(stateData, "configFingerprint").isBlank());
    assertFalse(stored.toString().contains(Json.string(stateData, "verifier")));
    var caps = json(call("GET", "/settings/capabilities", null, token));
    var providers = (List<?>) caps.get("providers");
    var exchange = providers.stream().map(x -> (Map<?, ?>) x).filter(x -> "EXCHANGE".equals(x.get("provider"))).findFirst().orElseThrow();
    assertEquals(true, exchange.get("configured"));
  }

  static Map<String, String> query(URI uri) {
    Map<String, String> result = new LinkedHashMap<>();
    for (String pair : uri.getRawQuery().split("&")) {
      String[] pieces = pair.split("=", 2);
      result.put(URLDecoder.decode(pieces[0], StandardCharsets.UTF_8),
          URLDecoder.decode(pieces.length == 2 ? pieces[1] : "", StandardCharsets.UTF_8));
    }
    return result;
  }

  void account(String id, String provider, boolean fingerprint) {
    var data = Json.map("id", id, "provider", provider, "email", id + "@example.test", "displayName", id,
        "status", "READY", "lastSyncAt", "2026-01-01T00:00:00Z", "unreadCount", 1, "errorCode", null);
    var secret = Json.map("accessToken", "existing-access-" + id, "refreshToken", "existing-refresh-" + id,
        "expiresAt", Instant.now().plusSeconds(3600).toString(), "scope", "fixture-scope");
    if (fingerprint) secret.put("configFingerprint", settings.effective(provider).fingerprint());
    store.db.update("INSERT INTO mail_account VALUES(?,?,?)", id, Json.encode(data), security.encrypt(Json.encode(secret)));
  }

  Map<String, Object> accountSecret(String id) {
    return Json.decode(security.decrypt((String) store.one("SELECT secret FROM mail_account WHERE id=?", id).get("secret")));
  }

  @Test
  void legacyEnvironmentAccountsSurviveUnchangedIdentityAndSecretRotation() throws Exception {
    account("legacy-gmail", "GMAIL", false);
    var accountBefore = store.data("mail_account", "legacy-gmail");
    var secretBefore = accountSecret("legacy-gmail");
    var body = body("GMAIL", 0);
    body.put("clientId", "environment-gmail-client");
    body.put("clientSecret", DB_SECRET);
    var saved = save("GMAIL", body);
    assertEquals(200, saved.statusCode(), saved.body());
    assertEquals(accountBefore, store.data("mail_account", "legacy-gmail"));
    var secretAfter = accountSecret("legacy-gmail");
    for (var entry : secretBefore.entrySet()) assertEquals(entry.getValue(), secretAfter.get(entry.getKey()));
    assertEquals(settings.effective("GMAIL").fingerprint(), secretAfter.get("configFingerprint"));
    assertEquals("existing-access-legacy-gmail", oauth.credentials("legacy-gmail").accessToken());
    assertNoSecrets(call("GET", "/accounts", null, token));
    assertFalse(call("GET", "/accounts", null, token).body().contains("existing-refresh-"));
  }

  @Test
  void changedApplicationRequiresReauthorizationWithoutDeletingAccountsOrTokens() throws Exception {
    account("gmail-account", "GMAIL", true);
    account("outlook-account", "OUTLOOK", true);
    var gmailBefore = accountSecret("gmail-account");
    var outlookBefore = store.data("mail_account", "outlook-account");
    var saved = save("GMAIL", body("GMAIL", 0));
    assertEquals(200, saved.statusCode(), saved.body());
    var changed = store.data("mail_account", "gmail-account");
    assertEquals("ERROR", changed.get("status"));
    assertEquals("REAUTH_REQUIRED", changed.get("errorCode"));
    assertEquals(gmailBefore, accountSecret("gmail-account"));
    assertEquals(outlookBefore, store.data("mail_account", "outlook-account"));
    assertEquals(2, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
    var error = assertThrows(ApiError.class, () -> oauth.credentials("gmail-account"));
    assertEquals("REAUTH_REQUIRED", error.code);
    assertEquals("existing-access-outlook-account", oauth.credentials("outlook-account").accessToken());
  }

  @Test
  void clearingSecretMarksOnlyAffectedProviderForReauthorization() throws Exception {
    account("gmail-account", "GMAIL", true);
    account("outlook-account", "OUTLOOK", true);
    var body = body("GMAIL", 0); body.put("clientId", "environment-gmail-client");
    body.put("clearClientSecret", true);
    assertEquals(200, save("GMAIL", body).statusCode());
    assertEquals("REAUTH_REQUIRED", store.data("mail_account", "gmail-account").get("errorCode"));
    assertEquals("READY", store.data("mail_account", "outlook-account").get("status"));
    assertEquals("existing-refresh-gmail-account", accountSecret("gmail-account").get("refreshToken"));
  }

  @Test
  void callbackRejectsChangedAppBeforeExchangeAndConsumesStateExactlyOnce() throws Exception {
    var started = call("POST", "/oauth/GMAIL/start", null, token);
    assertEquals(200, started.statusCode(), started.body());
    String state = query(URI.create((String) json(started).get("authorizationUrl"))).get("state");
    assertEquals(200, save("GMAIL", body("GMAIL", 0)).statusCode());
    // The real OAuth client must never contact Google: rejection happens before exchange.
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&code=synthetic-code", null, null),
        409, "OAUTH_CONFIG_CHANGED");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&code=synthetic-code", null, null),
        400, "INVALID_OAUTH_STATE");
  }

  @Test
  void stateIsProviderBoundExpiringAndDeniedAuthorizationIsNotReusable() throws Exception {
    var started = call("POST", "/oauth/GMAIL/start", null, token);
    String state = query(URI.create((String) json(started).get("authorizationUrl"))).get("state");
    assertError(call("GET", "/oauth/OUTLOOK/callback?state=" + state + "&error=access_denied", null, null),
        400, "INVALID_OAUTH_STATE");
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM oauth_state", Integer.class));
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&error=access_denied", null, null),
        400, "OAUTH_DENIED");
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&error=access_denied", null, null),
        400, "INVALID_OAUTH_STATE");
    started = call("POST", "/oauth/GMAIL/start", null, token);
    state = query(URI.create((String) json(started).get("authorizationUrl"))).get("state");
    store.db.update("UPDATE oauth_state SET expires_at=0");
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&error=access_denied", null, null),
        400, "INVALID_OAUTH_STATE");
  }

  /** Local provider fixture exercises real token HTTP requests without contacting external providers. */
  final class ProviderFixture implements AutoCloseable {
    final HttpServer server;
    final CountDownLatch reached = new CountDownLatch(1);
    final CountDownLatch release = new CountDownLatch(1);
    final AtomicInteger profileRequests = new AtomicInteger();
    final AtomicReference<String> tokenRequest = new AtomicReference<>();
    final OAuthService service;

    ProviderFixture(String blockedPath) throws Exception {
      server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
      server.createContext("/token", exchange -> {
        tokenRequest.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
        respond(exchange, "/token", blockedPath,
            "{\"access_token\":\"fixture-new-access\",\"refresh_token\":\"fixture-new-refresh\",\"expires_in\":3600}");
      });
      server.createContext("/profile", exchange -> {
        profileRequests.incrementAndGet();
        respond(exchange, "/profile", blockedPath, "{\"emailAddress\":\"gmail-account@example.test\"}");
      });
      server.start();
      var constructor = OAuthClient.class.getDeclaredConstructor(com.fasterxml.jackson.databind.ObjectMapper.class, String.class);
      constructor.setAccessible(true);
      var client = constructor.newInstance(Json.MAPPER, "http://127.0.0.1:" + server.getAddress().getPort());
      service = new OAuthService(store, security, settings, client);
    }

    void respond(com.sun.net.httpserver.HttpExchange exchange, String path, String blockedPath, String body)
        throws IOException {
      if (path.equals(blockedPath)) {
        reached.countDown();
        try {
          if (!release.await(10, TimeUnit.SECONDS)) throw new IOException("Timed out waiting for test mutation");
        } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException(e); }
      }
      byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
      exchange.getResponseHeaders().add("Content-Type", "application/json");
      exchange.sendResponseHeaders(200, bytes.length);
      exchange.getResponseBody().write(bytes);
      exchange.close();
    }

    String start() {
      return query(URI.create((String) service.start("GMAIL").get("authorizationUrl"))).get("state");
    }

    @Override public void close() {
      release.countDown();
      server.stop(0);
    }
  }

  @Test
  void callbackReturnsOnlyBoundCompletionMarkerAfterPersistence() throws Exception {
    String marker = "0123456789abcdef0123456789abcdef";
    try (var fixture = new ProviderFixture(null)) {
      var started = fixture.service.start("GMAIL", marker);
      String url = (String) started.get("authorizationUrl");
      assertFalse(url.contains(marker));
      String state = query(URI.create(url)).get("state");
      assertEquals(marker, fixture.service.callback("GMAIL", state, "synthetic-code", ""));
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
      assertThrows(ApiError.class, () -> fixture.service.callback("GMAIL", state, "synthetic-code", ""));
      assertEquals("", fixture.service.callback("GMAIL", fixture.start(), "synthetic-code", ""));
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
    }
  }

  @ParameterizedTest
  @ValueSource(strings = {"//evil.example", "https://evil.example", "<script>", "abc", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"})
  void invalidCompletionMarkerCannotStartAuthorization(String marker) throws Exception {
    assertError(call("POST", "/oauth/GMAIL/start", Json.map("completionId", marker), token),
        400, "INVALID_REQUEST");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM oauth_state", Integer.class));
  }

  @ParameterizedTest
  @ValueSource(strings = {"/token", "/profile"})
  void settingsChangeDuringCallbackNeverStoresTokensFromTheOldApplication(String blockedPath) throws Exception {
    account("gmail-account", "GMAIL", true);
    String before = (String) store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret");
    try (var fixture = new ProviderFixture(blockedPath); var executor = Executors.newVirtualThreadPerTaskExecutor()) {
      String state = fixture.start();
      var pending = executor.submit(() -> {
        fixture.service.callback("GMAIL", state, "synthetic-code", "");
        return null;
      });
      assertTrue(fixture.reached.await(5, TimeUnit.SECONDS), "Provider request did not start");
      var changed = save("GMAIL", body("GMAIL", 0));
      assertEquals(200, changed.statusCode(), changed.body());
      fixture.release.countDown();
      var failure = assertThrows(ExecutionException.class, () -> pending.get(5, TimeUnit.SECONDS));
      assertInstanceOf(ApiError.class, failure.getCause());
      assertEquals("OAUTH_CONFIG_CHANGED", ((ApiError) failure.getCause()).code);
      assertEquals(before, store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret"));
      assertEquals("REAUTH_REQUIRED", store.data("mail_account", "gmail-account").get("errorCode"));
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
      assertEquals(blockedPath.equals("/token") ? 0 : 1, fixture.profileRequests.get());
    }
  }

  @Test
  void successfulReauthorizationUpdatesExistingAccountAndPreservesItsMessages() throws Exception {
    account("gmail-account", "GMAIL", true);
    var labeled = store.data("mail_account", "gmail-account");
    labeled.put("displayName", "My custom mailbox label");
    labeled.put("lastSyncAt", "2026-01-01T00:00:00Z");
    store.db.update("UPDATE mail_account SET data=? WHERE id='gmail-account'", Json.encode(labeled));
    store.db.update("INSERT INTO mail_message(id,account_id,remote_id,data,revision,received_at,folder) VALUES(?,?,?,?,?,?,?)", "existing-message", "gmail-account", "remote-id",
        Json.encode(Json.map("id", "existing-message", "bodyText", "existing content")), 1, "2026-01-01T00:00:00Z", "INBOX");
    try (var fixture = new ProviderFixture(null)) {
      fixture.service.callback("GMAIL", fixture.start(), "synthetic-code", "");
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
      var stored = accountSecret("gmail-account");
      assertEquals("fixture-new-access", stored.get("accessToken"));
      assertEquals("fixture-new-refresh", stored.get("refreshToken"));
      assertEquals(settings.effective("GMAIL").fingerprint(), stored.get("configFingerprint"));
      assertEquals("NOT_SYNCED", store.data("mail_account", "gmail-account").get("status"));
      assertEquals("My custom mailbox label", store.data("mail_account", "gmail-account").get("displayName"));
      assertEquals("2026-01-01T00:00:00Z", store.data("mail_account", "gmail-account").get("lastSyncAt"));
      assertEquals("existing content", store.data("mail_message", "existing-message").get("bodyText"));
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_message", Integer.class));
      assertFalse(call("GET", "/accounts", null, token).body().contains("fixture-new-"));
    }
  }

  @Test
  void refreshInFlightCannotOverwriteNewlyReauthorizedTokens() throws Exception {
    account("gmail-account", "GMAIL", true);
    var expired = accountSecret("gmail-account");
    expired.put("expiresAt", Instant.now().minusSeconds(60).toString());
    store.db.update("UPDATE mail_account SET secret=? WHERE id='gmail-account'", security.encrypt(Json.encode(expired)));
    try (var fixture = new ProviderFixture("/token"); var executor = Executors.newVirtualThreadPerTaskExecutor()) {
      var pending = executor.submit(() -> fixture.service.credentials("gmail-account"));
      assertTrue(fixture.reached.await(5, TimeUnit.SECONDS), "Refresh request did not start");
      var reauthorized = accountSecret("gmail-account");
      reauthorized.put("accessToken", "concurrently-reauthorized-access");
      reauthorized.put("refreshToken", "concurrently-reauthorized-refresh");
      reauthorized.put("expiresAt", Instant.now().plusSeconds(3600).toString());
      String newCiphertext = security.encrypt(Json.encode(reauthorized));
      store.write(() -> {
        store.db.update("UPDATE mail_account SET secret=? WHERE id='gmail-account'", newCiphertext);
        return null;
      });
      fixture.release.countDown();
      var failure = assertThrows(ExecutionException.class, () -> pending.get(5, TimeUnit.SECONDS));
      assertInstanceOf(ApiError.class, failure.getCause());
      assertEquals("REAUTH_REQUIRED", ((ApiError) failure.getCause()).code);
      assertEquals(newCiphertext, store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret"));
      assertEquals("concurrently-reauthorized-access", fixture.service.credentials("gmail-account").accessToken());
    }
  }

  @Test
  void configurationChangeDuringRefreshKeepsExistingTokenRecord() throws Exception {
    account("gmail-account", "GMAIL", true);
    var expired = accountSecret("gmail-account");
    expired.put("expiresAt", Instant.now().minusSeconds(60).toString());
    String before = security.encrypt(Json.encode(expired));
    store.db.update("UPDATE mail_account SET secret=? WHERE id='gmail-account'", before);
    try (var fixture = new ProviderFixture("/token"); var executor = Executors.newVirtualThreadPerTaskExecutor()) {
      var pending = executor.submit(() -> fixture.service.credentials("gmail-account"));
      assertTrue(fixture.reached.await(5, TimeUnit.SECONDS));
      assertEquals(200, save("GMAIL", body("GMAIL", 0)).statusCode());
      fixture.release.countDown();
      var failure = assertThrows(ExecutionException.class, () -> pending.get(5, TimeUnit.SECONDS));
      assertInstanceOf(ApiError.class, failure.getCause());
      assertEquals("REAUTH_REQUIRED", ((ApiError) failure.getCause()).code);
      assertEquals(before, store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret"));
      assertEquals("REAUTH_REQUIRED", store.data("mail_account", "gmail-account").get("errorCode"));
    }
  }


  @Test
  void encryptedOverridesSurviveFreshSecurityAndSettingsInstances() throws Exception {
    var body = body("GMAIL", 0); body.put("clientSecret", DB_SECRET);
    assertEquals(200, save("GMAIL", body).statusCode());
    account("gmail-account", "GMAIL", true);
    String encryptedBefore = encryptedSecret("GMAIL");
    String tokenBefore = (String) store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret");
    var restartedSecurity = new Security(store, false, "oauth-test-admin", "synthetic-test-password-not-for-use",
        "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=", "127.0.0.1", "https://mail.example.test");
    restartedSecurity.init();
    var restartedSettings = new OAuthSettings(store, restartedSecurity, environment);
    restartedSettings.bindExistingEnvironmentTokens();
    var snapshot = restartedSettings.required("GMAIL");
    assertEquals("DATABASE", snapshot.source());
    assertEquals(1, snapshot.revision());
    assertEquals(DB_SECRET, snapshot.config().clientSecret());
    assertEquals(body.get("clientId"), snapshot.config().clientId());
    assertEquals(encryptedBefore, encryptedSecret("GMAIL"));
    assertEquals(tokenBefore, store.one("SELECT secret FROM mail_account WHERE id='gmail-account'").get("secret"));
    assertFalse(Json.encode(restartedSettings.list()).contains(DB_SECRET));
    assertEquals("existing-access-gmail-account",
        new OAuthService(store, restartedSecurity, restartedSettings).credentials("gmail-account").accessToken());
  }

  @ParameterizedTest
  @ValueSource(strings = {"save", "reset"})
  void storageFailureRollsBackSettingsAccountsSecretsAndChangeSequence(String operation) throws Exception {
    if (operation.equals("reset")) {
      var initial = body("GMAIL", 0); initial.put("clientSecret", DB_SECRET);
      assertEquals(200, save("GMAIL", initial).statusCode());
    }
    account("gmail-account", "GMAIL", operation.equals("reset"));
    var settingsBefore = store.one("SELECT * FROM oauth_provider_settings WHERE provider='GMAIL'");
    var accountBefore = store.one("SELECT * FROM mail_account WHERE id='gmail-account'");
    var sequenceBefore = store.one("SELECT seq FROM app_state WHERE id=1");
    store.db.update("DELETE FROM change_log WHERE type='OAUTH_SETTINGS'");
    int changesBefore = store.db.queryForObject("SELECT COUNT(*) FROM change_log", Integer.class);
    store.db.update("ALTER TABLE change_log ADD CONSTRAINT reject_oauth_settings_change CHECK (type <> 'OAUTH_SETTINGS')");
    try {
      var response = operation.equals("save") ? save("GMAIL", body("GMAIL", 0))
          : call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 1), token);
      assertError(response, 500, "INTERNAL_ERROR");
      assertEquals(settingsBefore, store.one("SELECT * FROM oauth_provider_settings WHERE provider='GMAIL'"));
      assertEquals(accountBefore, store.one("SELECT * FROM mail_account WHERE id='gmail-account'"));
      assertEquals(sequenceBefore, store.one("SELECT seq FROM app_state WHERE id=1"));
      assertEquals(changesBefore, store.db.queryForObject("SELECT COUNT(*) FROM change_log", Integer.class));
    } finally {
      store.db.update("ALTER TABLE change_log DROP CONSTRAINT reject_oauth_settings_change");
    }
  }

  @Test
  void legacyAuthorizationStateWithoutFingerprintCannotExchangeTokens() throws Exception {
    String state = security.token();
    store.db.update("INSERT INTO oauth_state VALUES(?,?,?,?)", Security.hash(state), "GMAIL",
        System.currentTimeMillis() + 60_000, security.encrypt(Json.encode(Json.map("verifier", "old-verifier", "owner", 1))));
    assertError(call("GET", "/oauth/GMAIL/callback?state=" + state + "&code=synthetic-code", null, null),
        409, "OAUTH_CONFIG_CHANGED");
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM oauth_state", Integer.class));
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
  }

  @Test
  void rotatingSecretBetweenStartAndCallbackUsesNewSecretWithoutChangingApplicationIdentity() throws Exception {
    try (var fixture = new ProviderFixture(null)) {
      String state = fixture.start();
      String fingerprint = settings.effective("GMAIL").fingerprint();
      var body = body("GMAIL", 0); body.put("clientId", "environment-gmail-client");
      body.put("clientSecret", DB_SECRET);
      assertEquals(200, save("GMAIL", body).statusCode());
      assertEquals(fingerprint, settings.effective("GMAIL").fingerprint());
      fixture.service.callback("GMAIL", state, "synthetic-code", "");
      assertTrue(fixture.tokenRequest.get().contains("client_secret=" + DB_SECRET));
      assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class));
      assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM oauth_state", Integer.class));
    }
  }


  @Test
  void resetToOriginalApplicationRestoresRetainedTokensWithoutHidingUnrelatedErrors() throws Exception {
    account("gmail-account", "GMAIL", true);
    var before = accountSecret("gmail-account");
    assertEquals(200, save("GMAIL", body("GMAIL", 0)).statusCode());
    assertEquals("REAUTH_REQUIRED", store.data("mail_account", "gmail-account").get("errorCode"));
    var reset = call("POST", "/settings/oauth/GMAIL/reset", Json.map("revision", 1), token);
    assertEquals(200, reset.statusCode(), reset.body());
    assertEquals("NOT_SYNCED", store.data("mail_account", "gmail-account").get("status"));
    assertNull(store.data("mail_account", "gmail-account").get("errorCode"));
    assertEquals(before, accountSecret("gmail-account"));
    assertEquals("existing-access-gmail-account", oauth.credentials("gmail-account").accessToken());
    var unrelated = store.data("mail_account", "gmail-account");
    unrelated.put("status", "ERROR"); unrelated.put("errorCode", "PROVIDER_RATE_LIMITED");
    store.db.update("UPDATE mail_account SET data=? WHERE id='gmail-account'", Json.encode(unrelated));
    var sameIdentity = body("GMAIL", 2); sameIdentity.put("clientId", "environment-gmail-client");
    assertEquals(200, save("GMAIL", sameIdentity).statusCode());
    assertEquals(unrelated, store.data("mail_account", "gmail-account"));
  }

  @Test
  void restoringClearedSecretForSameApplicationRestoresRetainedTokens() throws Exception {
    account("gmail-account", "GMAIL", true);
    var before = accountSecret("gmail-account");
    var body = body("GMAIL", 0); body.put("clientId", "environment-gmail-client");
    body.put("clearClientSecret", true);
    assertEquals(200, save("GMAIL", body).statusCode());
    assertEquals("REAUTH_REQUIRED", store.data("mail_account", "gmail-account").get("errorCode"));
    body.remove("clearClientSecret"); body.put("clientSecret", DB_SECRET); body.put("revision", 1);
    assertEquals(200, save("GMAIL", body).statusCode());
    assertEquals("NOT_SYNCED", store.data("mail_account", "gmail-account").get("status"));
    assertNull(store.data("mail_account", "gmail-account").get("errorCode"));
    assertEquals(before, accountSecret("gmail-account"));
    assertEquals("existing-access-gmail-account", oauth.credentials("gmail-account").accessToken());
  }


  @Test
  void incompleteDatabaseOverrideDoesNotFallBackPerFieldToEnvironment() throws Exception {
    var body = body("GMAIL", 0);
    body.put("clientId", ""); body.put("redirectUri", ""); body.put("clientSecret", DB_SECRET);
    var result = save("GMAIL", body);
    assertEquals(200, result.statusCode(), result.body());
    assertEquals("DATABASE", json(result).get("source"));
    assertEquals("", json(result).get("clientId"));
    assertEquals("", json(result).get("redirectUri"));
    assertEquals(false, json(result).get("configured"));
    assertEquals(true, json(result).get("hasClientSecret"));
    assertEquals(DB_SECRET, security.decrypt(encryptedSecret("GMAIL")));
    assertFalse(((List<?>) json(result).get("validationErrors")).isEmpty());
    assertError(call("POST", "/oauth/GMAIL/start", null, token), 409, "PROVIDER_NOT_CONFIGURED");
    assertNoSecrets(result);
  }

}
