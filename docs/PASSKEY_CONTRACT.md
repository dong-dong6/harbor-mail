# Passkey phase: proposed implementation interface

This phase is in development. It does not enroll real credentials or change production trust. Use a maintained server WebAuthn library (Yubico java-webauthn-server, security-fixed stable version at least 2.8.2); never implement signature/attestation verification manually. Client uses the maintained `passkeys` Flutter plugin against this project's own server, not a hosted example service. No restore-key auto-enrollment.

All paths under `/api/v1`:

- GET `/auth/passkeys/capabilities` (public): `{available, rpId?, reason?}`. Return only public deployment capability, never number of credentials/account details. Secure configured origin enables Web; Android requires an explicitly configured trusted APK-key-hash origin and website assetlinks association.
- POST `/auth/passkeys/registration/options` (owner browser bearer + password reauthentication): `{password,name}` -> `{requestId, publicKey}` where `publicKey` is standard PublicKeyCredentialCreationOptions JSON, userVerification required, residentKey preferred/required as library support permits, attestation none, existing credentials excluded. Account is existing owner only.
- POST `/auth/passkeys/registration/verify` (same creator bearer): `{requestId,credential}` -> `{id,name,createdAt}`. Standard credential JSON with type/id/rawId/response/clientExtensionResults. Request-bound verification, canonical configured RP/origins only, single-use challenge.
- POST `/auth/passkeys/authentication/options` (public): `{}` -> `{requestId,publicKey}` standard PublicKeyCredentialRequestOptions JSON with required userVerification.
- POST `/auth/passkeys/authentication/verify` (public): `{requestId,credential}` -> `{accessToken,expiresAt,accountName,permission:"OWNER_FULL_ACCESS"}`. Eight-hour in-memory session; assertion must match stored owner credential and user handle. No client boolean or biometric success flag is trusted as authentication.
- GET `/auth/passkeys` (owner bearer): `{items:[{id,name,createdAt,lastUsedAt}]}`. Opaque application UUID `id`, not raw binary credential ID.
- POST `/auth/passkeys/{id}/delete` (owner browser bearer + password): `{password}` -> 204. Keep password recovery available. Explicit UI confirmation for removing credentials; deletion invalidates outstanding requests relying on the removed credential.

Challenges expire after 120s, bound to operation and registration session, consumed transactionally, bounded/rate-limited, never serialized into URLs. Limit stored credentials (e.g. 20) and pending requests. Authentication failure must not enumerate account details. Password reauth failure403 retains current browser session; missing/expired session401. Existing exact method/path allowlist must be extended narrowly.

Persist credential ID bytes/public key/user handle/signature counter/backup flags and display metadata. Treat synced passkey counter semantics via maintained library configuration rather than assuming every counter must increase. Always enforce user verification, RP ID, exact allowed origins, challenge, credential ownership, signature and expected operation.

RP ID derives only from a stable administrator-configured HTTPS origin or explicit compatible configured RP ID. For synthetic loopback demo only, localhost HTTP may be enabled. Android `android:apk-key-hash:` origins require explicit validated allowlist configuration; never trust an origin provided by the client. Publishing assetlinks or registering a real passkey is a separate user-approved operation.

Client `PasskeyAuthenticator` gets standard options, invokes the OS/browser on explicit user gesture, submits standard credential response, discards stale success on cancel/server change/logout/unmount, and never retries registration/verification automatically after uncertain outcome. OS/browser UI controls fingerprint/face/PIN/security key selection; do not promise biometric-only Windows.

Any non-secret native saved profile may contain only canonical server URL and account label; no tokens/passwords/QR secrets/verifiers. System keystores/credential providers own passkey private keys. Test only isolated virtual/synthetic authenticators.

## Server implementation and administrator configuration

The server uses `com.yubico:webauthn-server-core:2.10.1`, verified against Yubico's [release notes](https://developers.yubico.com/java-webauthn-server/Release_Notes.html) and [YSA-2026-02](https://www.yubico.com/support/security-advisories/ysa-2026-02/). This version includes the account/credential-ownership fix originally released in 2.8.2. All WebAuthn parsing, attestation and assertion verification is performed by that library. No production signing keys are generated here.

- RP ID is exactly the hostname of `mail.allowed-origin`. The origin must be canonical HTTPS with no path, userinfo, query or fragment. IP-literal RP IDs are disabled. HTTP `localhost` is accepted only with explicit demo mode. Scheme, hostname and port are compared exactly; no subdomain/port wildcard.
- Explicit Android trust is optional: `mail.passkeys.android-origins` is a comma-separated list of `android:apk-key-hash:<canonical unpadded base64url SHA-256 certificate hash>`. It defaults to empty. Only an administrator can configure it; no client-supplied origin or signing certificate is learned. Real deployment also requires an independently approved website `assetlinks.json` association. This implementation does not publish that association.
- Discoverable credentials are required (`residentKey=required`), with UV required on registration and authentication. The authenticator may use fingerprint, face, PIN or another supported verification method. Supported credential algorithms are ES256, EdDSA and RS256 available on the Java 21 runtime.
- Single-use requests are serialized under the database mutation lock and expire after 120 seconds. Verification consumes the request in a separate committed transaction before cryptographic checks, including failed checks. Registration additionally rechecks the exact current browser session when storing the credential. Deletion increments a revocation epoch as well as clearing queued requests, covering an already-consumed ceremony racing a deletion.
- Limits: 20 owner credentials; 5 pending registrations per browser session; 1,000 pending ceremonies globally; public capability/options/verify traffic limited to 60 requests/IP/minute and 300 globally/minute. Password reauthentication shares the login password-attempt budget. Passkey JSON bodies are bounded to 65,536 bytes.
- Persisted material is credential ID, COSE public key, random account user handle, counters, backup flags and display metadata. Private keys never leave the authenticator. Userless assertion responses must include the matching persisted user handle. The library computes counter validity; non-backup-eligible credentials enforce that result, while backup-eligible synced passkeys tolerate a nonincreasing counter. Backup eligibility is checked by the library, and counter storage never decreases.
- Removing a credential does not revoke an already-issued eight-hour session. The user can sign out that session; password recovery remains available. Management UI should explain this when confirming removal.
- Errors: unavailable deployment 503/PASSKEY_UNAVAILABLE; rejected registration 400/INVALID_PASSKEY; rejected authentication 401/INVALID_PASSKEY; wrong management password 403/REAUTHENTICATION_FAILED; device bearer management 403/BROWSER_SESSION_REQUIRED; rate/resource limits 429. Expired/missing existing bearer remains 401. Start a new ceremony after a verification error; never automatically retry an uncertain verification response.

Synthetic browser validation: launch a separate demo server with a fresh H2 database, `--mail.allowed-origin=http://localhost:<port>`, `--server.port=<port>`, and `--mail.worker-enabled=false`; browse to that exact localhost origin. Use only a virtual authenticator in an isolated browser profile. This does not authorize or perform a real credential enrollment.

## Native Windows origin limitation

The pinned passkeys_windows 0.1.5 bridge constructs the client-data origin as
`https://` plus RP ID. Therefore native Windows Passkey currently requires the
canonical HTTPS origin on the default port. A custom HTTPS port remains usable
for password/pairing and local Windows Hello unlocking, but native Passkey will
be rejected by exact server origin verification. Use the browser at the exact
configured origin for that case; do not broaden the server origin allowlist.
