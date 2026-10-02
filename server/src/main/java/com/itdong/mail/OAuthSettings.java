package com.itdong.mail;

import com.itdong.mail.provider.OAuthClient;
import jakarta.annotation.PostConstruct;
import java.net.URI;
import java.util.*;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Service;

/** Single-owner admin settings. Database overrides are deliberately whole-provider, never per-field. */
@Service
public class OAuthSettings {
  static final List<String> PROVIDERS = List.of("GMAIL", "OUTLOOK", "EXCHANGE");
  final Store store;
  final Security security;
  final Environment env;

  OAuthSettings(Store store, Security security, Environment env) {
    this.store = store;
    this.security = security;
    this.env = env;
  }

  record Snapshot(OAuthClient.Config config, String source, long revision) {
    String fingerprint() {
      // Secret rotation does not change OAuth application identity or invalidate refresh tokens.
      return Security.hash(Json.encode(List.of("v1", config.provider(), config.clientId(),
          config.redirectUri(), config.tenant())));
    }

    List<String> errors() {
      var errors = new ArrayList<String>();
      if (config.clientId().isBlank()) errors.add("Client ID is required");
      if (config.clientSecret().isBlank()) errors.add("Client secret is required");
      if (config.redirectUri().isBlank()) errors.add("Redirect URI is required");
      else if (!validRedirect(config.provider(), config.redirectUri()))
        errors.add("Redirect URI must be HTTPS with the exact provider callback path and no query or fragment");
      if (!validTenant(config.provider(), config.tenant())) errors.add("Invalid tenant for this provider");
      if (config.clientId().length() > 1024 || hasControl(config.clientId())) errors.add("Invalid client ID");
      if (config.clientSecret().length() > 8192 || hasControl(config.clientSecret())) errors.add("Invalid client secret");
      return errors;
    }

    boolean configured() { return errors().isEmpty(); }

    Map<String, Object> metadata() {
      return Json.map("provider", config.provider(), "source", source, "revision", revision,
          "clientId", config.clientId(), "redirectUri", config.redirectUri(), "tenant", config.tenant(),
          "hasClientSecret", !config.clientSecret().isBlank(), "configured", configured(),
          "validationErrors", errors());
    }

    @Override public String toString() { return "OAuthSettingsSnapshot[REDACTED]"; }
  }

  static void provider(String provider) {
    if (!PROVIDERS.contains(provider)) throw ApiError.bad("Unsupported OAuth provider");
  }

  Snapshot effective(String provider) {
    provider(provider);
    var row = store.one("SELECT * FROM oauth_provider_settings WHERE provider=?", provider);
    String source = (String) row.get("source");
    OAuthClient.Config config;
    if ("DATABASE".equals(source)) {
      String encrypted = (String) row.get("client_secret");
      config = new OAuthClient.Config(provider, (String) row.get("client_id"),
          encrypted == null ? "" : security.decrypt(encrypted), (String) row.get("redirect_uri"),
          tenant(provider, (String) row.get("tenant")));
    } else {
      String prefix = "MAIL_OAUTH_" + provider + "_";
      config = new OAuthClient.Config(provider, env.getProperty(prefix + "CLIENT_ID", "").trim(),
          env.getProperty(prefix + "CLIENT_SECRET", ""),
          env.getProperty(prefix + "REDIRECT_URI", "").trim(),
          tenant(provider, env.getProperty(prefix + "TENANT", "").trim()));
    }
    return new Snapshot(config, source, ((Number) row.get("revision")).longValue());
  }

  Snapshot required(String provider) {
    Snapshot snapshot = effective(provider);
    if (!snapshot.configured())
      throw new ApiError(409, "PROVIDER_NOT_CONFIGURED",
          "Configure this provider's client ID, secret, HTTPS callback and tenant in admin settings");
    return snapshot;
  }

  Map<String, Object> list() {
    return store.write(() -> Json.map("demoMode", security.demo, "readOnly", security.demo,
        "items", PROVIDERS.stream().map(p -> effective(p).metadata()).toList()));
  }

  Map<String, Object> save(String provider, Map<String, Object> body) {
    writable(provider);
    only(body, Set.of("revision", "clientId", "redirectUri", "tenant", "clientSecret", "clearClientSecret"));
    long revision = revision(body);
    String id = text(body, "clientId", 1024, true);
    String redirect = text(body, "redirectUri", 2048, true);
    String tenant = tenant(provider, text(body, "tenant", 253, false));
    String suppliedSecret = text(body, "clientSecret", 8192, false);
    Object clearValue = body.getOrDefault("clearClientSecret", false);
    if (!(clearValue instanceof Boolean)) throw ApiError.bad("clearClientSecret must be a boolean");
    boolean clear = (Boolean) clearValue;
    if (clear && !suppliedSecret.isBlank())
      throw ApiError.bad("Choose either a replacement client secret or clearClientSecret");
    if (!redirect.isBlank() && !validRedirect(provider, redirect))
      throw ApiError.bad("Redirect URI must be HTTPS with exact path /api/v1/oauth/" + provider
          + "/callback, without credentials, query or fragment");
    if (!validTenant(provider, tenant))
      throw ApiError.bad("Invalid tenant: Outlook requires consumers; Exchange requires organizations, a tenant UUID or domain; Gmail has no tenant");
    return store.write(() -> {
      Snapshot old = effective(provider);
      checkRevision(old, revision);
      bindLegacyAccounts(old);
      String secret = clear ? "" : suppliedSecret.isBlank() ? old.config().clientSecret() : suppliedSecret;
      int changed = store.db.update("UPDATE oauth_provider_settings SET source='DATABASE',revision=?,client_id=?,"
              + "redirect_uri=?,tenant=?,client_secret=? WHERE provider=? AND revision=?",
          revision + 1, id, redirect, tenant, secret.isEmpty() ? null : security.encrypt(secret), provider, revision);
      if (changed != 1) throw revisionConflict();
      Snapshot updated = effective(provider);
      markIncompatibleAccounts(updated);
      store.changed("OAUTH_SETTINGS", provider, updated.revision());
      return updated.metadata();
    });
  }

  Map<String, Object> reset(String provider, Map<String, Object> body) {
    writable(provider);
    only(body, Set.of("revision"));
    long revision = revision(body);
    return store.write(() -> {
      Snapshot old = effective(provider);
      checkRevision(old, revision);
      bindLegacyAccounts(old);
      int changed = store.db.update("UPDATE oauth_provider_settings SET source='ENVIRONMENT',revision=?,"
              + "client_id='',redirect_uri='',tenant='',client_secret=NULL WHERE provider=? AND revision=?",
          revision + 1, provider, revision);
      if (changed != 1) throw revisionConflict();
      Snapshot updated = effective(provider);
      markIncompatibleAccounts(updated);
      store.changed("OAUTH_SETTINGS", provider, updated.revision());
      return updated.metadata();
    });
  }

  private void writable(String provider) {
    provider(provider);
    if (security.demo) throw new ApiError(409, "DEMO_MODE", "OAuth settings are read-only in demo mode");
  }

  static void checkRevision(Snapshot snapshot, long revision) {
    if (snapshot.revision() != revision) throw revisionConflict();
  }

  private static ApiError revisionConflict() {
    return new ApiError(409, "CONFIG_REVISION_CONFLICT", "OAuth settings changed; reload before saving");
  }

  private static long revision(Map<String, Object> body) {
    Object value = body.get("revision");
    if (!(value instanceof Integer || value instanceof Long) || ((Number) value).longValue() < 0
        || ((Number) value).longValue() == Long.MAX_VALUE)
      throw ApiError.bad("revision must be a non-negative integer");
    return ((Number) value).longValue();
  }

  private static void only(Map<String, Object> body, Set<String> allowed) {
    if (!allowed.containsAll(body.keySet())) throw ApiError.bad("Unknown OAuth setting field");
  }

  private static String text(Map<String, Object> body, String key, int max, boolean required) {
    Object value = body.get(key);
    if (value == null && !body.containsKey(key) && !required) return "";
    if (!(value instanceof String s) || s.length() > max || hasControl(s))
      throw ApiError.bad("Invalid " + key);
    return key.equals("clientSecret") ? s : s.trim();
  }

  private static boolean hasControl(String value) {
    return value.chars().anyMatch(Character::isISOControl);
  }

  static boolean validRedirect(String provider, String value) {
    try {
      URI uri = URI.create(value);
      return value.length() <= 2048 && "https".equals(uri.getScheme()) && uri.getHost() != null
          && !uri.getHost().isBlank() && uri.getRawUserInfo() == null
          && uri.getRawQuery() == null && uri.getRawFragment() == null
          && (uri.getPort() == -1 || (uri.getPort() > 0 && uri.getPort() <= 65535))
          && ("/api/v1/oauth/" + provider + "/callback").equals(uri.getRawPath());
    } catch (IllegalArgumentException e) { return false; }
  }

  static String tenant(String provider, String tenant) {
    if (tenant.isBlank()) return switch (provider) {
      case "OUTLOOK" -> "consumers";
      case "EXCHANGE" -> "organizations";
      default -> "";
    };
    return tenant.toLowerCase(Locale.ROOT);
  }

  static boolean validTenant(String provider, String tenant) {
    if (provider.equals("GMAIL")) return tenant.isEmpty();
    if (provider.equals("OUTLOOK")) return tenant.equals("consumers");
    if (tenant.equals("organizations")) return true;
    if (tenant.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) return true;
    if (tenant.length() > 253 || !tenant.contains(".")) return false;
    String[] labels = tenant.split("\\.", -1);
    for (String label : labels)
      if (!label.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) return false;
    return labels[labels.length - 1].matches("[a-z]{2,63}");
  }

  // Upgrade old env-based tokens before any override can change their application identity.
  // Only metadata is added; token values and the encryption key remain unchanged.
  @PostConstruct
  void bindExistingEnvironmentTokens() {
    if (security.demo) return;
    store.write(() -> {
      for (String provider : PROVIDERS) bindLegacyAccounts(effective(provider));
      return null;
    });
  }

  void bindLegacyAccounts(Snapshot snapshot) {
    if (!"ENVIRONMENT".equals(snapshot.source()) || !snapshot.configured()) return;
    for (var row : store.db.queryForList("SELECT id,data,secret FROM mail_account")) {
      var account = Json.decode((String) row.get("data"));
      if (!snapshot.config().provider().equals(account.get("provider"))) continue;
      var secret = Json.decode(security.decrypt((String) row.get("secret")));
      if (!Json.string(secret, "configFingerprint").isBlank()) continue;
      secret.put("configFingerprint", snapshot.fingerprint());
      store.db.update("UPDATE mail_account SET secret=? WHERE id=?",
          security.encrypt(Json.encode(secret)), row.get("id"));
    }
  }

  private void markIncompatibleAccounts(Snapshot snapshot) {
    for (var row : store.db.queryForList("SELECT id,data,secret FROM mail_account")) {
      var account = Json.decode((String) row.get("data"));
      if (!snapshot.config().provider().equals(account.get("provider"))) continue;
      var secret = Json.decode(security.decrypt((String) row.get("secret")));
      boolean compatible = snapshot.configured()
          && snapshot.fingerprint().equals(Json.string(secret, "configFingerprint"));
      if (compatible) {
        // Restoring the original app/secret can make retained tokens usable again. A manual sync
        // still verifies the provider before reporting CONNECTED or resuming automatic polling.
        if (!"REAUTH_REQUIRED".equals(account.get("errorCode"))) continue;
        account.put("status", "NOT_SYNCED");
        account.put("errorCode", null);
      } else {
        account.put("status", "ERROR");
        account.put("errorCode", "REAUTH_REQUIRED");
      }
      store.db.update("UPDATE mail_account SET data=? WHERE id=?", Json.encode(account), row.get("id"));
      store.changed("ACCOUNT", (String) row.get("id"), 1);
    }
  }
}
