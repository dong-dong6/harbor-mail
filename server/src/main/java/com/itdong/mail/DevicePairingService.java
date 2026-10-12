package com.itdong.mail;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import org.springframework.stereotype.Component;

/** Short-lived, single-use owner approval. Durable device sessions require explicit approval. */
@Component
public class DevicePairingService {
  static final long PAIRING_LIFETIME = 120_000, DEVICE_LIFETIME = 8 * 3600_000L;
  static final int MAX_PAIRINGS = 1000, MAX_PENDING_PER_SESSION = 5, MAX_DEVICES = 100;
  static final String PERMISSION = "OWNER_FULL_ACCESS";
  static final Set<String> PENDING = Set.of("CREATED", "CLAIMED", "APPROVED");
  final Store store;
  final Security security;
  // Only server-observed remote addresses, never client-forwarded IP headers. Global bounds also
  // bound map cardinality. Each entry expires in a minute; no per-untrusted-pairing-ID allocation.
  final Map<String, Security.Attempt> publicAttempts = new HashMap<>();

  DevicePairingService(Store store, Security security) {
    this.store = store;
    this.security = security;
  }

  synchronized void publicRateLimit(String ip) {
    long now = System.currentTimeMillis();
    publicAttempts.entrySet().removeIf(e -> now - e.getValue().start() >= 60_000);
    for (String key : List.of("GLOBAL", "IP:" + ip)) {
      var a = publicAttempts.get(key);
      int max = key.equals("GLOBAL") ? 600 : 120;
      if (a != null && a.count() >= max)
        throw new ApiError(429, "RATE_LIMITED", "Too many pairing requests; retry later");
      publicAttempts.put(key, new Security.Attempt(a == null ? now : a.start(), a == null ? 1 : a.count() + 1));
    }
  }

  static void fields(Map<String, Object> body, String... names) {
    if (body == null || !body.keySet().equals(Set.of(names)))
      throw ApiError.bad("Unexpected or missing request fields");
  }

  static String text(Map<String, Object> body, String field, int max) {
    if (!(body.get(field) instanceof String value) || value.isBlank() || value.length() > max)
      throw ApiError.bad("Invalid " + field);
    return value;
  }

  static String id(String id) {
    if (id == null || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw ApiError.bad("Invalid pairing or device identifier");
    return id;
  }

  static String proof(Map<String, Object> body, String field) {
    String value = text(body, field, 43);
    // Canonical base64url of exactly 32 bytes, including canonical unused trailing bits.
    try {
      byte[] bytes = Base64.getUrlDecoder().decode(value);
      if (bytes.length == 32 && Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).equals(value))
        return value;
    } catch (IllegalArgumentException ignored) { }
    throw ApiError.bad("Invalid " + field);
  }

  static String challenge(String verifier) {
    try {
      return Base64.getUrlEncoder().withoutPadding().encodeToString(
          MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
    } catch (java.security.NoSuchAlgorithmException impossible) {
      throw new IllegalStateException(impossible);
    }
  }

  static boolean equal(String a, String b) {
    return a != null && b != null && MessageDigest.isEqual(
        a.getBytes(StandardCharsets.US_ASCII), b.getBytes(StandardCharsets.US_ASCII));
  }

  String serverUrl() {
    try {
      if (security.origin.length() > 2048 || security.origin.indexOf('%') >= 0
          || security.origin.chars().anyMatch(c -> c < 0x21 || c > 0x7e))
        throw new IllegalArgumentException();
      URI uri = URI.create(security.origin);
      String host = uri.getHost();
      boolean loopback = Set.of("localhost", "127.0.0.1", "[::1]").contains(host == null ? "" : host);
      if (host == null || uri.getRawUserInfo() != null || uri.getRawQuery() != null
          || uri.getRawFragment() != null || !Objects.toString(uri.getRawPath(), "").isEmpty()
          || uri.getPort() < -1 || uri.getPort() == 0 || uri.getPort() > 65535
          || !("https".equals(uri.getScheme()) || (security.demo && loopback && "http".equals(uri.getScheme())))
          || !uri.toASCIIString().equals(security.origin)
          || !host.equals(host.toLowerCase(Locale.ROOT))
          || !uri.getRawAuthority().equals(host + (uri.getPort() == -1 ? "" : ":" + uri.getPort()))
          || !validHost(host))
        throw new IllegalArgumentException();
      return uri.toASCIIString() + "/api/v1";
    } catch (IllegalArgumentException e) {
      throw new ApiError(503, "PAIRING_UNAVAILABLE", "Configure a trusted HTTPS MAIL_ALLOWED_ORIGIN before pairing");
    }
  }

  static boolean validHost(String host) {
    if (host.startsWith("[")) return true; // URI validates IPv6 literals.
    if (host.length() > 253 || host.endsWith(".")) return false;
    for (String label : host.split("\\.", -1))
      if (!label.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) return false;
    if (host.matches("[0-9.]+")) {
      String[] octets = host.split("\\.");
      if (octets.length != 4) return false;
      for (String octet : octets)
        if (!octet.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(octet) > 255) return false;
    } else if (host.matches(".*(?:^|\\.)0x[0-9a-f]+(?:$|\\.).*")) return false;
    return true;
  }

  boolean liveBrowser(String hash, long now) {
    return hash != null && store.db.queryForObject(
        "SELECT COUNT(*) FROM access_token a WHERE a.token_hash=? AND a.expires_at>? "
            + "AND NOT EXISTS (SELECT 1 FROM device_access_token d WHERE d.token_hash=a.token_hash)",
        Integer.class, hash, now) == 1;
  }

  void requireBrowser(String hash, long now) {
    if (!liveBrowser(hash, now))
      throw new ApiError(403, "BROWSER_SESSION_REQUIRED", "Use a currently signed-in browser session");
  }

  void cleanup(long now) {
    store.db.update("DELETE FROM access_token WHERE expires_at<=? AND token_hash NOT IN (SELECT token_hash FROM device_session_access)", now);
    store.db.update("UPDATE device_pairing SET state='EXPIRED',secret_hash=NULL WHERE state IN ('CREATED','CLAIMED','APPROVED') "
        + "AND (expires_at<=? OR NOT EXISTS (SELECT 1 FROM access_token a WHERE a.token_hash=device_pairing.creator_hash AND a.expires_at>?))", now, now);
    store.db.update("DELETE FROM device_pairing WHERE expires_at<?", now - 600_000);
    store.db.update("DELETE FROM paired_device WHERE expires_at<?", now - 86_400_000);
  }

  Map<String, Object> create(String creator, Map<String, Object> body) {
    fields(body);
    String destination = serverUrl();
    return store.write(() -> {
      long now = System.currentTimeMillis();
      requireBrowser(creator, now);
      cleanup(now);
      if (store.db.queryForObject("SELECT COUNT(*) FROM device_pairing", Integer.class) >= MAX_PAIRINGS
          || store.db.queryForObject("SELECT COUNT(*) FROM device_pairing WHERE creator_hash=? "
              + "AND state IN ('CREATED','CLAIMED','APPROVED')", Integer.class, creator) >= MAX_PENDING_PER_SESSION)
        throw new ApiError(429, "PAIRING_LIMIT", "Too many pending pairings; cancel one or wait for expiry");
      String id = Store.id(), secret = security.token();
      long expires = now + PAIRING_LIFETIME;
      store.db.update("INSERT INTO device_pairing(id,creator_hash,secret_hash,state,created_at,expires_at) VALUES(?,?,?,'CREATED',?,?)",
          id, creator, Security.hash(secret), now, expires);
      return Json.map("pairingId", id, "qrPayload", Json.encode(Json.map(
          "type", "harbor-mail-device-pairing", "version", 1, "serverUrl", destination,
          "pairingId", id, "secret", secret)), "expiresAt", iso(expires), "state", "CREATED");
    });
  }

  Map<String, Object> pairing(String id) {
    return store.one("SELECT * FROM device_pairing WHERE id=?", id(id));
  }

  void expire(Map<String, Object> row, long now) {
    if (PENDING.contains(row.get("state")) && (number(row, "expires_at") <= now
        || !liveBrowser((String) row.get("creator_hash"), now))) {
      store.db.update("UPDATE device_pairing SET state='EXPIRED',secret_hash=NULL WHERE id=?", row.get("id"));
      row.put("state", "EXPIRED");
      row.put("secret_hash", null);
    }
  }

  Map<String, Object> ownerPairing(String creator, String id, long now) {
    requireBrowser(creator, now);
    var row = pairing(id);
    if (!equal(creator, (String) row.get("creator_hash"))) throw ApiError.missing();
    expire(row, now);
    return row;
  }

  Map<String, Object> view(String creator, String id) {
    return store.write(() -> state(ownerPairing(creator, id, System.currentTimeMillis())));
  }

  Map<String, Object> claim(Map<String, Object> body, String ip) {
    publicRateLimit(ip);
    fields(body, "pairingId", "secret", "deviceName", "codeChallenge");
    String id = id(text(body, "pairingId", 80)), secret = proof(body, "secret"), code = proof(body, "codeChallenge");
    String name = text(body, "deviceName", 80).strip();
    if (name.isBlank() || name.codePoints().anyMatch(c -> Character.isISOControl(c)
        || Character.getType(c) == Character.FORMAT || c == 0x2028 || c == 0x2029))
      throw ApiError.bad("Invalid deviceName");
    return store.write(() -> {
      var rows = store.db.queryForList("SELECT * FROM device_pairing WHERE id=?", id);
      if (rows.isEmpty()) throw invalidProof();
      var row = rows.getFirst();
      if (!equal(Security.hash(secret), (String) row.get("secret_hash"))) throw invalidProof();
      expire(row, System.currentTimeMillis());
      requireState(row, "CREATED");
      String confirmation = String.format(Locale.ROOT, "%06d", security.random.nextInt(1_000_000));
      store.db.update("UPDATE device_pairing SET state='CLAIMED',secret_hash=NULL,code_challenge=?,device_name=?,confirmation_code=? WHERE id=?",
          code, name, confirmation, id);
      return state(pairing(id));
    });
  }

  Map<String, Object> prove(Map<String, Object> body) {
    fields(body, "pairingId", "codeVerifier");
    String id = id(text(body, "pairingId", 80)), verifier = proof(body, "codeVerifier");
    var rows = store.db.queryForList("SELECT * FROM device_pairing WHERE id=?", id);
    if (rows.isEmpty() || !equal(challenge(verifier), (String) rows.getFirst().get("code_challenge")))
      throw invalidProof();
    var row = rows.getFirst();
    expire(row, System.currentTimeMillis());
    return row;
  }

  Map<String, Object> poll(Map<String, Object> body, String ip) {
    publicRateLimit(ip);
    return store.write(() -> {
      var row = prove(body);
      long now = System.currentTimeMillis();
      if (now - number(row, "last_poll_at") < 2000)
        throw new ApiError(429, "POLL_TOO_FAST", "Wait at least two seconds between polls");
      store.db.update("UPDATE device_pairing SET last_poll_at=? WHERE id=?", now, row.get("id"));
      return state(row);
    });
  }

  Map<String, Object> approve(String creator, String id, Map<String, Object> body, String ip) {
    if (body.containsKey("rememberDevice")) fields(body, "password", "confirmationCode", "rememberDevice");
    else fields(body, "password", "confirmationCode");
    boolean remember = DeviceSessionService.remember(body);
    String password = text(body, "password", 72), confirmation = text(body, "confirmationCode", 6);
    if (!confirmation.matches("[0-9]{6}")) throw ApiError.bad("Invalid confirmationCode");
    // Verify outside the database lock; login shares the same bounded password-attempt budget.
    // Both creator session and transaction state are rechecked under the lock afterwards.
    try {
      security.confirmOwnerPassword(password, ip);
    } catch (ApiError error) {
      if (error.status == 401)
        throw new ApiError(403, "REAUTHENTICATION_FAILED", "Incorrect owner password");
      throw error;
    }
    return store.write(() -> {
      var row = ownerPairing(creator, id, System.currentTimeMillis());
      requireState(row, "CLAIMED");
      if (!equal(confirmation, (String) row.get("confirmation_code")))
        throw new ApiError(400, "CONFIRMATION_MISMATCH", "Confirmation codes do not match");
      store.db.update("UPDATE device_pairing SET state='APPROVED',remember_device=? WHERE id=?", remember, id);
      row.put("remember_device", remember);
      row.put("state", "APPROVED");
      return state(row);
    });
  }

  Map<String, Object> reject(String creator, String id, Map<String, Object> body) {
    fields(body);
    return store.write(() -> {
      var row = ownerPairing(creator, id, System.currentTimeMillis());
      if (PENDING.contains(row.get("state"))) {
        store.db.update("UPDATE device_pairing SET state='REJECTED',secret_hash=NULL WHERE id=?", id);
        row.put("state", "REJECTED");
      } else if ("REDEEMED".equals(row.get("state"))) {
        throw ApiError.conflict("Pairing already redeemed; revoke the device to remove access");
      }
      return state(row);
    });
  }

  Map<String, Object> redeem(Map<String, Object> body, String ip) {
    publicRateLimit(ip);
    return store.write(() -> {
      var row = prove(body);
      requireState(row, "APPROVED");
      long now = System.currentTimeMillis(), expires = now + DEVICE_LIFETIME;
      if (store.db.queryForObject("SELECT COUNT(*) FROM paired_device WHERE revoked=FALSE AND expires_at>?",
          Integer.class, now) >= MAX_DEVICES
          || store.db.queryForObject("SELECT COUNT(*) FROM paired_device", Integer.class) >= 1000)
        throw new ApiError(429, "DEVICE_LIMIT", "Too many devices; revoke an unused device or wait for expiry");
      if (Boolean.TRUE.equals(row.get("remember_device"))) {
        var session = security.deviceSessions.issue((String) row.get("device_name"));
        store.db.update("UPDATE device_pairing SET state='REDEEMED',secret_hash=NULL WHERE id=?", row.get("id"));
        return session;
      }
      String deviceId = Store.id(), token = security.token();
      store.db.update("INSERT INTO paired_device(id,name,created_at,expires_at,last_seen_at,revoked) VALUES(?,?,?,?,?,FALSE)",
          deviceId, row.get("device_name"), now, expires, now);
      store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token), expires);
      store.db.update("INSERT INTO device_access_token VALUES(?,?)", Security.hash(token), deviceId);
      store.db.update("UPDATE device_pairing SET state='REDEEMED',secret_hash=NULL WHERE id=?", row.get("id"));
      return Json.map("accessToken", token, "expiresAt", iso(expires), "deviceId", deviceId,
          "accountName", accountName(), "permission", PERMISSION);
    });
  }

  List<Map<String, Object>> devices() {
    return store.db.queryForList("SELECT * FROM paired_device ORDER BY created_at DESC,id").stream()
        .map(row -> Json.map("id", row.get("id"), "name", row.get("name"),
            "createdAt", iso(number(row, "created_at")), "expiresAt", iso(number(row, "expires_at")),
            "lastSeenAt", iso(number(row, "last_seen_at")), "revoked", row.get("revoked"), "permission", PERMISSION)).toList();
  }

  void revoke(String deviceId) {
    id(deviceId);
    store.write(() -> {
      security.deviceSessions.revokeDevice(deviceId);
      store.db.update("UPDATE paired_device SET revoked=TRUE WHERE id=?", deviceId);
      store.db.update("DELETE FROM access_token WHERE token_hash IN (SELECT token_hash FROM device_access_token WHERE device_id=?)", deviceId);
      return null;
    });
  }

  Map<String, Object> state(Map<String, Object> row) {
    var result = Json.map("pairingId", row.get("id"), "state", row.get("state"),
        "expiresAt", iso(number(row, "expires_at")), "accountName", accountName(), "permission", PERMISSION,
        "rememberDevice", Boolean.TRUE.equals(row.get("remember_device")));
    if (row.get("device_name") != null) result.put("deviceName", row.get("device_name"));
    if (row.get("confirmation_code") != null) result.put("confirmationCode", row.get("confirmation_code"));
    return result;
  }

  String accountName() {
    return store.db.queryForObject("SELECT username FROM owner_user WHERE id=1", String.class);
  }

  static long number(Map<String, Object> row, String key) { return ((Number) row.get(key)).longValue(); }
  static String iso(long value) { return Instant.ofEpochMilli(value).toString(); }
  static ApiError invalidProof() { return new ApiError(401, "INVALID_PAIRING_PROOF", "Invalid pairing proof"); }
  static void requireState(Map<String, Object> row, String expected) {
    if ("EXPIRED".equals(row.get("state"))) throw new ApiError(410, "PAIRING_EXPIRED", "Pairing expired; create a new QR code");
    if (!expected.equals(row.get("state"))) throw ApiError.conflict("Pairing is not " + expected);
  }
}
