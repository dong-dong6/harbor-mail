package dev.harbor.harbor_mail;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.URI;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure, host-testable framing and binding rules; never opens a network connection. */
public final class SessionVaultPolicy {
    private SessionVaultPolicy() {}
    public static final long MAX_LIFETIME_MS = 8L * 60 * 60 * 1000;
    public static final int MAX_RECORD_BYTES = 16384;
    private static final int MAGIC = 0x484d5631; // HMV1
    private static final Pattern BASE = Pattern.compile(
            "^https://(\\[[0-9a-f:]+\\]|[a-z0-9.-]+)(?::([1-9][0-9]{0,4}))?/api/v1$");

    public static final class Metadata {
        public final String apiBase;
        public final String accountId;
        public final long expiresAt;
        public Metadata(String apiBase, String accountId, long expiresAt) {
            if (!validBase(apiBase) || accountId == null || accountId.isEmpty()
                    || accountId.length() > 320 || control(accountId) || expiresAt <= 0) {
                throw new IllegalArgumentException("Invalid session metadata");
            }
            this.apiBase = apiBase;
            this.accountId = accountId;
            this.expiresAt = expiresAt;
        }
        public boolean matches(String base, String account) {
            return apiBase.equals(base) && accountId.equals(account);
        }
        public boolean validAt(long now) {
            return now > 0 && expiresAt > now && expiresAt - now <= MAX_LIFETIME_MS;
        }
        public Map<String, Object> toMap() {
            Map<String, Object> map = new HashMap<>();
            map.put("apiBase", apiBase);
            map.put("accountId", accountId);
            map.put("expiresAt", expiresAt);
            return map;
        }
        public byte[] aad() throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bytes);
            out.writeInt(MAGIC);
            out.writeUTF(apiBase);
            out.writeUTF(accountId);
            out.writeLong(expiresAt);
            out.flush();
            return bytes.toByteArray();
        }
    }

    public static final class Record {
        public final Metadata metadata;
        public final byte[] iv;
        public final byte[] ciphertext;
        public Record(Metadata metadata, byte[] iv, byte[] ciphertext) {
            if (metadata == null || iv == null || iv.length != 12 || ciphertext == null
                    || ciphertext.length < 32 || ciphertext.length > 8208) {
                throw new IllegalArgumentException("Invalid encrypted session");
            }
            this.metadata = metadata;
            this.iv = iv.clone();
            this.ciphertext = ciphertext.clone();
        }
        public byte[] encode() throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bytes);
            out.write(metadata.aad());
            out.write(iv);
            out.writeInt(ciphertext.length);
            out.write(ciphertext);
            out.flush();
            if (bytes.size() > MAX_RECORD_BYTES) throw new IOException("Session too large");
            return bytes.toByteArray();
        }
    }

    public static Record decode(byte[] bytes) throws IOException {
        if (bytes == null || bytes.length > MAX_RECORD_BYTES) throw new IOException("Invalid session record");
        try {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
            if (in.readInt() != MAGIC) throw new IOException("Invalid session version");
            Metadata metadata = new Metadata(in.readUTF(), in.readUTF(), in.readLong());
            byte[] iv = new byte[12];
            in.readFully(iv);
            int length = in.readInt();
            if (length < 32 || length > 8208 || in.available() != length) {
                throw new IOException("Invalid session frame");
            }
            byte[] ciphertext = new byte[length];
            in.readFully(ciphertext);
            return new Record(metadata, iv, ciphertext);
        } catch (IllegalArgumentException e) {
            throw new IOException("Invalid session record");
        }
    }

    public static boolean validToken(String token) {
        if (token == null || token.length() < 16 || token.length() > 8192) return false;
        for (int i = 0; i < token.length(); i++) {
            if (token.charAt(i) < 0x21 || token.charAt(i) > 0x7e) return false;
        }
        return true;
    }

    public static boolean validBase(String base) {
        if (base == null || base.length() > 2048) return false;
        Matcher match = BASE.matcher(base);
        if (!match.matches()) return false;
        String host = match.group(1);
        String port = match.group(2);
        if (port != null && (Integer.parseInt(port) > 65535 || port.equals("443"))) return false;
        try {
            URI uri = new URI(base).parseServerAuthority();
            if (uri.getHost() == null || !base.equals(uri.toASCIIString())) return false;
        } catch (Exception e) { return false; }
        if (!host.startsWith("[")) {
            if (host.length() > 253) return false;
            for (String label : host.split("\\.", -1)) {
                if (label.length() > 63 || !label.matches("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")) return false;
            }
            if (host.matches("[0-9.]+")) {
                String[] parts = host.split("\\.");
                if (parts.length != 4) return false;
                for (String part : parts) {
                    if (!part.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(part) > 255) return false;
                }
            } else if (Pattern.compile("(^|\\.)0x[0-9a-f]+($|\\.)").matcher(host).find()) return false;
        }
        return true;
    }

    private static boolean control(String value) {
        for (int i = 0; i < value.length(); i++) {
            if (value.charAt(i) < 0x20 || value.charAt(i) == 0x7f) return true;
        }
        return false;
    }
}
