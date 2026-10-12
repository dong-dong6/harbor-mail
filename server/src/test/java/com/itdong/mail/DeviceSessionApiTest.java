package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.net.URI;
import java.net.http.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.*;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

/** Synthetic credentials and disposable H2/PostgreSQL only. Includes real HTTP and row-lock races. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {"mail.worker-enabled=false", "mail.allowed-origin=https://mail.example.invalid"})
@ActiveProfiles("demo")
@Import(DeviceSessionApiTest.TimeConfiguration.class)
class DeviceSessionApiTest {
  @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "device_session_test");
  }
  static class TestClock extends Clock {
    final AtomicLong value = new AtomicLong();
    public ZoneId getZone() { return ZoneOffset.UTC; }
    public Clock withZone(ZoneId zone) { return this; }
    public Instant instant() { return Instant.ofEpochMilli(millis()); }
    public long millis() { return value.get(); }
    void advance(long millis) { value.addAndGet(millis); }
  }
  @TestConfiguration static class TimeConfiguration {
    @Bean @Primary TestClock testClock() { return new TestClock(); }
  }
  @Autowired Store store;
  @Autowired Security security;
  @Autowired DevicePairingService pairing;
  @Autowired DeviceSessionService sessions;
  @Autowired TestClock clock;
  @LocalServerPort int port;
  final HttpClient http = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();

  @BeforeEach void reset() {
    clock.value.set(System.currentTimeMillis());
    store.write(() -> {
      for (String table : List.of("device_pairing", "paired_device", "access_token")) store.db.update("DELETE FROM " + table);
      return null;
    });
    security.attempts.clear(); pairing.publicAttempts.clear(); sessions.publicAttempts.clear();
  }
  HttpResponse<String> call(String method, String path, Object body, String access) throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1" + path))
        .timeout(Duration.ofSeconds(15)).header("Content-Type", "application/json");
    if (access != null) request.header("Authorization", "Bearer " + access);
    return http.send(request.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(Json.encode(body))).build(), HttpResponse.BodyHandlers.ofString());
  }
  Map<String, Object> ok(HttpResponse<String> response) {
    assertEquals(200, response.statusCode(), response.body());
    assertEquals("no-store", response.headers().firstValue("Cache-Control").orElseThrow());
    assertTrue(response.headers().firstValue("Location").isEmpty());
    return Json.decode(response.body());
  }
  String error(HttpResponse<String> response) { return (String) ((Map<?, ?>) Json.decode(response.body()).get("error")).get("code"); }
  Map<String, Object> login(Boolean remember) throws Exception {
    var body = Json.map("username", "demo", "password", "demo-local-only");
    if (remember != null) { body.put("rememberDevice", remember); body.put("deviceName", "Synthetic Android"); }
    return ok(call("POST", "/auth/login", body, null));
  }
  Map<String, Object> rotation(String old) { return Json.map("refreshToken", old, "nextRefreshToken", security.token(), "requestId", Store.id()); }
  HttpResponse<String> refresh(Map<String, Object> body) throws Exception { return call("POST", "/auth/refresh", body, null); }
  int authorized(Object token) throws Exception { return call("GET", "/accounts", null, (String) token).statusCode(); }
  long at(Map<String, Object> response, String key) { return Instant.parse((String) response.get(key)).toEpochMilli(); }
  Map<String, Object> family() { return store.one("SELECT * FROM device_session"); }

  @Test void optInKeepsLegacyEightHourSessionsAndUsesOnlyHashes() throws Exception {
    for (Boolean choice : Arrays.asList(null, false)) {
      var result = login(choice);
      assertFalse(result.containsKey("refreshToken"));
      assertTrue(at(result, "expiresAt") >= clock.millis() + 8 * 3600_000L);
    }
    var session = login(true);
    assertEquals(clock.millis() + 900_000L, at(session, "expiresAt"));
    assertEquals(clock.millis() + 30 * 86_400_000L, at(session, "refreshExpiresAt"));
    assertEquals(clock.millis() + 365 * 86_400_000L, at(session, "sessionExpiresAt"));
    assertEquals(200, authorized(session.get("accessToken")));
    for (String table : List.of("device_session", "device_refresh_token", "device_access_token", "device_session_access", "access_token")) {
      var rows = store.db.queryForList("SELECT * FROM " + table).toString();
      assertFalse(rows.contains((String) session.get("refreshToken")));
      assertFalse(rows.contains((String) session.get("accessToken")));
    }
    assertEquals(Security.hash((String) session.get("refreshToken")), family().get("refresh_hash"));
    assertEquals(403, call("POST", "/auth/device-pairings", Json.map(), (String) session.get("accessToken")).statusCode());
    assertEquals(403, call("POST", "/auth/passkeys/registration/options", Json.map("password", "demo-local-only", "name", "No"), (String) session.get("accessToken")).statusCode());
  }

  @Test void rotationSurvivesLostResponseAndExactRetryDoesNotExtendIdle() throws Exception {
    var initial = login(true); var body = rotation((String) initial.get("refreshToken"));
    clock.advance(16 * 60_000L);
    var expired = call("GET", "/accounts", null, (String) initial.get("accessToken"));
    assertEquals(401, expired.statusCode()); assertEquals("ACCESS_EXPIRED", error(expired));
    var first = ok(refresh(body)); // Pretend this response was lost; client retained the tuple.
    long idle = at(first, "refreshExpiresAt");
    clock.advance(60_000);
    var retried = ok(refresh(body));
    assertEquals(body.get("nextRefreshToken"), retried.get("refreshToken"));
    assertEquals(idle, at(retried, "refreshExpiresAt"));
    assertNotEquals(first.get("accessToken"), retried.get("accessToken"));
    assertEquals(200, authorized(first.get("accessToken"))); assertEquals(200, authorized(retried.get("accessToken")));
    assertEquals(2, store.db.queryForObject("SELECT COUNT(*) FROM device_refresh_token", Integer.class));
  }

  @Test void delayedExactHistoricalRetryDoesNotRevokeButDifferentTupleCommitsRevocation() throws Exception {
    var initial = login(true); var ab = rotation((String) initial.get("refreshToken")); var b = ok(refresh(ab));
    var bc = rotation((String) b.get("refreshToken")); var c = ok(refresh(bc));
    var stale = refresh(ab); assertEquals(409, stale.statusCode()); assertEquals("STALE_ROTATION", error(stale));
    assertEquals(200, authorized(c.get("accessToken"))); assertEquals(false, family().get("revoked"));
    var reuse = refresh(rotation((String) initial.get("refreshToken")));
    assertEquals(401, reuse.statusCode()); assertEquals("REFRESH_REUSED", error(reuse));
    assertEquals(true, family().get("revoked"));
    for (var response : List.of(initial, b, c)) assertEquals(401, authorized(response.get("accessToken")));
    assertEquals("SESSION_REVOKED", error(refresh(rotation((String) c.get("refreshToken")))));
    assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM device_session_access", Integer.class));
    reset(); var other = login(true); var old = (String) other.get("refreshToken"); ok(refresh(rotation(old)));
    var selfSuccessor = rotation(old); selfSuccessor.put("nextRefreshToken", old);
    assertEquals("REFRESH_REUSED", error(refresh(selfSuccessor)));
    assertEquals(true, family().get("revoked"));
  }

  @Test void idleAndAbsoluteExpiryBoundEveryAccessWithoutExtensionByRetry() throws Exception {
    var initial = login(true); var body = rotation((String) initial.get("refreshToken"));
    var rotated = ok(refresh(body));
    clock.value.set(at(rotated, "refreshExpiresAt") - 1);
    var retry = ok(refresh(body)); assertEquals(at(rotated, "refreshExpiresAt"), at(retry, "expiresAt"));
    clock.advance(1);
    assertEquals(401, authorized(retry.get("accessToken")));
    assertEquals("SESSION_EXPIRED", error(refresh(body)));
    reset(); initial = login(true);
    long absolute = at(initial, "sessionExpiresAt");
    store.db.update("UPDATE device_session SET idle_expires_at=?", absolute + 86_400_000L);
    store.db.update("UPDATE paired_device SET expires_at=?", absolute + 86_400_000L);
    clock.value.set(absolute - 1);
    var last = ok(refresh(rotation((String) initial.get("refreshToken"))));
    assertEquals(absolute, at(last, "refreshExpiresAt")); assertEquals(absolute, at(last, "expiresAt"));
    clock.advance(1);
    assertEquals(401, authorized(last.get("accessToken")));
    assertEquals("SESSION_EXPIRED", error(refresh(rotation((String) last.get("refreshToken")))));
  }

  @Test void allLogoutPathsRevokeFamilyAndHistoricalProofWorksWithoutAccess() throws Exception {
    for (String mode : List.of("historical", "current", "bearer", "owner-revoke")) {
      reset(); var session = login(true); var rotated = ok(refresh(rotation((String) session.get("refreshToken"))));
      if (mode.equals("bearer")) assertEquals(204, call("POST", "/auth/logout", Json.map(), (String) rotated.get("accessToken")).statusCode());
      else if (mode.equals("owner-revoke")) {
        var browser = login(false);
        assertEquals(204, call("DELETE", "/auth/devices/" + session.get("deviceId"), null, (String) browser.get("accessToken")).statusCode());
      } else {
        clock.advance(16 * 60_000L);
        Object proof = mode.equals("historical") ? session.get("refreshToken") : rotated.get("refreshToken");
        for (int i = 0; i < 2; i++) assertEquals(204, call("POST", "/auth/device-session/logout", Json.map("refreshToken", proof), null).statusCode());
      }
      assertEquals(true, family().get("revoked"));
      assertEquals(401, authorized(session.get("accessToken"))); assertEquals(401, authorized(rotated.get("accessToken")));
      assertEquals("SESSION_REVOKED", error(refresh(rotation((String) rotated.get("refreshToken")))));
    }
  }

  @Test void invalidProofCannotRevokeAndRotationRejectsGlobalTokenOrRequestCollision() throws Exception {
    var initial = login(true); var first = rotation((String) initial.get("refreshToken")); var second = ok(refresh(first));
    var unknown = refresh(rotation(security.token())); assertEquals("INVALID_REFRESH", error(unknown)); assertEquals(false, family().get("revoked"));
    var collision = rotation((String) second.get("refreshToken")); collision.put("nextRefreshToken", initial.get("refreshToken"));
    assertEquals("INVALID_ROTATION", error(refresh(collision)));
    collision = rotation((String) second.get("refreshToken")); collision.put("requestId", first.get("requestId"));
    assertEquals("INVALID_ROTATION", error(refresh(collision)));
    var another = login(true); collision = rotation((String) second.get("refreshToken")); collision.put("nextRefreshToken", another.get("refreshToken"));
    assertEquals("INVALID_ROTATION", error(refresh(collision)));
    assertEquals(200, authorized(second.get("accessToken"))); assertEquals(200, authorized(another.get("accessToken")));
  }

  List<HttpResponse<String>> race(Callable<HttpResponse<String>> first, Callable<HttpResponse<String>> second) throws Exception {
    var gate = new CyclicBarrier(2);
    try (var executor = Executors.newFixedThreadPool(2)) {
      var a = executor.submit(() -> { gate.await(); return first.call(); });
      var b = executor.submit(() -> { gate.await(); return second.call(); });
      return List.of(a.get(15, TimeUnit.SECONDS), b.get(15, TimeUnit.SECONDS));
    }
  }

  @Test void concurrentExactRotationsConvergeAndDifferentRotationsRevokeWholeFamily() throws Exception {
    var initial = login(true); var body = rotation((String) initial.get("refreshToken"));
    for (var response : race(() -> refresh(body), () -> refresh(body))) assertEquals(body.get("nextRefreshToken"), ok(response).get("refreshToken"));
    assertEquals(2, store.db.queryForObject("SELECT COUNT(*) FROM device_refresh_token", Integer.class));
    var a = rotation((String) body.get("nextRefreshToken")); var b = rotation((String) body.get("nextRefreshToken"));
    var results = race(() -> refresh(a), () -> refresh(b));
    assertEquals(List.of(200, 401), results.stream().map(HttpResponse::statusCode).sorted().toList());
    assertEquals(true, family().get("revoked"));
    for (var response : results) if (response.statusCode() == 200) assertEquals(401, authorized(Json.decode(response.body()).get("accessToken")));
  }

  @Test void refreshRacingLogoutOrRevocationCannotLeaveLiveCredentials() throws Exception {
    for (boolean byProof : List.of(true, false)) {
      reset(); var initial = login(true); var body = rotation((String) initial.get("refreshToken")); var browser = login(false);
      var results = race(() -> refresh(body), () -> byProof
          ? call("POST", "/auth/device-session/logout", Json.map("refreshToken", initial.get("refreshToken")), null)
          : call("DELETE", "/auth/devices/" + initial.get("deviceId"), null, (String) browser.get("accessToken")));
      assertEquals(204, results.get(1).statusCode()); assertTrue(Set.of(200, 401).contains(results.getFirst().statusCode()));
      assertEquals(true, family().get("revoked")); assertEquals(401, authorized(initial.get("accessToken")));
      if (results.getFirst().statusCode() == 200) assertEquals(401, authorized(Json.decode(results.getFirst().body()).get("accessToken")));
    }
  }

  @Test void rotationWriteFailureRollsBackEntireTupleSoIdenticalPendingRequestCanRetry() throws Exception {
    var initial = login(true); var body = rotation((String) initial.get("refreshToken"));
    var broken = new DeviceSessionService(store, clock, 900, 30, 365) {
      @Override Map<String, Object> access(Map<String, Object> family, String refresh, long now) {
        super.access(family, refresh, now);
        throw new IllegalStateException("Synthetic failure before commit");
      }
    };
    assertThrows(IllegalStateException.class, () -> broken.refresh(body, "synthetic"));
    assertEquals(Security.hash((String) initial.get("refreshToken")), family().get("refresh_hash"));
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM device_refresh_token", Integer.class));
    assertEquals(1, store.db.queryForObject("SELECT COUNT(*) FROM device_session_access", Integer.class));
    assertEquals(body.get("nextRefreshToken"), ok(refresh(body)).get("refreshToken"));
  }

  @Test void pairingDurabilityCanOnlyBeChosenByApprovingOwner() throws Exception {
    var browser = login(false); String token = (String) browser.get("accessToken");
    var created = ok(call("POST", "/auth/device-pairings", Json.map(), token));
    var qr = Json.decode((String) created.get("qrPayload")); String verifier = security.token();
    var claim = Json.map("pairingId", qr.get("pairingId"), "secret", qr.get("secret"), "deviceName", "Phone", "codeChallenge", DevicePairingService.challenge(verifier));
    claim.put("rememberDevice", true); assertEquals(400, call("POST", "/auth/device-pairings/claim", claim, null).statusCode());
    claim.remove("rememberDevice"); var claimed = ok(call("POST", "/auth/device-pairings/claim", claim, null));
    var approved = ok(call("POST", "/auth/device-pairings/" + qr.get("pairingId") + "/approve", Json.map("password", "demo-local-only", "confirmationCode", claimed.get("confirmationCode"), "rememberDevice", true), token));
    assertEquals(true, approved.get("rememberDevice"));
    var proof = Json.map("pairingId", qr.get("pairingId"), "codeVerifier", verifier);
    var redeemed = ok(call("POST", "/auth/device-pairings/redeem", proof, null));
    assertNotNull(redeemed.get("refreshToken")); assertEquals(200, authorized(redeemed.get("accessToken")));
    assertEquals(409, call("POST", "/auth/device-pairings/redeem", proof, null).statusCode());
  }

  @Test void strictPublicRoutesInputsBoundedBodiesAndThrottle() throws Exception {
    var initial = login(true); var valid = rotation((String) initial.get("refreshToken"));
    for (String path : List.of("/auth/refresh", "/auth/device-session/logout")) {
      assertEquals(400, call("POST", path + "?refreshToken=never", valid, null).statusCode());
      for (String method : List.of("GET", "PUT", "DELETE", "PATCH")) assertEquals(401, call(method, path, null, null).statusCode());
      assertEquals(401, call("POST", path + "/extra", valid, null).statusCode());
      assertEquals(413, call("POST", path, Json.map("padding", "x".repeat(5000)), null).statusCode());
    }
    for (String key : List.of("refreshToken", "nextRefreshToken", "requestId")) {
      for (Object value : List.of("", "malformed", 123, true, "x".repeat(500))) {
        var malformed = new LinkedHashMap<>(valid); malformed.put(key, value);
        assertEquals(400, refresh(malformed).statusCode());
      }
    }
    var malformed = new LinkedHashMap<>(valid); malformed.put("extra", true); assertEquals(400, refresh(malformed).statusCode());
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/api/v1/auth/refresh"))
        .header("Content-Type", "text/plain").POST(HttpRequest.BodyPublishers.ofString(Json.encode(valid))).build();
    assertEquals(415, http.send(request, HttpResponse.BodyHandlers.ofString()).statusCode());
    sessions.publicAttempts.put("IP:127.0.0.1", new Security.Attempt(clock.millis(), 120));
    assertEquals(429, refresh(valid).statusCode());
    assertEquals(false, family().get("revoked"));
  }

  @Test void persistedFamilyQuotasSurviveServiceRestartWithoutDisablingReuseDetectionOrLogout() throws Exception {
    var initial = login(true); var ab = rotation((String) initial.get("refreshToken"));
    ok(refresh(ab));
    for (int i = 0; i < 10; i++) ok(refresh(ab));
    var retryLimited = refresh(ab);
    assertEquals(429, retryLimited.statusCode());
    assertEquals("60", retryLimited.headers().firstValue("Retry-After").orElseThrow());
    var restarted = new DeviceSessionService(store, clock, 900, 30, 365);
    assertEquals(429, assertThrows(ApiError.class, () -> restarted.refresh(ab, "different-ip")).status);
    assertEquals("REFRESH_REUSED", error(refresh(rotation((String) initial.get("refreshToken")))));
    assertEquals(true, family().get("revoked"));

    reset(); initial = login(true); String current = (String) initial.get("refreshToken");
    for (int batch = 0; batch < 3; batch++) {
      for (int i = 0; i < 10; i++) {
        var body = rotation(current); var value = sessions.refresh(body, "synthetic"); current = (String) value.get("refreshToken");
      }
      if (batch == 0) {
        var body = rotation(current);
        assertEquals(429, assertThrows(ApiError.class, () -> sessions.refresh(body, "synthetic")).status);
      }
      clock.advance(61_000);
    }
    var pending = rotation(current);
    var quota = assertThrows(ApiError.class, () -> new DeviceSessionService(store, clock, 900, 30, 365).refresh(pending, "another-ip"));
    assertEquals(429, quota.status); assertTrue(quota.retryAfterSeconds > 3000);
    assertEquals(Security.hash(current), family().get("refresh_hash"));
    clock.advance(3_600_000);
    assertEquals(pending.get("nextRefreshToken"), sessions.refresh(pending, "synthetic").get("refreshToken"));
    assertEquals(204, call("POST", "/auth/device-session/logout", Json.map("refreshToken", initial.get("refreshToken")), null).statusCode());
    assertEquals(true, family().get("revoked"));
  }

  @Test void configurationFailsClosedOutsideDocumentedBounds() {
    for (long[] values : List.of(new long[]{59,30,365}, new long[]{3601,30,365}, new long[]{900,0,365}, new long[]{900,91,365}, new long[]{900,30,29}, new long[]{900,30,731}))
      assertThrows(IllegalArgumentException.class, () -> new DeviceSessionService(store, clock, values[0], values[1], values[2]));
  }
}
