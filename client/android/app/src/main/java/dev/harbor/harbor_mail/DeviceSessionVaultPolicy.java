package dev.harbor.harbor_mail;

import java.io.*;
import java.util.*;

/** Pure framing and journal invariants. No credentials are logged or debug-rendered. */
public final class DeviceSessionVaultPolicy {
    private DeviceSessionVaultPolicy() {}
    public static final int MAX_RECORD_BYTES = 32768;
    private static final int MAGIC = 0x48445231; // HDR1, distinct from legacy bearer vault
    public static final String ALIAS_PREFIX = "harbor_mail.device_session.v1.";

    /** Minimal adapter allows key-retirement failures/crash recovery to be host-tested. */
    public interface KeyAliases {
        Collection<String> aliases() throws Exception;
        void delete(String alias) throws Exception;
        boolean contains(String alias) throws Exception;
    }
    public static void retireOtherAliases(String currentAlias, KeyAliases keys) throws Exception {
        if (currentAlias == null || !currentAlias.startsWith(ALIAS_PREFIX)
                || !validRequestId(currentAlias.substring(ALIAS_PREFIX.length())) || !keys.contains(currentAlias))
            throw new IOException("Missing current protection key");
        for (String alias : new ArrayList<>(keys.aliases())) {
            if (alias.startsWith(ALIAS_PREFIX) && !alias.equals(currentAlias)) {
                keys.delete(alias);
                if (keys.contains(alias)) throw new IOException("Could not retire old protection key");
            }
        }
        for (String alias : keys.aliases()) {
            if (alias.startsWith(ALIAS_PREFIX) && !alias.equals(currentAlias))
                throw new IOException("Unretired protection key");
        }
    }

    public static final class Metadata {
        public final String apiBase, accountId, familyId;
        public final long idleExpiresAt, absoluteExpiresAt;
        public Metadata(String base, String account, String family, long idle, long absolute) {
            if (!SessionVaultPolicy.validBase(base) || account == null || account.isEmpty()
                    || account.length() > 320 || account.chars().anyMatch(c -> c < 32 || c == 127)
                    || family == null || !family.matches("[a-zA-Z0-9_-]{16,128}")
                    || idle <= 0 || absolute < idle) throw new IllegalArgumentException("Invalid metadata");
            apiBase = base; accountId = account; familyId = family;
            idleExpiresAt = idle; absoluteExpiresAt = absolute;
        }
        public boolean matches(String base, String account, String family) {
            return apiBase.equals(base) && accountId.equals(account) && (family == null || familyId.equals(family));
        }
        public boolean validAt(long now) { return now > 0 && absoluteExpiresAt > now; }
        public Map<String, Object> toMap(boolean biometric) {
            Map<String, Object> out = new HashMap<>();
            out.put("apiBase", apiBase); out.put("accountId", accountId); out.put("familyId", familyId);
            out.put("idleExpiresAt", idleExpiresAt); out.put("absoluteExpiresAt", absoluteExpiresAt);
            out.put("biometricEnabled", biometric); return out;
        }
        void binding(DataOutputStream out) throws IOException {
            out.writeInt(MAGIC); out.writeUTF(apiBase); out.writeUTF(accountId); out.writeUTF(familyId);
        }
        void encode(DataOutputStream out) throws IOException {
            binding(out); out.writeLong(idleExpiresAt); out.writeLong(absoluteExpiresAt);
        }
    }

    public static boolean validRefresh(String value) {
        if (value == null || !value.matches("[A-Za-z0-9_-]{43}")) return false;
        // A canonical 32-byte base64url string has two zero low bits at the end.
        return "AEIMQUYcgkosw048".indexOf(value.charAt(42)) >= 0;
    }
    public static boolean validRequestId(String value) {
        return value != null && value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    }
    public static final class Pending {
        public final String oldRefresh, nextRefresh, requestId;
        public Pending(String old, String next, String id) {
            if (!validRefresh(old) || !validRefresh(next) || old.equals(next) || !validRequestId(id))
                throw new IllegalArgumentException("Invalid rotation");
            oldRefresh = old; nextRefresh = next; requestId = id;
        }
        public Map<String, Object> toMap() {
            Map<String, Object> out = new HashMap<>(); out.put("oldRefresh", oldRefresh);
            out.put("nextRefresh", nextRefresh); out.put("requestId", requestId); return out;
        }
        @Override public String toString() { return "Pending([redacted])"; }
    }
    public static final class State {
        public final Metadata metadata;
        public final String refreshToken;
        public final Pending pending;
        public State(Metadata metadata, String refresh, Pending pending) {
            if (metadata == null || !validRefresh(refresh) || (pending != null && !refresh.equals(pending.oldRefresh)))
                throw new IllegalArgumentException("Invalid device state");
            this.metadata = metadata; refreshToken = refresh; this.pending = pending;
        }
        public State begin(String next, String requestId) {
            // Recovery owns the existing tuple, regardless of supplied new candidates.
            return pending != null ? this : new State(metadata, refreshToken, new Pending(refreshToken, next, requestId));
        }
        public State commit(String id, String next, long idle, long absolute, long now) {
            if (pending == null || !pending.requestId.equals(id) || !pending.nextRefresh.equals(next)
                    || absolute != metadata.absoluteExpiresAt || idle < metadata.idleExpiresAt)
                throw new IllegalArgumentException("Rotation mismatch");
            Metadata updated = new Metadata(metadata.apiBase, metadata.accountId, metadata.familyId, idle, absolute);
            if (!updated.validAt(now)) throw new IllegalArgumentException("Expired rotation");
            return new State(updated, next, null);
        }
        public byte[] encode() throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
            out.writeInt(MAGIC); out.writeUTF(refreshToken); out.writeBoolean(pending != null);
            if (pending != null) { out.writeUTF(pending.oldRefresh); out.writeUTF(pending.nextRefresh); out.writeUTF(pending.requestId); }
            out.flush(); return bytes.toByteArray();
        }
        @Override public String toString() { return "DeviceState([redacted])"; }
    }
    public static State decodeState(Metadata metadata, byte[] bytes) throws IOException {
        if (bytes == null || bytes.length > MAX_RECORD_BYTES) throw new IOException("Invalid state");
        try {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
            if (in.readInt() != MAGIC) throw new IOException("Invalid state version");
            String refresh = in.readUTF(); int present = in.readUnsignedByte();
            if (present > 1) throw new IOException("Invalid pending flag");
            Pending pending = present == 1 ? new Pending(in.readUTF(), in.readUTF(), in.readUTF()) : null;
            if (in.available() != 0) throw new IOException("Trailing state data");
            return new State(metadata, refresh, pending);
        } catch (IllegalArgumentException e) { throw new IOException("Invalid state"); }
    }

    public static byte[] wrapAad(Metadata metadata, boolean biometric, String alias) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
        metadata.binding(out); out.writeBoolean(biometric); out.writeUTF(alias); out.flush(); return bytes.toByteArray();
    }
    public static final class Record {
        public final Metadata metadata;
        public final boolean biometricEnabled;
        public final String alias;
        public final byte[] wrapIv, wrappedKey, dataIv, ciphertext;
        public Record(Metadata metadata, boolean biometric, String alias, byte[] wrapIv,
                      byte[] wrappedKey, byte[] dataIv, byte[] ciphertext) {
            if (metadata == null || alias == null || !alias.startsWith(ALIAS_PREFIX)
                    || !validRequestId(alias.substring(ALIAS_PREFIX.length())) || wrapIv == null || wrapIv.length != 12
                    || wrappedKey == null || wrappedKey.length != 48 || dataIv == null || dataIv.length != 12
                    || ciphertext == null || ciphertext.length < 16 || ciphertext.length > 16384)
                throw new IllegalArgumentException("Invalid encrypted device record");
            this.metadata = metadata; biometricEnabled = biometric; this.alias = alias;
            this.wrapIv = wrapIv.clone(); this.wrappedKey = wrappedKey.clone(); this.dataIv = dataIv.clone(); this.ciphertext = ciphertext.clone();
        }
        public byte[] aad() throws IOException { return dataAad(metadata, biometricEnabled, alias, wrapIv, wrappedKey); }
        public byte[] encode() throws IOException {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
            out.write(aad()); out.write(dataIv); out.writeInt(ciphertext.length); out.write(ciphertext); out.flush();
            if (bytes.size() > MAX_RECORD_BYTES) throw new IOException("Record too large"); return bytes.toByteArray();
        }
    }
    public static byte[] dataAad(Metadata metadata, boolean biometric, String alias, byte[] wrapIv, byte[] wrappedKey) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
        metadata.encode(out); out.writeBoolean(biometric); out.writeUTF(alias); out.write(wrapIv); out.write(wrappedKey); out.flush(); return bytes.toByteArray();
    }
    public static Record decodeRecord(byte[] bytes) throws IOException {
        if (bytes == null || bytes.length > MAX_RECORD_BYTES) throw new IOException("Invalid record");
        try {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
            if (in.readInt() != MAGIC) throw new IOException("Invalid record version");
            Metadata metadata = new Metadata(in.readUTF(), in.readUTF(), in.readUTF(), in.readLong(), in.readLong());
            int biometric = in.readUnsignedByte(); if (biometric > 1) throw new IOException("Invalid protection mode");
            String alias = in.readUTF(); byte[] wrapIv = new byte[12], wrappedKey = new byte[48], dataIv = new byte[12];
            in.readFully(wrapIv); in.readFully(wrappedKey); in.readFully(dataIv); int size = in.readInt();
            if (size < 16 || size > 16384 || size != in.available()) throw new IOException("Invalid record frame");
            byte[] cipher = new byte[size]; in.readFully(cipher);
            return new Record(metadata, biometric == 1, alias, wrapIv, wrappedKey, dataIv, cipher);
        } catch (IllegalArgumentException e) { throw new IOException("Invalid record"); }
    }
}
