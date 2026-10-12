package dev.harbor.harbor_mail;

import android.content.Context;
import android.os.Build;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyPermanentlyInvalidatedException;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;

import androidx.biometric.BiometricManager;
import androidx.biometric.BiometricPrompt;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.FragmentActivity;
import androidx.lifecycle.Lifecycle;
import androidx.lifecycle.LifecycleEventObserver;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import javax.crypto.AEADBadTagException;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Opt-in storage of one existing, short-lived bearer. Every encryption AND
 * decryption uses the exact OS-authenticated CryptoObject. No software key,
 * authentication time window, plaintext token file, refresh, or password API.
 *
 * All callbacks/channel calls run on the main thread. A canceled operation stays
 * busy until its terminal callback, preventing a late cancellation from being
 * applied to a new prompt. Detach never commits a pending save/restore.
 */
public final class SessionVaultBridge implements MethodChannel.MethodCallHandler {
    private static final String CHANNEL = "dev.harbor.mail/session_vault";
    private static final String ALIAS = "harbor_mail.session_vault.aes_gcm.v1";
    private static final int AUTHENTICATORS = BiometricManager.Authenticators.BIOMETRIC_STRONG
            | BiometricManager.Authenticators.DEVICE_CREDENTIAL;
    private static final AtomicReference<SessionVaultBridge> OWNER = new AtomicReference<>();

    private final FragmentActivity activity;
    private final Context context;
    private final MethodChannel channel;
    private final AtomicFile file;
    private final LifecycleEventObserver lifecycleObserver;
    private Operation active;
    private boolean detached;

    private static final class Operation {
        final MethodChannel.Result result;
        final SessionVaultPolicy.Metadata metadata;
        final Cipher cipher;
        final boolean saving;
        byte[] input;
        BiometricPrompt prompt;
        boolean canceled;
        boolean authenticated;
        boolean replied;
        Operation(MethodChannel.Result result, SessionVaultPolicy.Metadata metadata,
                  Cipher cipher, boolean saving, byte[] input) {
            this.result = result;
            this.metadata = metadata;
            this.cipher = cipher;
            this.saving = saving;
            this.input = input;
        }
        void wipe() {
            if (input != null) Arrays.fill(input, (byte) 0);
            input = null;
        }
    }

    public SessionVaultBridge(FragmentActivity activity, BinaryMessenger messenger) {
        this.activity = activity;
        context = activity.getApplicationContext();
        // Android excludes this directory from cloud backup and device transfer.
        // The AndroidKeyStore key is device-local and never exported.
        file = new AtomicFile(new File(context.getNoBackupFilesDir(), "harbor-session-vault-v1"));
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(this);
        lifecycleObserver = (source, event) -> {
            Operation operation = active;
            if (event == Lifecycle.Event.ON_DESTROY) {
                detach();
            } else if (operation != null && event == Lifecycle.Event.ON_RESUME
                    && operation.authenticated) {
                finishAuthenticated(operation);
            } else if (operation != null && event == Lifecycle.Event.ON_STOP
                    && operation.authenticated) {
                // An already-granted operation cannot survive a subsequent
                // background transition. Before grant, ON_STOP may be the OS
                // credential UI, so blindly canceling it would break PIN entry.
                cancelActive();
            }
        };
        activity.getLifecycle().addObserver(lifecycleObserver);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (detached) { result.success(reply("canceled")); return; }
        try {
            switch (call.method) {
                case "cancel":
                    cancelActive();
                    result.success(reply("canceled"));
                    return;
                case "clear":
                    // Logout must cancel another engine's pending save as well.
                    SessionVaultBridge owner = OWNER.get();
                    if (owner != null) owner.cancelActive();
                    clearStorage();
                    result.success(reply("empty"));
                    return;
                case "status":
                    status(result);
                    return;
                case "save":
                    save(call.arguments, result);
                    return;
                case "restore":
                    restore(call.arguments, result);
                    return;
                default:
                    result.notImplemented();
            }
        } catch (KeyPermanentlyInvalidatedException e) {
            failClosed(result, "invalidated");
        } catch (IllegalArgumentException e) {
            result.success(reply("corrupt"));
        } catch (Exception e) {
            // Never put exception strings, arguments, or plaintext into logs.
            result.success(reply("failed"));
        }
    }

    private boolean available() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                && BiometricManager.from(context).canAuthenticate(AUTHENTICATORS)
                == BiometricManager.BIOMETRIC_SUCCESS;
    }

    private void status(MethodChannel.Result result) throws Exception {
        SessionVaultPolicy.Record record;
        try { record = readRecord(); }
        catch (Exception e) { failClosed(result, "corrupt"); return; }
        if (record == null) { result.success(reply(available() ? "empty" : "unavailable")); return; }
        if (!record.metadata.validAt(System.currentTimeMillis())) {
            failClosed(result, "expired"); return;
        }
        if (!keyStore().containsAlias(ALIAS)) { failClosed(result, "invalidated"); return; }
        if (!available()) { result.success(reply("unavailable")); return; }
        Map<String, Object> data = reply("saved");
        data.put("metadata", record.metadata.toMap());
        result.success(data);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> arguments(Object raw) {
        if (!(raw instanceof Map)) throw new IllegalArgumentException("Invalid request");
        return (Map<String, Object>) raw;
    }

    private static String string(Map<String, Object> data, String key) {
        Object value = data.get(key);
        if (!(value instanceof String)) throw new IllegalArgumentException("Invalid request");
        return (String) value;
    }

    private void save(Object raw, MethodChannel.Result result) throws Exception {
        Map<String, Object> data = arguments(raw);
        if (!Boolean.TRUE.equals(data.get("explicitOptIn"))) {
            result.success(reply("canceled")); return;
        }
        Object expiry = data.get("expiresAt");
        if (!(expiry instanceof Long) && !(expiry instanceof Integer)) {
            throw new IllegalArgumentException("Invalid expiry");
        }
        SessionVaultPolicy.Metadata metadata = new SessionVaultPolicy.Metadata(
                string(data, "apiBase"), string(data, "accountId"), ((Number) expiry).longValue());
        String token = string(data, "token");
        if (!SessionVaultPolicy.validToken(token)) throw new IllegalArgumentException("Invalid token");
        if (!metadata.validAt(System.currentTimeMillis())) { result.success(reply("expired")); return; }
        if (!admit(result)) return;
        try {
            // A new opt-in applies to exactly this authenticated session. Never
            // leave an older account/token recoverable after a canceled switch.
            clearStorage();
            KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .setUserAuthenticationRequired(true)
                    .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG
                            | KeyProperties.AUTH_DEVICE_CREDENTIAL)
                    .build());
            SecretKey key = generator.generateKey();
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key);
            cipher.updateAAD(metadata.aad());
            authenticate(new Operation(result, metadata, cipher, true,
                    token.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            OWNER.compareAndSet(this, null);
            failClosed(result, "failed");
        }
    }

    private void restore(Object raw, MethodChannel.Result result) throws Exception {
        Map<String, Object> data = arguments(raw);
        String expectedBase = string(data, "apiBase");
        String expectedAccount = string(data, "accountId");
        if (!SessionVaultPolicy.validBase(expectedBase)) {
            result.success(reply("mismatch")); return;
        }
        SessionVaultPolicy.Record record;
        try { record = readRecord(); }
        catch (Exception e) { failClosed(result, "corrupt"); return; }
        if (record == null) { result.success(reply("empty")); return; }
        if (!record.metadata.matches(expectedBase, expectedAccount)) {
            // Wrong selection may be corrected; never prompt/decrypt/transmit.
            result.success(reply("mismatch")); return;
        }
        if (!record.metadata.validAt(System.currentTimeMillis())) {
            failClosed(result, "expired"); return;
        }
        if (!admit(result)) return;
        try {
            SecretKey key = (SecretKey) keyStore().getKey(ALIAS, null);
            if (key == null) {
                OWNER.compareAndSet(this, null);
                failClosed(result, "invalidated"); return;
            }
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, record.iv));
            cipher.updateAAD(record.metadata.aad());
            authenticate(new Operation(result, record.metadata, cipher, false, record.ciphertext));
        } catch (KeyPermanentlyInvalidatedException e) {
            OWNER.compareAndSet(this, null);
            failClosed(result, "invalidated");
        } catch (Exception e) {
            OWNER.compareAndSet(this, null);
            failClosed(result, "corrupt");
        }
    }

    private boolean admit(MethodChannel.Result result) {
        if (!available()) { result.success(reply("unavailable")); return false; }
        if (activity.isFinishing() || activity.isDestroyed()
                || !activity.getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.RESUMED)
                || activity.getSupportFragmentManager().isStateSaved()) {
            result.success(reply("canceled")); return false;
        }
        if (!OWNER.compareAndSet(null, this)) { result.success(reply("busy")); return false; }
        return true;
    }

    private void authenticate(Operation operation) {
        active = operation;
        operation.prompt = new BiometricPrompt(activity, ContextCompat.getMainExecutor(context),
                new BiometricPrompt.AuthenticationCallback() {
            @Override public void onAuthenticationError(int code, CharSequence ignored) {
                if (active != operation) return;
                String status;
                if (operation.canceled || code == BiometricPrompt.ERROR_CANCELED
                        || code == BiometricPrompt.ERROR_USER_CANCELED
                        || code == BiometricPrompt.ERROR_NEGATIVE_BUTTON) status = "canceled";
                else if (code == BiometricPrompt.ERROR_LOCKOUT
                        || code == BiometricPrompt.ERROR_LOCKOUT_PERMANENT) status = "lockedOut";
                else if (code == BiometricPrompt.ERROR_NO_BIOMETRICS
                        || code == BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL
                        || code == BiometricPrompt.ERROR_HW_NOT_PRESENT
                        || code == BiometricPrompt.ERROR_HW_UNAVAILABLE) status = "unavailable";
                else status = "failed";
                if (operation.saving) {
                    try { clearStorage(); } catch (Exception e) { status = "failed"; }
                }
                complete(operation, reply(status));
            }
            @Override public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult authentication) {
                if (active != operation) return;
                if (detached || operation.canceled) {
                    if (operation.saving) completeInvalid(operation, "canceled");
                    else complete(operation, reply("canceled"));
                    return;
                }
                BiometricPrompt.CryptoObject crypto = authentication.getCryptoObject();
                if (crypto == null || crypto.getCipher() != operation.cipher) {
                    completeInvalid(operation, "failed"); return;
                }
                operation.authenticated = true;
                // Device-credential success may precede Activity.onResume.
                // Keep the operation handle, but no decrypted token, until then.
                finishAuthenticated(operation);
            }
            // A non-matching biometric is not terminal; the OS owns retries.
            @Override public void onAuthenticationFailed() {}
        });
        try {
            operation.prompt.authenticate(new BiometricPrompt.PromptInfo.Builder()
                    .setTitle(operation.saving ? "安全保存当前泊信会话" : "恢复泊信会话")
                    .setSubtitle("仅在原会话有效期内使用，不会延长登录时间")
                    .setAllowedAuthenticators(AUTHENTICATORS)
                    .setConfirmationRequired(true)
                    .build(), new BiometricPrompt.CryptoObject(operation.cipher));
        } catch (Exception e) {
            completeInvalid(operation, "failed");
        }
    }

    private void finishAuthenticated(Operation operation) {
        if (active != operation) return;
        if (detached || operation.canceled) { complete(operation, reply("canceled")); return; }
        if (!activity.getLifecycle().getCurrentState().isAtLeast(Lifecycle.State.RESUMED)) return;
        byte[] output = null;
        try {
            if (!operation.metadata.validAt(System.currentTimeMillis())) {
                clearStorage(); complete(operation, reply("expired")); return;
            }
            // Only the callback-verified exact auth-per-use operation reaches
            // this method. No decryption or token delivery while backgrounded.
            output = operation.cipher.doFinal(operation.input);
            Map<String, Object> data = reply(operation.saving ? "saved" : "restored");
            data.put("metadata", operation.metadata.toMap());
            if (operation.saving) {
                writeRecord(new SessionVaultPolicy.Record(operation.metadata,
                        operation.cipher.getIV(), output));
            } else {
                String token = new String(output, StandardCharsets.UTF_8);
                if (!SessionVaultPolicy.validToken(token)) throw new IOException("Invalid plaintext");
                data.put("token", token);
            }
            complete(operation, data);
        } catch (AEADBadTagException e) {
            completeInvalid(operation, "corrupt");
        } catch (Exception e) {
            completeInvalid(operation, operation.saving ? "failed" : "corrupt");
        } finally {
            if (output != null) Arrays.fill(output, (byte) 0);
        }
    }

    private void cancelActive() {
        Operation operation = active;
        if (operation == null || operation.canceled) return;
        operation.canceled = true;
        operation.wipe();
        if (operation.authenticated) {
            // The OS success callback already terminated its prompt. A deferred
            // foreground commit can be canceled synchronously without overlap.
            if (operation.saving) completeInvalid(operation, "canceled");
            else complete(operation, reply("canceled"));
            return;
        }
        if (operation.prompt != null) operation.prompt.cancelAuthentication();
        // Keep ownership AND the save/restore Future pending until the OS
        // terminal callback. The UI must not start another local_auth prompt.
        // A broken OS that never calls back stays busy until activity teardown.
    }

    private void completeInvalid(Operation operation, String status) {
        try { clearStorage(); } catch (Exception e) { status = "failed"; }
        complete(operation, reply(status));
    }

    private void complete(Operation operation, Map<String, Object> result) {
        if (active != operation) return;
        operation.wipe();
        active = null;
        OWNER.compareAndSet(this, null);
        if (!operation.replied) {
            operation.replied = true;
            operation.result.success(result);
        }
    }

    public void detach() {
        if (detached) return;
        detached = true;
        channel.setMethodCallHandler(null);
        activity.getLifecycle().removeObserver(lifecycleObserver);
        Operation operation = active;
        cancelActive();
        // Activity teardown is the exception to waiting for an OS callback.
        // A dead Activity cannot host another prompt and must not leak Futures.
        if (operation != null && active == operation) {
            if (operation.saving) completeInvalid(operation, "canceled");
            else complete(operation, reply("canceled"));
        }
        OWNER.compareAndSet(this, null);
    }

    private static Map<String, Object> reply(String status) {
        Map<String, Object> result = new HashMap<>();
        result.put("status", status);
        return result;
    }

    private KeyStore keyStore() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        return store;
    }

    private boolean recordExists() {
        String path = file.getBaseFile().getPath();
        return new File(path).exists() || new File(path + ".bak").exists()
                || new File(path + ".new").exists();
    }

    private SessionVaultPolicy.Record readRecord() throws IOException {
        if (!recordExists()) return null;
        try (FileInputStream input = file.openRead(); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (bytes.size() + count > SessionVaultPolicy.MAX_RECORD_BYTES) {
                    throw new IOException("Invalid session file");
                }
                bytes.write(buffer, 0, count);
            }
            return SessionVaultPolicy.decode(bytes.toByteArray());
        }
    }

    private void writeRecord(SessionVaultPolicy.Record record) throws IOException {
        FileOutputStream output = null;
        try {
            output = file.startWrite();
            output.write(record.encode());
            file.finishWrite(output);
        } catch (IOException e) {
            file.failWrite(output);
            throw e;
        }
    }

    private void clearStorage() throws Exception {
        // Attempt BOTH even if one fails. Never report success until neither
        // the key nor the base/backup/partial ciphertext file remains.
        boolean keyGone = false;
        boolean fileGone = false;
        try {
            KeyStore store = keyStore();
            store.deleteEntry(ALIAS);
            keyGone = !store.containsAlias(ALIAS);
        } catch (Exception ignored) {
            // Continue to remove the encrypted record even if Keystore failed.
        }
        try {
            file.delete();
            fileGone = !recordExists();
        } catch (Exception ignored) {
            // Key deletion above still prevents decryption if it succeeded.
        }
        if (!keyGone || !fileGone) throw new IOException("Could not remove saved session");
    }

    private void failClosed(MethodChannel.Result result, String status) {
        try { clearStorage(); } catch (Exception e) { status = "failed"; }
        result.success(reply(status));
    }
}
