# v0.3.2 Android remembered device sessions

Status: final local Flutter analysis and all 529 tests passed; current-source Web release built. Server full H2 and PostgreSQL each passed 395 tests. Exact-commit CI/native packages and physical-device verification are not implied. No production rollout or real device enrollment occurred.

## Changes

- Password, Passkey, and owner-approved QR login support explicit remembered-device consent. Passkey intent is fixed in the challenge, not upgraded by verification; QR intent is fixed by the approving owner.
- Short access tokens rotate through a server-hashed refresh family. Defaults: access 15 minutes, idle 30 days, absolute 365 days. Existing temporary sessions keep their original lifetime.
- Android stores only encrypted refresh state and an exact pending rotation journal. Process death or a lost response retries the same transition. Reuse with a different transition revokes the family. A genuine delayed duplicate is rejected without revoking a healthy successor.
- Biometric/PIN protection is separate and initially off. Actual OS cryptographic authorization enables it. One unlocked foreground interval can refresh without repeated prompts; background requests are blocked.
- Logout and owner revocation invalidate the device family. Local removal and remote revocation are attempted independently, with honest warnings when either is unconfirmed. An old callback cannot delete or revoke a replacement family.
- Passive mailbox/outbox polling does not refresh expired access or extend an unattended grant. Returning to the foreground or an explicit action renews access without a new login.
- Device names default to manufacturer/model and remain editable. No unique device identifiers are collected.
- All pre-existing mail rendering, update-signature verification and stale-compose/session protections remain required regressions.

## Verification evidence

These are local/source-stage results, not release or hardware approval:

- Server: full H2 395 and PostgreSQL 17.11 395, zero failures/errors/skips. Includes 13 device-session and 31 Passkey cases.
- Final aggregate Flutter: 529 tests passed and analysis has no issues. Current-source Web release build passed.
- Current Web + Java JAR rebuilt with `mvn clean verify`: 395 H2 tests passed again. Loopback-only synthetic demo 10 checks and integrated static asset HTTP/header/cache checks across 8 paths passed; the temporary demo was stopped. Local JAR is 89,681,392 bytes, SHA-256 `afbd403b9e8f251e4ac6e10cf8a3cc2eff0c2c8564e918d0ec54af3e77551ae2`; it contains no APK and is not the selected release artifact.
- Refresh coordinator/API/Passkey: 96 focused Dart tests, included in the aggregate.
- Native vault: 21 new Dart contract tests, 58 Java policy assertions; old vault 44 and updater 82 Java assertions also pass.
- Real Android/AndroidX/Flutter API compilation: all Java sources and MainActivity Kotlin passed. This does not build an APK or exercise the Android OS.
- Python: 9 APK manifest and 1 Web asset test passed.
- Node: 9 OAuth bridge tests, 72 Passkey-harness guards, 12 sanitizer groups, 2 history groups and 1 selector group passed.
- Final picker/privacy batch: 64 focused tests passed, including 21 durable UI cases; all are included in the final aggregate. Tests cover same-family picker resumption, zero HTTP while paused, wrong-family/server-switch rejection, protected-mode cancellation, platform Back, and preserved modal/inline drafts. Independent static review found no remaining blocking issue.
- Browser execution: local Chromium could not start because sandbox socket creation was denied, before any assertions. Renderer/routes/live browser protocols require a permitted environment or exact-commit CI. No browser success is claimed.

## Final validation still required

Full APK and Windows builds and actual Chromium flows require their real toolchains/CI. Cloud Chromium cannot start in this sandbox. Real Android PIN/fingerprint/cold restart/filesystem fault behavior requires device QA. The local native compile covers seven application Java sources and one Kotlin activity, not generated plugin registration, Gradle packaging or hardware execution.

No permanent signing key or Android assetlinks/native Passkey trust has been generated or configured. Existing ephemeral development signing cannot promise cross-CI in-place upgrades. No real user passwords, refresh grants or Passkeys were created or stored by this development work. Synthetic test credentials are isolated fixtures only.
