package dev.harbor.harbor_mail;

import java.util.*;
import java.nio.charset.StandardCharsets;
import javax.crypto.*;
import javax.crypto.spec.*;

/** Host-only synthetic fixtures, not proof of Android Keystore/biometric behavior. */
public final class DeviceSessionVaultPolicySelfTest {
    static int count;
    interface Action { void run() throws Exception; }
    static void ok(boolean b, String label) { count++; if (!b) throw new AssertionError(label); }
    static void reject(Action a, String label) throws Exception {
        count++; try { a.run(); } catch (Exception expected) { return; } throw new AssertionError(label);
    }
    static final long NOW = 1800000000000L;
    static final String FAMILY = "00000000-0000-4000-8000-000000000001";
    static final String ID = "00000000-0000-4000-8000-000000000002";
    static final String OTHER = "00000000-0000-4000-8000-000000000003";
    static final String OLD = Base64.getUrlEncoder().withoutPadding().encodeToString(new byte[32]);
    static final String NEXT;
    static { byte[] next = new byte[32]; Arrays.fill(next, (byte) 1); NEXT = Base64.getUrlEncoder().withoutPadding().encodeToString(next); }
    static DeviceSessionVaultPolicy.Metadata meta(String base, String account, String family, long idle, long absolute) {
        return new DeviceSessionVaultPolicy.Metadata(base, account, family, idle, absolute);
    }
    static DeviceSessionVaultPolicy.Metadata meta() { return meta("https://mail.example/api/v1", "owner", FAMILY, NOW + 1000, NOW + 100000); }
    static byte[] crypt(int mode, byte[] key, byte[] iv, byte[] aad, byte[] input) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(mode, new SecretKeySpec(key,"AES"), new GCMParameterSpec(128,iv)); c.updateAAD(aad); return c.doFinal(input);
    }
    public static void main(String[] args) throws Exception {
        var m = meta(); var state = new DeviceSessionVaultPolicy.State(m, OLD, null);
        ok(DeviceSessionVaultPolicy.validRefresh(OLD), "canonical 32B token");
        ok(!DeviceSessionVaultPolicy.validRefresh(OLD.substring(1)), "reject short token");
        ok(!DeviceSessionVaultPolicy.validRefresh(OLD.substring(0,42)+"B"), "reject noncanonical last bits");
        ok(!DeviceSessionVaultPolicy.validRefresh(OLD+"="), "reject padding");
        ok(DeviceSessionVaultPolicy.validRequestId(ID), "UUIDv4 request ID");
        ok(!DeviceSessionVaultPolicy.validRequestId(ID.replace("4000","1000")), "reject old UUID version");
        ok(m.validAt(NOW+2000), "old idle is advisory, preserve pending lost-response recovery");
        ok(!m.validAt(m.absoluteExpiresAt), "absolute expiry closed");
        reject(() -> meta("http://mail.example/api/v1", "owner", FAMILY, NOW, NOW+1), "HTTPS required");
        reject(() -> meta("https://MAIL.example/api/v1", "owner", FAMILY, NOW, NOW+1), "canonical origin required");
        reject(() -> meta(m.apiBase,"own\ner",FAMILY,NOW,NOW+1), "account control rejected");
        reject(() -> meta(m.apiBase,"owner","x",NOW,NOW+1), "short family rejected");
        reject(() -> meta(m.apiBase,"owner",FAMILY,NOW+1,NOW), "invalid lifetime rejected");
        var pending = state.begin(NEXT, ID);
        ok(state.pending == null, "begin immutable before disk commit");
        ok(pending.pending.oldRefresh.equals(OLD) && pending.pending.nextRefresh.equals(NEXT), "old+next persisted together");
        ok(pending.begin(OLD, OTHER) == pending, "ambiguous retries preserve exact tuple even supplied invalid replacement");
        var restored = DeviceSessionVaultPolicy.decodeState(m,pending.encode());
        ok(restored.pending.requestId.equals(ID) && restored.pending.oldRefresh.equals(OLD) && restored.pending.nextRefresh.equals(NEXT), "crash reload keeps entire tuple");
        ok(restored.begin(OLD,OTHER).pending.requestId.equals(ID), "crash retry does not issue new request ID");
        reject(() -> restored.commit(OTHER,NEXT,NOW+5000,m.absoluteExpiresAt,NOW), "wrong request ID cannot commit");
        reject(() -> restored.commit(ID,OLD,NOW+5000,m.absoluteExpiresAt,NOW), "wrong next cannot commit");
        reject(() -> restored.commit(ID,NEXT,NOW+5000,m.absoluteExpiresAt+1,NOW), "absolute may not extend");
        reject(() -> restored.commit(ID,NEXT,NOW+999,m.absoluteExpiresAt,NOW), "idle cannot go backwards");
        var committed = restored.commit(ID,NEXT,NOW+5000,m.absoluteExpiresAt,NOW+2000);
        ok(committed.pending == null && committed.refreshToken.equals(NEXT), "commit clears pending only for exact confirmed transition");
        ok(committed.metadata.absoluteExpiresAt == m.absoluteExpiresAt, "absolute preserved");
        reject(() -> state.commit(ID,NEXT,NOW+5000,m.absoluteExpiresAt,NOW), "no pending no commit");
        reject(() -> new DeviceSessionVaultPolicy.State(m,NEXT,pending.pending), "current must equal pending old");
        reject(() -> new DeviceSessionVaultPolicy.Pending(OLD,OLD,ID), "no self successor");
        byte[] trailing = Arrays.copyOf(pending.encode(),pending.encode().length+1);
        reject(() -> DeviceSessionVaultPolicy.decodeState(m,trailing), "trailing plaintext rejected");
        reject(() -> DeviceSessionVaultPolicy.decodeState(m, new byte[40000]), "oversize plaintext rejected");
        ok(!state.toString().contains(OLD) && !pending.pending.toString().contains(NEXT), "debug redacted");
        byte[] wrappingKey = new byte[32], key = new byte[32], wrapIv = new byte[12], dataIv = new byte[12];
        new java.security.SecureRandom().nextBytes(wrappingKey); new java.security.SecureRandom().nextBytes(key);
        new java.security.SecureRandom().nextBytes(wrapIv); new java.security.SecureRandom().nextBytes(dataIv);
        String alias = DeviceSessionVaultPolicy.ALIAS_PREFIX+FAMILY;
        byte[] wrapped = crypt(Cipher.ENCRYPT_MODE,wrappingKey,wrapIv,DeviceSessionVaultPolicy.wrapAad(m,false,alias),key);
        byte[] encrypted = crypt(Cipher.ENCRYPT_MODE,key,dataIv,DeviceSessionVaultPolicy.dataAad(m,false,alias,wrapIv,wrapped),pending.encode());
        var record = new DeviceSessionVaultPolicy.Record(m,false,alias,wrapIv,wrapped,dataIv,encrypted);
        var decoded = DeviceSessionVaultPolicy.decodeRecord(record.encode());
        ok(Arrays.equals(record.encode(),decoded.encode()), "canonical record round trip");
        String raw = new String(record.encode(),StandardCharsets.ISO_8859_1);
        ok(!raw.contains(OLD) && !raw.contains(NEXT) && !raw.contains(ID), "credential absent from on-disk envelope");
        ok(Arrays.equals(crypt(Cipher.DECRYPT_MODE,wrappingKey,wrapIv,DeviceSessionVaultPolicy.wrapAad(m,false,alias),wrapped),key),"envelope unwrap");
        ok(DeviceSessionVaultPolicy.decodeState(m,crypt(Cipher.DECRYPT_MODE,key,dataIv,decoded.aad(),decoded.ciphertext)).pending.requestId.equals(ID), "encrypted pending recovery");
        for (var changed : new DeviceSessionVaultPolicy.Metadata[]{meta("https://other.example/api/v1","owner",FAMILY,m.idleExpiresAt,m.absoluteExpiresAt),
                meta(m.apiBase,"other",FAMILY,m.idleExpiresAt,m.absoluteExpiresAt), meta(m.apiBase,"owner",OTHER,m.idleExpiresAt,m.absoluteExpiresAt),
                meta(m.apiBase,"owner",FAMILY,m.idleExpiresAt+1,m.absoluteExpiresAt),meta(m.apiBase,"owner",FAMILY,m.idleExpiresAt,m.absoluteExpiresAt+1)}) {
            reject(() -> crypt(Cipher.DECRYPT_MODE,key,dataIv,DeviceSessionVaultPolicy.dataAad(changed,false,alias,wrapIv,wrapped),encrypted),"data origin/account/family/expiry AEAD binding");
        }
        reject(() -> crypt(Cipher.DECRYPT_MODE,wrappingKey,wrapIv,DeviceSessionVaultPolicy.wrapAad(m,true,alias),wrapped),"protection mode bound to wrapped key");
        reject(() -> crypt(Cipher.DECRYPT_MODE,wrappingKey,wrapIv,DeviceSessionVaultPolicy.wrapAad(meta(m.apiBase,"owner",OTHER,m.idleExpiresAt,m.absoluteExpiresAt),false,alias),wrapped),"family bound to wrapped key");
        byte[] changed = encrypted.clone(); changed[0] ^= 1;
        reject(() -> crypt(Cipher.DECRYPT_MODE,key,dataIv,record.aad(),changed),"tampered ciphertext rejected");
        for (int size : new int[]{0,1,10,record.encode().length-1}) {
            reject(() -> DeviceSessionVaultPolicy.decodeRecord(Arrays.copyOf(record.encode(),size)),"truncated record rejected");
        }
        reject(() -> DeviceSessionVaultPolicy.decodeRecord(Arrays.copyOf(record.encode(),record.encode().length+1)),"trailing bytes rejected");
        reject(() -> DeviceSessionVaultPolicy.decodeRecord(new byte[40000]),"oversize record rejected");
        reject(() -> new DeviceSessionVaultPolicy.Record(m,false,"foreign.alias",wrapIv,wrapped,dataIv,encrypted),"foreign key aliases rejected");
        // Mutable idle expiry changes payload AAD, never the auth-per-use wrapper.
        var extended = meta(m.apiBase,m.accountId,m.familyId,NOW+5000,m.absoluteExpiresAt);
        ok(Arrays.equals(DeviceSessionVaultPolicy.wrapAad(m,true,alias),DeviceSessionVaultPolicy.wrapAad(extended,true,alias)), "many rotations need no new biometric prompt");
        ok(!Arrays.equals(DeviceSessionVaultPolicy.dataAad(m,true,alias,wrapIv,wrapped),DeviceSessionVaultPolicy.dataAad(extended,true,alias,wrapIv,wrapped)),"idle authenticated by data envelope");
        // Simulate death after protected record commit but before old-key
        // retirement. Restart must retire every stale key before claiming mode.
        class Keys implements DeviceSessionVaultPolicy.KeyAliases {
            final Set<String> values = new HashSet<>(); boolean ignoreDelete, throwDelete;
            public Collection<String> aliases() { return new ArrayList<>(values); }
            public boolean contains(String value) { return values.contains(value); }
            public void delete(String value) throws Exception {
                if (throwDelete) throw new java.io.IOException("Synthetic deletion failure");
                if (!ignoreDelete) values.remove(value);
            }
        }
        var keys = new Keys(); String previousAlias = DeviceSessionVaultPolicy.ALIAS_PREFIX+OTHER;
        keys.values.add(alias); keys.values.add(previousAlias); keys.values.add("legacy.must.remain");
        keys.ignoreDelete = true;
        reject(() -> DeviceSessionVaultPolicy.retireOtherAliases(alias, keys),"silent key-delete failure must block protection claim");
        ok(keys.values.contains(alias) && keys.values.contains(previousAlias),"failed transition never destroys selected new key");
        keys.ignoreDelete = false; keys.throwDelete = true;
        reject(() -> DeviceSessionVaultPolicy.retireOtherAliases(alias, keys),"thrown key-delete failure must block protection claim");
        keys.throwDelete = false;
        DeviceSessionVaultPolicy.retireOtherAliases(alias, keys);
        ok(keys.values.equals(Set.of(alias,"legacy.must.remain")),"restart finishes interrupted mode transition and preserves other namespaces");
        DeviceSessionVaultPolicy.retireOtherAliases(alias, keys);
        ok(keys.values.contains(alias),"retirement retry idempotent");
        reject(() -> DeviceSessionVaultPolicy.retireOtherAliases(previousAlias, keys),"missing active key does not retire any survivor");
        reject(() -> DeviceSessionVaultPolicy.retireOtherAliases("legacy.must.remain", keys),"foreign active alias rejected");
        System.out.println("DeviceSessionVaultPolicySelfTest: " + count + " assertions passed (synthetic host fixtures)");
    }
}
