package com.itdong.mail;

import com.itdong.mail.provider.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;

@Service
public class OAuthService {
  final Store store;
  final Security security;
  final Environment env;
  final OAuthClient client = new OAuthClient(Json.MAPPER);

  OAuthService(Store store, Security security, Environment env) {
    this.store = store;
    this.security = security;
    this.env = env;
  }

  boolean configured(String provider) {
    return !env.getProperty("MAIL_OAUTH_" + provider + "_CLIENT_ID", "").isBlank()
        && !env.getProperty("MAIL_OAUTH_" + provider + "_REDIRECT_URI", "").isBlank()
        && !env.getProperty("MAIL_OAUTH_" + provider + "_CLIENT_SECRET", "").isBlank();
  }

  OAuthClient.Config config(String provider) {
    if (!Set.of("GMAIL", "OUTLOOK", "EXCHANGE").contains(provider))
      throw ApiError.bad("Unsupported OAuth provider");
    if (!configured(provider))
      throw new ApiError(
          409,
          "PROVIDER_NOT_CONFIGURED",
          "Operator must configure this provider's OAuth client and HTTPS redirect URI");
    String pre = "MAIL_OAUTH_" + provider + "_";
    return new OAuthClient.Config(
        provider,
        env.getProperty(pre + "CLIENT_ID"),
        env.getProperty(pre + "CLIENT_SECRET", ""),
        env.getProperty(pre + "REDIRECT_URI"),
        env.getProperty(pre + "TENANT", ""));
  }

  Map<String, Object> start(String provider) {
    if (security.demo)
      throw new ApiError(409, "DEMO_MODE", "Real mailbox authorization is disabled in demo mode");
    var c = config(provider);
    String state = security.token(), verifier = security.token() + security.token();
    try {
      String challenge =
          Base64.getUrlEncoder()
              .withoutPadding()
              .encodeToString(
                  MessageDigest.getInstance("SHA-256")
                      .digest(verifier.getBytes(StandardCharsets.US_ASCII)));
      String url = client.authorizationUrl(c, state, challenge);
      store.write(
          () -> {
            store.db.update(
                "DELETE FROM oauth_state WHERE expires_at<?", System.currentTimeMillis());
            store.db.update(
                "INSERT INTO oauth_state VALUES(?,?,?,?)",
                Security.hash(state),
                provider,
                System.currentTimeMillis() + 600_000,
                security.encrypt(Json.encode(Json.map("verifier", verifier, "owner", 1))));
            return null;
          });
      return Json.map("authorizationUrl", url);
    } catch (java.security.NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  void callback(String provider, String state, String code, String error) {
    if (security.demo) throw new ApiError(409, "DEMO_MODE", "OAuth disabled in demo");
    if (state.length() > 200 || state.isBlank()) throw ApiError.bad("Invalid authorization state");
    var row =
        store.write(
            () -> {
              var rows =
                  store.db.queryForList(
                      "SELECT * FROM oauth_state WHERE state_hash=? AND provider=? AND"
                          + " expires_at>?",
                      Security.hash(state),
                      provider,
                      System.currentTimeMillis());
              if (rows.isEmpty())
                throw new ApiError(
                    400, "INVALID_OAUTH_STATE", "Authorization state expired or already used");
              store.db.update("DELETE FROM oauth_state WHERE state_hash=?", Security.hash(state));
              return rows.getFirst();
            });
    if (!error.isBlank() || code.isBlank())
      throw new ApiError(400, "OAUTH_DENIED", "Mailbox authorization was not completed");
    if (code.length() > 8192) throw ApiError.bad("Invalid code");
    var stateData = Json.decode(security.decrypt((String) row.get("payload")));
    var config = config(provider);
    var tokens = client.exchange(config, code, Json.string(stateData, "verifier"));
    String email = MailService.address(client.identityEmail(config, tokens.accessToken()));
    store.write(
        () -> {
          var existing =
              store.db.queryForList("SELECT id,data FROM mail_account").stream()
                  .filter(
                      a -> {
                        var d = Json.decode((String) a.get("data"));
                        return provider.equals(d.get("provider"))
                            && email.equalsIgnoreCase(Json.string(d, "email"));
                      })
                  .findFirst();
          String id = existing.isPresent() ? (String) existing.get().get("id") : Store.id();
          var a =
              Json.map(
                  "id",
                  id,
                  "provider",
                  provider,
                  "email",
                  email,
                  "displayName",
                  email,
                  "status",
                  "NOT_SYNCED",
                  "lastSyncAt",
                  null,
                  "unreadCount",
                  0,
                  "errorCode",
                  null);
          String secret = security.encrypt(Json.encode(secret(tokens)));
          if (existing.isPresent())
            store.db.update(
                "UPDATE mail_account SET data=?,secret=? WHERE id=?", Json.encode(a), secret, id);
          else
            store.db.update("INSERT INTO mail_account VALUES(?,?,?)", id, Json.encode(a), secret);
          store.changed("ACCOUNT", id, 1);
          return null;
        });
  }

  static Map<String, Object> secret(OAuthClient.Tokens t) {
    return Json.map(
        "accessToken",
        t.accessToken(),
        "refreshToken",
        t.refreshToken(),
        "expiresAt",
        t.expiresAt().toString(),
        "scope",
        t.scope());
  }

  // Single-owner, single-node MVP: synchronized refresh prevents token rotation races.
  synchronized ProviderGateway.Credentials credentials(String id) {
    var a = store.data("mail_account", id);
    var row = store.one("SELECT secret FROM mail_account WHERE id=?", id);
    var s = Json.decode(security.decrypt((String) row.get("secret")));
    String provider = Json.string(a, "provider");
    if (Set.of("GMAIL", "OUTLOOK", "EXCHANGE").contains(provider)
        && !Json.string(s, "expiresAt").isEmpty()
        && Instant.parse(Json.string(s, "expiresAt")).isBefore(Instant.now().plusSeconds(90))) {
      String refresh = Json.string(s, "refreshToken");
      if (refresh.isBlank())
        throw new ApiError(409, "REAUTH_REQUIRED", "Authorize this mailbox again");
      var tokens = client.refresh(config(provider), refresh);
      s = secret(tokens);
      String encoded = security.encrypt(Json.encode(s));
      store.write(
          () -> {
            store.db.update("UPDATE mail_account SET secret=? WHERE id=?", encoded, id);
            return null;
          });
    }
    return new ProviderGateway.Credentials(
        provider, Json.string(a, "email"), Json.string(s, "accessToken"), Json.string(s, "secret"));
  }
}
