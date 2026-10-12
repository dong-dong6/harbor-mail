package com.itdong.mail;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.core.io.ClassPathResource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

/** Synthetic byte fixtures check serving integrity, never claim APK installability. */
class AndroidDownloadsTest {
  static final byte[] APK = "PK\u0003\u0004synthetic-contract-fixture-not-installable".getBytes(StandardCharsets.UTF_8);

  static Map<String, Object> metadata() throws Exception {
    return new LinkedHashMap<>(Map.ofEntries(
        Map.entry("schemaVersion", 1), Map.entry("available", true),
        Map.entry("downloadPath", AndroidDownloads.APK_PATH), Map.entry("fileName", "harbor-mail-dev.apk"),
        Map.entry("packageName", "dev.harbor.harbor_mail.dev"), Map.entry("versionName", "0.2.3"),
        Map.entry("versionCode", 5), Map.entry("sizeBytes", APK.length),
        Map.entry("sha256", HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(APK))),
        Map.entry("sourceCommit", "b".repeat(40)),
        Map.entry("signing", Map.of("classification", "development-debug", "certificateSha256", "a".repeat(64)))));
  }

  static AndroidDownloads fixture() throws Exception { return downloads(metadata(), APK); }

  static AndroidDownloads downloads(Map<String, Object> manifest, byte[] apk) {
    return new AndroidDownloads(new ByteArrayResource(Json.encode(manifest).getBytes(StandardCharsets.UTF_8)),
        new ByteArrayResource(apk));
  }

  @Test void missingArtifactsNeverAdvertiseAPlaceholder() {
    var missing = new ClassPathResource("nonexistent-android-test-resource");
    var downloads = new AndroidDownloads(missing, missing);
    assertFalse(downloads.available());
    assertEquals(Map.of("schemaVersion", 1, "available", false, "reason", "NOT_BUILT"), downloads.manifest());
    assertNull(downloads.apk());
    assertFalse(downloads.manifest().containsKey("downloadPath"));
  }

  @Test void validatedBytesHaveExpectedPublicMetadata() throws Exception {
    var downloads = fixture();
    assertTrue(downloads.available());
    assertEquals(APK.length, downloads.size());
    assertEquals(metadata().get("sha256"), downloads.manifest().get("sha256"));
    assertEquals("development-debug", ((Map<?, ?>) downloads.manifest().get("signing")).get("classification"));
  }

  @Test void rejectsMismatchOversizeMetadataAndUntrustedFields() throws Exception {
    for (var change : Map.ofEntries(
        Map.entry("sha256", (Object) "0".repeat(64)), Map.entry("sizeBytes", (Object) (APK.length + 1)),
        Map.entry("versionCode", (Object) 1.5), Map.entry("schemaVersion", (Object) 4294967297L), Map.entry("sizeBytes2", (Object) "/private/local/path"),
        Map.entry("downloadPath", (Object) "https://attacker.invalid/malware.apk"),
        Map.entry("packageName", (Object) "dev.harbor.harbor_mail"),
        Map.entry("signing", (Object) Map.of("classification", "production", "certificateSha256", "a".repeat(64))))
        .entrySet()) {
      var manifest = metadata();
      manifest.put(change.getKey(), change.getValue());
      var invalid = downloads(manifest, APK);
      assertFalse(invalid.available(), change.getKey());
      assertEquals(Map.of("schemaVersion", 1, "available", false, "reason", "INVALID_ARTIFACT"), invalid.manifest());
    }
    assertFalse(downloads(metadata(), "not-an-apk".getBytes(StandardCharsets.UTF_8)).available());
    var huge = new AndroidDownloads(new ByteArrayResource(new byte[AndroidDownloads.MAX_MANIFEST_BYTES + 1]), new ByteArrayResource(APK));
    assertFalse(huge.available());
    var trailing = Json.encode(metadata()) + " {}";
    assertFalse(new AndroidDownloads(new ByteArrayResource(trailing.getBytes(StandardCharsets.UTF_8)), new ByteArrayResource(APK)).available());
    var duplicate = Json.encode(metadata()).replace("\"available\":true", "\"available\":true,\"available\":true");
    assertFalse(new AndroidDownloads(new ByteArrayResource(duplicate.getBytes(StandardCharsets.UTF_8)), new ByteArrayResource(APK)).available());
  }

  @Test void unavailableEndpointIs404AndHasNoAttachmentHeaders() throws Exception {
    var missing = new ClassPathResource("nonexistent-android-test-resource");
    var controller = new AndroidDownloadsController(new AndroidDownloads(missing, missing));
    var request = new MockHttpServletRequest("GET", AndroidDownloads.APK_PATH);
    var response = new MockHttpServletResponse();
    controller.apk(request, response);
    assertEquals(404, response.getStatus());
    assertEquals("no-store", response.getHeader("Cache-Control"));
    assertNull(response.getHeader("Content-Disposition"));
    assertFalse(response.getContentAsString().contains("META-INF"));
  }

  @Test void onlyExactCanonicalPathsAreServed() throws Exception {
    var controller = new AndroidDownloadsController(fixture());
    for (String path : new String[]{"/downloads/android/%61pp.apk", "/downloads/android/app.apk/",
        "/downloads/android/app.apk;param=1", "/downloads/android/../app.apk"}) {
      var response = new MockHttpServletResponse();
      controller.apk(new MockHttpServletRequest("GET", path), response);
      assertEquals(404, response.getStatus());
      assertEquals(0, response.getContentAsByteArray().length);
    }
  }
}
