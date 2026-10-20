# Persistent Android development signing

The downloadable app keeps `dev.harbor.harbor_mail.dev`. Trusted CI builds must restore
one persistent private key from Actions Secrets and verify the pinned certificate. They
never generate a replacement key or fall back to the runner's temporary debug keystore.
The app is still a development/debug build; this change does not promote it to a production
release or weaken the installer/signature checks.

## Configure the repository once

Store these five repository Actions Secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 of the encrypted PKCS12 keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Private-key password |
| `ANDROID_KEY_ALIAS` | Private-key alias |
| `ANDROID_SIGNING_CERTIFICATE_SHA256` | SHA-256 of the DER signing certificate, 64 hexadecimal characters |

The owner-authorized identity created locally for this project is held under the ignored,
access-restricted `tools/signing/` directory. Keep an offline backup of the keystore and its
passwords. Neither signing material nor its setup JSON belongs in Git, packages, build logs,
CI artifacts, dependency caches, or chat messages.

Public certificate SHA-256:

```text
2444ba9ea34a65797e680613e858101a84b635527c750023db64a9d409a9cffe
```

After signing in with the official GitHub CLI, the local setup file can be uploaded without
printing its contents or putting passwords on the command line:

```sh
python scripts/configure-android-signing.py --secrets-file tools/signing/github-signing-secrets.json
```

The helper refuses to overwrite any existing signing Secret. Stop and inspect a partial
configuration if setup is interrupted. Do not run key generation again to fix a failed job.

## CI behavior

- Trusted pushes and manual builds fail before compilation if a signing Secret is missing,
  the keystore cannot be opened, or the public certificate differs from the configured pin.
- Gradle uses the explicit distribution signing configuration for the existing `.dev` build.
  A release build no longer silently uses a debug signing configuration.
- After building, official `apksigner verify` must succeed and its actual certificate SHA-256
  must match the pin before the APK and manifest are published.
- Each run restores the same encrypted key into the runner's temporary directory and removes
  it in an `always()` cleanup step. Only public certificate metadata is logged.
- Pull requests and Dependabot validate with an ephemeral debug key and never receive the
  signing Secrets. Their artifacts are validation outputs, not an upgrade distribution channel.

## Existing installations

Android requires the same package and signing identity plus a higher version code to update
in place. The new fixed identity supports that continuity for subsequent builds. It cannot
replace an installation signed by a lost temporary private key. The original temporary keys
were not retained, so seamless migration of those installations is unavailable. Do not
disable signature validation or uninstall an app holding local data merely to bypass this.
The new signing channel requires a separate, explicit installation/migration decision.

Reference: [Android app signing](https://developer.android.com/studio/publish/app-signing).
