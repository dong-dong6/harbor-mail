package com.itdong.mail;

import java.security.SecureRandom;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Hash-only, opt-in device sessions with client-prepared, crash-recoverable refresh rotation. */
@Component
public class DeviceSessionService {
  final Store store;
  final Clock clock;
  final long accessMillis, idleMillis, absoluteMillis;
  final SecureRandom random = new SecureRandom();
  final Map<String, Security.Attempt> publicAttempts = new HashMap<>();

  DeviceSessionService(Store store, Clock clock,
      @Value("${mail.device-session.access-seconds:900}") long accessSeconds,
      @Value("${mail.device-session.idle-days:30}") long idleDays,
      @Value("${mail.device-session.absolute-days:365}") long absoluteDays) {
    if (accessSeconds < 60 || accessSeconds > 3600 || idleDays < 1 || idleDays > 90
        || absoluteDays < 1 || absoluteDays > 730 || idleDays > absoluteDays)
      throw new IllegalArgumentException("Device sessions require access 60..3600 seconds, idle 1..90 days, absolute 1..730 days, idle <= absolute");
    this.store = store; this.clock = clock;
    accessMillis = accessSeconds * 1000L;
    idleMillis = idleDays * 86_400_000L;
    absoluteMillis = absoluteDays * 86_400_000L;
  }

  long now() { return clock.millis(); }
  String token() {
    byte[] bytes = new byte[32]; random.nextBytes(bytes);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  static boolean remember(Map<String, Object> body) {
    if (!body.containsKey("rememberDevice")) return false;
    if (!(body.get("rememberDevice") instanceof Boolean value)) throw ApiError.bad("Invalid rememberDevice");
    return value;
  }

  static String deviceName(Map<String, Object> body) {
    String name = body.containsKey("deviceName") ? DevicePairingService.text(body, "deviceName", 80).strip() : "Remembered device";
    if (name.isBlank() || name.codePoints().anyMatch(c -> Character.isISOControl(c)
        || Character.getType(c) == Character.FORMAT || c == 0x2028 || c == 0x2029)) throw ApiError.bad("Invalid deviceName");
    return name;
  }

  synchronized void rateLimit(String ip) {
    long now = now();
    publicAttempts.entrySet().removeIf(e -> now - e.getValue().start() >= 60_000);
    for (String key : List.of("GLOBAL", "IP:" + ip)) {
      var prior = publicAttempts.get(key);
      if (prior != null && prior.count() >= (key.equals("GLOBAL") ? 600 : 120))
        throw new ApiError(429, "RATE_LIMITED", "Too many device session requests; retry later");
      publicAttempts.put(key, new Security.Attempt(prior == null ? now : prior.start(), prior == null ? 1 : prior.count() + 1));
    }
  }

  Map<String, Object> issue(String name) {
    return store.write(() -> {
      long now = now();
      store.db.update("DELETE FROM paired_device WHERE expires_at<?", now - 86_400_000L);
      if (store.db.queryForObject("SELECT COUNT(*) FROM paired_device WHERE revoked=FALSE AND expires_at>?", Integer.class, now) >= DevicePairingService.MAX_DEVICES
          || store.db.queryForObject("SELECT COUNT(*) FROM paired_device", Integer.class) >= 1000)
        throw new ApiError(429, "DEVICE_LIMIT", "Too many devices; revoke an unused device or wait for expiry");
      String device = Store.id(), session = Store.id(), refresh = token();
      long absolute = now + absoluteMillis, idle = Math.min(now + idleMillis, absolute);
      store.db.update("INSERT INTO paired_device(id,name,created_at,expires_at,last_seen_at,revoked) VALUES(?,?,?,?,?,FALSE)", device, name, now, idle, now);
      store.db.update("INSERT INTO device_session(id,device_id,refresh_hash,created_at,idle_expires_at,absolute_expires_at) VALUES(?,?,?,?,?,?)",
          session, device, Security.hash(refresh), now, idle, absolute);
      store.db.update("INSERT INTO device_refresh_token(token_hash,session_id) VALUES(?,?)", Security.hash(refresh), session);
      return access(store.one("SELECT * FROM device_session WHERE id=?", session), refresh, now);
    });
  }

  /** Caller owns a transaction and the family row lock. Never store or log bearer plaintext. */
  Map<String, Object> access(Map<String, Object> family, String refresh, long now) {
    long idle = number(family, "idle_expires_at"), absolute = number(family, "absolute_expires_at");
    long expires = Math.min(now + accessMillis, Math.min(idle, absolute));
    String token = token();
    store.db.update("DELETE FROM access_token WHERE expires_at<=?", now - 86_400_000L);
    store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token), expires);
    store.db.update("INSERT INTO device_access_token VALUES(?,?)", Security.hash(token), family.get("device_id"));
    store.db.update("INSERT INTO device_session_access VALUES(?,?)", Security.hash(token), family.get("id"));
    return Json.map("accessToken", token, "expiresAt", iso(expires), "refreshToken", refresh,
        "refreshExpiresAt", iso(idle), "sessionExpiresAt", iso(absolute), "deviceId", family.get("device_id"),
        "accountName", store.db.queryForObject("SELECT username FROM owner_user WHERE id=1", String.class),
        "permission", DevicePairingService.PERMISSION);
  }

  record Result(Map<String, Object> value, ApiError error) {}
  static Result error(String code, String message) { return new Result(null, new ApiError(401, code, message)); }

  Map<String, Object> refresh(Map<String, Object> body, String ip) {
    rateLimit(ip);
    DevicePairingService.fields(body, "refreshToken", "nextRefreshToken", "requestId");
    String old = DevicePairingService.proof(body, "refreshToken"), next = DevicePairingService.proof(body, "nextRefreshToken");
    String request = DevicePairingService.text(body, "requestId", 36);
    if (!request.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")) throw ApiError.bad("Invalid requestId");
    String oldHash = Security.hash(old), nextHash = Security.hash(next);
    Result result = store.write(() -> {
      var proofs = store.db.queryForList("SELECT * FROM device_refresh_token WHERE token_hash=?", oldHash);
      if (proofs.isEmpty()) return error("INVALID_REFRESH", "Sign in required");
      var proof = proofs.getFirst();
      var family = store.one("SELECT * FROM device_session WHERE id=? FOR UPDATE", proof.get("session_id"));
      // Store.write currently also locks app_state. Re-read under the family lock so rotation
      // remains correct if a future implementation narrows the global serialization scope.
      proof = store.one("SELECT * FROM device_refresh_token WHERE token_hash=?", oldHash);
      long now = now();
      boolean deviceRevoked = store.db.queryForObject("SELECT revoked FROM paired_device WHERE id=?", Boolean.class, family.get("device_id"));
      if (Boolean.TRUE.equals(family.get("revoked")) || deviceRevoked) return error("SESSION_REVOKED", "Device session revoked; sign in again");
      if (number(family, "idle_expires_at") <= now || number(family, "absolute_expires_at") <= now)
        return error("SESSION_EXPIRED", "Device session expired; sign in again");
      if (proof.get("consumed_at") != null) {
        if (request.equals(proof.get("request_id")) && nextHash.equals(proof.get("successor_hash"))) {
          if (nextHash.equals(family.get("refresh_hash"))) {
            long window = number(family, "retry_window_start");
            int count = ((Number) family.get("retry_count")).intValue();
            if (now - window >= 60_000) { window = now; count = 0; }
            if (count >= 10) return limited(window + 60_000 - now);
            store.db.update("UPDATE device_session SET retry_window_start=?,retry_count=? WHERE id=?", window, count + 1, family.get("id"));
            return new Result(access(family, next, now), null);
          }
          return new Result(null, new ApiError(409, "STALE_ROTATION", "This rotation was already superseded"));
        }
        // Returning an error value commits this revocation; throwing here would roll it back.
        revokeFamily((String) family.get("id"));
        return error("REFRESH_REUSED", "Refresh reuse detected; device session revoked");
      }
      if (!oldHash.equals(family.get("refresh_hash"))) return error("INVALID_REFRESH", "Sign in required");
      if (oldHash.equals(nextHash)) return new Result(null, ApiError.bad("Refresh successor must be new"));
      if (store.db.queryForObject("SELECT COUNT(*) FROM device_refresh_token WHERE token_hash=? OR (session_id=? AND request_id=?)",
          Integer.class, nextHash, family.get("id"), request) != 0)
        return new Result(null, new ApiError(409, "INVALID_ROTATION", "Use a new successor token and request identifier"));
      // Persisted sliding windows bound ledger growth across server restarts and source IPs.
      for (long[] limit : List.of(new long[]{60_000L, 10}, new long[]{3_600_000L, 30})) {
        var times = store.db.queryForList("SELECT consumed_at FROM device_refresh_token WHERE session_id=? AND consumed_at>? ORDER BY consumed_at",
            Long.class, family.get("id"), now - limit[0]);
        if (times.size() >= limit[1]) return limited(times.getFirst() + limit[0] - now);
      }
      long idle = Math.min(now + idleMillis, number(family, "absolute_expires_at"));
      store.db.update("UPDATE device_refresh_token SET request_id=?,successor_hash=?,consumed_at=? WHERE token_hash=?", request, nextHash, now, oldHash);
      store.db.update("INSERT INTO device_refresh_token(token_hash,session_id) VALUES(?,?)", nextHash, family.get("id"));
      store.db.update("UPDATE device_session SET refresh_hash=?,idle_expires_at=? WHERE id=?", nextHash, idle, family.get("id"));
      store.db.update("UPDATE paired_device SET expires_at=?,last_seen_at=? WHERE id=?", idle, now, family.get("device_id"));
      family.put("refresh_hash", nextHash); family.put("idle_expires_at", idle);
      return new Result(access(family, next, now), null);
    });
    if (result.error() != null) throw result.error();
    return result.value();
  }

  static Result limited(long millis) {
    int seconds = (int) Math.max(1, (millis + 999) / 1000);
    return new Result(null, new ApiError(429, "RATE_LIMITED", "Retry the same saved rotation after the delay", seconds));
  }

  void logout(Map<String, Object> body, String ip) {
    rateLimit(ip); DevicePairingService.fields(body, "refreshToken");
    String hash = Security.hash(DevicePairingService.proof(body, "refreshToken"));
    store.write(() -> {
      var proofs = store.db.queryForList("SELECT session_id FROM device_refresh_token WHERE token_hash=?", hash);
      if (!proofs.isEmpty()) {
        String session = (String) proofs.getFirst().get("session_id");
        store.db.queryForList("SELECT id FROM device_session WHERE id=? FOR UPDATE", session);
        revokeFamily(session);
      }
      return null;
    });
  }

  void revokeFamily(String session) {
    store.db.update("UPDATE device_session SET revoked=TRUE WHERE id=?", session);
    store.db.update("UPDATE paired_device SET revoked=TRUE WHERE id IN (SELECT device_id FROM device_session WHERE id=?)", session);
    store.db.update("DELETE FROM access_token WHERE token_hash IN (SELECT token_hash FROM device_session_access WHERE session_id=?)", session);
  }

  void revokeByAccess(String hash) {
    for (var row : store.db.queryForList("SELECT session_id FROM device_session_access WHERE token_hash=?", hash))
      revokeFamily((String) row.get("session_id"));
  }

  void revokeDevice(String device) {
    for (var row : store.db.queryForList("SELECT id FROM device_session WHERE device_id=?", device))
      revokeFamily((String) row.get("id"));
  }

  static long number(Map<String, Object> row, String key) { return ((Number) row.get(key)).longValue(); }
  static String iso(long value) { return java.time.Instant.ofEpochMilli(value).toString(); }
}
