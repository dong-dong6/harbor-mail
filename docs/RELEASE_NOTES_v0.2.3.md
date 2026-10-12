# Harbor Mail v0.2.3

## Changes

- Full-page connected-account settings, local name editing and explicitly confirmed local disconnect. Adding a mailbox and administrator OAuth configuration use separate pages.
- Complete message envelope above the body, fresh scroll position on open, and inline reply/forward with guarded unsaved or uncertain-send state.
- Authenticated, current-message-bound remote image proxy; images remain blocked until requested. The browser never falls back to the original image URL. DNS/address, redirect, TLS, time, byte, concurrency, raster and client rendering budgets are enforced.
- Shareable internal hash URLs, copied-link login restoration and guarded browser Back/Forward. Login tokens remain memory-only.
- Exact-manifest public gzip/ETag revalidation; API data and OAuth completion stay no-store. Complete CJK glyph coverage is retained.
- Canonical request-path enforcement closes an inherited authentication bypass caused by differing servlet/handler path interpretations.

## Migration and deployment

V5 creates a separate `attachment_owner` table while preserving all five original attachment columns. Populated V4→V5 migrations and an actual binary compiled from the previous bf3780f source were freshly tested on H2 and PostgreSQL: the older application starts, creates a draft, uploads with its original five-value INSERT, and retrieves matching bytes after V5. Unattributable historical attachment orphans are retained rather than guessed; another account's shared references protect their bytes.

Before deployment, stop writes and verify a restorable database backup and preserved runtime configuration. Restoring that backup discards writes after the snapshot; merely reverting a JAR does not restore deleted local drafts/accounts. Compatibility with the older binary does not make it a safe rollback target: it retains the known authentication-path weakness. Prefer a corrected forward fix, or an explicitly reviewed rollback with a safe authentication boundary.

The application remains single-instance. No database credentials, OAuth grants or server settings need to be changed for this release. Automated checks use synthetic data and isolated databases, never production mailbox operations. Production provider acceptance remains a separate stage.

## Validation

See `docs/BUILD_INFO.json` and the exact commit's GitHub Actions reports. Earlier unpublished test counts are not evidence for this reconstructed source. The release gate includes complete H2/PostgreSQL suites, Flutter analysis/widgets/Web build, real Chromium OAuth/renderer/navigation/header/inline-input checks, and packaged-JAR HTTP/static smoke tests.
