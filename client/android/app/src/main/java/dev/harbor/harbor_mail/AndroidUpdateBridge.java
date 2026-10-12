package dev.harbor.harbor_mail;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;

import androidx.core.content.FileProvider;

import com.android.apksig.ApkVerifier;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.cert.X509Certificate;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import javax.net.ssl.HttpsURLConnection;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** User-driven sideload updater. This bridge never installs silently or grants permissions. */
public final class AndroidUpdateBridge implements MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler {
    private static final String CHANNEL = "dev.harbor.mail/updates";
    private static final long CACHE_TTL_MS = TimeUnit.HOURS.toMillis(24);
    private static final long DOWNLOAD_TIMEOUT_MS = TimeUnit.MINUTES.toMillis(10);
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ExecutorService IO = Executors.newSingleThreadExecutor();
    private static final ScheduledExecutorService ABORT = Executors.newSingleThreadScheduledExecutor();
    // Process-wide, so a second Activity/Flutter engine cannot start a concurrent operation.
    private static final AtomicReference<Operation> ACTIVE = new AtomicReference<>();
    private static final Map<String, Download> DOWNLOADS = new ConcurrentHashMap<>();
    private static final AtomicBoolean CLEANUP_SCHEDULED = new AtomicBoolean();

    private final Activity activity;
    private final Context context;
    private final MethodChannel methods;
    private final EventChannel events;
    private volatile EventChannel.EventSink eventSink;
    private volatile boolean detached;

    public AndroidUpdateBridge(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;
        this.context = activity.getApplicationContext();
        methods = new MethodChannel(messenger, CHANNEL);
        events = new EventChannel(messenger, CHANNEL + "/progress");
        methods.setMethodCallHandler(this);
        events.setStreamHandler(this);
        if (CLEANUP_SCHEDULED.compareAndSet(false, true)) {
            IO.execute(this::cleanupExpiredFiles);
        }
    }

    @Override public void onListen(Object arguments, EventChannel.EventSink sink) { eventSink = sink; }
    @Override public void onCancel(Object arguments) { eventSink = null; }

    public void detach() {
        detached = true;
        eventSink = null;
        methods.setMethodCallHandler(null);
        events.setStreamHandler(null);
        cancel(null);
    }

    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (detached) {
            result.error("cancelled", "The update screen is no longer active.", null);
            return;
        }
        try {
            switch (call.method) {
                case "installedInfo":
                    PackageInfo installed = installedPackage();
                    Map<String, Object> info = new HashMap<>();
                    info.put("versionName", installed.versionName);
                    info.put("versionCode", versionCode(installed));
                    info.put("packageName", installed.packageName);
                    info.put("certificateSha256", certificateHash(installed));
                    result.success(info);
                    break;
                case "download":
                    download(UpdatePolicy.parse(call.arguments), result);
                    break;
                case "cancel":
                    cancel(result);
                    break;
                case "install":
                    install(UpdatePolicy.token(call.arguments), result);
                    break;
                case "openInstallSettings":
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:" + context.getPackageName())));
                    }
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
            }
        } catch (Exception e) {
            report(result, e, "installFailed");
        }
    }

    private void download(UpdatePolicy.Request request, MethodChannel.Result result) throws Exception {
        PackageInfo installed = installedPackage();
        requireCompatible(request, installed);
        Operation operation = begin(result);
        if (operation == null) return;
        IO.execute(() -> {
            File part = null;
            File apk = null;
            HttpsURLConnection connection = null;
            String token = UUID.randomUUID().toString().replace("-", "");
            ScheduledFuture<?> timeout = ABORT.schedule(operation::timeout,
                    DOWNLOAD_TIMEOUT_MS, TimeUnit.MILLISECONDS);
            try {
                // Invalidate only this bridge's earlier unhanded download, before starting a new one.
                removeUnhandedDownloads();
                operation.check();
                part = cacheFile(token + ".part");
                apk = cacheFile(token + ".apk");
                connection = (HttpsURLConnection) request.apkUri.toURL().openConnection();
                operation.connection = connection;
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(15_000);
                connection.setReadTimeout(15_000);
                connection.setUseCaches(false);
                connection.setRequestProperty("Accept-Encoding", "identity");
                connection.setRequestProperty("Accept", "application/vnd.android.package-archive");
                operation.check();
                UpdatePolicy.response(connection.getResponseCode(),
                        connection.getHeaderField("Content-Encoding"),
                        connection.getHeaderField("Content-Length"), request.sizeBytes);
                try (InputStream input = connection.getInputStream();
                     FileOutputStream output = new FileOutputStream(part)) {
                    UpdatePolicy.transfer(input, output, request.sizeBytes, request.sha256, received -> {
                        operation.check();
                        progress(operation, received, request.sizeBytes);
                    });
                    output.getFD().sync();
                }
                operation.check();
                // Inspect and cryptographically verify the complete .part before publishing a token.
                verifyApk(part, request, operation);
                operation.check();
                if (!part.renameTo(apk)) throw new IOException("Cannot finalize the update file.");
                if (!apk.setReadOnly()) throw new IOException("Cannot protect the update file.");
                Download downloaded = new Download(this, token, apk, request);
                DOWNLOADS.put(token, downloaded);
                operation.check();
                finishDownload(operation, result, downloaded);
                apk = null; // The record owns this file until cancellation or installer handoff.
            } catch (Exception e) {
                DOWNLOADS.remove(token);
                finish(operation, result, null, operation.failureOr(e), "downloadFailed");
            } finally {
                timeout.cancel(false);
                operation.connection = null;
                if (connection != null) connection.disconnect();
                if (part != null) part.delete();
                if (apk != null) apk.delete();
            }
        });
    }

    private void install(String token, MethodChannel.Result result) throws Exception {
        Download download = DOWNLOADS.get(token);
        if (download == null || download.owner != this) {
            throw UpdatePolicy.invalid("The update token expired. Download the update again.");
        }
        Operation operation = begin(result);
        if (operation == null) return;
        IO.execute(() -> {
            try {
                operation.check();
                File file = download.file;
                if (!file.isFile() || !file.getCanonicalFile().equals(cacheFile(token + ".apk"))
                        || file.length() != download.request.sizeBytes) {
                    throw UpdatePolicy.integrity("The cached update is missing or has changed.");
                }
                try (FileInputStream input = new FileInputStream(file)) {
                    UpdatePolicy.transfer(input, null, download.request.sizeBytes,
                            download.request.sha256, received -> operation.check());
                }
                // Re-read the current installed identity and re-verify, even after permission settings.
                verifyApk(file, download.request, operation);
                operation.check();
                MAIN.post(() -> {
                    try {
                        operation.check();
                        if (detached || activity.isFinishing() || activity.isDestroyed()) {
                            throw new UpdatePolicy.Failure("cancelled", "The update screen was closed.");
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                                && !context.getPackageManager().canRequestPackageInstalls()) {
                            finishOnMain(operation, result, "permissionRequired", null, "installFailed");
                            return;
                        }
                        Uri uri = FileProvider.getUriForFile(context,
                                context.getPackageName() + ".updates", file);
                        Intent intent = new Intent(Intent.ACTION_INSTALL_PACKAGE)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        intent.setClipData(ClipData.newRawUri("Android update", uri));
                        activity.startActivity(intent);
                        download.handedOff = true;
                        // Keep the APK for the installer; never delete it on Activity pause/detach.
                        file.setLastModified(System.currentTimeMillis());
                        finishOnMain(operation, result, "opened", null, "installFailed");
                    } catch (Exception e) {
                        discard(download);
                        finishOnMain(operation, result, null, operation.failureOr(e), "installFailed");
                    }
                });
            } catch (Exception e) {
                discard(download);
                finish(operation, result, null, operation.failureOr(e), "installFailed");
            }
        });
    }

    private void verifyApk(File file, UpdatePolicy.Request request, Operation operation) throws Exception {
        operation.check();
        PackageInfo installed = installedPackage();
        requireCompatible(request, installed);
        PackageInfo archive = context.getPackageManager().getPackageArchiveInfo(
                file.getAbsolutePath(), signatureFlags());
        if (archive == null || !context.getPackageName().equals(archive.packageName)
                || versionCode(archive) != request.versionCode
                || !request.versionName.equals(archive.versionName)
                || !certificateHash(archive).equals(certificateHash(installed))) {
            throw UpdatePolicy.integrity("The APK package, version, or signing identity does not match.");
        }
        ApkVerifier.Result verified;
        try {
            verified = new ApkVerifier.Builder(file)
                    .setMinCheckedPlatformVersion(Build.VERSION.SDK_INT)
                    .setMaxCheckedPlatformVersion(Build.VERSION.SDK_INT)
                    .build().verify();
        } catch (LinkageError unavailableVerifier) {
            throw UpdatePolicy.integrity("APK signature verification is unavailable on this device.");
        } catch (Exception invalidSignature) {
            throw UpdatePolicy.integrity("The APK signature could not be verified.");
        }
        operation.check();
        List<X509Certificate> signers = verified.getSignerCertificates();
        if (!verified.isVerified() || signers.size() != 1
                || !UpdatePolicy.certificateHash(signers.get(0).getEncoded())
                .equals(certificateHash(installed))) {
            throw UpdatePolicy.integrity("The APK signature is invalid or belongs to another signer.");
        }
    }

    private void requireCompatible(UpdatePolicy.Request request, PackageInfo installed) throws Exception {
        if (request.versionCode <= versionCode(installed)) {
            throw UpdatePolicy.integrity("Only a newer Android version can be installed.");
        }
        // The manifest cert is a consistency check, never the source of signing trust.
        if (!request.certificateSha256.equals(certificateHash(installed))) {
            throw UpdatePolicy.integrity("The update signer differs from the installed app.");
        }
    }

    private Operation begin(MethodChannel.Result result) {
        Operation operation = new Operation(this);
        if (!ACTIVE.compareAndSet(null, operation)) {
            result.error("busy", "An Android update operation is already in progress.", null);
            return null;
        }
        return operation;
    }

    private void cancel(MethodChannel.Result result) {
        Operation current = ACTIVE.get();
        Operation operation = current != null && current.owner == this ? current : null;
        if (operation != null) operation.cancel();
        // This barrier runs only after the transfer has stopped and closed its streams. File cleanup
        // is owner-scoped, so an old Activity cannot cancel or delete a newer Activity's download.
        IO.execute(() -> {
            removeUnhandedDownloads();
            MAIN.post(() -> {
                if (operation != null) ACTIVE.compareAndSet(operation, null);
                if (result != null) result.success(null);
            });
        });
    }

    private void finishDownload(Operation operation, MethodChannel.Result result, Download download) {
        MAIN.post(() -> {
            ACTIVE.compareAndSet(operation, null);
            try {
                // A deadline/cancel may have fired after IO published the record but before
                // this callback. A rejected token must not leave an ownerless cached APK.
                UpdatePolicy.deliverVerifiedDownload(ignored -> operation.check(),
                        () -> result.success(download.token), () -> discard(download));
            } catch (Exception e) {
                report(result, operation.failureOr(e), "downloadFailed");
            }
        });
    }

    private void finish(Operation operation, MethodChannel.Result result, Object value,
                        Exception failure, String defaultCode) {
        MAIN.post(() -> finishOnMain(operation, result, value, failure, defaultCode));
    }

    private void finishOnMain(Operation operation, MethodChannel.Result result, Object value,
                              Exception failure, String defaultCode) {
        ACTIVE.compareAndSet(operation, null);
        if (failure != null) report(result, failure, defaultCode);
        else if (operation.cancelled.get()) report(result, operation.cancellationFailure(), defaultCode);
        else result.success(value);
    }

    private void progress(Operation operation, long received, long total) {
        long now = SystemClock.elapsedRealtime();
        if (received != 0 && received != total && now - operation.lastProgress < 100) return;
        if (received == operation.lastReceived) return;
        operation.lastProgress = now;
        operation.lastReceived = received;
        MAIN.post(() -> {
            EventChannel.EventSink sink = eventSink;
            if (sink != null && !detached && !operation.cancelled.get() && ACTIVE.get() == operation) {
                Map<String, Object> progress = new HashMap<>();
                progress.put("received", received);
                progress.put("total", total);
                sink.success(progress);
            }
        });
    }

    private File cacheFile(String basename) throws IOException {
        File dir = new File(context.getCacheDir(), "updates").getCanonicalFile();
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("Cannot create update cache.");
        File file = new File(dir, basename).getCanonicalFile();
        if (!dir.equals(file.getParentFile())) throw UpdatePolicy.invalid("Invalid update cache path.");
        return file;
    }

    private void cleanupExpiredFiles() {
        File[] files = new File(context.getCacheDir(), "updates").listFiles();
        if (files == null) return;
        long cutoff = System.currentTimeMillis() - CACHE_TTL_MS;
        for (File file : files) {
            String name = file.getName();
            if (name.matches("[a-f0-9]{32}\\.part")
                    || (name.matches("[a-f0-9]{32}\\.apk") && file.lastModified() < cutoff)) {
                file.delete();
            }
        }
    }

    private void removeUnhandedDownloads() {
        for (Download download : DOWNLOADS.values()) {
            if (download.owner == this) {
                discard(download);
                // A detached Activity must not be retained by process-wide token records. The
                // installer still has its URI grant; preserve the handed-off file until startup TTL.
                if (detached && download.handedOff) DOWNLOADS.remove(download.token, download);
            }
        }
    }

    private static void discard(Download download) {
        if (!download.handedOff && DOWNLOADS.remove(download.token, download)) download.file.delete();
    }

    @SuppressWarnings("deprecation")
    private PackageInfo installedPackage() throws PackageManager.NameNotFoundException {
        return context.getPackageManager().getPackageInfo(context.getPackageName(), signatureFlags());
    }

    @SuppressWarnings("deprecation")
    private static int signatureFlags() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                ? PackageManager.GET_SIGNING_CERTIFICATES : PackageManager.GET_SIGNATURES;
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo info) {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ? info.getLongVersionCode() : info.versionCode;
    }

    @SuppressWarnings("deprecation")
    private static String certificateHash(PackageInfo info) throws UpdatePolicy.Failure {
        Signature[] signatures;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            signatures = info.signingInfo == null ? null : info.signingInfo.getApkContentsSigners();
        } else {
            signatures = info.signatures;
        }
        // No historical signer fallback or implicit key-rotation trust.
        if (signatures == null || signatures.length != 1) {
            throw UpdatePolicy.integrity("A single verifiable current signing certificate is required.");
        }
        return UpdatePolicy.certificateHash(signatures[0].toByteArray());
    }

    private static void report(MethodChannel.Result result, Exception error, String defaultCode) {
        if (error instanceof UpdatePolicy.Failure) {
            UpdatePolicy.Failure failure = (UpdatePolicy.Failure) error;
            result.error(failure.code, failure.getMessage(), null);
        } else {
            // Never expose server URLs, local paths, HTTP bodies, or authentication data to errors.
            result.error(defaultCode, "The Android update operation could not be completed.", null);
        }
    }

    private static final class Download {
        final AndroidUpdateBridge owner;
        final String token;
        final File file;
        final UpdatePolicy.Request request;
        volatile boolean handedOff;

        Download(AndroidUpdateBridge owner, String token, File file, UpdatePolicy.Request request) {
            this.owner = owner;
            this.token = token;
            this.file = file;
            this.request = request;
        }
    }

    private static final class Operation {
        final AndroidUpdateBridge owner;
        final AtomicBoolean cancelled = new AtomicBoolean();
        volatile boolean timedOut;
        volatile HttpsURLConnection connection;
        long lastProgress;
        long lastReceived = -1;

        Operation(AndroidUpdateBridge owner) { this.owner = owner; }

        void cancel() {
            cancelled.set(true);
            HttpsURLConnection current = connection;
            if (current != null) ABORT.execute(current::disconnect);
        }

        void timeout() { timedOut = true; cancel(); }

        void check() throws UpdatePolicy.Failure {
            if (cancelled.get()) throw cancellationFailure();
        }

        UpdatePolicy.Failure cancellationFailure() {
            return new UpdatePolicy.Failure(timedOut ? "downloadFailed" : "cancelled",
                    timedOut ? "The update download timed out." : "The update was cancelled.");
        }

        Exception failureOr(Exception fallback) {
            return cancelled.get() ? cancellationFailure() : fallback;
        }
    }
}
