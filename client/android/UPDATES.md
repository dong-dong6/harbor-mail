# Android native update bridge

The updater is opt-in and hands a verified APK to Android's installer. It never
silently installs, changes account settings, grants unknown-source permission,
changes signing keys, or opens permission settings without the explicit method call.

## Channel contract

Method channel: `dev.harbor.mail/updates`.

- `installedInfo`: `{versionName, versionCode, packageName, certificateSha256}`.
- `download`: arguments `{origin, versionCode, versionName, sizeBytes, sha256,
  certificateSha256}`; returns an opaque 32-character lowercase hex token.
- `cancel`: stops pending download/install verification and cleans unhanded files;
  returns `null` only after the transfer/cleanup barrier. Already handed-off files
  remain readable by the installer. Cancelling does not dismiss Android's installer.
- `install`: `{token}`; rehashes and revalidates the APK, then returns
  `permissionRequired` or `opened`. `opened` means the installer was launched,
  not that installation succeeded. The same token can be explicitly retried after
  dismissing the installer, while this Activity is still alive.
- `openInstallSettings`: explicitly opens this app's unknown-source settings on
  Android 8+; returns `null`. Returning from settings does not automatically install.

Event channel `dev.harbor.mail/updates/progress` emits `{received, total}` byte
counts. Native errors use `invalidArgument`, `busy`, `cancelled`, `integrityError`,
`downloadFailed`, or `installFailed`.

## Security and lifecycle

- Plain HTTPS origin only: no credentials, paths other than `/`, queries,
  fragments, percent escapes or redirects. The download path is always
  `/downloads/android/app.apk`; response must be HTTP 200 and identity-encoded.
- Both declared and actual sizes are bounded to 256 MiB; a present Content-Length
  must agree. Connect/read timeouts are 15 seconds and the transfer deadline is
  10 minutes. Interrupted, oversized, truncated and digest-mismatched files fail
  closed. No server credentials, authorization headers or download URLs are logged.
- Manifest version codes must be positive and at most 2,100,000,000; version names
  use the existing numeric `major.minor.patch` format. Downloads cannot downgrade.
- Package and version metadata are checked with PackageManager; the complete APK
  signature is independently verified with Google's `ApkVerifier`. A single current
  signer must exactly equal the installed app's signer. Manifest certificate data
  is a consistency check, never a trust anchor. There is no signer-history or key-
  rotation fallback. Different temporary development keys are rejected.
- Download and install verification have one process-wide flight and run off the
  main thread. Cancellation is checked again on the main thread immediately before
  installer launch, preventing a closed update screen from opening it later.
- Files reside only in private `cache/updates/`. An unexported FileProvider exposes
  only that subdirectory, with a temporary read-only content-URI grant. Tokens never
  accept a path. Completed APK files are made read-only.
- Activity detach invalidates its in-memory tokens without retaining the Activity.
  Partial files are removed on failure/cancel/startup. Handed-off APKs survive until
  a subsequent process startup removes files older than 24 hours; this avoids
  deleting a file while Android's installer still needs it.

## Dependencies

Pinned dependencies in `app/build.gradle.kts`:

- `androidx.core:core:1.17.0`, for FileProvider.
- `com.android.tools.build:apksig:9.1.0`, for cryptographic APK verification.
- `com.android.tools:desugar_jdk_libs:2.1.5`, with core library desugaring enabled
  for Java library APIs such as `java.time` on supported Android versions below 26.

Google's apksig artifact is Java 8 bytecode and depends on standard Java APIs.
On-device/runtime and packaged-app compatibility still require Android build and
device checks; JVM verification is not a substitute. If the verifier cannot load,
installation fails closed. No signing configuration was changed.

## Checks

With JDK 17+ on PATH:

```sh
bash client/android/tests/run-policy-tests.sh
```

This SDK-independent suite covers 72 policy checks: origin restrictions, fixed
path, integer/version limits, digest normalization, opaque tokens, redirect/status
and encoding rejection, response lengths, streaming limits, truncation, hash
mismatch, cancellation, progress and installation-time rehashing.

Additional implementation validation (2026-10-12):

- Java sources compile with `javac --release 17` against real Android 16 API classes
  (Robolectric `android-all:16-robolectric-13921718`), the project's Flutter engine
  jar, AndroidX core and apksig. This is a source/API compilation check, not an AGP
  APK build, manifest merge, resource compile or D8/R8 check.
- `MainActivity.kt` compiles with the real Kotlin 2.4.0 JVM compiler, target 17,
  against the compiled bridge, Flutter engine, Android 16 API and AndroidX Activity/
  Fragment/Lifecycle/SavedState classes. This confirms the actual registration and
  cleanup overrides compile; it is not an Android Gradle build.
- Pinned apksig verified the existing, unmodified CI development APK at Android API
  24 and API 36, including its single expected signing certificate. This tests the
  verifier against an actual APK, not the newly implemented bridge on Android.
- XML parses and whitespace checks pass.

Source compilation commands (classpath variables point to the jars described above):

```sh
javac --release 17 -cp "$ANDROID_FLUTTER_CORE_APKSIG_CLASSPATH" -d "$CLASSES" \
  client/android/app/src/main/java/dev/harbor/harbor_mail/*.java
java -cp "$KOTLIN_COMPILER_CLASSPATH" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -no-stdlib -no-reflect -jvm-target 17 -classpath "$ANDROID_FLUTTER_ANDROIDX_CLASSPATH:$CLASSES" \
  -d "$CLASSES" client/android/app/src/main/kotlin/dev/harbor/harbor_mail/MainActivity.kt
```

Both commands exited 0; javac emitted only an expected deprecated-API note for
backwards-compatible Android package metadata/installer APIs. The policy suite
reported `Android update policy: 72 checks passed.`

Still required before native release: build the new APK with a provisioned Android
SDK and test download/cancellation, activity recreation, mismatched package/version/
signer, changed cached APK, unknown-source permission denied/granted, installer
cancellation/retry, process death and a completed upgrade on a real device or
emulator. This implementation environment did not have an Android SDK or adb; no
new native APK or successful on-device installation is claimed.
