# v0.3.1 Android and responsive-login fixes

Development source based on c074f282e48e124cf0155ce81bf6d70091113afd. No production trust, fixed signing key, real passkey enrollment, mailbox access or device grant was created during development.

## Implemented boundaries

- Device security settings are explicit and OFF by default. Merely opening settings never invokes OS authentication. First local-lock setup commits ON only after successful verification; cancellation preserves the prior OFF state. Existing enabled-session unlock failures remain locked.
- Android 11+ secure-save stores the existing bearer, canonical origin, owner name and original absolute expiry using auth-per-operation AndroidKeyStore AES-GCM. Metadata is authenticated as AAD. No password, refresh credential or expiry renewal. The encrypted record lives outside Android backup/device transfer. OS authentication uses the exact CryptoObject; background restoration cannot reveal the mailbox.
- Cold start only discovers non-secret metadata. The user explicitly restores; server validation at the bound origin precedes authenticated UI. Cancellation/offline do not authenticate; expiry/401/logout clear storage. Failed clear remains visible and cannot claim success. Generations discard stale restoration. Local unlock and vault prompts are mutually exclusive.
- Manufacturer/model are editable suggestions, never trusted identity or unique identifiers.
- Native HTML is sanitized to a limited formatting allowlist and rendered by Flutter widgets, not a WebView. Scripts/forms/frames/external styles/fonts are removed. Every generic image factory is disabled; only explicitly requested, mail-bound proxy PNG data becomes in-memory image widgets. Input/tree/depth/compressed-byte/pixel budgets bound resource use. Links are restricted and require destination confirmation. Complex unsupported HTML can use plain text.
- Desktop login has separate 410px login/download panes within a 980px layout; mobile stacks them and folds installation detail while retaining test-signature warnings.
- In-app updates preserve origin, size/hash/package/version and installed signing identity checks. Installation always hands off to Android's installer. Failed/canceled result delivery cleans its unclaimed APK.

## Verification status

Local aggregate Flutter tests: 437 passed; Flutter analyze: no issues. H2 server tests: 379 passed. Java policy checks: 82 updater + 44 session vault passed. Actual Android API/source compilation: all five Java sources and MainActivity Kotlin passed. Web release build passed. Python packaging tests: 9 Android + 1 Web passed. Existing Node unit checks plus 72 browser-harness guards passed. The new desktop/mobile compiled-Web geometry checks and real Chromium screenshots are pending CI, as are full APK, Windows and PostgreSQL validation. No emulator or physical-device biometric/PIN, camera, cold restart, key invalidation or installer acceptance has run here. Source/API compilation is not an APK or hardware test.

Development APK signing remains ephemeral. A new CI APK may not share the installed v0.3.0 certificate; in-place update is correctly refused in that case. Stable signing and Android Passkey domain association require separate configuration and approval. Existing records cannot recover a previously lost memory-only token; after installing this fix, the user must log in/pair once and explicitly enable saving.

## First CI visual diagnostic and correction

The first c283 CI run compiled the real Android APK and Windows release and passed protocol, Web navigation, 435 Flutter tests and H2. The new desktop-login visual gate correctly stopped publication on a geometry discrepancy. Its diagnostic showed a 410px Flutter form and 410px APK pane, but the transparent browser input proxy measured 418px because native padding/borders surround its content width. The harness now measures the actual Flutter semantic render frame, keeps the raw input/box-model evidence, and retains the 410px bound. APK heading/warning semantics are separate so visibility checks measure the actual text, not the whole card. The final 437-test aggregate passed locally; a new exact-commit CI must rerun every release gate.
