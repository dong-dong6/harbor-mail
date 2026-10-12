package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.io.ByteArrayInputStream;
import java.net.URI;
import java.net.http.*;
import java.util.zip.GZIPInputStream;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "mail.worker-enabled=false",
      "mail.web-assets-manifest=META-INF/test-public-assets.json"
    })
@ActiveProfiles("demo")
class PublicWebAssetsTest {
  @DynamicPropertySource
  static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "static_assets");
  }

  @LocalServerPort int port;
  @Autowired Security security;
  @Autowired Store store;
  final HttpClient client = HttpClient.newHttpClient();

  HttpResponse<byte[]> request(String method, String path, String... headers) throws Exception {
    var builder = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path));
    for (int i = 0; i < headers.length; i += 2) builder.header(headers[i], headers[i + 1]);
    return client.send(builder.method(method, HttpRequest.BodyPublishers.noBody()).build(),
        HttpResponse.BodyHandlers.ofByteArray());
  }

  String header(HttpResponse<?> response, String name) {
    return response.headers().firstValue(name).orElse("");
  }

  @Test
  void coldGzipWarm304AndIdentityHaveRepresentationSpecificEtags() throws Exception {
    var identity = request("GET", "/cache-fixture/app.js");
    var gzip = request("GET", "/cache-fixture/app.js", "Accept-Encoding", "br, gzip",
        "Origin", "http://localhost:3000");
    assertEquals(200, gzip.statusCode());
    assertEquals("gzip", header(gzip, "Content-Encoding"));
    assertEquals("public, no-cache, must-revalidate", header(gzip, "Cache-Control"));
    assertEquals("nosniff", header(gzip, "X-Content-Type-Options"));
    assertEquals("DENY", header(gzip, "X-Frame-Options"));
    String varies = String.join(",", gzip.headers().allValues("Vary"));
    assertTrue(varies.contains("Accept-Encoding"));
    assertTrue(varies.contains("Origin"));
    assertTrue(gzip.body().length < identity.body().length / 2);
    assertArrayEquals(identity.body(), new GZIPInputStream(new ByteArrayInputStream(gzip.body())).readAllBytes());
    assertTrue(String.join(",", identity.headers().allValues("Vary")).contains("Origin"));
    assertNotEquals(header(identity, "ETag"), header(gzip, "ETag"));
    var warm = request("GET", "/cache-fixture/app.js", "Accept-Encoding", "gzip",
        "If-None-Match", header(gzip, "ETag"));
    assertEquals(304, warm.statusCode());
    assertEquals(0, warm.body().length);
    assertEquals(header(gzip, "Cache-Control"), header(warm, "Cache-Control"));
    assertEquals(header(gzip, "ETag"), header(warm, "ETag"));
    assertEquals(200, request("GET", "/cache-fixture/app.js", "Accept-Encoding", "gzip",
        "If-None-Match", header(identity, "ETag")).statusCode());
    assertEquals(200, request("GET", "/cache-fixture/app.js", "If-None-Match", "\"previous-build\"").statusCode());
    assertEquals(304, request("GET", "/cache-fixture/app.js", "If-None-Match",
        "\"older-build\", W/" + header(identity, "ETag")).statusCode());
  }

  @Test
  void bootstrapHeadQueryAndEncodingNegotiation() throws Exception {
    var plain = request("GET", "/cache-fixture/app.js");
    var head = request("HEAD", "/cache-fixture/app.js?version=current", "Accept-Encoding", "gzip");
    assertEquals(200, head.statusCode());
    assertEquals(0, head.body().length);
    assertEquals("gzip", header(head, "Content-Encoding"));
    assertTrue(Long.parseLong(header(head, "Content-Length")) > 0);
    for (String encoding : new String[] {"br", "gzip;q=0, br", "gzip;q=0.1, identity;q=1"}) {
      var identity = request("GET", "/cache-fixture/app.js", "Accept-Encoding", encoding);
      assertEquals("", header(identity, "Content-Encoding"));
      assertArrayEquals(plain.body(), identity.body());
    }
    assertEquals("gzip", header(request("GET", "/cache-fixture/app.js", "Accept-Encoding",
        "gzip;q=0.5, identity;q=0"), "Content-Encoding"));
    var unacceptable = request("GET", "/cache-fixture/app.js", "Accept-Encoding", "gzip;q=0, identity;q=0");
    assertEquals(406, unacceptable.statusCode());
    assertEquals("no-store", header(unacceptable, "Cache-Control"));
    var bootstrap = request("GET", "/cache-fixture/bootstrap.html");
    assertEquals("public, no-cache, must-revalidate", header(bootstrap, "Cache-Control"));
    assertEquals(304, request("GET", "/cache-fixture/bootstrap.html", "If-None-Match", header(bootstrap, "ETag")).statusCode());
  }

  @Test
  void privateAuthMailAttachmentProxyErrorsAndUnlistedFilesStayNoStore() throws Exception {
    String token = security.token();
    store.db.update("INSERT INTO access_token VALUES(?,?)", Security.hash(token), System.currentTimeMillis() + 60000);
    try {
      for (String path : new String[] {
          "/api/v1/health", "/api/v1/auth/login", "/api/v1/accounts", "/oauth-complete.html",
          "/api/v1/messages", "/api/v1/attachments/missing",
          "/api/v1/accounts/missing/messages/missing/images", "/cache-fixture/missing.js",
          "/cache-fixture/unlisted.js", "/cache-fixture/app.js.gz", "/private/userdata.js"
      }) {
        var response = request("GET", path, "Accept-Encoding", "gzip", "If-None-Match", "*");
        assertEquals("no-store", header(response, "Cache-Control"), path);
        assertEquals("", header(response, "Content-Encoding"), path);
        assertNotEquals(304, response.statusCode(), path);
        if (path.startsWith("/api/v1/") && !path.endsWith("/health") && !path.endsWith("/login")) {
          assertEquals(401, response.statusCode(), path);
          var authenticated = request("GET", path, "Authorization", "Bearer " + token);
          assertEquals("no-store", header(authenticated, "Cache-Control"), path);
        }
      }
      assertEquals("no-store", header(request("POST", "/cache-fixture/app.js"), "Cache-Control"));
    } finally {
      store.db.update("DELETE FROM access_token WHERE token_hash=?", Security.hash(token));
    }
  }
}
