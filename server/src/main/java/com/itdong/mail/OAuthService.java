package com.itdong.mail;

import com.itdong.mail.provider.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

@Service
public class OAuthService {
  final Store store;
  final Security security;
  final OAuthSettings settings;
  final OAuthClient client;

  @Autowired
  OAuthService(Store store, Security security, OAuthSettings settings) {
    this(store, security, settings, new OAuthClient(Json.MAPPER));
  }

  OAuthService(Store store, Security security, OAuthSettings settings, OAuthClient client) {
    this.store = store;
    this.security = security;
    this.settings = settings;
    this.client = client;
  }

  boolean configured(String provider) {
    return settings.effective(provider).configured();
  }

  OAuthClient.Config config(String provider) {
    return settings.required(provider).config();
  }

  Map<String, Object> start(String provider) {
    return start(provider, "");
  }

  Map<String, Object> start(String provider, String completionId) {
    if (!completionId.isEmpty() && !completionId.matches("[a-f0-9]{32}"))
      throw ApiError.bad("Invalid completion identifier");
    if (security.demo)
      throw new ApiError(409, "DEMO_MODE", "Real mailbox authorization is disabled in demo mode");
    String state = security.token(), verifier = security.token() + security.token();
    try {
      String challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
          MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.US_ASCII)));
      return store.write(() -> {
        var snapshot = settings.required(provider);
        String url = client.authorizationUrl(snapshot.config(), state, challenge);
        store.db.update("DELETE FROM oauth_state WHERE expires_at<?", System.currentTimeMillis());
        store.db.update("INSERT INTO oauth_state VALUES(?,?,?,?)", Security.hash(state), provider,
            System.currentTimeMillis() + 600_000,
            security.encrypt(Json.encode(Json.map("verifier", verifier, "owner", 1,
                "configFingerprint", snapshot.fingerprint(), "completionId", completionId))));
        return Json.map("authorizationUrl", url);
      });
    } catch (java.security.NoSuchAlgorithmException e) { throw new IllegalStateException(e); }
  }

  String callback(String provider, String state, String code, String error) {
    if (security.demo) throw new ApiError(409, "DEMO_MODE", "OAuth disabled in demo");
    OAuthSettings.provider(provider);
    if (state.length() > 200 || state.isBlank()) throw ApiError.bad("Invalid authorization state");
    var row = store.write(() -> {
      var rows = store.db.queryForList("SELECT * FROM oauth_state WHERE state_hash=? AND provider=? AND expires_at>?",
          Security.hash(state), provider, System.currentTimeMillis());
      if (rows.isEmpty()) throw new ApiError(400, "INVALID_OAUTH_STATE", "Authorization state expired or already used");
      store.db.update("DELETE FROM oauth_state WHERE state_hash=?", Security.hash(state));
      return rows.getFirst();
    });
    if (!error.isBlank() || code.isBlank())
      throw new ApiError(400, "OAUTH_DENIED", "Mailbox authorization was not completed");
    if (code.length() > 8192) throw ApiError.bad("Invalid code");
    var stateData = Json.decode(security.decrypt((String) row.get("payload")));
    var snapshot = settings.effective(provider);
    if (!snapshot.configured() || !snapshot.fingerprint().equals(Json.string(stateData, "configFingerprint")))
      throw configChanged();
    var tokens = client.exchange(snapshot.config(), code, Json.string(stateData, "verifier"));
    // Avoid identity retrieval with a token if an admin changed the app while exchange was in flight.
    ensureUnchanged(snapshot);
    String email = MailService.address(client.identityEmail(snapshot.config(), tokens.accessToken()));
    store.write(() -> {
      // Recheck under the same DB lock used by admin mutations before storing any returned token.
      ensureUnchanged(snapshot);
      var existing = store.db.queryForList("SELECT id,data FROM mail_account").stream()
          .filter(a -> {
            var d = Json.decode((String) a.get("data"));
            return provider.equals(d.get("provider")) && email.equalsIgnoreCase(Json.string(d, "email"));
          }).findFirst();
      String id = existing.isPresent() ? (String) existing.get().get("id") : Store.id();
      var a = Json.map("id", id, "provider", provider, "email", email, "displayName", email,
          "status", "NOT_SYNCED", "lastSyncAt", null, "unreadCount", 0, "errorCode", null);
      var tokenData = secret(tokens);
      tokenData.put("configFingerprint", snapshot.fingerprint());
      String secret = security.encrypt(Json.encode(tokenData));
      if (existing.isPresent())
        store.db.update("UPDATE mail_account SET data=?,secret=? WHERE id=?", Json.encode(a), secret, id);
      else store.db.update("INSERT INTO mail_account VALUES(?,?,?)", id, Json.encode(a), secret);
      store.changed("ACCOUNT", id, 1);
      return null;
    });
    return Json.string(stateData, "completionId");
  }

  private void ensureUnchanged(OAuthSettings.Snapshot snapshot) {
    var current = settings.effective(snapshot.config().provider());
    if (!current.configured() || current.revision() != snapshot.revision()
        || !current.fingerprint().equals(snapshot.fingerprint())) throw configChanged();
  }

  private static ApiError configChanged() {
    return new ApiError(409, "OAUTH_CONFIG_CHANGED", "OAuth settings changed; start mailbox authorization again");
  }

  private static ApiError reauthorize() {
    return new ApiError(409, "REAUTH_REQUIRED", "OAuth application settings changed or tokens expired; authorize this mailbox again");
  }

  static Map<String, Object> secret(OAuthClient.Tokens t) {
    return Json.map("accessToken", t.accessToken(), "refreshToken", t.refreshToken(),
        "expiresAt", t.expiresAt().toString(), "scope", t.scope());
  }

  private record CredentialSnapshot(Map<String, Object> account, String encoded,
      Map<String, Object> secret, OAuthSettings.Snapshot settings) {
    @Override public String toString() { return "CredentialSnapshot[REDACTED]"; }
  }

  // Single-owner, single-node MVP: synchronized refresh prevents token rotation races.
  synchronized ProviderGateway.Credentials credentials(String id) {
    var captured = store.write(() -> {
      var account = store.data("mail_account", id);
      String provider = Json.string(account, "provider");
      OAuthSettings.Snapshot snapshot = null;
      if (OAuthSettings.PROVIDERS.contains(provider)) {
        snapshot = settings.effective(provider);
        settings.bindLegacyAccounts(snapshot);
      }
      String encoded = (String) store.one("SELECT secret FROM mail_account WHERE id=?", id).get("secret");
      var secret = Json.decode(security.decrypt(encoded));
      if (snapshot != null && (!snapshot.configured()
          || !snapshot.fingerprint().equals(Json.string(secret, "configFingerprint")))) throw reauthorize();
      return new CredentialSnapshot(account, encoded, secret, snapshot);
    });
    var secret = captured.secret();
    String provider = Json.string(captured.account(), "provider");
    if (captured.settings() != null && !Json.string(secret, "expiresAt").isEmpty()
        && Instant.parse(Json.string(secret, "expiresAt")).isBefore(Instant.now().plusSeconds(90))) {
      String refresh = Json.string(secret, "refreshToken");
      if (refresh.isBlank()) throw reauthorize();
      var tokens = client.refresh(captured.settings().config(), refresh);
      secret = secret(tokens);
      secret.put("configFingerprint", captured.settings().fingerprint());
      String encoded = security.encrypt(Json.encode(secret));
      store.write(() -> {
        var current = settings.effective(provider);
        if (!current.configured() || current.revision() != captured.settings().revision()
            || !current.fingerprint().equals(captured.settings().fingerprint())) throw reauthorize();
        // A newly completed authorization must never be overwritten by an older refresh.
        if (store.db.update("UPDATE mail_account SET secret=? WHERE id=? AND secret=?",
            encoded, id, captured.encoded()) != 1) throw reauthorize();
        return null;
      });
    }
    return new ProviderGateway.Credentials(provider, Json.string(captured.account(), "email"),
        Json.string(secret, "accessToken"), Json.string(secret, "secret"));
  }
}
