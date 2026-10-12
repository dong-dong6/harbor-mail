# Android APK downloads

## What the website offers

The Android download card uses public, same-origin endpoints:

- `GET /downloads/android/manifest.json`: build availability and verified metadata.
- `GET /downloads/android/app.apk`: the verified APK as an attachment. `HEAD` is supported.

The card never invents an APK link. If an artifact or its manifest is absent, the manifest is
`{"schemaVersion":1,"available":false,"reason":"NOT_BUILT"}` and the APK endpoint returns 404.
If integrity or metadata validation fails, the reason is `INVALID_ARTIFACT`; no download URL,
local filesystem path, or parsing detail is disclosed. No account login, API bearer token, or
pairing secret is required for these public downloads. Mail APIs remain authenticated.

## CI builds this project's APK

The `android-apk` job in `.github/workflows/build.yml` builds the checked-out Flutter source.
It does not ask users to provide an existing APK. The normal Web/Java job depends on that job,
receives the artifact from the same workflow run and commit, and embeds it in the runnable JAR.
The integrated smoke test downloads the actual APK from the running JAR and checks its bytes,
size, SHA-256, source commit and attachment headers.

Current artifacts are **development/debug builds**, with application ID
`dev.harbor.harbor_mail.dev`. The `.dev` suffix keeps this test build separate from the future
production package `dev.harbor.harbor_mail`. The default Android debug keystore is ephemeral
on the isolated CI runner. No production signing key is created, uploaded, cached or persisted.
The existing release Gradle configuration also uses debug signing and is **not** a production
release signing configuration. This workflow deliberately invokes `flutter build apk --debug`.

Each CI run can have a different debug certificate. Android may therefore reject updating an
older test build in place. Uninstalling that old development app clears its local app data;
reinstall and pair it again. Do not use this debug build for production mail or real accounts.
A future production build needs an approved existing signing-key setup, stable application ID,
release-signing configuration, update policy, and a separately reviewed manifest classification.

## SDK requirements and license policy

The job uses the official runner's preinstalled Android SDK. It checks actual files for
Android platforms 35/36, build-tools 36.0.0, NDK 29.0.14206865, CMake 3.31.5 and existing SDK license state before
building. It does not run `sdkmanager`, accept SDK licenses, or install missing SDK components.
Gradle SDK auto-download is disabled. If a runner lacks a prerequisite, the job fails with an
explicit diagnostic and no downloadable artifact is published.

Flutter 3.47.5 normally selects NDK 28.2; current runner images do not necessarily contain it.
`HARBOR_ANDROID_NDK_VERSION` selects the explicitly checked preinstalled NDK for CI. Without
that environment variable, local builds retain Flutter's default. Build-tools remain pinned.
Android library plugins have independent DSL settings: `jni` explicitly selects Flutter's NDK.
The root Gradle script uses the supported AGP `finalizeDsl` callbacks for both application and
library modules to apply `HARBOR_ANDROID_NDK_VERSION` and `HARBOR_ANDROID_CMAKE_VERSION`
after plugin declarations, before native build configuration. This also avoids JNI's absent
default CMake 3.10.2; CI selects and verifies the preinstalled 3.31.5. No pub-cache plugin files
are modified. Without these environment variables, plugin defaults remain unchanged.
Flutter comes from the official, SHA-256-pinned archive already used by the Web workflow.

References:

- [Official Android apksigner verification](https://developer.android.com/tools/apksigner)
- [Official Android SDK update and auto-download behavior](https://developer.android.com/studio/intro/update)
- [GitHub Ubuntu 24.04 hosted runner inventory](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)

No Android SDK is installed by the local source/test work. A real Android build is verified only
when the authorized CI job completes; passing synthetic tests does not prove installability.

## Verification and embedding

`scripts/build-android-download.sh` runs the Flutter build, then
`scripts/prepare-android-download.py` stages its output and invokes official `aapt dump badging`
and `apksigner verify --verbose --print-certs`. The script requires:

1. A nonempty APK ZIP container no larger than 256 MiB.
2. Successful signature verification and exactly one signing certificate.
3. The actual `.dev` application ID, expected project version name and version code.
4. Android's debuggable flag and the Android Debug certificate identity.
5. A full CI source commit. No guessed or manually entered APK hash, size, version or certificate.

The generated manifest includes schema version, availability, exact download path and filename,
actual package/version/code, file byte length, file SHA-256, source commit, signing classification
and certificate SHA-256. The public key fingerprint is metadata, not a signing secret.

Artifacts are private classpath resources at `META-INF/android-download/{manifest.json,app.apk}`.
They are excluded from Git; no placeholder APK is checked in. Prepare them **offline before
packaging**, never against a running server's exploded classpath. The server validates bounded
metadata and streams the APK once on startup to verify its exact byte count, ZIP magic and digest.
Serve the immutable packaged JAR and restart after replacing a build; do not mutate its resources
in place. APK bytes are streamed to clients without loading the complete binary into heap memory.

The manifest is `no-store`. The stable APK URL uses its SHA-256 as ETag and
`public, no-cache, must-revalidate`, so a browser revalidates every reuse. Downloads use
`application/vnd.android.package-archive`, a fixed attachment filename and `nosniff`.
Only the exact two public paths are served. Encoded, traversal, suffix, private-resource and
unsupported-method variants do not expose the artifact. No request input becomes a file path.

## Installing a test build

1. In the website's device section, check the development warning and version, then choose
   “下载测试 APK”. The file SHA-256 and signing certificate SHA-256 are expandable for verification.
2. On Android, open the downloaded APK. If needed, allow installation from that specific browser
   or file manager for this install, and disable that allowance afterward. Do not bypass a
   system security warning about an untrusted or invalid file.
3. Open Harbor Mail, scan the website's connection QR code, and compare the device and displayed
   confirmation code before approving it on the website.

This APK is Android-only, not an iPhone installer. Hosting must expose the same-origin download
paths along with the JAR's website. There is no third-party APK redirect or arbitrary URL from
manifest metadata. Deploy the Web client and its APK in the same integrated build.

## Local checks

```sh
python3 scripts/test-prepare-android-download.py
flutter test test/android_downloads_test.dart # from client/
mvn -f server/pom.xml -Dtest=AndroidDownloadsTest,AndroidDownloadsHttpTest test
```

Python and Java tests intentionally use synthetic byte fixtures to verify contracts, invalid
metadata, missing files, digest/size mismatch and HTTP handling. They are not signed APKs and
are never shipped. Only the official build-tool verification followed by the integrated CI
HTTP smoke test establishes that a real built artifact is downloadable. Physical Android
installation, camera scanning and OS permission flows still need device testing.
