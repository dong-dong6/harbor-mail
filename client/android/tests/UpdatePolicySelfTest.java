package dev.harbor.harbor_mail;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/** Runs without an Android SDK; this is policy coverage, not an emulator/install test. */
public final class UpdatePolicySelfTest {
    private static int checks;
    private static final byte[] APK = "synthetic APK bytes".getBytes(StandardCharsets.UTF_8);
    private static final String HASH = UpdatePolicy.certificateHash(APK);

    public static void main(String[] args) throws Exception {
        Map<String, Object> valid = arguments();
        UpdatePolicy.Request request = UpdatePolicy.parse(valid);
        equal("https://mail.example/downloads/android/app.apk", request.apkUri.toString());
        equal(25L, request.versionCode);
        equal(HASH, request.sha256);
        equal("https://mail.example:8443/downloads/android/app.apk",
                UpdatePolicy.apkUri("https://mail.example:8443/").toString());
        equal("https://[::1]/downloads/android/app.apk", UpdatePolicy.apkUri("https://[::1]").toString());
        for (String origin : new String[]{"http://mail.example", "https://user:pass@mail.example",
                "https://mail.example/api", "https://mail.example/?x=y", "https://mail.example/#x",
                "https://mail.example:0", "https://mail.example:65536", "https://mail.example:",
                "https://mail.example/%2e%2e", "https://mail.example\\@evil.example", "https:///x",
                "https://mail.example\n", "file:///tmp/x", "//mail.example", "https://%65xample.com"}) {
            fails("invalidArgument", () -> UpdatePolicy.apkUri(origin));
        }
        fails("invalidArgument", () -> UpdatePolicy.parse(null));
        for (Object size : new Object[]{0L, -1L, UpdatePolicy.MAX_BYTES + 1, 1.5, "10"}) {
            changed("sizeBytes", size, "invalidArgument");
        }
        for (Object code : new Object[]{0L, -1L, 2_100_000_001L, 5.0, "5"}) {
            changed("versionCode", code, "invalidArgument");
        }
        for (String version : new String[]{"", "1.2", "1.2.3-beta", " 1.2.3", "abc", "1.2.3\n"}) {
            changed("versionName", version, "invalidArgument");
        }
        changed("sha256", "a".repeat(63), "invalidArgument");
        changed("certificateSha256", "g".repeat(64), "invalidArgument");
        Map<String, Object> uppercase = arguments();
        uppercase.put("sha256", HASH.toUpperCase(java.util.Locale.ROOT));
        equal(HASH, UpdatePolicy.parse(uppercase).sha256);
        for (String token : new String[]{"../app.apk", "/tmp/app.apk", "A".repeat(32), "a".repeat(31), ""}) {
            fails("invalidArgument", () -> UpdatePolicy.token(Map.of("token", token)));
        }
        equal("a".repeat(32), UpdatePolicy.token(Map.of("token", "a".repeat(32))));

        UpdatePolicy.response(200, null, null, APK.length); checks++;
        UpdatePolicy.response(200, "identity", Integer.toString(APK.length), APK.length); checks++;
        for (int status : new int[]{201, 204, 206, 301, 302, 307, 308, 404, 500}) {
            fails("downloadFailed", () -> UpdatePolicy.response(status, null, null, APK.length));
        }
        fails("integrityError", () -> UpdatePolicy.response(200, "gzip", null, APK.length));
        for (String size : new String[]{"1", "-1", "garbage", "9999999999999999999999999999"}) {
            fails("integrityError", () -> UpdatePolicy.response(200, null, size, APK.length));
        }

        ByteArrayOutputStream output = new ByteArrayOutputStream();
        long[] last = {-1};
        UpdatePolicy.transfer(new ByteArrayInputStream(APK), output, APK.length, HASH, received -> {
            if (received < last[0] || received > APK.length) throw new AssertionError("Invalid progress");
            last[0] = received;
        });
        equal(APK.length, output.size());
        equal((long) APK.length, last[0]);
        // The same function is used with output=null to rehash the cached APK before every install.
        UpdatePolicy.transfer(new ByteArrayInputStream(APK), null, APK.length, HASH, ignored -> {}); checks++;
        fails("integrityError", () -> UpdatePolicy.transfer(new ByteArrayInputStream(APK), null,
                APK.length + 1, HASH, ignored -> {}));
        fails("integrityError", () -> UpdatePolicy.transfer(new ByteArrayInputStream(APK), null,
                APK.length - 1, HASH, ignored -> {}));
        fails("integrityError", () -> UpdatePolicy.transfer(new ByteArrayInputStream(APK), null,
                APK.length, "0".repeat(64), ignored -> {}));
        fails("invalidArgument", () -> UpdatePolicy.transfer(new ByteArrayInputStream(APK), null,
                UpdatePolicy.MAX_BYTES + 1, HASH, ignored -> {}));
        fails("cancelled", () -> UpdatePolicy.transfer(new ByteArrayInputStream(APK), null,
                APK.length, HASH, ignored -> { throw new UpdatePolicy.Failure("cancelled", "Cancelled"); }));
        ByteArrayOutputStream bounded = new ByteArrayOutputStream();
        fails("integrityError", () -> UpdatePolicy.transfer(new ByteArrayInputStream(new byte[100]),
                bounded, 4, HASH, ignored -> {}));
        equal(0, bounded.size()); // Excess data was never written to disk.
        // Deterministically queue a completed download, then time out/cancel before
        // main-thread delivery. The production delivery helper owns cleanup in this window.
        for (String reason : new String[]{"downloadFailed", "cancelled"}) {
            java.nio.file.Path file = java.nio.file.Files.createTempFile("update-delivery-", ".apk");
            Map<String, java.nio.file.Path> records = new HashMap<>();
            records.put("token", file);
            boolean[] canceled = {false}, delivered = {false};
            Checked queuedDelivery = () -> UpdatePolicy.deliverVerifiedDownload(ignored -> {
                if (canceled[0]) throw new UpdatePolicy.Failure(reason, "Late cancellation");
            }, () -> delivered[0] = true, () -> {
                records.remove("token");
                try { java.nio.file.Files.deleteIfExists(file); }
                catch (java.io.IOException e) { throw new RuntimeException(e); }
            });
            canceled[0] = true;
            fails(reason, queuedDelivery);
            equal(false, delivered[0]);
            equal(true, records.isEmpty());
            equal(false, java.nio.file.Files.exists(file));
        }
        boolean[] delivered = {false}, discarded = {false};
        UpdatePolicy.deliverVerifiedDownload(ignored -> {}, () -> delivered[0] = true,
                () -> discarded[0] = true);
        equal(true, delivered[0]);
        equal(false, discarded[0]);
        System.out.println("Android update policy: " + checks + " checks passed.");
    }

    private static Map<String, Object> arguments() {
        Map<String, Object> map = new HashMap<>();
        map.put("origin", "https://mail.example");
        map.put("versionCode", 25L);
        map.put("versionName", "0.3.1");
        map.put("sizeBytes", (long) APK.length);
        map.put("sha256", HASH);
        map.put("certificateSha256", "a".repeat(64));
        return map;
    }

    private static void changed(String key, Object value, String code) throws Exception {
        Map<String, Object> map = arguments();
        map.put(key, value);
        fails(code, () -> UpdatePolicy.parse(map));
    }

    private interface Checked { void run() throws Exception; }

    private static void fails(String code, Checked action) throws Exception {
        try { action.run(); }
        catch (UpdatePolicy.Failure e) { equal(code, e.code); return; }
        throw new AssertionError("Expected " + code);
    }

    private static void equal(Object expected, Object actual) {
        if (!expected.equals(actual)) throw new AssertionError(expected + " != " + actual);
        checks++;
    }
}
