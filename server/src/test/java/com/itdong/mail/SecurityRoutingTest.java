package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.net.Socket;
import java.net.URI;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

/** Raw loopback HTTP and isolated synthetic data. No mailbox or provider is contacted. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = "mail.worker-enabled=false")
@ActiveProfiles("demo")
class SecurityRoutingTest {
  @DynamicPropertySource
  static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "securityrouting");
  }

  @LocalServerPort int port;
  @Autowired Store store;
  @Autowired Security security;
  @Autowired MailService mail;
  @MockitoBean OAuthService oauth;
  final HttpClient client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
  String token;

  @BeforeEach
  void setup() {
    store.write(() -> {
      for (String table : List.of("remote_attachment", "attachment", "job", "draft",
          "mail_message", "mail_account", "change_log", "access_token", "oauth_state"))
        store.db.update("DELETE FROM " + table);
      return null;
    });
    mail.seed();
    security.attempts.clear();
    token = security.token();
    store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token),
        System.currentTimeMillis() + 60_000);
  }

  HttpResponse<String> request(String method, String path, String body, String bearer) throws Exception {
    var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path));
    if (bearer != null) request.header("Authorization", "Bearer " + bearer);
    if (body != null) request.header("Content-Type", "application/json");
    return client.send(request.method(method, body == null ? HttpRequest.BodyPublishers.noBody()
        : HttpRequest.BodyPublishers.ofString(body)).build(), HttpResponse.BodyHandlers.ofString());
  }

  record WireResponse(int status, String response) {}

  // High-level clients may normalize attack spellings before transmission. A raw socket preserves
  // the original target. The destination is always loopback and both time and response are bounded.
  WireResponse wire(String method, String path, String body, String bearer) throws Exception {
    byte[] payload = (body == null ? "" : body).getBytes(StandardCharsets.UTF_8);
    try (Socket socket = new Socket("127.0.0.1", port)) {
      socket.setSoTimeout(10_000);
      String headers = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:" + port
          + "\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: " + payload.length
          + (bearer == null ? "" : "\r\nAuthorization: Bearer " + bearer) + "\r\n\r\n";
      socket.getOutputStream().write(headers.getBytes(StandardCharsets.US_ASCII));
      socket.getOutputStream().write(payload);
      socket.getOutputStream().flush();
      String response = new String(socket.getInputStream().readNBytes(128 * 1024), StandardCharsets.UTF_8);
      return new WireResponse(Integer.parseInt(response.split(" ", 3)[1]), response);
    }
  }

  static final List<String> ALTERNATE_PREFIXES = List.of(
      "/%61pi/v1", "/a%70i/v1", "/api/%761", "/%2561pi/v1", "/api;/v1",
      "/api;ignored/v1", "/api;jsessionid=synthetic/v1", "/api/v1;ignored",
      "/./api/v1", "/public/../api/v1", "/%2e/api/v1", "/public/%2e%2e/api/v1",
      "//api/v1", "///api/v1", "/api//v1", "/%2fapi/v1", "/api%2fv1",
      "/api\\v1", "/public\\..\\api/v1", "/api%5cv1");

  @Test
  void alternateSpellingsCannotReadProtectedResourcesWithOrWithoutBearer() throws Exception {
    for (String prefix : ALTERNATE_PREFIXES) {
      for (String bearer : new String[] {null, token}) {
        WireResponse result = wire("GET", prefix + "/accounts", null, bearer);
        assertEquals(400, result.status(), prefix);
        assertFalse(result.response().contains("demo1@example.invalid"), prefix);
      }
    }
    assertEquals(401, request("GET", "/api/v1/accounts", null, null).statusCode());
    assertEquals(200, request("GET", "/api/v1/accounts", null, token).statusCode());
  }

  @Test
  void alternateSpellingsCannotRenameDisconnectOrCreateDrafts() throws Exception {
    String before = Json.encode(mail.account("demo-gmail"));
    int count = store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class);
    for (String prefix : ALTERNATE_PREFIXES) {
      for (String bearer : new String[] {null, token}) {
        assertEquals(400, wire("PATCH", prefix + "/accounts/demo-gmail",
            "{\"displayName\":\"Unauthorized change\"}", bearer).status(), prefix);
        assertEquals(400, wire("DELETE", prefix + "/accounts/demo-gmail", null, bearer).status(), prefix);
        assertEquals(400, wire("POST", prefix + "/drafts",
            "{\"accountId\":\"demo-gmail\",\"bodyText\":\"Unauthorized draft\"}", bearer).status(), prefix);
        assertEquals(before, Json.encode(mail.account("demo-gmail")), prefix);
        assertEquals(count, store.db.queryForObject("SELECT COUNT(*) FROM mail_account", Integer.class), prefix);
        assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM draft", Integer.class), prefix);
        assertEquals(0, store.db.queryForObject("SELECT COUNT(*) FROM job", Integer.class), prefix);
      }
    }
    assertEquals(401, request("DELETE", "/api/v1/accounts/demo-gmail", null, null).statusCode());
    assertEquals(401, request("PATCH", "/api/v1/accounts/demo-gmail",
        "{\"displayName\":\"Unauthorized change\"}", null).statusCode());
    assertEquals(before, Json.encode(mail.account("demo-gmail")));
    assertEquals(200, request("PATCH", "/api/v1/accounts/demo-gmail",
        "{\"displayName\":\"Authorized label\"}", token).statusCode());
    assertEquals("Authorized label", mail.account("demo-gmail").get("displayName"));
  }

  @Test
  void canonicalPublicLoginHealthAndOauthCallbackKeepWorkingWithEncodedQueryValues() throws Exception {
    var health = request("GET", "/api/v1/health?unused=%2f%3b%5c%2e", null, null);
    assertEquals(200, health.statusCode());
    assertEquals("no-store", health.headers().firstValue("Cache-Control").orElseThrow());
    assertEquals(200, request("HEAD", "/api/v1/health", null, null).statusCode());
    var login = request("POST", "/api/v1/auth/login",
        "{\"username\":\"demo\",\"password\":\"demo-local-only\"}", null);
    assertEquals(200, login.statusCode());
    String issued = Json.string(Json.decode(login.body()), "accessToken");
    assertFalse(issued.isBlank());
    assertEquals(200, request("GET", "/api/v1/accounts", null, issued).statusCode());
    for (String provider : List.of("GMAIL", "OUTLOOK", "EXCHANGE")) {
      when(oauth.callback(provider, "state /+?", "code /+?", ""))
          .thenReturn("0123456789abcdef0123456789abcdef");
      var callback = request("GET", "/api/v1/oauth/" + provider
          + "/callback?state=state%20%2F%2B%3F&code=code%20%2F%2B%3F", null, null);
      assertEquals(303, callback.statusCode());
      assertEquals("/oauth-complete.html#0123456789abcdef0123456789abcdef",
          callback.headers().firstValue("Location").orElseThrow());
      assertEquals("no-store", callback.headers().firstValue("Cache-Control").orElseThrow());
      verify(oauth).callback(provider, "state /+?", "code /+?", "");
    }
    assertEquals(401, request("POST", "/api/v1/health", null, null).statusCode());
    assertEquals(401, request("GET", "/api/v1/auth/login", null, null).statusCode());
    assertEquals(401, request("POST", "/api/v1/oauth/GMAIL/callback", null, null).statusCode());
  }

  @Test
  void malformedPathsAreRejectedBeforePublicExceptionsAndPreflight() throws Exception {
    var invalid = wire("GET", "/%61pi/v1/health", null, null);
    assertEquals(400, invalid.status());
    assertTrue(invalid.response().contains("INVALID_PATH"));
    assertTrue(invalid.response().toLowerCase().contains("cache-control: no-store"));
    assertEquals(400, wire("POST", "/api;/v1/auth/login",
        "{\"username\":\"demo\",\"password\":\"demo-local-only\"}", null).status());
    assertEquals(400, wire("GET", "/%61pi/v1/oauth/GMAIL/callback?state=s&code=c", null, null).status());
    assertEquals(400, wire("OPTIONS", "/%61pi/v1/accounts", null, null).status());
    verifyNoInteractions(oauth);
  }

  @Test
  void canonicalStaticPathsAndRootRemainPublic() throws Exception {
    assertEquals(200, request("GET", "/security-route-fixture.js", null, null).statusCode());
    assertEquals(200, request("HEAD", "/security-route-fixture.js", null, null).statusCode());
    // Backend-only checkouts may omit the generated Flutter index.
    int root = request("GET", "/", null, null).statusCode();
    assertTrue(root == 200 || root == 404, "Canonical root must reach the public resource handler");
    var request = new MockHttpServletRequest();
    request.setRequestURI("/");
    request.setServletPath("/");
    assertEquals("/", Security.canonicalRequestPath(request));
  }

  @Test
  void pathClassifierFailsClosedWhenContainerInterpretationDiffers() {
    var request = new MockHttpServletRequest();
    request.setRequestURI("/public");
    request.setServletPath("/api/v1/accounts");
    assertNull(Security.canonicalRequestPath(request));
    request.setRequestURI("/mail/api/v1/accounts");
    request.setContextPath("/mail");
    assertEquals("/api/v1/accounts", Security.canonicalRequestPath(request));
    request.setRequestURI("/mail/dispatcher/api/v1/accounts");
    request.setServletPath("/dispatcher");
    request.setPathInfo("/api/v1/accounts");
    assertEquals("/api/v1/accounts", Security.canonicalRequestPath(request));
    request.setRequestURI("/api/v1/accounts/");
    request.setContextPath("");
    request.setPathInfo(null);
    request.setServletPath("/api/v1/accounts/");
    assertNull(Security.canonicalRequestPath(request));
  }
}
