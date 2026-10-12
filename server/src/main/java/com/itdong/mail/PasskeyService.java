package com.itdong.mail;

import com.yubico.webauthn.*;
import com.yubico.webauthn.data.*;
import java.net.URI;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Standard WebAuthn verification is exclusively delegated to Yubico's maintained library. */
@Component
public class PasskeyService {
  static final long LIFETIME = 120_000;
  static final int MAX_PENDING = 1000, MAX_PER_SESSION = 5, MAX_CREDENTIALS = 20;
  final Store store;
  final Security security;
  final DevicePairingService pairing;
  final PasskeyCredentialRepository credentials;
  final String androidOrigins;
  final Map<String, Security.Attempt> publicAttempts = new HashMap<>();

  PasskeyService(Store store, Security security, DevicePairingService pairing,
      PasskeyCredentialRepository credentials,
      @Value("${mail.passkeys.android-origins:}") String androidOrigins) {
    this.store = store; this.security = security; this.pairing = pairing;
    this.credentials = credentials; this.androidOrigins = androidOrigins;
  }

  record Configuration(String rpId, Set<String> origins) {}
  Configuration configuration() {
    try {
      // Reuse strict canonical administrator-origin validation; never trust Host, Forwarded,
      // an Origin header, or anything supplied by the options request to establish trust.
      URI configured = URI.create(pairing.serverUrl());
      String host = configured.getHost();
      // WebAuthn RP IDs are domain names, not IP address literals. Synthetic localhost is explicit.
      if (host == null || host.startsWith("[") || host.matches("[0-9.]+")
          || ("localhost".equals(host) && !security.demo)) throw new IllegalArgumentException();
      var origins = new HashSet<String>(); origins.add(security.origin);
      if (!androidOrigins.isBlank()) {
        if (androidOrigins.length() > 1024) throw new IllegalArgumentException();
        for (String entry : androidOrigins.split(",", -1)) {
          String origin = entry.strip();
          String prefix = "android:apk-key-hash:";
          if (!origin.startsWith(prefix)) throw new IllegalArgumentException();
          String hash = origin.substring(prefix.length());
          byte[] bytes = Base64.getUrlDecoder().decode(hash);
          if (bytes.length != 32 || !Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).equals(hash))
            throw new IllegalArgumentException();
          origins.add(origin);
        }
      }
      return new Configuration(host, Set.copyOf(origins));
    } catch (RuntimeException error) { throw unavailable(); }
  }

  RelyingParty relyingParty() {
    var config = configuration();
    return RelyingParty.builder()
        .identity(RelyingPartyIdentity.builder().id(config.rpId()).name("Harbor Mail").build())
        .credentialRepository(credentials).origins(config.origins())
        .allowOriginPort(false).allowOriginSubdomain(false)
        .attestationConveyancePreference(AttestationConveyancePreference.NONE)
        .preferredPubkeyParams(List.of(PublicKeyCredentialParameters.ES256,
            PublicKeyCredentialParameters.EdDSA, PublicKeyCredentialParameters.RS256))
        // Library computes counter validity. Synced (BE) credentials may legitimately not
        // increment; only non-BE credentials require the library's strict counter result below.
        .validateSignatureCounter(false).build();
  }

  Map<String, Object> capabilities() {
    try { return Json.map("available", true, "rpId", configuration().rpId()); }
    catch (ApiError error) { return Json.map("available", false, "reason", "Configure a stable trusted HTTPS origin (localhost only for demo)"); }
  }

  synchronized void publicRateLimit(String ip) {
    long now = System.currentTimeMillis();
    publicAttempts.entrySet().removeIf(e -> now - e.getValue().start() >= 60_000);
    for (String key : List.of("GLOBAL", "IP:" + ip)) {
      var attempt = publicAttempts.get(key);
      if (attempt != null && attempt.count() >= (key.equals("GLOBAL") ? 300 : 60))
        throw new ApiError(429, "RATE_LIMITED", "Too many passkey requests; retry later");
      publicAttempts.put(key, new Security.Attempt(attempt == null ? now : attempt.start(), attempt == null ? 1 : attempt.count() + 1));
    }
  }

  void reauthenticate(String creator, Map<String, Object> body, String ip) {
    pairing.requireBrowser(creator, System.currentTimeMillis());
    if (!(body.get("password") instanceof String password) || password.length() > 72)
      throw ApiError.bad("Invalid password");
    try { security.confirmOwnerPassword(password, ip); }
    catch (ApiError error) {
      if (error.status == 401) throw new ApiError(403, "REAUTHENTICATION_FAILED", "Incorrect owner password");
      throw error;
    }
  }

  void cleanup(long now) {
    store.db.update("DELETE FROM passkey_request WHERE expires_at<=? OR (creator_hash IS NOT NULL AND NOT EXISTS "
        + "(SELECT 1 FROM access_token a WHERE a.token_hash=passkey_request.creator_hash AND a.expires_at>?))", now, now);
  }

  String saveRequest(String operation, String creator, String name, String json) {
    long now = System.currentTimeMillis(); cleanup(now);
    if (store.db.queryForObject("SELECT COUNT(*) FROM passkey_request", Integer.class) >= MAX_PENDING
        || (creator != null && store.db.queryForObject("SELECT COUNT(*) FROM passkey_request WHERE creator_hash=?", Integer.class, creator) >= MAX_PER_SESSION))
      throw new ApiError(429, "PASSKEY_LIMIT", "Too many pending requests; wait for expiry");
    String id = Store.id();
    store.db.update("INSERT INTO passkey_request(id,operation,creator_hash,credential_name,request_json,expires_at,credential_epoch) VALUES(?,?,?,?,?,?,?)",
        id, operation, creator, name, json, now + LIFETIME, epoch());
    return id;
  }

  long epoch() {
    var rows = store.db.queryForList("SELECT revocation_epoch FROM passkey_user WHERE owner_id=1");
    return rows.isEmpty() ? 0 : ((Number) rows.getFirst().get("revocation_epoch")).longValue();
  }

  void requireLiveRequest(Map<String, Object> saved, String operation) {
    if (((Number) saved.get("expires_at")).longValue() <= System.currentTimeMillis()
        || ((Number) saved.get("credential_epoch")).longValue() != epoch()) throw invalid(operation);
  }

  Map<String, Object> registrationOptions(String creator, Map<String, Object> body, String ip) {
    DevicePairingService.fields(body, "password", "name");
    reauthenticate(creator, body, ip);
    String name = DevicePairingService.text(body, "name", 80).strip();
    if (name.codePoints().anyMatch(c -> Character.isISOControl(c) || Character.getType(c) == Character.FORMAT || c == 0x2028 || c == 0x2029))
      throw ApiError.bad("Invalid passkey name");
    var rp = relyingParty();
    return store.write(() -> {
      pairing.requireBrowser(creator, System.currentTimeMillis()); requireCredentialCapacity();
      if (store.db.queryForObject("SELECT COUNT(*) FROM passkey_user WHERE owner_id=1", Integer.class) == 0)
        store.db.update("INSERT INTO passkey_user(owner_id,user_handle) VALUES(1,?)", security.token());
      String username = pairing.accountName();
      var request = rp.startRegistration(StartRegistrationOptions.builder()
          .user(UserIdentity.builder().name(username).displayName(username)
              .id(credentials.getUserHandleForUsername(username).orElseThrow()).build())
          .authenticatorSelection(AuthenticatorSelectionCriteria.builder()
              .residentKey(ResidentKeyRequirement.REQUIRED).userVerification(UserVerificationRequirement.REQUIRED).build())
          .timeout(LIFETIME).build());
      try {
        String id = saveRequest("REGISTER", creator, name, request.toJson());
        return Json.map("requestId", id, "publicKey", Json.decode(request.toCredentialsCreateJson()).get("publicKey"));
      } catch (com.fasterxml.jackson.core.JsonProcessingException error) { throw new IllegalStateException("Cannot serialize passkey options", error); }
    });
  }

  void requireCredentialCapacity() {
    if (store.db.queryForObject("SELECT COUNT(*) FROM passkey_credential WHERE owner_id=1", Integer.class) >= MAX_CREDENTIALS)
      throw new ApiError(429, "PASSKEY_LIMIT", "Remove an unused passkey before adding another");
  }

  /** Independent committed consume: a failed verification cannot roll back and revive a challenge. */
  Map<String, Object> consume(Map<String, Object> body, String operation, String creator) {
    DevicePairingService.fields(body, "requestId", "credential");
    String id = DevicePairingService.id(DevicePairingService.text(body, "requestId", 36));
    return store.write(() -> {
      var rows = store.db.queryForList("SELECT * FROM passkey_request WHERE id=?", id);
      if (rows.isEmpty()) throw invalid(operation);
      var row = rows.getFirst();
      // A different session cannot burn another browser's registration challenge.
      if (!operation.equals(row.get("operation")) || (creator != null && !DevicePairingService.equal(creator, (String) row.get("creator_hash"))))
        throw invalid(operation);
      store.db.update("DELETE FROM passkey_request WHERE id=?", id);
      return row;
    });
  }

  String responseJson(Map<String, Object> body) {
    if (!(body.get("credential") instanceof Map<?, ?> value)) throw new IllegalArgumentException();
    String json = Json.encode(value);
    if (json.length() > 65_536) throw new IllegalArgumentException();
    return json;
  }

  void requireFirstParty(AuthenticatorResponse response) {
    // This app does not support embedded cross-origin ceremonies. Cryptographic parsing and
    // origin/challenge/signature verification still belong to the library.
    var client = Json.decode(new String(response.getClientDataJSON().getBytes(), java.nio.charset.StandardCharsets.UTF_8));
    if ((client.containsKey("crossOrigin") && !Boolean.FALSE.equals(client.get("crossOrigin")))
        || client.containsKey("topOrigin")) throw new IllegalArgumentException();
  }

  Map<String, Object> registrationVerify(String creator, Map<String, Object> body) {
    pairing.requireBrowser(creator, System.currentTimeMillis());
    var saved = consume(body, "REGISTER", creator);
    return store.write(() -> {
      pairing.requireBrowser(creator, System.currentTimeMillis()); requireCredentialCapacity();
      requireLiveRequest(saved, "REGISTER");
      try {
        var request = PublicKeyCredentialCreationOptions.fromJson((String) saved.get("request_json"));
        var response = PublicKeyCredential.parseRegistrationResponseJson(responseJson(body));
        requireFirstParty(response.getResponse());
        var result = relyingParty().finishRegistration(FinishRegistrationOptions.builder().request(request)
            .response(response).build());
        if (!result.isUserVerified() || result.getKeyId().getId().size() > 1536
            || !credentials.getUserHandleForUsername(pairing.accountName()).orElseThrow().equals(request.getUser().getId()))
          throw new IllegalArgumentException();
        if (!credentials.lookupAll(result.getKeyId().getId()).isEmpty()) throw new IllegalArgumentException();
        String id = Store.id(); long now = System.currentTimeMillis();
        store.db.update("INSERT INTO passkey_credential(id,owner_id,credential_id,public_key,signature_count,backup_eligible,backup_state,name,created_at) VALUES(?,1,?,?,?,?,?,?,?)",
            id, result.getKeyId().getId().getBase64Url(), result.getPublicKeyCose().getBase64Url(), result.getSignatureCount(),
            result.isBackupEligible(), result.isBackedUp(), saved.get("credential_name"), now);
        return Json.map("id", id, "name", saved.get("credential_name"), "createdAt", DevicePairingService.iso(now));
      } catch (ApiError error) { throw error; }
      catch (Exception error) { throw invalid("REGISTER"); }
    });
  }

  Map<String, Object> authenticationOptions(Map<String, Object> body, String ip) {
    publicRateLimit(ip);
    if (body == null || !Set.of("rememberDevice", "deviceName").containsAll(body.keySet()))
      throw ApiError.bad("Unexpected authentication options fields");
    boolean remember = DeviceSessionService.remember(body);
    String deviceName = DeviceSessionService.deviceName(body);
    var request = relyingParty().startAssertion(StartAssertionOptions.builder()
        .userVerification(UserVerificationRequirement.REQUIRED).timeout(LIFETIME).build());
    return store.write(() -> {
      try {
        String id = saveRequest("AUTHENTICATE", null, null, request.toJson());
        store.db.update("UPDATE passkey_request SET remember_device=?,device_name=? WHERE id=?", remember, remember ? deviceName : null, id);
        return Json.map("requestId", id, "publicKey", Json.decode(request.toCredentialsGetJson()).get("publicKey"));
      } catch (com.fasterxml.jackson.core.JsonProcessingException error) { throw new IllegalStateException("Cannot serialize passkey options", error); }
    });
  }

  Map<String, Object> authenticationVerify(Map<String, Object> body, String ip) {
    publicRateLimit(ip);
    var saved = consume(body, "AUTHENTICATE", null);
    return store.write(() -> {
      requireLiveRequest(saved, "AUTHENTICATE");
      try {
        var response = PublicKeyCredential.parseAssertionResponseJson(responseJson(body));
        requireFirstParty(response.getResponse());
        // Discoverable authentication must supply its persisted userHandle, never client username.
        if (response.getResponse().getUserHandle().isEmpty()) throw new IllegalArgumentException();
        var result = relyingParty().finishAssertion(FinishAssertionOptions.builder()
            .request(AssertionRequest.fromJson((String) saved.get("request_json"))).response(response).build());
        if (!result.isSuccess() || !result.isUserVerified()
            || (!result.isBackupEligible() && !result.isSignatureCounterValid())
            || !result.getUsername().equals(pairing.accountName())
            || credentials.lookup(result.getCredential().getCredentialId(), response.getResponse().getUserHandle().orElseThrow()).isEmpty())
          throw new IllegalArgumentException();
        store.db.update("UPDATE passkey_credential SET signature_count=?,backup_state=?,last_used_at=? WHERE owner_id=1 AND credential_id=?",
            Math.max(result.getSignatureCount(), result.getCredential().getSignatureCount()), result.isBackedUp(),
            System.currentTimeMillis(), result.getCredential().getCredentialId().getBase64Url());
        var session = Boolean.TRUE.equals(saved.get("remember_device"))
            ? security.deviceSessions.issue((String) saved.get("device_name")) : security.issueOwnerSession();
        session.put("accountName", pairing.accountName()); session.put("permission", DevicePairingService.PERMISSION);
        return session;
      } catch (ApiError error) { throw error; }
      catch (Exception error) { throw invalid("AUTHENTICATE"); }
    });
  }

  List<Map<String, Object>> list() {
    return store.db.queryForList("SELECT id,name,created_at,last_used_at FROM passkey_credential WHERE owner_id=1 ORDER BY created_at,id")
        .stream().map(row -> Json.map("id", row.get("id"), "name", row.get("name"),
            "createdAt", DevicePairingService.iso(((Number) row.get("created_at")).longValue()),
            "lastUsedAt", row.get("last_used_at") == null ? null : DevicePairingService.iso(((Number) row.get("last_used_at")).longValue()))).toList();
  }

  void delete(String creator, String id, Map<String, Object> body, String ip) {
    DevicePairingService.id(id); DevicePairingService.fields(body, "password");
    reauthenticate(creator, body, ip);
    store.write(() -> {
      pairing.requireBrowser(creator, System.currentTimeMillis());
      store.db.update("DELETE FROM passkey_credential WHERE id=? AND owner_id=1", id);
      // All outstanding ceremonies may reference deleted credentials (including exclusion lists).
      store.db.update("UPDATE passkey_user SET revocation_epoch=revocation_epoch+1 WHERE owner_id=1");
      store.db.update("DELETE FROM passkey_request");
      return null;
    });
  }

  static ApiError unavailable() { return new ApiError(503, "PASSKEY_UNAVAILABLE", "Configure a stable trusted HTTPS origin before using passkeys"); }
  static ApiError invalid(String operation) { return new ApiError(operation.equals("REGISTER") ? 400 : 401, "INVALID_PASSKEY", "Passkey verification failed; start again"); }
}
