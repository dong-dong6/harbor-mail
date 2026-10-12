package dev.harbor.harbor_mail;

import android.app.KeyguardManager;
import android.content.*;
import android.os.Build;
import android.security.keystore.*;
import android.util.AtomicFile;
import android.util.Base64;
import android.system.Os;
import android.system.OsConstants;
import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleEventObserver;
import java.io.*;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import io.flutter.plugin.common.*;

/**
 * Separate from the legacy eight-hour bearer vault. Default protection is
 * device-local Keystore encryption, NOT biometric authentication. The optional
 * auth-per-use key wraps a random data key; one foreground unlock permits many
 * fresh-IV journal updates without repeated prompts. No network or access-token
 * persistence exists here. All operations are serialized on the platform thread.
 */
public final class DeviceSessionVaultBridge implements MethodChannel.MethodCallHandler {
    private static final String CHANNEL = "dev.harbor.mail/device_session_vault";
    private static final int AUTH = BiometricManager.Authenticators.BIOMETRIC_STRONG
            | BiometricManager.Authenticators.DEVICE_CREDENTIAL;
    // Held for the complete foreground unlocked session, not just one call.
    private static final AtomicReference<DeviceSessionVaultBridge> OWNER = new AtomicReference<>();
    private final FragmentActivity activity;
    private final Context context;
    private final MethodChannel channel;
    private final AtomicFile file;
    private final LifecycleEventObserver observer;
    private final BroadcastReceiver screenOff;
    private final SecureRandom random = new SecureRandom();
    private byte[] dataKey;
    private DeviceSessionVaultPolicy.Record cachedRecord;
    private DeviceSessionVaultPolicy.State cachedState;
    private Operation active;
    private boolean detached;

    private static final class Operation {
        final MethodChannel.Result result;
        final DeviceSessionVaultPolicy.Record record;
        final Cipher cipher;
        final String newAlias; // only a pending enable operation creates a key
        BiometricPrompt prompt;
        boolean canceled, authenticated, replied;
        Operation(MethodChannel.Result result, DeviceSessionVaultPolicy.Record record, Cipher cipher, String newAlias) {
            this.result = result; this.record = record; this.cipher = cipher; this.newAlias = newAlias;
        }
    }

    public DeviceSessionVaultBridge(FragmentActivity activity, BinaryMessenger messenger) {
        this.activity = activity; context = activity.getApplicationContext();
        file = new AtomicFile(new File(context.getNoBackupFilesDir(), "harbor-device-session-v1"));
        channel = new MethodChannel(messenger, CHANNEL); channel.setMethodCallHandler(this);
        observer = (source, event) -> {
            if (event == Lifecycle.Event.ON_DESTROY) detach();
            else if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) {
                wipeCache();
                // A pending device-PIN activity may itself stop this activity.
                // It retains only ciphertext and an OS crypto handle, never a
                // decrypted DEK. Delivery/commit waits until the app resumes.
                if (event == Lifecycle.Event.ON_STOP && active != null && active.authenticated) cancelActive();
                if (active == null) OWNER.compareAndSet(this, null);
            } else if (event == Lifecycle.Event.ON_RESUME && active != null && active.authenticated) {
                finishAuthentication(active);
            }
        };
        activity.getLifecycle().addObserver(observer);
        screenOff = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent i) { lock(); }
        };
        ContextCompat.registerReceiver(context, screenOff, new IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (detached) { result.success(reply("canceled")); return; }
        try {
            switch (call.method) {
                case "lock": case "cancel": lock(); result.success(reply("locked")); return;
                case "clear": {
                    DeviceSessionVaultBridge owner = OWNER.get(); if (owner != null) owner.lock();
                    wipeCache(); clearStorage(); result.success(reply("empty")); return;
                }
                case "status": status(result); return;
                case "save": save(args(call.arguments), result); return;
                case "unlock": unlock(args(call.arguments), result); return;
                case "beginRotation": begin(args(call.arguments), result); return;
                case "commitRotation": commit(args(call.arguments), result); return;
                case "setBiometricEnabled": setMode(args(call.arguments), result); return;
                default: result.notImplemented();
            }
        } catch (KeyPermanentlyInvalidatedException | java.security.UnrecoverableKeyException e) {
            lock(); result.success(reply("invalidated"));
        } catch (AEADBadTagException e) {
            lock(); result.success(reply("corrupt"));
        } catch (IllegalArgumentException e) {
            result.success(reply("corrupt"));
        } catch (Exception e) {
            // Never include exception strings, token material, or key bytes.
            result.success(reply("failed"));
        } finally {
            if (active == null && dataKey == null) OWNER.compareAndSet(this, null);
        }
    }

    private boolean foreground() {
        KeyguardManager keyguard = (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
        return !detached && !activity.isFinishing() && !activity.isDestroyed()
                && activity.getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.RESUMED)
                && !activity.getSupportFragmentManager().isStateSaved()
                && (keyguard == null || !keyguard.isDeviceLocked());
    }
    private boolean admit(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) { result.success(reply("unavailable")); return false; }
        if (!foreground()) { lock(); result.success(reply("locked")); return false; }
        if (active != null || (OWNER.get() != this && !OWNER.compareAndSet(null, this))) {
            result.success(reply("busy")); return false;
        }
        return true;
    }
    private boolean authenticated(MethodChannel.Result result) {
        if (!admit(result)) return false;
        if (dataKey == null || cachedState == null || cachedRecord == null) { result.success(reply("locked")); return false; }
        if (!cachedState.metadata.validAt(System.currentTimeMillis())) { lock(); result.success(reply("expired")); return false; }
        return true;
    }
    private void status(MethodChannel.Result result) throws Exception {
        DeviceSessionVaultPolicy.Record record = readRecord();
        if (record == null) { result.success(reply(Build.VERSION.SDK_INT >= 23 ? "empty" : "unavailable")); return; }
        if (!record.metadata.validAt(System.currentTimeMillis())) { result.success(reply("expired")); return; }
        if (!store().containsAlias(record.alias)) { result.success(reply("invalidated")); return; }
        if (record.biometricEnabled) retireOtherAliases(record.alias);
        result.success(metadataReply("saved", record));
    }
    private void save(Map<String, Object> args, MethodChannel.Result result) throws Exception {
        if (!Boolean.TRUE.equals(args.get("explicitOptIn"))) { result.success(reply("canceled")); return; }
        DeviceSessionVaultPolicy.Metadata metadata = metadata(args);
        DeviceSessionVaultPolicy.State state = new DeviceSessionVaultPolicy.State(metadata, str(args, "refreshToken"), null);
        if (!metadata.validAt(System.currentTimeMillis())) { result.success(reply("expired")); return; }
        if (!admit(result)) return;
        DeviceSessionVaultPolicy.Record old = readRecord();
        // Never silently replace an explicitly authenticated protection mode.
        if (old != null && old.biometricEnabled) { result.success(reply("locked")); return; }
        String alias = newAlias(); byte[] key = randomKey(); boolean committed = false;
        try {
            Cipher wrap = wrappingCipher(alias, false, metadata);
            byte[] wrapped = wrap.doFinal(key);
            DeviceSessionVaultPolicy.Record record = encrypt(state, key, false, alias, wrap.getIV(), wrapped);
            writeRecord(record); committed = true; cache(key, record, state);
            if (old != null) deleteAliasQuietly(old.alias);
            result.success(stateReply("saved"));
        } finally {
            Arrays.fill(key, (byte) 0); if (!committed) deleteAliasIfUnreferenced(alias);
        }
    }
    private void unlock(Map<String, Object> args, MethodChannel.Result result) throws Exception {
        if (!admit(result)) return;
        DeviceSessionVaultPolicy.Record record = readRecord();
        if (record == null) { result.success(reply("empty")); return; }
        if (!matches(record.metadata, args, false)) { result.success(reply("mismatch")); return; }
        if (!record.metadata.validAt(System.currentTimeMillis())) { lock(); result.success(reply("expired")); return; }
        if (cachedRecord != null && cachedRecord.alias.equals(record.alias) && dataKey != null) {
            result.success(stateReply("unlocked")); return;
        }
        if (record.biometricEnabled) retireOtherAliases(record.alias);
        wipeCache(); Cipher cipher = unwrappingCipher(record);
        if (record.biometricEnabled) { authenticate(new Operation(result, record, cipher, null)); return; }
        byte[] key = cipher.doFinal(record.wrappedKey);
        try { cache(key, record, decrypt(record, key)); result.success(stateReply("unlocked")); }
        finally { Arrays.fill(key, (byte) 0); }
    }
    private void begin(Map<String, Object> args, MethodChannel.Result result) throws Exception {
        if (!authenticated(result)) return;
        if (!matches(cachedState.metadata, args, true)) { result.success(reply("mismatch")); return; }
        if (cachedState.pending == null) {
            byte[] bytes = randomKey(); String next;
            try { next = Base64.encodeToString(bytes, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING); }
            finally { Arrays.fill(bytes, (byte) 0); }
            DeviceSessionVaultPolicy.State state = cachedState.begin(next, UUID.randomUUID().toString());
            persist(state); // Only return the tuple after AtomicFile finishWrite.
        }
        result.success(stateReply("unlocked"));
    }
    private void commit(Map<String, Object> args, MethodChannel.Result result) throws Exception {
        if (!authenticated(result)) return;
        if (!matches(cachedState.metadata, args, true)) { result.success(reply("mismatch")); return; }
        DeviceSessionVaultPolicy.State next;
        try {
            next = cachedState.commit(str(args, "requestId"), str(args, "nextRefresh"), number(args, "idleExpiresAt"),
                    number(args, "absoluteExpiresAt"), System.currentTimeMillis());
        } catch (IllegalArgumentException e) { result.success(reply("mismatch")); return; }
        persist(next); result.success(stateReply("saved"));
    }
    private void persist(DeviceSessionVaultPolicy.State state) throws Exception {
        DeviceSessionVaultPolicy.Record r = cachedRecord;
        DeviceSessionVaultPolicy.Record next = encrypt(state, dataKey, r.biometricEnabled, r.alias, r.wrapIv, r.wrappedKey);
        writeRecord(next); // Failure retains the previous in-memory and on-disk tuple.
        cachedState = state; cachedRecord = next;
    }
    private void setMode(Map<String, Object> args, MethodChannel.Result result) throws Exception {
        if (!Boolean.TRUE.equals(args.get("explicitOptIn"))) { result.success(reply("canceled")); return; }
        if (!(args.get("enabled") instanceof Boolean)) throw new IllegalArgumentException("Invalid mode");
        if (!authenticated(result)) return;
        boolean enabled = (Boolean) args.get("enabled");
        if (cachedRecord.biometricEnabled == enabled) { result.success(metadataReply("saved", cachedRecord)); return; }
        if (enabled && (Build.VERSION.SDK_INT < 30 || BiometricManager.from(context).canAuthenticate(AUTH) != BiometricManager.BIOMETRIC_SUCCESS)) {
            result.success(reply("unavailable")); return;
        }
        String alias = newAlias(); Cipher cipher;
        try { cipher = wrappingCipher(alias, enabled, cachedState.metadata); }
        catch (Exception e) { deleteAliasQuietly(alias); throw e; }
        if (enabled) {
            DeviceSessionVaultPolicy.Record old = cachedRecord;
            wipeCache(); // Pending enable holds only ciphertext and an OS handle.
            authenticate(new Operation(result, old, cipher, alias));
            return;
        }
        // Disabling requires an already-unlocked authenticated foreground state
        // and explicit user selection. A new envelope preserves pending journal.
        byte[] key = randomKey(); boolean committed = false;
        try {
            byte[] wrapped = cipher.doFinal(key); String oldAlias = cachedRecord.alias;
            DeviceSessionVaultPolicy.Record record = encrypt(cachedState, key, false, alias, cipher.getIV(), wrapped);
            writeRecord(record); committed = true; cache(key, record, cachedState);
            deleteAliasQuietly(oldAlias); result.success(metadataReply("saved", record));
        } finally { Arrays.fill(key, (byte) 0); if (!committed) deleteAliasIfUnreferenced(alias); }
    }

    private void authenticate(Operation op) {
        if (Build.VERSION.SDK_INT < 30 || BiometricManager.from(context).canAuthenticate(AUTH) != BiometricManager.BIOMETRIC_SUCCESS) {
            if (op.newAlias != null) deleteAliasQuietly(op.newAlias);
            restorePreviousIfSafe(op);
            op.result.success(reply("unavailable")); return;
        }
        active = op;
        op.prompt = new BiometricPrompt(activity, ContextCompat.getMainExecutor(context), new BiometricPrompt.AuthenticationCallback() {
            @Override public void onAuthenticationError(int code, CharSequence ignored) {
                if (active != op) return;
                String status = op.canceled || code == BiometricPrompt.ERROR_CANCELED || code == BiometricPrompt.ERROR_USER_CANCELED
                        || code == BiometricPrompt.ERROR_NEGATIVE_BUTTON ? "canceled"
                        : code == BiometricPrompt.ERROR_LOCKOUT || code == BiometricPrompt.ERROR_LOCKOUT_PERMANENT ? "lockedOut" : "unavailable";
                complete(op, reply(status), false);
            }
            @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult authentication) {
                if (active != op) return;
                if (op.canceled || detached) { complete(op, reply("canceled"), false); return; }
                if (authentication.getCryptoObject() == null || authentication.getCryptoObject().getCipher() != op.cipher) {
                    complete(op, reply("failed"), false); return;
                }
                op.authenticated = true; finishAuthentication(op);
            }
            @Override public void onAuthenticationFailed() {}
        });
        try {
            op.prompt.authenticate(new BiometricPrompt.PromptInfo.Builder()
                    .setTitle(op.newAlias == null ? "解锁泊信设备会话" : "启用设备身份验证")
                    .setSubtitle("此后每次打开应用时验证；不会后台解锁")
                    .setAllowedAuthenticators(AUTH).setConfirmationRequired(true).build(), new BiometricPrompt.CryptoObject(op.cipher));
        } catch (Exception e) { complete(op, reply("failed"), false); }
    }
    private void finishAuthentication(Operation op) {
        if (active != op) return;
        if (op.canceled || detached) { complete(op, reply("canceled"), false); return; }
        if (!foreground()) return; // PIN success can arrive immediately before onResume.
        byte[] key = null, oldKey = null; boolean committed = false;
        try {
            if (!op.record.metadata.validAt(System.currentTimeMillis())) { complete(op, reply("expired"), false); return; }
            if (op.newAlias == null) {
                key = op.cipher.doFinal(op.record.wrappedKey);
                cache(key, op.record, decrypt(op.record, key));
                complete(op, stateReply("unlocked"), false);
            } else {
                // Enabling began in ordinary mode. Unwrap the previous envelope
                // only now, after successful OS authentication and foreground.
                oldKey = unwrappingCipher(op.record).doFinal(op.record.wrappedKey);
                DeviceSessionVaultPolicy.State state = decrypt(op.record, oldKey);
                key = randomKey(); byte[] wrapped = op.cipher.doFinal(key);
                DeviceSessionVaultPolicy.Record record = encrypt(state, key, true, op.newAlias, op.cipher.getIV(), wrapped);
                writeRecord(record); committed = true; cache(key, record, state);
                try { retireOtherAliases(record.alias); }
                catch (Exception e) {
                    // Never claim stronger protection while a no-auth key that
                    // could decrypt an old envelope remains usable.
                    wipeCache(); try { clearStorage(); } catch (Exception ignored) {}
                    complete(op, reply("failed"), true); return;
                }
                complete(op, metadataReply("saved", record), true);
            }
        } catch (KeyPermanentlyInvalidatedException | java.security.UnrecoverableKeyException e) {
            wipeCache(); complete(op, reply("invalidated"), committed);
        } catch (AEADBadTagException e) {
            wipeCache(); complete(op, reply("corrupt"), committed);
        } catch (Exception e) {
            wipeCache(); complete(op, reply("failed"), committed);
        } finally {
            if (key != null) Arrays.fill(key, (byte) 0); if (oldKey != null) Arrays.fill(oldKey, (byte) 0);
        }
    }
    private void complete(Operation op, Map<String, Object> result, boolean committed) {
        if (active != op) return;
        active = null;
        if (!committed && op.newAlias != null) {
            deleteAliasIfUnreferenced(op.newAlias);
            restorePreviousIfSafe(op);
        }
        if (dataKey == null) OWNER.compareAndSet(this, null);
        if (!op.replied) { op.replied = true; op.result.success(result); }
    }
    private void restorePreviousIfSafe(Operation op) {
        // User canceling the enable prompt leaves ordinary mode operational.
        // Explicit lock/cancel/background must never rehydrate the key cache.
        if (op.newAlias == null || op.canceled || op.record.biometricEnabled || !foreground()) return;
        byte[] key = null;
        try {
            DeviceSessionVaultPolicy.Record current = readRecord();
            if (current == null || !current.alias.equals(op.record.alias)) return;
            key = unwrappingCipher(current).doFinal(current.wrappedKey);
            cache(key, current, decrypt(current, key));
        } catch (Exception ignored) { wipeCache(); }
        finally { if (key != null) Arrays.fill(key, (byte) 0); }
    }
    private void cancelActive() {
        Operation op = active; if (op == null || op.canceled) return;
        op.canceled = true;
        if (op.authenticated) complete(op, reply("canceled"), false);
        else if (op.prompt != null) op.prompt.cancelAuthentication();
        // Keep the owner until the terminal callback so a late OS cancellation
        // cannot cancel a newer prompt. Teardown is the sole exception.
    }
    private void lock() { wipeCache(); cancelActive(); if (active == null) OWNER.compareAndSet(this, null); }
    private void wipeCache() {
        if (dataKey != null) Arrays.fill(dataKey, (byte) 0);
        dataKey = null; cachedState = null; cachedRecord = null;
        // Java/Dart immutable strings cannot be guaranteed physically zeroed;
        // never retain references beyond the foreground/session boundary.
    }
    private void cache(byte[] key, DeviceSessionVaultPolicy.Record record, DeviceSessionVaultPolicy.State state) throws IOException {
        if (key.length != 32 || !foreground()) throw new IOException("Foreground key required");
        wipeCache(); dataKey = key.clone(); cachedRecord = record; cachedState = state;
    }
    public void detach() {
        if (detached) return; detached = true; channel.setMethodCallHandler(null);
        activity.getLifecycle().removeObserver(observer);
        try { context.unregisterReceiver(screenOff); } catch (Exception ignored) {}
        lock(); if (active != null) complete(active, reply("canceled"), false);
        OWNER.compareAndSet(this, null);
    }

    private String newAlias() { return DeviceSessionVaultPolicy.ALIAS_PREFIX + UUID.randomUUID(); }
    private byte[] randomKey() { byte[] bytes = new byte[32]; random.nextBytes(bytes); return bytes; }
    private Cipher wrappingCipher(String alias, boolean biometric, DeviceSessionVaultPolicy.Metadata metadata) throws Exception {
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        KeyGenParameterSpec.Builder builder = new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(biometric);
        if (biometric) builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG | KeyProperties.AUTH_DEVICE_CREDENTIAL);
        generator.init(builder.build()); SecretKey key = generator.generateKey();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key);
        cipher.updateAAD(DeviceSessionVaultPolicy.wrapAad(metadata, biometric, alias));
        return cipher;
    }
    private Cipher unwrappingCipher(DeviceSessionVaultPolicy.Record record) throws Exception {
        SecretKey key = (SecretKey) store().getKey(record.alias, null);
        if (key == null) throw new java.security.UnrecoverableKeyException("Missing device key");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, record.wrapIv));
        cipher.updateAAD(DeviceSessionVaultPolicy.wrapAad(record.metadata, record.biometricEnabled, record.alias)); return cipher;
    }
    private DeviceSessionVaultPolicy.Record encrypt(DeviceSessionVaultPolicy.State state, byte[] key, boolean biometric,
            String alias, byte[] wrapIv, byte[] wrapped) throws Exception {
        byte[] plain = state.encode(); byte[] iv = new byte[12]; random.nextBytes(iv);
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
            cipher.updateAAD(DeviceSessionVaultPolicy.dataAad(state.metadata, biometric, alias, wrapIv, wrapped));
            return new DeviceSessionVaultPolicy.Record(state.metadata, biometric, alias, wrapIv, wrapped, iv, cipher.doFinal(plain));
        } finally { Arrays.fill(plain, (byte) 0); }
    }
    private DeviceSessionVaultPolicy.State decrypt(DeviceSessionVaultPolicy.Record record, byte[] key) throws Exception {
        if (key.length != 32) throw new IOException("Invalid data key");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, record.dataIv));
        cipher.updateAAD(record.aad()); byte[] plain = cipher.doFinal(record.ciphertext);
        try { return DeviceSessionVaultPolicy.decodeState(record.metadata, plain); }
        finally { Arrays.fill(plain, (byte) 0); }
    }
    private KeyStore store() throws Exception { KeyStore s = KeyStore.getInstance("AndroidKeyStore"); s.load(null); return s; }
    private void retireOtherAliases(String currentAlias) throws Exception {
        // Resume an interrupted protection migration before reporting it active.
        // There is only one durable device-session record, and the dedicated
        // namespace never includes legacy vault or other app keys.
        DeviceSessionVaultBridge owner = OWNER.get();
        if (owner != null && owner.active != null && owner.active.newAlias != null
                && !owner.active.newAlias.equals(currentAlias))
            throw new IOException("Protection transition in progress");
        final KeyStore s = store();
        DeviceSessionVaultPolicy.retireOtherAliases(currentAlias, new DeviceSessionVaultPolicy.KeyAliases() {
            @Override public Collection<String> aliases() throws Exception { return Collections.list(s.aliases()); }
            @Override public void delete(String alias) throws Exception { s.deleteEntry(alias); }
            @Override public boolean contains(String alias) throws Exception { return s.containsAlias(alias); }
        });
    }
    private void deleteAliasIfUnreferenced(String alias) {
        try {
            DeviceSessionVaultPolicy.Record current = readRecord();
            if (current == null || !current.alias.equals(alias)) deleteAliasQuietly(alias);
        } catch (Exception ignored) { /* Unknown disk commit: retain its key for recovery. */ }
    }
    private void deleteAliasQuietly(String alias) { try { store().deleteEntry(alias); } catch (Exception ignored) {} }
    private boolean exists() {
        String p = file.getBaseFile().getPath(); return new File(p).exists() || new File(p + ".bak").exists() || new File(p + ".new").exists();
    }
    private DeviceSessionVaultPolicy.Record readRecord() throws IOException {
        if (!exists()) return null;
        try (FileInputStream in = file.openRead(); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024]; int count;
            while ((count = in.read(buffer)) != -1) {
                if (bytes.size() + count > DeviceSessionVaultPolicy.MAX_RECORD_BYTES) throw new IOException("Invalid file");
                bytes.write(buffer, 0, count);
            }
            return DeviceSessionVaultPolicy.decodeRecord(bytes.toByteArray());
        }
    }
    private void writeRecord(DeviceSessionVaultPolicy.Record record) throws IOException {
        FileOutputStream out = null;
        boolean finishing = false;
        byte[] expected = record.encode();
        try {
            out = file.startWrite(); out.write(expected); out.flush(); out.getFD().sync();
            finishing = true;
            file.finishWrite(out); // Android can log rather than throw failures.
            // Durably record the atomic rename and verify the committed frame;
            // an unconfirmed write never permits a network request.
            java.io.FileDescriptor directory = null;
            try {
                directory = Os.open(file.getBaseFile().getParent(), OsConstants.O_RDONLY, 0);
                Os.fsync(directory);
            } catch (Exception e) { throw new IOException("Unconfirmed directory sync"); }
            finally { if (directory != null) try { Os.close(directory); } catch (Exception ignored) {} }
            DeviceSessionVaultPolicy.Record actual = readRecord();
            if (actual == null || !Arrays.equals(expected, actual.encode())) throw new IOException("Unconfirmed atomic commit");
        } catch (IOException e) {
            if (!finishing && out != null) file.failWrite(out);
            // A rename might have committed even though verification failed.
            // Force disk recovery before another beginRotation, never create a
            // second successor from stale cached state after this ambiguity.
            wipeCache(); throw e;
        }
    }
    private void clearStorage() throws Exception {
        boolean keysGone = false, fileGone = false;
        try {
            KeyStore s = store(); Enumeration<String> entries = s.aliases(); List<String> aliases = new ArrayList<>();
            while (entries.hasMoreElements()) { String a = entries.nextElement(); if (a.startsWith(DeviceSessionVaultPolicy.ALIAS_PREFIX)) aliases.add(a); }
            for (String a : aliases) s.deleteEntry(a);
            keysGone = true; for (String a : aliases) if (s.containsAlias(a)) keysGone = false;
        } catch (Exception ignored) {}
        try { file.delete(); fileGone = !exists(); } catch (Exception ignored) {}
        if (!keysGone || !fileGone) throw new IOException("Could not clear device session");
    }
    @SuppressWarnings("unchecked") private static Map<String, Object> args(Object value) {
        if (!(value instanceof Map)) throw new IllegalArgumentException("Invalid arguments"); return (Map<String, Object>) value;
    }
    private static String str(Map<String, Object> a, String key) {
        if (!(a.get(key) instanceof String)) throw new IllegalArgumentException("Invalid field"); return (String) a.get(key);
    }
    private static long number(Map<String, Object> a, String key) {
        Object v = a.get(key); if (!(v instanceof Long) && !(v instanceof Integer)) throw new IllegalArgumentException("Invalid date"); return ((Number) v).longValue();
    }
    private static DeviceSessionVaultPolicy.Metadata metadata(Map<String, Object> a) {
        return new DeviceSessionVaultPolicy.Metadata(str(a, "apiBase"), str(a, "accountId"), str(a, "familyId"), number(a, "idleExpiresAt"), number(a, "absoluteExpiresAt"));
    }
    private static boolean matches(DeviceSessionVaultPolicy.Metadata m, Map<String, Object> a, boolean family) {
        return m.matches(str(a, "apiBase"), str(a, "accountId"), family ? str(a, "familyId") : null);
    }
    private static Map<String, Object> reply(String status) { Map<String, Object> out = new HashMap<>(); out.put("status", status); return out; }
    private static Map<String, Object> metadataReply(String status, DeviceSessionVaultPolicy.Record r) {
        Map<String, Object> out = reply(status); out.put("metadata", r.metadata.toMap(r.biometricEnabled)); return out;
    }
    private Map<String, Object> stateReply(String status) {
        Map<String, Object> out = metadataReply(status, cachedRecord); out.put("refreshToken", cachedState.refreshToken);
        if (cachedState.pending != null) out.put("pending", cachedState.pending.toMap()); return out;
    }
}
