package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.net.URI;
import java.net.http.*;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = "mail.worker-enabled=false")
@ActiveProfiles("demo")
@Import(AndroidDownloadsHttpTest.FixtureConfiguration.class)
class AndroidDownloadsHttpTest {
  @TestConfiguration
  static class FixtureConfiguration {
    @Bean @Primary AndroidDownloads fixtureDownloads() throws Exception {
      var metadata = AndroidDownloadsTest.metadata();
      metadata.put("releaseNotes", "更新说明\n- 保留设置。\n<script>plain text</script>");
      return AndroidDownloadsTest.downloads(metadata, AndroidDownloadsTest.APK);
    }
  }
  @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
    TestDatabases.configure(registry, "android_downloads");
  }
  @LocalServerPort int port;
  final HttpClient client = HttpClient.newHttpClient();

  HttpResponse<byte[]> request(String method, String path, String... headers) throws Exception {
    var builder = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path));
    for (int i = 0; i < headers.length; i += 2) builder.header(headers[i], headers[i + 1]);
    return client.send(builder.method(method, HttpRequest.BodyPublishers.noBody()).build(), HttpResponse.BodyHandlers.ofByteArray());
  }
  String header(HttpResponse<?> response, String key) { return response.headers().firstValue(key).orElse(""); }

  @Test void publicManifestAndDownloadAreSameArtifactWithoutAuthentication() throws Exception {
    var response = request("GET", AndroidDownloads.MANIFEST_PATH);
    assertEquals(200, response.statusCode());
    assertEquals("no-store", header(response, "Cache-Control"));
    var manifest = Json.decode(new String(response.body(), java.nio.charset.StandardCharsets.UTF_8));
    assertEquals(true, manifest.get("available"));
    assertEquals(1, manifest.get("schemaVersion"));
    assertEquals("更新说明\n- 保留设置。\n<script>plain text</script>", manifest.get("releaseNotes"));
    var apk = request("GET", (String) manifest.get("downloadPath"));
    assertEquals(200, apk.statusCode());
    assertArrayEquals(AndroidDownloadsTest.APK, apk.body());
    assertEquals("application/vnd.android.package-archive", header(apk, "Content-Type"));
    assertEquals("attachment; filename=\"harbor-mail-dev.apk\"", header(apk, "Content-Disposition"));
    assertEquals("nosniff", header(apk, "X-Content-Type-Options"));
    assertEquals("public, no-cache, must-revalidate", header(apk, "Cache-Control"));
    assertEquals("\"" + manifest.get("sha256") + "\"", header(apk, "ETag"));
    assertEquals(401, request("GET", "/api/v1/accounts").statusCode());
  }

  @Test void headAndRevalidationAreBoundedAndDoNotReturnTheBody() throws Exception {
    var head = request("HEAD", AndroidDownloads.APK_PATH);
    assertEquals(200, head.statusCode());
    assertEquals(0, head.body().length);
    assertEquals(String.valueOf(AndroidDownloadsTest.APK.length), header(head, "Content-Length"));
    var cached = request("GET", AndroidDownloads.APK_PATH, "If-None-Match", header(head, "ETag"));
    assertEquals(304, cached.statusCode());
    assertEquals(0, cached.body().length);
    assertEquals(200, request("GET", AndroidDownloads.APK_PATH, "If-None-Match", "\"wrong\"").statusCode());
    assertEquals(0, request("HEAD", AndroidDownloads.MANIFEST_PATH).body().length);
  }

  @Test void methodPathAndPrivateResourceVariantsCannotExposeTheApk() throws Exception {
    for (String path : new String[]{"/downloads/android/other.apk", "/downloads/android/app.apk/", "/downloads/android/app.apk.gz",
        "/downloads/android/%61pp.apk", "/downloads/android/app.apk;param=1",
        "/META-INF/android-download/app.apk", "/downloads/android/manifest.json/"}) {
      var response = request("GET", path);
      assertTrue(response.statusCode() >= 400, path + ": " + response.statusCode());
      assertNotEquals("application/vnd.android.package-archive", header(response, "Content-Type"));
    }
    assertTrue(request("POST", AndroidDownloads.APK_PATH).statusCode() >= 400);
  }
}
