# Phase A device pairing contract (development, not deployed)

Baseline: remote main `5a1d5328114783fc13d6ef4664c3efb9726bd327`, all 276 tracked blobs verified. Phase A does not add persistent login, refresh tokens, biometrics, or passkeys. Device access lasts at most eight hours and stays in client memory. This is the existing single-owner authorization model: full mail and settings access.

All endpoints below are under `/api/v1`. Public endpoints are exact POST routes only. Secrets are JSON bodies, never query strings or route fragments. No mail-provider credentials cross devices.

## Web owner endpoints (existing bearer authentication)

- POST `/auth/device-pairings` body `{}` returns `{pairingId, qrPayload, expiresAt, state: "CREATED"}`. `qrPayload` is a JSON string `{type:"harbor-mail-device-pairing",version:1,serverUrl:"https://host/api/v1",pairingId,secret}`. Server URL is derived from configured trusted allowed-origin, not Host/X-Forwarded-* headers or request input. Production requires HTTPS. Demo may use explicit loopback HTTP only. Lifetime 120 seconds.
- GET `/auth/device-pairings/{id}` returns `{pairingId,state,expiresAt,deviceName?,confirmationCode?,accountName,permission:"OWNER_FULL_ACCESS"}`. Only its creating bearer session may view/act. QR secret must not be returned here.
- POST `/auth/device-pairings/{id}/approve` body `{password,confirmationCode}`. Verify current owner's password with login-equivalent throttling, exact creator session, unexpired CLAIMED transaction and matching confirmation code. Return state APPROVED.
- POST `/auth/device-pairings/{id}/reject` body `{}`. Cancels pending transaction; never revokes a completed device implicitly.
- GET `/auth/devices` returns `{items:[{id,name,createdAt,expiresAt,lastSeenAt,revoked,permission:"OWNER_FULL_ACCESS"}]}`.
- DELETE `/auth/devices/{id}` revokes that device and all its access tokens; returns 204. Revocation is idempotent.

## New app endpoints (no existing bearer; never inherit one)

- POST `/auth/device-pairings/claim` body `{pairingId,secret,deviceName,codeChallenge}` returns `{pairingId,state:"CLAIMED",confirmationCode,expiresAt,accountName,permission:"OWNER_FULL_ACCESS"}`. App creates 32 random bytes, base64url without padding as codeVerifier (43 characters); codeChallenge is base64url-no-padding SHA256 of ASCII verifier (43 characters). Claim atomically consumes QR secret and binds the challenge. App and webpage show the same server-generated six-digit confirmation code. First claim wins; never replace claimant.
- POST `/auth/device-pairings/poll` body `{pairingId,codeVerifier}` returns same public app state fields. Proof is required even for polling. Poll interval >=2 seconds.
- POST `/auth/device-pairings/redeem` body `{pairingId,codeVerifier}` returns `{accessToken,expiresAt,deviceId,accountName,permission:"OWNER_FULL_ACCESS"}` after APPROVED. Atomic one-time redemption; codeVerifier never appeared in QR. Token is independent of browser token. No automatic retry after uncertain redemption.

States: CREATED -> CLAIMED -> APPROVED -> REDEEMED; terminal alternatives REJECTED, EXPIRED. Check expiry and creator-session validity in transitions, including redemption. Creator logout/expiry invalidates unredeemed pairings. All server transitions serialized transactionally, bounded lengths, resource bounds and public-endpoint throttling. Store secret hash/challenge only; do not log secrets or tokens. Response Cache-Control no-store. Synthetic tests only.

Client validates QR schema, max length, exact type/version, HTTPS normalized authority plus `/api/v1`, no userinfo/query/fragment/custom port ambiguity; supports valid explicit HTTPS ports and private deployments without bypassing TLS checks. Loopback HTTP available only via explicit demo/test option, not arbitrary QR. Reject server redirects and never send an existing bearer to a newly scanned server. Show destination before claim, owner permission warning and code while waiting. Do not trust QR-provided account identity. Discard stale asynchronous results on close, rescan, server change, logout and unmount. Cancelled pairing cannot silently log in later.

Android camera scanning and QR rendering use maintained registry packages; native signing is not configured here. Runtime server profile is non-secret connection data. Tokens remain memory-only in Phase A; do not promise restart persistence. Actual device enrollment and passkey creation require user approval; development tests use isolated synthetic credentials.
