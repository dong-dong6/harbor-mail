# Durable Android device sessions (implementation in progress)

Baseline: verified v0.3.1 source, remote commit 33ee2c3fe113cb8fb2f362eda4efa2b75363e1a4.
No publication, production policy changes, or real credential enrollment is authorized by this development task.

## User-visible behavior

An explicit remembered-device password or passkey login, or owner-approved QR pairing creates an independently revocable device session. Default access lifetime is 15 minutes; refresh family expires after 30 days without a successful new rotation, or 365 days from initial authorization. These are server-enforced bounded configuration values, shown in returned metadata/UI. Normal foreground use renews access without login. Background keepalive must not indefinitely preserve idle devices. Existing eight-hour sessions are never silently upgraded.

Remember-device consent and optional biometric protection are separate. The latter defaults off, becomes enabled only after successful actual OS cryptographic authentication, and must not prompt on each refresh. The existing legacy saved-access feature remains compatible but does not acquire longer permission. Native passkey trust/signing is a separate unresolved configuration task.

Passkey authentication options bind remember-device consent and the device label in stored challenge state. Verification cannot upgrade or alter that choice and creates a family only after successful library-verified assertion. Password recovery and real native trust prerequisites remain unchanged.

## Hash-only rotation protocol

POST /api/v1/auth/refresh accepts canonical CSPRNG 32-byte base64url refreshToken, nextRefreshToken and UUIDv4 requestId. Before sending, Android atomically persists an encrypted pending tuple; all callers in the current single-process app share one rotation. The native bridge also excludes a second active engine owner. Adding a separate Android process would require an inter-process lock and explicit recovery tests before it may access this vault. The server transaction locks the family, validates status/idle/absolute deadlines, consumes the current hash, records the transition fingerprint, installs the successor hash, and issues a short-lived opaque access token. Both token kinds are hashed at rest on the server. New access validity is bounded by the family's deadlines.

An exact retry whose successor is still current may obtain another access token without extending the idle deadline. An exact historical retry after the successor has itself been consumed returns STALE_ROTATION, without issuing tokens or revoking the family. A verified consumed token presented with a different transition revokes the family and every associated access token. Unknown tokens cannot select a family to revoke. Consumed hashes and transition fingerprints remain available through family validity. Fresh successors cannot reuse a previous accepted token.

This idempotent transition extension is an explicit design choice beyond the simple RFC rotation example. It avoids storing recoverable plaintext refresh tokens on the server and avoids signing out a legitimate app solely because a rotation response was lost. Retry rate limits and bounded state retention are required.

Every access lookup checks family validity, so revocation is immediate for subsequent authenticated requests. Logout accepts refresh proof even if access expired; owner device revocation uses the same family revocation path. Already executing actions cannot be retroactively undone. Offline logout removes local access/storage and reports remote revocation as unconfirmed.

## Android envelope and lifecycle

A new vault stores refresh state and pending rotation only, never passwords or access tokens, in an atomic no-backup file. A random data-encryption key is wrapped by Android Keystore, with origin/account/family-bound authenticated encryption. Default remembered mode does not require biometrics. Optional protected mode uses actual BiometricPrompt CryptoObject authorization to unwrap the data key once for an active foreground session; it removes the unprotected wrapper. Cached plaintext is cleared on lock/background/teardown. Refresh operations within an unlocked foreground use new AES-GCM IVs without another prompt.

Locking/backgrounding preserves the encrypted pending tuple because an already sent request may still commit remotely. Late callbacks cannot reopen a locked session or commit an older generation. The next permitted foreground unlock retries the identical durable tuple. Key invalidation, corrupt storage, failed deletion, and failed durable writes fail visibly; there is no plaintext or silent security downgrade fallback.

## Verification gates

- H2 and PostgreSQL: first issuance, consent, original-session compatibility, precise idle/absolute boundary, expired access refresh, rotation and full-family revocation.
- Concurrent identical and conflicting refresh requests; revocation versus refresh; transaction rollback; unknown-token denial without family revocation.
- Lost responses and crashes before/after each durable write and server commit; old exact duplicate after two rotations; failed client commit; no late callback rollback.
- Client singleflight, foreground-only demand, optional biometric cancellation/enable/disable, server/account changes, logout during refresh, offline retention, no unsafe mutating-request replay.
- Native Keystore cryptographic authorization, backup exclusions, key invalidation and real Android lifecycle behavior. Mock/unit/API compilation must be distinguished from physical-device tests.
- Existing full Flutter, Java/H2/PostgreSQL, Web/browser, APK/Windows and updater security regression gates after integration. CI/publication requires separate coordination.

## References

- RFC 9700 refresh protection: https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14
- Android Keystore: https://developer.android.com/privacy-and-security/keystore
- Android biometric cryptography: https://developer.android.com/identity/sign-in/biometric-auth
