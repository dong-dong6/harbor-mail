package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.net.Socket;
import java.net.URI;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Disposable synthetic loopback HTTP and database fixtures only. Never enrolls a real device. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {"mail.worker-enabled=false", "mail.allowed-origin=https://mail.example.invalid:8443"})
@ActiveProfiles("demo")
class DevicePairingApiTest {
  @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "device_pairing_test");
  }
  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired DevicePairingService pairing;
  final HttpClient http = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
  String browser, otherBrowser;

  @BeforeEach void reset() {
    store.write(() -> {
      for (String table : List.of("device_pairing", "device_access_token", "paired_device", "access_token"))
        store.db.update("DELETE FROM " + table);
      return null;
    });
    security.attempts.clear(); pairing.publicAttempts.clear();
    browser = session(); otherBrowser = session();
  }

  String session() {
    String token = security.token();
    // Deliberately retain the existing legacy two-column insertion contract.
    store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token), System.currentTimeMillis() + 3_600_000);
    return token;
  }

  HttpResponse<String> call(String method, String path, Object body, String bearer) throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1" + path))
        .timeout(java.time.Duration.ofSeconds(15)).header("Content-Type", "application/json");
    if (bearer != null) request.header("Authorization", "Bearer " + bearer);
    return http.send(request.method(method, body == null ? HttpRequest.BodyPublishers.noBody()
        : HttpRequest.BodyPublishers.ofString(Json.encode(body))).build(), HttpResponse.BodyHandlers.ofString());
  }

  Map<String, Object> ok(HttpResponse<String> response) {
    assertEquals(200, response.statusCode(), response.body());
    assertEquals("no-store", response.headers().firstValue("Cache-Control").orElseThrow());
    return Json.decode(response.body());
  }
  String error(HttpResponse<String> response) { return (String) ((Map<?, ?>) Json.decode(response.body()).get("error")).get("code"); }

  record Fixture(String id, String secret, String verifier) {
    String path() { return "/auth/device-pairings/" + id; }
    Map<String, Object> claim() { return Json.map("pairingId", id, "secret", secret, "deviceName", "Synthetic Android", "codeChallenge", DevicePairingService.challenge(verifier)); }
    Map<String, Object> proof() { return Json.map("pairingId", id, "codeVerifier", verifier); }
  }
  Fixture create() throws Exception {
    var result = ok(call("POST", "/auth/device-pairings", Json.map(), browser));
    assertEquals("CREATED", result.get("state"));
    var qr = Json.decode((String) result.get("qrPayload"));
    return new Fixture((String) result.get("pairingId"), (String) qr.get("secret"), security.token());
  }
  String claim(Fixture f) throws Exception {
    var response = ok(call("POST", "/auth/device-pairings/claim", f.claim(), null));
    assertEquals("CLAIMED", response.get("state"));
    return (String) response.get("confirmationCode");
  }
  void approve(Fixture f, String code) throws Exception {
    assertEquals("APPROVED", ok(call("POST", f.path() + "/approve", Json.map("password", "demo-local-only", "confirmationCode", code), browser)).get("state"));
  }
  Map<String, Object> enroll(Fixture f) throws Exception {
    approve(f, claim(f));
    return ok(call("POST", "/auth/device-pairings/redeem", f.proof(), null));
  }

  @Test void completeFlowIssuesIndependentEightHourTokenAndSafeMetadata() throws Exception {
    long start = System.currentTimeMillis();
    var f = create();
    var raw = store.one("SELECT * FROM device_pairing WHERE id=?", f.id());
    assertEquals(Security.hash(f.secret()), raw.get("secret_hash"));
    assertFalse(raw.toString().contains(f.secret()));
    long expiry = ((Number) raw.get("expires_at")).longValue();
    assertTrue(expiry >= start + 120_000 && expiry <= System.currentTimeMillis() + 120_000);
    String code = claim(f);
    assertTrue(code.matches("[0-9]{6}"));
    var view = ok(call("GET", f.path(), null, browser));
    assertEquals(code, view.get("confirmationCode"));
    assertEquals("demo", view.get("accountName"));
    assertEquals("OWNER_FULL_ACCESS", view.get("permission"));
    assertFalse(Json.encode(view).contains(f.secret())); assertFalse(view.containsKey("qrPayload"));
    raw = store.one("SELECT * FROM device_pairing WHERE id=?", f.id());
    assertNull(raw.get("secret_hash")); assertFalse(raw.toString().contains(f.verifier()));
    assertEquals(DevicePairingService.challenge(f.verifier()), raw.get("code_challenge"));
    assertEquals(409, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
    assertEquals("CLAIMED", ok(call("POST", "/auth/device-pairings/poll", f.proof(), null)).get("state"));
    approve(f, code);
    long before = System.currentTimeMillis();
    var redeemed = ok(call("POST", "/auth/device-pairings/redeem", f.proof(), null));
    String token = (String) redeemed.get("accessToken");
    assertNotEquals(browser, token); assertNotEquals(f.secret(), token); assertNotEquals(f.verifier(), token);
    long tokenExpiry = Instant.parse((String) redeemed.get("expiresAt")).toEpochMilli();
    assertTrue(tokenExpiry >= before + DevicePairingService.DEVICE_LIFETIME);
    assertTrue(tokenExpiry <= System.currentTimeMillis() + DevicePairingService.DEVICE_LIFETIME);
    assertEquals(200, call("GET", "/accounts", null, token).statusCode());
    assertEquals(409, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
    var devices = ok(call("GET", "/auth/devices", null, browser));
    var device = (Map<?, ?>) ((List<?>) devices.get("items")).getFirst();
    assertEquals(Set.of("id", "name", "createdAt", "expiresAt", "lastSeenAt", "revoked", "permission"), device.keySet());
    assertEquals("Synthetic Android", device.get("name")); assertEquals(false, device.get("revoked"));
    assertFalse(Json.encode(devices).contains(token));
    assertEquals("REDEEMED", ok(call("GET", f.path(), null, browser)).get("state"));
  }

  @Test void qrDestinationUsesOnlyTrustedConfigNeverHeadersOrInput() throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1/auth/device-pairings"))
        .header("Authorization", "Bearer " + browser).header("Content-Type", "application/json")
        .header("Forwarded", "host=attacker.example;proto=http").header("X-Forwarded-Host", "attacker.example")
        .header("X-Forwarded-Proto", "http").POST(HttpRequest.BodyPublishers.ofString("{}")).build();
    var qr = Json.decode((String) ok(http.send(request, HttpResponse.BodyHandlers.ofString())).get("qrPayload"));
    assertEquals("https://mail.example.invalid:8443/api/v1", qr.get("serverUrl"));
    assertEquals(Set.of("type", "version", "serverUrl", "pairingId", "secret"), qr.keySet());
    assertEquals("harbor-mail-device-pairing", qr.get("type")); assertEquals(1, qr.get("version"));
    assertEquals(400, call("POST", "/auth/device-pairings", Json.map("serverUrl", "https://attacker.invalid"), browser).statusCode());
  }

  @Test void productionOriginValidationIsStrictAndDemoHttpIsLoopbackOnly() {
    for (String origin : List.of("", "http://mail.example", "https://user@host", "https://host/path", "https://host/",
        "https://host?x=1", "https://host#x", "https://host:", "https://host:0", "https://host:65536", "https://host:0443", "https://[fe80::1%25eth0]", "https://127.1", "https://0177.0.0.1", "https://0x7f000001", "https://host.", "https://HOST", "ftp://host")) {
      var p = new DevicePairingService(store, new Security(store, false, "", "", "", "127.0.0.1", origin));
      assertEquals("PAIRING_UNAVAILABLE", assertThrows(ApiError.class, p::serverUrl, origin).code);
    }
    for (String origin : List.of("http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080")) {
      var p = new DevicePairingService(store, new Security(store, true, "", "", "", "127.0.0.1", origin));
      assertEquals(origin + "/api/v1", p.serverUrl());
    }
    var p = new DevicePairingService(store, new Security(store, true, "", "", "", "127.0.0.1", "http://192.168.1.2"));
    assertThrows(ApiError.class, p::serverUrl);
  }

  @Test void ownerActionsRequireExactCreatorAndDeviceBearerCannotEnrollAnother() throws Exception {
    var f = create(); String code = claim(f);
    assertEquals(401, call("GET", f.path(), null, null).statusCode());
    assertEquals(404, call("GET", f.path(), null, otherBrowser).statusCode());
    assertEquals(404, call("POST", f.path() + "/reject", Json.map(), otherBrowser).statusCode());
    assertEquals(404, call("POST", f.path() + "/approve", Json.map("password", "demo-local-only", "confirmationCode", code), otherBrowser).statusCode());
    approve(f, code);
    var token = (String) ok(call("POST", "/auth/device-pairings/redeem", f.proof(), null)).get("accessToken");
    assertEquals(403, call("POST", "/auth/device-pairings", Json.map(), token).statusCode());
    assertEquals(403, call("GET", f.path(), null, token).statusCode());
    assertEquals(401, call("GET", "/auth/devices", null, null).statusCode());
    assertEquals(401, call("DELETE", "/auth/devices/" + Store.id(), null, null).statusCode());
  }

  @Test void proofRequiredForClaimPollAndRedeemAndQrCannotBeReplayed() throws Exception {
    var f = create();
    var wrong = f.claim(); wrong.put("secret", security.token());
    assertEquals(401, call("POST", "/auth/device-pairings/claim", wrong, null).statusCode());
    assertEquals(401, call("POST", "/auth/device-pairings/poll", f.proof(), null).statusCode());
    claim(f);
    assertEquals(401, call("POST", "/auth/device-pairings/claim", f.claim(), null).statusCode());
    var proof = Json.map("pairingId", f.id(), "codeVerifier", f.secret());
    assertEquals(401, call("POST", "/auth/device-pairings/poll", proof, null).statusCode());
    assertEquals(401, call("POST", "/auth/device-pairings/redeem", proof, null).statusCode());
    assertEquals(401, call("POST", "/auth/device-pairings/poll", Json.map("pairingId", Store.id(), "codeVerifier", f.verifier()), null).statusCode());
    assertEquals("CLAIMED", ok(call("GET", f.path(), null, browser)).get("state"));
  }

  @Test void passwordAndDisplayedCodeAreBothRequiredWithSharedLoginThrottle() throws Exception {
    var f = create(); String code = claim(f);
    assertEquals(403, call("POST", f.path() + "/approve", Json.map("password", "wrong", "confirmationCode", code), browser).statusCode());
    assertEquals(400, call("POST", f.path() + "/approve", Json.map("password", "demo-local-only", "confirmationCode", code.equals("000000") ? "000001" : "000000"), browser).statusCode());
    assertEquals("CLAIMED", ok(call("GET", f.path(), null, browser)).get("state"));
    long now = System.currentTimeMillis();
    security.attempts.put("127.0.0.1", new Security.Attempt(now, 10));
    assertEquals(429, call("POST", f.path() + "/approve", Json.map("password", "demo-local-only", "confirmationCode", code), browser).statusCode());
    assertEquals(429, call("POST", "/auth/login", Json.map("username", "demo", "password", "demo-local-only"), null).statusCode());
  }

  @Test void rejectionIsTerminalAndCannotRevokeCompletedDeviceImplicitly() throws Exception {
    var f = create(); claim(f);
    assertEquals("REJECTED", ok(call("POST", f.path() + "/reject", Json.map(), browser)).get("state"));
    assertEquals("REJECTED", ok(call("POST", "/auth/device-pairings/poll", f.proof(), null)).get("state"));
    assertEquals(409, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
    assertEquals("REJECTED", ok(call("POST", f.path() + "/reject", Json.map(), browser)).get("state"));
    var complete = create(); var device = enroll(complete);
    assertEquals(409, call("POST", complete.path() + "/reject", Json.map(), browser).statusCode());
    assertEquals(200, call("GET", "/accounts", null, (String) device.get("accessToken")).statusCode());
  }

  @Test void transactionAndCreatorExpiryInvalidateEveryPendingStage() throws Exception {
    for (String stage : List.of("CREATED", "CLAIMED", "APPROVED")) {
      var f = create(); String code = stage.equals("CREATED") ? null : claim(f);
      if (stage.equals("APPROVED")) approve(f, code);
      store.db.update("UPDATE device_pairing SET expires_at=? WHERE id=?", System.currentTimeMillis() - 1, f.id());
      if (stage.equals("CREATED")) assertEquals(410, call("POST", "/auth/device-pairings/claim", f.claim(), null).statusCode());
      else {
        assertEquals(410, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
        assertEquals("EXPIRED", ok(call("POST", "/auth/device-pairings/poll", f.proof(), null)).get("state"));
      }
      assertEquals("EXPIRED", ok(call("GET", f.path(), null, browser)).get("state"));
    }
    var f = create(); approve(f, claim(f));
    store.db.update("UPDATE access_token SET expires_at=? WHERE token_hash=?", System.currentTimeMillis() - 1, Security.hash(browser));
    assertEquals(410, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
    assertEquals("EXPIRED", ok(call("POST", "/auth/device-pairings/poll", f.proof(), null)).get("state"));
  }

  @Test void creatorLogoutInvalidatesPendingPairingsButKeepsRedeemedDeviceIndependent() throws Exception {
    var completed = create(); var device = enroll(completed);
    var pending = create(); approve(pending, claim(pending));
    assertEquals(204, call("POST", "/auth/logout", Json.map(), browser).statusCode());
    assertEquals(401, call("GET", "/accounts", null, browser).statusCode());
    assertEquals("EXPIRED", ok(call("POST", "/auth/device-pairings/poll", pending.proof(), null)).get("state"));
    assertEquals(410, call("POST", "/auth/device-pairings/redeem", pending.proof(), null).statusCode());
    assertEquals(200, call("GET", "/accounts", null, (String) device.get("accessToken")).statusCode());
  }

  @Test void deviceRevocationIsIdempotentAndRemovesAllTokensAndLeavesOtherSessions() throws Exception {
    var first = enroll(create()); var second = enroll(create());
    String id = (String) first.get("deviceId"), token = (String) first.get("accessToken"), extra = session();
    store.db.update("INSERT INTO device_access_token VALUES(?,?)", Security.hash(extra), id);
    store.db.update("UPDATE paired_device SET last_seen_at=0 WHERE id=?", id);
    assertEquals(200, call("GET", "/accounts", null, token).statusCode());
    assertTrue(((Number) store.one("SELECT last_seen_at FROM paired_device WHERE id=?", id).get("last_seen_at")).longValue() > 0);
    for (int i = 0; i < 2; i++) assertEquals(204, call("DELETE", "/auth/devices/" + id, null, browser).statusCode());
    assertEquals(401, call("GET", "/accounts", null, token).statusCode());
    assertEquals(401, call("GET", "/accounts", null, extra).statusCode());
    assertEquals(200, call("GET", "/accounts", null, (String) second.get("accessToken")).statusCode());
    assertEquals(200, call("GET", "/accounts", null, browser).statusCode());
    assertEquals(true, store.one("SELECT revoked FROM paired_device WHERE id=?", id).get("revoked"));
    assertEquals(204, call("DELETE", "/auth/devices/" + Store.id(), null, browser).statusCode());
  }

  @Test void deviceExpiryAndLogoutRemoveDeviceAccessWithoutARefreshRoute() throws Exception {
    var first = enroll(create()); String token = (String) first.get("accessToken");
    store.db.update("UPDATE paired_device SET expires_at=? WHERE id=?", System.currentTimeMillis() - 1, first.get("deviceId"));
    assertEquals(401, call("GET", "/accounts", null, token).statusCode());
    var second = enroll(create()); String secondToken = (String) second.get("accessToken");
    assertEquals(204, call("POST", "/auth/logout", Json.map(), secondToken).statusCode());
    assertEquals(401, call("GET", "/accounts", null, secondToken).statusCode());
    assertEquals(true, store.one("SELECT revoked FROM paired_device WHERE id=?", second.get("deviceId")).get("revoked"));
    assertEquals(401, call("POST", "/auth/refresh", Json.map(), null).statusCode());
  }

  @Test void concurrentClaimsChooseOneChallengeAndConcurrentRedeemsIssueOneToken() throws Exception {
    var f = create(); var challenger = new Fixture(f.id(), f.secret(), security.token());
    var results = race(() -> call("POST", "/auth/device-pairings/claim", f.claim(), null),
        () -> call("POST", "/auth/device-pairings/claim", challenger.claim(), null));
    assertEquals(List.of(200, 401), results.stream().map(HttpResponse::statusCode).sorted().toList());
    boolean firstWon = results.getFirst().statusCode() == 200;
    var winner = firstWon ? f : challenger; var loser = firstWon ? challenger : f;
    String code = (String) Json.decode((firstWon ? results.getFirst() : results.get(1)).body()).get("confirmationCode");
    assertEquals(401, call("POST", "/auth/device-pairings/poll", loser.proof(), null).statusCode());
    approve(winner, code);
    var redeemed = race(() -> call("POST", "/auth/device-pairings/redeem", winner.proof(), null),
        () -> call("POST", "/auth/device-pairings/redeem", winner.proof(), null));
    assertEquals(List.of(200, 409), redeemed.stream().map(HttpResponse::statusCode).sorted().toList());
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM paired_device", Integer.class));
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM device_access_token", Integer.class));
  }

  @Test void logoutRacingRedemptionIsSerializedAndCannotLeaveUsablePendingPairing() throws Exception {
    var f = create(); approve(f, claim(f));
    var results = race(() -> call("POST", "/auth/logout", Json.map(), browser),
        () -> call("POST", "/auth/device-pairings/redeem", f.proof(), null));
    assertEquals(204, results.getFirst().statusCode());
    assertTrue(Set.of(200, 410).contains(results.get(1).statusCode()), results.get(1).body());
    String state = (String) store.one("SELECT state FROM device_pairing WHERE id=?", f.id()).get("state");
    assertEquals(results.get(1).statusCode() == 200 ? "REDEEMED" : "EXPIRED", state);
    assertEquals(401, call("GET", "/accounts", null, browser).statusCode());
    if (results.get(1).statusCode() == 200) assertEquals(200, call("GET", "/accounts", null,
        (String) Json.decode(results.get(1).body()).get("accessToken")).statusCode());
  }

  @Test void rejectRacingRedemptionCannotMintAfterRejection() throws Exception {
    var f = create(); approve(f, claim(f));
    var results = race(() -> call("POST", f.path() + "/reject", Json.map(), browser),
        () -> call("POST", "/auth/device-pairings/redeem", f.proof(), null));
    assertTrue((results.getFirst().statusCode() == 200 && results.get(1).statusCode() == 409)
        || (results.getFirst().statusCode() == 409 && results.get(1).statusCode() == 200));
    assertEquals(results.get(1).statusCode() == 200 ? 1 : 0,
        store.db.queryForObject("SELECT COUNT(*) FROM device_access_token", Integer.class));
  }

  List<HttpResponse<String>> race(Callable<HttpResponse<String>> first, Callable<HttpResponse<String>> second) throws Exception {
    var gate = new CyclicBarrier(2);
    try (var executor = Executors.newFixedThreadPool(2)) {
      var a = executor.submit(() -> { gate.await(); return first.call(); });
      var b = executor.submit(() -> { gate.await(); return second.call(); });
      return List.of(a.get(15, TimeUnit.SECONDS), b.get(15, TimeUnit.SECONDS));
    }
  }

  @Test void pollingAndPublicRateLimitsAreBoundedAndForwardedIpCannotBypassThem() throws Exception {
    var f = create(); claim(f);
    assertEquals(200, call("POST", "/auth/device-pairings/poll", f.proof(), null).statusCode());
    var fast = call("POST", "/auth/device-pairings/poll", f.proof(), null);
    assertEquals(429, fast.statusCode()); assertEquals("POLL_TOO_FAST", error(fast));
    store.db.update("UPDATE device_pairing SET last_poll_at=? WHERE id=?", System.currentTimeMillis() - 2001, f.id());
    assertEquals(200, call("POST", "/auth/device-pairings/poll", f.proof(), null).statusCode());
    pairing.publicAttempts.put("IP:127.0.0.1", new Security.Attempt(System.currentTimeMillis(), 120));
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1/auth/device-pairings/poll"))
        .header("Content-Type", "application/json").header("X-Forwarded-For", "192.0.2.5")
        .POST(HttpRequest.BodyPublishers.ofString(Json.encode(f.proof()))).build();
    assertEquals(429, http.send(request, HttpResponse.BodyHandlers.ofString()).statusCode());
    pairing.publicAttempts.clear();
    for (int i = 0; i < 600; i++) pairing.publicRateLimit("synthetic-" + i);
    for (int i = 600; i < 700; i++) {
      String ip = "synthetic-" + i;
      assertEquals(429, assertThrows(ApiError.class, () -> pairing.publicRateLimit(ip)).status);
    }
    assertEquals(601, pairing.publicAttempts.size());
  }

  @Test void creationAndDeviceResourceBoundsAndExpiredCleanupWork() throws Exception {
    for (int i = 0; i < DevicePairingService.MAX_PENDING_PER_SESSION; i++) create();
    assertEquals(429, call("POST", "/auth/device-pairings", Json.map(), browser).statusCode());
    store.db.update("UPDATE device_pairing SET expires_at=?", System.currentTimeMillis() - 600_001);
    var f = create(); assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM device_pairing", Integer.class));
    for (int i = 0; i < DevicePairingService.MAX_DEVICES; i++) store.db.update(
        "INSERT INTO paired_device VALUES(?,?,?,?,?,FALSE)", Store.id(), "Synthetic", 0, System.currentTimeMillis() + 60_000, 0);
    approve(f, claim(f));
    assertEquals(429, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
    assertEquals("APPROVED", ok(call("GET", f.path(), null, browser)).get("state"));
    store.db.update("UPDATE paired_device SET revoked=TRUE");
    assertEquals(200, call("POST", "/auth/device-pairings/redeem", f.proof(), null).statusCode());
  }

  @Test void malformedFieldsUnknownKeysAndOversizedBodiesCannotMutatePairing() throws Exception {
    var f = create();
    for (Object value : List.of("", "x".repeat(81), "bad\nname", "bad\u202Ename", 123, List.of("name"))) {
      var body = f.claim(); body.put("deviceName", value);
      assertEquals(400, call("POST", "/auth/device-pairings/claim", body, null).statusCode());
    }
    for (String key : List.of("secret", "codeChallenge", "pairingId")) {
      var body = f.claim(); body.put(key, "malformed");
      assertEquals(400, call("POST", "/auth/device-pairings/claim", body, null).statusCode());
    }
    var body = f.claim(); body.put("codeVerifier", f.verifier());
    assertEquals(400, call("POST", "/auth/device-pairings/claim", body, null).statusCode());
    assertEquals(413, call("POST", "/auth/device-pairings/claim", Json.map("padding", "x".repeat(5000)), null).statusCode());
    assertEquals(400, call("POST", "/auth/device-pairings/claim?secret=not-in-url", f.claim(), null).statusCode());
    assertEquals("CREATED", ok(call("GET", f.path(), null, browser)).get("state"));
  }

  @Test void publicAllowlistIsExactMethodAndCanonicalPathOnly() throws Exception {
    for (String suffix : List.of("claim", "poll", "redeem")) {
      for (String method : List.of("GET", "PUT", "DELETE", "HEAD", "PATCH"))
        assertEquals(401, call(method, "/auth/device-pairings/" + suffix, null, null).statusCode());
      assertEquals(401, call("POST", "/auth/device-pairings/" + suffix + "/extra", Json.map(), null).statusCode());
      for (String path : List.of("/%61pi/v1/auth/device-pairings/" + suffix,
          "/api;/v1/auth/device-pairings/" + suffix, "/api/v1/auth//device-pairings/" + suffix,
          "/api/v1/auth/device-pairings/" + suffix + ";ignored", "/api/v1/auth/device-pairings/" + suffix + "/"))
        assertEquals(400, wire(path, "{}"), path);
    }
  }


  @Test void totalPairingCapacityIsEnforcedAndProofEncodingMatchesRfc7636() throws Exception {
    assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        DevicePairingService.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    store.write(() -> {
      for (int i = 0; i < DevicePairingService.MAX_PAIRINGS; i++)
        store.db.update("INSERT INTO device_pairing(id,creator_hash,state,created_at,expires_at) VALUES(?,?,'REJECTED',?,?)",
            Store.id(), Security.hash(otherBrowser), System.currentTimeMillis(), System.currentTimeMillis() + 120_000);
      return null;
    });
    assertEquals(429, call("POST", "/auth/device-pairings", Json.map(), browser).statusCode());
    assertEquals(DevicePairingService.MAX_PAIRINGS,
        store.db.queryForObject("SELECT COUNT(*) FROM device_pairing", Integer.class));
  }

  @Test void chunkedOversizedPairingBodyIsBoundedWithoutContentLength() throws Exception {
    try (Socket socket = new Socket("127.0.0.1", port)) {
      socket.setSoTimeout(10_000);
      String body = Json.encode(Json.map("padding", "x".repeat(5000)));
      String headers = "POST /api/v1/auth/device-pairings/claim HTTP/1.1\r\nHost: localhost\r\nConnection: close"
          + "\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n";
      String wire = headers + Integer.toHexString(body.length()) + "\r\n" + body + "\r\n0\r\n\r\n";
      socket.getOutputStream().write(wire.getBytes(StandardCharsets.US_ASCII));
      String response = new String(socket.getInputStream().readNBytes(65536), StandardCharsets.UTF_8);
      assertTrue(response.startsWith("HTTP/1.1 400") || response.startsWith("HTTP/1.1 413"), response);
      assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM device_pairing", Integer.class));
    }
  }

  int wire(String path, String body) throws Exception {
    try (Socket socket = new Socket("127.0.0.1", port)) {
      socket.setSoTimeout(10_000);
      byte[] data = body.getBytes(StandardCharsets.UTF_8);
      String headers = "POST " + path + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + data.length + "\r\n\r\n";
      socket.getOutputStream().write(headers.getBytes(StandardCharsets.US_ASCII)); socket.getOutputStream().write(data);
      String response = new String(socket.getInputStream().readNBytes(65536), StandardCharsets.UTF_8);
      return Integer.parseInt(response.split(" ", 3)[1]);
    }
  }
}
