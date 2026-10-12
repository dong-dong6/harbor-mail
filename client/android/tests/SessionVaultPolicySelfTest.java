package dev.harbor.harbor_mail;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Synthetic host tests only. No AndroidKeyStore enrollment or real tokens. */
public final class SessionVaultPolicySelfTest {
    private static int assertions;
    private static void check(boolean condition, String message) {
        assertions++;
        if (!condition) throw new AssertionError(message);
    }
    private static void rejects(Throwing action, String message) throws Exception {
        assertions++;
        try { action.run(); } catch (Exception expected) { return; }
        throw new AssertionError(message);
    }
    private interface Throwing { void run() throws Exception; }

    public static void main(String[] args) throws Exception {
        long now = 1800000000000L;
        for (String base : new String[]{"https://mail.example/api/v1", "https://mail.example:8443/api/v1", "https://[::1]/api/v1"}) {
            check(SessionVaultPolicy.validBase(base), "valid canonical HTTPS URL");
        }
        for (String base : new String[]{"http://localhost/api/v1", "https://MAIL.example/api/v1", "https://mail.example:443/api/v1", "https://mail.example/api/v1/", "https://user@mail.example/api/v1", "https://mail.example/api/v1?q=x", "https://mail.example/api/v1#x", "https://mail.example/%61pi/v1", "https://mail.example:0443/api/v1", "https://mail.example:65536/api/v1", "https://127.01.0.1/api/v1", "https://2130706433/api/v1", "https://0x7f000001/api/v1", "https://mail..example/api/v1", "https://-mail.example/api/v1"}) {
            check(!SessionVaultPolicy.validBase(base), "reject ambiguous URL");
        }
        SessionVaultPolicy.Metadata metadata = new SessionVaultPolicy.Metadata("https://mail.example/api/v1", "owner", now + 3600000);
        check(metadata.validAt(now), "session valid");
        check(!metadata.validAt(metadata.expiresAt), "expiry boundary is closed");
        check(!metadata.validAt(now - SessionVaultPolicy.MAX_LIFETIME_MS), "rollback/overlong expiry rejected");
        check(new SessionVaultPolicy.Metadata(metadata.apiBase, metadata.accountId, now + SessionVaultPolicy.MAX_LIFETIME_MS).validAt(now), "exact 8h allowed");
        check(!new SessionVaultPolicy.Metadata(metadata.apiBase, metadata.accountId, now + SessionVaultPolicy.MAX_LIFETIME_MS + 1).validAt(now), "8h plus 1ms rejected");
        check(!metadata.matches("https://other.example/api/v1", "owner"), "origin binding");
        check(!metadata.matches(metadata.apiBase, "other"), "account binding");
        check(SessionVaultPolicy.validToken("synthetic-session-only"), "synthetic token valid");
        check(!SessionVaultPolicy.validToken("synthetic\ncredential"), "control token rejected");
        check(!SessionVaultPolicy.validToken("x".repeat(8193)), "large token rejected");
        rejects(() -> new SessionVaultPolicy.Metadata(metadata.apiBase, "", metadata.expiresAt), "empty owner rejected");
        rejects(() -> new SessionVaultPolicy.Metadata(metadata.apiBase, "a\nb", metadata.expiresAt), "control owner rejected");

        // The pure policy uses the same AEAD AAD as the device bridge. This
        // proves tamper binding, not Android OS authentication (device QA required).
        KeyGenerator generator = KeyGenerator.getInstance("AES");
        generator.init(256);
        SecretKey key = generator.generateKey();
        byte[] plaintext = "synthetic-session-only".getBytes(StandardCharsets.UTF_8);
        Cipher encrypt = Cipher.getInstance("AES/GCM/NoPadding");
        encrypt.init(Cipher.ENCRYPT_MODE, key);
        encrypt.updateAAD(metadata.aad());
        byte[] ciphertext = encrypt.doFinal(plaintext);
        SessionVaultPolicy.Record record = new SessionVaultPolicy.Record(metadata, encrypt.getIV(), ciphertext);
        byte[] encoded = record.encode();
        SessionVaultPolicy.Record decoded = SessionVaultPolicy.decode(encoded);
        check(decoded.metadata.expiresAt == metadata.expiresAt, "expiry preserved exactly");
        check(decoded.metadata.matches(metadata.apiBase, metadata.accountId), "binding preserved");
        check(Arrays.equals(decrypt(key, decoded, decoded.metadata), plaintext), "roundtrip synthetic token");
        check(!new String(encoded, StandardCharsets.ISO_8859_1).contains("synthetic-session-only"), "token absent from record");
        rejects(() -> decrypt(key, decoded, new SessionVaultPolicy.Metadata("https://other.example/api/v1", "owner", metadata.expiresAt)), "origin substitution fails AEAD");
        rejects(() -> decrypt(key, decoded, new SessionVaultPolicy.Metadata(metadata.apiBase, "other", metadata.expiresAt)), "owner substitution fails AEAD");
        rejects(() -> decrypt(key, decoded, new SessionVaultPolicy.Metadata(metadata.apiBase, "owner", metadata.expiresAt + 1)), "expiry extension fails AEAD");
        byte[] changed = ciphertext.clone(); changed[0] ^= 1;
        rejects(() -> decrypt(key, new SessionVaultPolicy.Record(metadata, encrypt.getIV(), changed), metadata), "ciphertext mutation fails AEAD");
        byte[] changedIv = encrypt.getIV(); changedIv[0] ^= 1;
        rejects(() -> decrypt(key, new SessionVaultPolicy.Record(metadata, changedIv, ciphertext), metadata), "IV mutation fails AEAD");
        rejects(() -> SessionVaultPolicy.decode(Arrays.copyOf(encoded, encoded.length - 1)), "truncation rejected");
        rejects(() -> SessionVaultPolicy.decode(Arrays.copyOf(encoded, encoded.length + 1)), "trailing bytes rejected");
        rejects(() -> SessionVaultPolicy.decode(new byte[SessionVaultPolicy.MAX_RECORD_BYTES + 1]), "oversize rejected");
        byte[] wrongVersion = encoded.clone(); wrongVersion[3] ^= 1;
        rejects(() -> SessionVaultPolicy.decode(wrongVersion), "wrong version rejected");
        rejects(() -> new SessionVaultPolicy.Record(metadata, new byte[8], ciphertext), "short nonce rejected");
        System.out.println("SessionVaultPolicySelfTest: " + assertions + " assertions passed");
    }

    private static byte[] decrypt(SecretKey key, SessionVaultPolicy.Record record,
                                  SessionVaultPolicy.Metadata metadata) throws Exception {
        Cipher decrypt = Cipher.getInstance("AES/GCM/NoPadding");
        decrypt.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, record.iv));
        decrypt.updateAAD(metadata.aad());
        return decrypt.doFinal(record.ciphertext);
    }
}
