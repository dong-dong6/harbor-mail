package com.itdong.mail.provider;

import com.fasterxml.jackson.databind.*;
import java.net.URI;
import java.time.Instant;
import java.util.*;

/** State storage, PKCE verifier retention and single-flight refresh belong to the owner service. */
public final class OAuthClient {
  public record Config(
      String provider, String clientId, String clientSecret, String redirectUri, String tenant) {
    @Override
    public String toString() {
      return "OAuthConfig[REDACTED]";
    }
  }

  public record Tokens(String accessToken, String refreshToken, Instant expiresAt, String scope) {
    @Override
    public String toString() {
      return "Tokens[REDACTED]";
    }
  }

  private final HttpTransport http;
  private final String testBase;

  public OAuthClient(ObjectMapper mapper) {
    http = new HttpTransport(mapper);
    testBase = null;
  }

  OAuthClient(ObjectMapper mapper, String testBase) {
    URI u = URI.create(testBase);
    if (!Set.of("127.0.0.1", "localhost", "::1").contains(u.getHost()))
      throw new IllegalArgumentException();
    http = new HttpTransport(mapper);
    this.testBase = testBase;
  }

  private String auth(Config c) {
    return testBase != null
        ? testBase + "/authorize"
        : c.provider().equals("GMAIL")
            ? "https://accounts.google.com/o/oauth2/v2/auth"
            : ms(c) + "/authorize";
  }

  private String token(Config c) {
    return testBase != null
        ? testBase + "/token"
        : c.provider().equals("GMAIL") ? "https://oauth2.googleapis.com/token" : ms(c) + "/token";
  }

  private String ms(Config c) {
    String tenant = c.tenant();
    if (tenant == null || tenant.isBlank())
      tenant = c.provider().equals("OUTLOOK") ? "consumers" : "organizations";
    if (!tenant.matches("[A-Za-z0-9.-]+")) throw new ProviderException("INVALID_TENANT", false);
    return "https://login.microsoftonline.com/" + tenant + "/oauth2/v2.0";
  }

  private String scope(Config c) {
    return c.provider().equals("GMAIL")
        ? "https://www.googleapis.com/auth/gmail.modify"
        : "offline_access https://graph.microsoft.com/Mail.ReadWrite"
            + " https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/User.Read";
  }

  private void validate(Config c) {
    if (!Set.of("GMAIL", "OUTLOOK", "EXCHANGE").contains(c.provider()))
      throw new ProviderException("NOT_SUPPORTED", false);
    if (c.clientId() == null || c.clientId().isBlank() || c.redirectUri() == null)
      throw new ProviderException("PROVIDER_NOT_CONFIGURED", false);
    if (testBase == null && !"https".equals(URI.create(c.redirectUri()).getScheme()))
      throw new ProviderException("INVALID_REDIRECT_URI", false);
  }

  public String authorizationUrl(Config c, String state, String pkceChallenge) {
    validate(c);
    Map<String, String> p = new LinkedHashMap<>();
    p.put("client_id", c.clientId());
    p.put("redirect_uri", c.redirectUri());
    p.put("response_type", "code");
    p.put("scope", scope(c));
    p.put("state", state);
    p.put("code_challenge", pkceChallenge);
    p.put("code_challenge_method", "S256");
    if (c.provider().equals("GMAIL")) {
      p.put("access_type", "offline");
      p.put("prompt", "consent");
    }
    return auth(c) + "?" + form(p);
  }

  public Tokens exchange(Config c, String code, String verifier) {
    Map<String, String> p = base(c);
    p.put("grant_type", "authorization_code");
    p.put("code", code);
    p.put("redirect_uri", c.redirectUri());
    p.put("code_verifier", verifier);
    return request(c, p, null);
  }

  public Tokens refresh(Config c, String refreshToken) {
    Map<String, String> p = base(c);
    p.put("grant_type", "refresh_token");
    p.put("refresh_token", refreshToken);
    return request(c, p, refreshToken);
  }

  private Map<String, String> base(Config c) {
    validate(c);
    Map<String, String> p = new LinkedHashMap<>();
    p.put("client_id", c.clientId());
    if (c.clientSecret() != null && !c.clientSecret().isBlank())
      p.put("client_secret", c.clientSecret());
    return p;
  }

  private Tokens request(Config c, Map<String, String> p, String previous) {
    JsonNode n =
        http.request(
            "POST",
            URI.create(token(c)),
            null,
            form(p),
            false,
            Map.of("Content-Type", "application/x-www-form-urlencoded"));
    String access = n.path("access_token").asText();
    if (access.isBlank()) throw new ProviderException("INVALID_TOKEN_RESPONSE", false);
    return new Tokens(
        access,
        n.path("refresh_token").asText(previous),
        Instant.now().plusSeconds(Math.max(1, n.path("expires_in").asLong(3600))),
        n.path("scope").asText());
  }

  public String identityEmail(Config c, String accessToken) {
    validate(c);
    String url =
        testBase != null
            ? testBase + "/profile"
            : c.provider().equals("GMAIL")
                ? "https://gmail.googleapis.com/gmail/v1/users/me/profile"
                : "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName";
    JsonNode n = http.request("GET", URI.create(url), accessToken, null, false, Map.of());
    String email =
        c.provider().equals("GMAIL") ? n.path("emailAddress").asText() : n.path("mail").asText();
    if (email.isBlank()) email = n.path("userPrincipalName").asText();
    if (email.isBlank() || !email.contains("@"))
      throw new ProviderException("IDENTITY_UNAVAILABLE", false);
    return email;
  }

  static String form(Map<String, String> p) {
    return p.entrySet().stream()
        .map(e -> HttpTransport.enc(e.getKey()) + "=" + HttpTransport.enc(e.getValue()))
        .collect(java.util.stream.Collectors.joining("&"));
  }
}
