package dev.harbor.harbor_mail;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.Map;

/** Pure-Java, fail-closed policy shared by the native downloader and JVM tests. */
final class UpdatePolicy {
    static final long MAX_BYTES = 256L * 1024 * 1024;
    static final String APK_PATH = "/downloads/android/app.apk";

    static final class Failure extends IOException {
        final String code;

        Failure(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    static final class Request {
        final URI apkUri;
        final long versionCode;
        final String versionName;
        final long sizeBytes;
        final String sha256;
        final String certificateSha256;

        private Request(URI apkUri, long versionCode, String versionName, long sizeBytes,
                        String sha256, String certificateSha256) {
            this.apkUri = apkUri;
            this.versionCode = versionCode;
            this.versionName = versionName;
            this.sizeBytes = sizeBytes;
            this.sha256 = sha256;
            this.certificateSha256 = certificateSha256;
        }
    }

    interface Checkpoint {
        void check(long received) throws IOException;
    }

    static Request parse(Object arguments) throws Failure {
        if (!(arguments instanceof Map)) {
            throw invalid("Update arguments must be an object.");
        }
        Map<?, ?> values = (Map<?, ?>) arguments;
        URI uri = apkUri(string(values, "origin"));
        long code = integer(values, "versionCode");
        long size = integer(values, "sizeBytes");
        String name = string(values, "versionName");
        if (code <= 0 || code > 2_100_000_000L || size <= 0 || size > MAX_BYTES
                || name.length() > 64 || !name.matches("[0-9]+\\.[0-9]+\\.[0-9]+")) {
            throw invalid("Invalid version or update size.");
        }
        return new Request(uri, code, name, size, digest(string(values, "sha256")),
                digest(string(values, "certificateSha256")));
    }

    static URI apkUri(String origin) throws Failure {
        try {
            URI uri = new URI(origin);
            String path = uri.getRawPath();
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                    || uri.getHost().isEmpty() || uri.getRawUserInfo() != null
                    || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || (path != null && !path.isEmpty() && !"/".equals(path))
                    || uri.getPort() == 0 || uri.getPort() > 65535
                    || origin.length() > 2048 || uri.getRawAuthority().endsWith(":")
                    || origin.indexOf('\\') >= 0 || origin.indexOf('%') >= 0) {
                throw invalid("Updates require a plain HTTPS server origin.");
            }
            // Reconstruct the URL, rather than resolve an externally supplied path.
            return new URI("https", null, uri.getHost(), uri.getPort(), APK_PATH, null, null);
        } catch (URISyntaxException e) {
            throw invalid("Invalid update server origin.");
        }
    }

    static String token(Object arguments) throws Failure {
        if (!(arguments instanceof Map)) throw invalid("Missing update token.");
        String token = string((Map<?, ?>) arguments, "token");
        if (!token.matches("[a-f0-9]{32}")) throw invalid("Invalid update token.");
        return token;
    }

    static void response(int status, String encoding, String contentLength, long expectedSize)
            throws Failure {
        if (status != 200) {
            throw new Failure("downloadFailed",
                    "The update server did not return a direct successful response.");
        }
        if (encoding != null && !"identity".equalsIgnoreCase(encoding.trim())) {
            throw integrity("Encoded update responses are not allowed.");
        }
        if (contentLength != null && (!contentLength.matches("[0-9]+")
                || !contentLength.equals(Long.toString(expectedSize)))) {
            throw integrity("The update server returned an unexpected size.");
        }
    }

    /** Copy/hash without trusting Content-Length; reject both truncation and excess bytes. */
    static void transfer(InputStream input, OutputStream output, long expectedSize,
                         String expectedHash, Checkpoint checkpoint) throws IOException {
        if (expectedSize <= 0 || expectedSize > MAX_BYTES) throw invalid("Invalid update size.");
        MessageDigest hash = sha256();
        byte[] buffer = new byte[64 * 1024];
        long received = 0;
        checkpoint.check(received);
        while (true) {
            checkpoint.check(received);
            int count = input.read(buffer);
            if (count < 0) break;
            if (count == 0) continue;
            if (count > expectedSize - received) {
                throw integrity("The downloaded update exceeds its declared size.");
            }
            if (output != null) output.write(buffer, 0, count);
            hash.update(buffer, 0, count);
            received += count;
            checkpoint.check(received);
        }
        checkpoint.check(received);
        if (received != expectedSize || !hex(hash.digest()).equals(expectedHash)) {
            throw integrity("The update size or SHA-256 does not match.");
        }
    }

    /** Recheck at callback delivery time, and release ownership if no token was delivered. */
    static void deliverVerifiedDownload(Checkpoint checkpoint, Runnable deliver, Runnable discard)
            throws IOException {
        boolean delivered = false;
        try {
            checkpoint.check(0);
            deliver.run();
            delivered = true;
        } finally {
            if (!delivered) discard.run();
        }
    }

    static String certificateHash(byte[] certificate) {
        return hex(sha256().digest(certificate));
    }

    static String digest(String value) throws Failure {
        if (!value.matches("[a-fA-F0-9]{64}")) throw invalid("Invalid SHA-256 digest.");
        return value.toLowerCase(Locale.ROOT);
    }

    static Failure invalid(String message) { return new Failure("invalidArgument", message); }
    static Failure integrity(String message) { return new Failure("integrityError", message); }

    private static String string(Map<?, ?> map, String key) throws Failure {
        Object value = map.get(key);
        if (!(value instanceof String)) throw invalid("Missing or invalid " + key + ".");
        return (String) value;
    }

    private static long integer(Map<?, ?> map, String key) throws Failure {
        Object value = map.get(key);
        if (!(value instanceof Integer) && !(value instanceof Long)) {
            throw invalid("Missing or invalid " + key + ".");
        }
        return ((Number) value).longValue();
    }

    private static MessageDigest sha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is unavailable", e);
        }
    }

    private static String hex(byte[] bytes) {
        char[] result = new char[bytes.length * 2];
        char[] alphabet = "0123456789abcdef".toCharArray();
        for (int i = 0; i < bytes.length; i++) {
            result[2 * i] = alphabet[(bytes[i] & 0xff) >>> 4];
            result[2 * i + 1] = alphabet[bytes[i] & 0x0f];
        }
        return new String(result);
    }

    private UpdatePolicy() {}
}
