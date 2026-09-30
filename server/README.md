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
- HTML is converted to plain text; raw provider HTML is never returned. Uploads: 10 files / 10 MiB total raw attachment bytes per draft, plus adapter MIME limits. Remote downloads: 10 MiB maximum. MIME recursion/parts/body limits are enforced by adapters. Message body cache and attachments live in PostgreSQL/H2; only provider secrets are application-encrypted. Protect database/backups/disk accordingly.
- Search is a local, bounded-scope subject/sender/snippet search, not provider full-text search. No 100k-message performance claim has been validated. Reply/forward currently compose ordinary messages; RFC threading headers and provider-native threaded reply are not implemented. Sent-copy reconciliation for real SMTP/API submissions is not yet implemented.
- This version is single-instance only. Do not run multiple app replicas against one database. OAuth refresh/worker recovery rely on that deployment boundary.

## Verification

Tests exercise actual localhost HTTP for authentication, demo mail, optimistic revisions, concurrent idempotency, attachments, frozen sends and crash recovery. Provider tests run deterministic localhost HTTP/IMAP/SMTP fixtures, not real accounts. To run the same HTTP tests against an isolated PostgreSQL database:

`TEST_DATABASE_URL=jdbc:postgresql://127.0.0.1:5432/mail_test TEST_DATABASE_USER=... TEST_DATABASE_PASSWORD=... mvn -Dtest=MailApiTest test`

The test suite deletes its synthetic data. **Never point TEST_DATABASE_URL at a live mailbox database.** Production provider acceptance, Docker runtime and native client release builds remain separate acceptance gates.
