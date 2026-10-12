package com.itdong.mail;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadConstraints;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.DeserializationFeature;
import java.io.IOException;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.core.io.ClassPathResource;
import org.springframework.core.io.Resource;
import org.springframework.stereotype.Component;

/** Immutable build-time APK resources. No request input is used as a resource path. */
@Component
public final class AndroidDownloads {
  static final String MANIFEST_PATH = "/downloads/android/manifest.json";
  static final String APK_PATH = "/downloads/android/app.apk";
  static final long MAX_APK_BYTES = 256L * 1024 * 1024;
  static final int MAX_MANIFEST_BYTES = 64 * 1024;
  static final int MAX_RELEASE_NOTES_CHARS = 4000;
  private static final ObjectMapper MAPPER = new ObjectMapper(JsonFactory.builder()
      .streamReadConstraints(StreamReadConstraints.builder().maxNestingDepth(8)
          .maxStringLength(MAX_RELEASE_NOTES_CHARS * 2).maxNumberLength(20).build())
      .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
      .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
  private final Resource apk;
  private final Map<String, Object> manifest;

  public AndroidDownloads() {
    this(new ClassPathResource("META-INF/android-download/manifest.json"),
        new ClassPathResource("META-INF/android-download/app.apk"));
  }

  AndroidDownloads(Resource metadata, Resource apk) {
    Map<String, Object> result;
    Resource verified = null;
    if (!metadata.exists() || !apk.exists()) {
      result = unavailable("NOT_BUILT");
    } else {
      try {
        result = verify(metadata, apk);
        verified = apk;
      } catch (Exception invalid) {
        // Do not expose filesystem paths, parser details, or unchecked manifest fields.
        result = unavailable("INVALID_ARTIFACT");
      }
    }
    this.apk = verified;
    manifest = Map.copyOf(result);
  }

  private static Map<String, Object> unavailable(String reason) {
    return Map.of("schemaVersion", 1, "available", false, "reason", reason);
  }

  private static Map<String, Object> verify(Resource metadata, Resource apk) throws Exception {
    byte[] bytes;
    try (var input = metadata.getInputStream()) {
      bytes = input.readNBytes(MAX_MANIFEST_BYTES + 1);
    }
    if (bytes.length > MAX_MANIFEST_BYTES) throw new IOException("Manifest limit");
    var root = MAPPER.readTree(bytes);
    if (root == null || !root.isObject() || root.size() != (root.has("releaseNotes") ? 12 : 11)
        || !root.path("schemaVersion").isIntegralNumber() || !root.path("schemaVersion").canConvertToInt()
        || root.path("schemaVersion").intValue() != 1
        || !root.path("available").isBoolean() || !root.path("available").booleanValue()
        || !APK_PATH.equals(root.path("downloadPath").textValue())
        || !"harbor-mail-dev.apk".equals(root.path("fileName").textValue())
        || !"dev.harbor.harbor_mail.dev".equals(root.path("packageName").textValue())
        || root.path("versionName").asText("").length() > 64
        || !root.path("versionName").asText("").matches("[0-9]+\\.[0-9]+\\.[0-9]+")
        || !root.path("sourceCommit").asText("").matches("[0-9a-f]{40}")
        || !root.path("sha256").asText("").matches("[0-9a-f]{64}"))
      throw new IOException("Manifest format");
    var notes = root.get("releaseNotes");
    if (notes != null && (!notes.isTextual()
        || notes.textValue().codePointCount(0, notes.textValue().length()) > MAX_RELEASE_NOTES_CHARS))
      throw new IOException("Release notes format");
    var versionCode = root.path("versionCode");
    var size = root.path("sizeBytes");
    if (!versionCode.isIntegralNumber() || !versionCode.canConvertToInt()
        || versionCode.intValue() < 1 || versionCode.intValue() > 2100000000
        || !size.isIntegralNumber() || !size.canConvertToLong()
        || size.longValue() < 1 || size.longValue() > MAX_APK_BYTES)
      throw new IOException("Manifest range");
    var signing = root.path("signing");
    if (!signing.isObject() || signing.size() != 2
        || !"development-debug".equals(signing.path("classification").textValue())
        || !signing.path("certificateSha256").asText("").matches("[0-9a-f]{64}"))
      throw new IOException("Signing classification");
    var digest = MessageDigest.getInstance("SHA-256");
    long count = 0;
    try (var input = apk.getInputStream()) {
      byte[] magic = input.readNBytes(4);
      if (magic.length != 4 || magic[0] != 'P' || magic[1] != 'K' || magic[2] != 3 || magic[3] != 4)
        throw new IOException("APK container");
      digest.update(magic);
      count = magic.length;
      byte[] buffer = new byte[64 * 1024];
      for (int read; (read = input.read(buffer)) != -1; ) {
        count += read;
        if (count > size.longValue()) throw new IOException("APK length");
        digest.update(buffer, 0, read);
      }
    }
    if (count != size.longValue()
        || !HexFormat.of().formatHex(digest.digest()).equals(root.path("sha256").textValue()))
      throw new IOException("APK integrity");
    // Build the public response explicitly, never pass through arbitrary metadata.
    var result = new LinkedHashMap<String, Object>(Map.ofEntries(
        Map.entry("schemaVersion", 1), Map.entry("available", true),
        Map.entry("downloadPath", APK_PATH), Map.entry("fileName", "harbor-mail-dev.apk"),
        Map.entry("packageName", root.path("packageName").textValue()),
        Map.entry("versionName", root.path("versionName").textValue()),
        Map.entry("versionCode", versionCode.intValue()), Map.entry("sizeBytes", count),
        Map.entry("sha256", root.path("sha256").textValue()),
        Map.entry("sourceCommit", root.path("sourceCommit").textValue()),
        Map.entry("signing", Map.of("classification", "development-debug",
            "certificateSha256", signing.path("certificateSha256").textValue()))));
    if (notes != null) result.put("releaseNotes", notes.textValue());
    return result;
  }

  Map<String, Object> manifest() { return manifest; }
  Resource apk() { return apk; }
  boolean available() { return apk != null; }
  long size() { return ((Number) manifest.get("sizeBytes")).longValue(); }
  String etag() { return "\"" + manifest.get("sha256") + "\""; }
}
