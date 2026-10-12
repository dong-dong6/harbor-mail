# Java server v0.1

Java 21 + Spring Boot 4.0.8, JDBC, Flyway. One owner, one server replica. See the root README for full build/run and the client. Standard Maven: `mvn test package`.

## Run

`java -jar target/mail-server-0.1.0.jar --spring.profiles.active=demo`

Explicit **synthetic local demo**: 127.0.0.1:8080, username `demo`, password `demo-local-only`, durable H2 at `./data/demo`. All five displayed accounts are invented. No provider network calls are made by demo mode. Demo refuses a non-loopback bind and disables real account/OAuth creation. Never expose demo through a public proxy or reuse its credentials/key.

Production: PostgreSQL is the default datastore. Set `DATABASE_URL` (JDBC URL), `DATABASE_USER`, `DATABASE_PASSWORD`, `MAIL_ADMIN_USERNAME`, a unique `MAIL_ADMIN_PASSWORD` (16+ characters, at most 72 UTF-8 bytes), and `MAIL_ENCRYPTION_KEY` (base64 of exactly 32 cryptographically random bytes). Missing credentials, weak passwords, bad keys, or the published demo key cause startup failure. The administrator password is bootstrapped once and bcrypt-hashed; changing the environment does not overwrite an existing owner's password. Back up the encryption key separately from the database. Losing it prevents credential recovery.

`BIND_ADDRESS` defaults to loopback. Use an HTTPS reverse proxy for production. `MAIL_ALLOWED_ORIGIN` is one exact optional separate frontend origin; same-origin packaged Web needs no CORS changes. No browser cookies or localStorage bearer tokens are used. Authentication tokens expire after eight hours; logout revokes the current token. Tokens are stored only as SHA-256 hashes. Local/remote content downloads require authentication and are forced as octet-stream attachments.

OAuth variables for each of GMAIL, OUTLOOK, EXCHANGE:

- `MAIL_OAUTH_<PROVIDER>_CLIENT_ID`
- `MAIL_OAUTH_<PROVIDER>_CLIENT_SECRET`
- `MAIL_OAUTH_<PROVIDER>_REDIRECT_URI`, HTTPS `/api/v1/oauth/<PROVIDER>/callback`
- Optional `MAIL_OAUTH_<PROVIDER>_TENANT` for Microsoft

Uses single-use, ten-minute state, PKCE, server-side token exchange, verified identity email, encrypted tokens and serialized refresh. Provider app registration, consent policies and real-account verification are operator tasks. QQ/163 use fixed TLS IMAP/SMTP hosts and app authorization codes. The client never receives provider credentials.

## Reliability and scope

- All drafts, jobs and frozen send snapshots are durable. Draft edits use revisions; Idempotency-Key reuse with a different request returns 409. Client timeouts can safely retry the same operation/key.
- The single worker commits SUBMITTING before provider submission. A crash during SUBMITTING or an ambiguous provider result becomes UNKNOWN. It is never automatically resent. ACCEPTED means provider submission accepted, not recipient delivery. Demo alone creates a synthetic Sent copy.
- Message mutations are queued; a revision conflict or unsupported remote capability fails explicitly. IMAP MOVE requires MOVE + UIDPLUS and returns a new locator. No EXPUNGE, permanent remote delete or cross-account move endpoint exists. RESTORE targets Inbox.
- Successful connected accounts are polled every 120 seconds (`MAIL_POLL_INTERVAL_MS`); errors pause automatic polling until manual retry. Each sync fetches at most 100 recent messages in each supported canonical folder. This is a **partial read model**, not a complete backup. Provider pagination/backfill, delta streams, remote tombstone reconciliation and push are unfinished. Moves/deletes made in other clients can leave stale cached entries. Never infer that absence from a bounded page means remote deletion.
- The change feed has a persistent generation and commit-ordered sequence under a DB lock. A foreign generation or cursor ahead of the server returns 410. Restoring a backup should also rotate its generation. Full cross-device offline replay and compaction are not implemented.
- Provider HTML is returned only as bounded, untrusted bodyHtml in the authenticated JSON detail API. The Web reader sanitizes it and uses an opaque-origin sandbox with remote images blocked by default; bodyText remains available as a fallback. Uploads: 10 files / 10 MiB total raw attachment bytes per draft, plus adapter MIME limits. Remote downloads: 10 MiB maximum. MIME recursion/parts/body limits are enforced by adapters. Message body cache and attachments live in PostgreSQL/H2; only provider secrets are application-encrypted. Protect database/backups/disk accordingly.
- Search is a local, bounded-scope subject/sender/snippet search, not provider full-text search. No 100k-message performance claim has been validated. Reply/forward currently compose ordinary messages; RFC threading headers and provider-native threaded reply are not implemented. Sent-copy reconciliation for real SMTP/API submissions is not yet implemented.
- This version is single-instance only. Do not run multiple app replicas against one database. OAuth refresh/worker recovery rely on that deployment boundary.

## Verification

Tests exercise actual localhost HTTP for authentication, demo mail, optimistic revisions, concurrent idempotency, attachments, frozen sends and crash recovery. Provider tests run deterministic localhost HTTP/IMAP/SMTP fixtures, not real accounts. To run the same HTTP tests against an isolated PostgreSQL database:

`TEST_DATABASE_URL=jdbc:postgresql://127.0.0.1:5432/mail_test TEST_DATABASE_USER=... TEST_DATABASE_PASSWORD=... mvn -Dtest=MailApiTest test`

The test suite deletes its synthetic data. **Never point TEST_DATABASE_URL at a live mailbox database.** Production provider acceptance, Docker runtime and native client release builds remain separate acceptance gates.

## Phase A device pairing (development)

A signed-in memory-only owner browser session can create a two-minute, one-time QR code. A native app claims it
with its own S256 verifier, then both screens display a six-digit confirmation code. The browser
owner must compare the codes and re-enter the current owner password. Approval grants the existing
single-owner scope: full mail and settings access. A claimed device cannot create another pairing.
By default the independent device bearer lasts at most eight hours and has no refresh token. Clients keep
it in memory only. Explicit remembered-device approval instead uses the durable protocol below. Client local unlocking and server WebAuthn are separate features documented below.

Set `MAIL_ALLOWED_ORIGIN` to the exact reachable server origin, for example
`https://mail.example.com` or `https://mail.example.com:8443`, without a trailing slash or path.
Pairing appends `/api/v1`; it never trusts Host, Forwarded headers or a QR destination supplied in a
request. HTTPS is mandatory outside explicit demo mode. Demo permits only configured loopback HTTP
origins, which cannot be used by a separate physical phone to reach this machine. Invalid/missing
pairing-origin configuration disables pairing with `PAIRING_UNAVAILABLE` without breaking login.

Only the creating owner browser session can inspect, approve or reject its pairing. Browser logout or
expiry invalidates pending pairings; already redeemed device sessions remain independent. The
owner's device list supports immediate, idempotent revocation of all tokens for one device. Device
logout revokes that device's session. Approval-password failures return 403
`REAUTHENTICATION_FAILED`; 401 still denotes a missing/invalid bearer on protected endpoints.

Public pairing endpoints are only exact POST `/auth/device-pairings/claim`, `/poll`, and `/redeem`
under `/api/v1`. Proof is required for every poll and redemption. App polling must be at least two
seconds apart. Limits: 4 KiB JSON auth bodies; 120 public pairing requests per observed IP/minute;
600 global/minute; five pending pairings per creator; 1,000 retained pairing rows; 100 active devices
and 1,000 retained device rows. Old pairing records are pruned ten minutes after expiry and device
records 24 hours after expiry during pairing creation. Password approval shares login's throttling.
These conservative limits assume the existing single-replica deployment. No real device enrollment
is performed by tests; `DevicePairingApiTest` runs synthetic localhost fixtures on H2 or an explicitly
supplied disposable PostgreSQL database.

## Passkeys (development, synthetic acceptance only)

Standard WebAuthn endpoints are implemented under `/api/v1/auth/passkeys`. The server verifies
registration and assertions with Yubico `webauthn-server-core` 2.10.1, including the 2026 credential
ownership security fix. Existing owner browser bearer plus current password is required to add or
remove a passkey. Discoverable credentials and user verification are required; successful assertions
issue an eight-hour owner session by default, or a remembered device family when the options
request explicitly opted in. Password recovery remains available.

Use the exact stable HTTPS `MAIL_ALLOWED_ORIGIN`; its hostname is the RP ID. Ports and subdomains are
not interchangeable. Explicit demo mode supports `http://localhost:<port>` for disposable virtual
authenticator testing; IP-address RP IDs are disabled. The optional `mail.passkeys.android-origins`
property defaults empty and accepts only explicitly approved `android:apk-key-hash:` SHA-256 origins.
Nothing automatically configures trusted Android certificates or publishes website asset links.
See [Passkey contract](../docs/PASSKEY_CONTRACT.md) for configuration, security bounds and error codes.

`PasskeyApiTest` uses temporary P-256 keys to exercise actual ES256 WebAuthn verification and failure
cases over localhost HTTP, on H2 and disposable PostgreSQL. It never enrolls real authenticators.
Removing a passkey prevents future sign-in but does not revoke existing sessions. No private passkey
export or automatic real-device enrollment is provided.

## Opt-in remembered device sessions (development)

V8 adds durable session families without changing the legacy access-token table shape or upgrading
existing tokens. Password login may explicitly send `rememberDevice: true` and optional `deviceName`.
Pairing becomes durable only when its browser owner approves with `rememberDevice: true`; the QR,
claimant and redemption request cannot choose this. Omission/false preserves eight-hour memory-only
login and pairing. Passkey authentication options also accept `rememberDevice: true` and optional
`deviceName`. The server binds this choice to the single-use assertion request; verification accepts
only `requestId` and `credential` and cannot add/change the choice. Only a successfully verified
assertion issues a remembered family; canceled, failed or expired ceremonies issue none. Remembered
password and passkey logins are device sessions, so they cannot create pairings or manage passkeys;
use a fresh memory-only browser login for that.

Defaults and bounded configuration:

| Variable | Default | Valid range |
| --- | --- | --- |
| `MAIL_DEVICE_ACCESS_SECONDS` | 900 (15 minutes) | 60–3600 seconds |
| `MAIL_DEVICE_IDLE_DAYS` | 30 | 1–90 days, no more than absolute |
| `MAIL_DEVICE_ABSOLUTE_DAYS` | 365 | 1–730 days |

Access is additionally bounded by the current idle and absolute expiry. Only a successful new
rotation advances idle expiry. Retried rotations, API use and background polling do not keep a
session alive. Absolute expiry is fixed at issuance. Both expiries and revocation are checked on
every authenticated request. All family access tokens are invalidated immediately on logout,
owner device revocation or refresh-token reuse.

### Client-prepared refresh protocol

The native client must serialize refresh across all callers/processes and persist a pending record
containing the old refresh secret, a fresh CSPRNG successor secret and a UUIDv4 request ID *before*
sending any bytes. Each secret is exactly 32 bytes encoded as canonical unpadded base64url. Post JSON
only to `/api/v1/auth/refresh`:

```json
{"refreshToken":"<old>","nextRefreshToken":"<next>","requestId":"<lowercase UUIDv4>"}
```

Success returns `accessToken`, `expiresAt`, `refreshToken` (the submitted successor),
`refreshExpiresAt` (idle limit), `sessionExpiresAt` (absolute limit), `deviceId`, `accountName`, and
`permission`. Durable password login also returns `demoMode`. Confirm the echoed successor matches
and atomically replace the pending record with the new session before using the new access token.
After timeout, process death, connection loss or uncertain server commit, retry **the exact saved
old/next/request-ID tuple**. Never invent a new tuple using the old secret.

The server transaction locks the family and stores only SHA-256 secret hashes. An exact retry while
the successor remains current returns fresh short-lived access and does not advance idle expiry or
invalidate previously issued access. An exact older transition after a later successful rotation
returns `409 STALE_ROTATION` without issuing credentials or revoking the family. A consumed old
secret with different successor/request ID commits full family revocation and returns
`401 REFRESH_REUSED`. Unknown proofs return `401 INVALID_REFRESH` and cannot revoke any family.
Other terminal refresh errors are `SESSION_EXPIRED` and `SESSION_REVOKED`. `409 INVALID_ROTATION`
rejects a successor previously seen in any family or a duplicate request ID without mutation.

The authentication filter returns `401 ACCESS_EXPIRED` only when an expired device bearer belongs
to a still-live family; this rejection occurs before endpoint execution. A client may refresh once
and retry such a request. Do not replay a mail-send or other mutation after timeout, ambiguous
network failure, generic handler 401, or an arbitrary HTTP failure. Expired durable access proofs
are retained up to 24 hours for this classification; older missing proofs return `UNAUTHORIZED`.
Clients should proactively refresh based on saved expiry when resuming after a longer absence.

`POST /api/v1/auth/device-session/logout` accepts only `{"refreshToken":"<current or historical>"}`.
It works with expired access, revokes all family access and is idempotent (204). Unknown proofs also
return 204. The existing bearer logout and device-list revoke routes revoke the entire associated
family. Offline local logout cannot guarantee server revocation; clients must say so rather than
claiming the device has been revoked.

Refresh/logout accept exact POST routes and JSON content types, reject query parameters and unknown
body fields, cap JSON bodies at 4 KiB, never redirect secrets and return no-store responses. Refresh
and proof logout share bounded observed-IP (120/minute) and global (600/minute) limits. Additionally,
each family permits at most 10 new rotations/minute and 30/hour (persisted sliding windows), and
10 exact retries/minute (persisted counter). The family caps are independent of IP and survive
server restarts; 429 includes `Retry-After` and `error.retryAfterSeconds`. Keep the saved tuple and
retry after that delay. Historical replay detection and logout are not blocked by family quotas. Never enable
proxy/APM request-body logging for any authentication endpoint. Application error logs include only
the request ID and exception class, never submitted bodies or token values. TLS is required at the
production reverse proxy; none of this configures real device grants or production settings.

Retained transition records are needed to distinguish replay from delayed legitimate requests and
allow historical-proof logout. They are indexed by hash and family; retain them until their family
is removed 24 hours after its effective expiry by subsequent pairing/session creation. At the
normal 15-minute cadence one continuously used year-long family has about 35,040 transition records.
The public rate limits also apply to exact retries (each can mint another overlapping access token).
There is no small lifetime rotation-count limit that unexpectedly logs a daily-use device out.
Operators should size and monitor database storage and authentication traffic, particularly for
compromised clients rotating much faster than their access-token lifetime. Expiry indexes support
cleanup; no independent background refresh heartbeat is implemented.

`DeviceSessionApiTest` runs synthetic H2 and disposable PostgreSQL HTTP fixtures, injectable-clock
expiry tests, same-tuple/conflicting concurrent refresh races, refresh-vs-revoke/logout races,
commit/rollback recovery and delayed historical duplicates. Real Android KeyStore/process-death,
biometric/device-policy, TLS/reverse-proxy and production release acceptance remain separate gates.
