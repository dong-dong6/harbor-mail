# Combined mailbox fixes v0.2.2: pre-publication verification report

Base: deployed v0.2.1 source at `0ffea0a83de28086745c25e0c0d6193174459d2e`.

## Changes

1. Preserve separate HTML/plain email bodies for Gmail, Microsoft Graph and IMAP, refresh legacy body caches once, preserve caches during metadata sync, and render a conservative HTML subset inside a script-free opaque-origin Web iframe.
2. OAuth completion returns to the originating mailbox tab, refreshing accounts after a correlated success event; fixed same-origin fallback completion page supports absent/closed origin tabs.
3. Approved mailbox layout: persistent left account list, mobile horizontal account choices, compact rows and clearer account/name hierarchy. Uses connected account data, no hard-coded example mailboxes.

## Verified

- Java 21 / Maven full clean verify: 119 tests, zero failures, errors or skips. Synthetic H2, mocked provider APIs and local protocols only.
- Combined Dart static analysis: no issues.
- Combined Flutter widget suite: 51 tests passed, including four-size account navigation renders and narrow reader/compose regressions.
- OAuth browser protocol unit harness: 9 tests passed.
- HTML sanitizer DOM unit harness: 11 checks passed (active content/unsafe URL/CSS removal, presentation allowlist, blocked images, explicit opt-in and reset).
- Web release build with local Web resources: passed. Final Web assets were packaged into the integrated JAR; the served mail renderer was byte-compared with its source.
- Integrated synthetic demo smoke: 10 checks passed (auth, version agreement, message detail/pagination, durable mutations/drafts, synthetic send idempotency, change feed and token revocation). The release JAR checksum is recorded in BUILD_INFO.json.
- Actual Flutter widget renders inspected at 1440×960, 800×600, 390×844 and 320×720; no clipping/overflow errors found. These are synthetic widget renders, not live browser screenshots.

## Chromium CI follow-up

The first browser run identified a test synchronization race on popup closure, fixed by awaiting its actual close event. The next run passed all nine OAuth browser cases and caught Chromium CSSOM expanding border shorthands. The renderer now reads safe properties by name and permits explicit border/radius longhands; regression checks retain presentation assertions. Final exact-commit CI is required after this repair.

## Remaining acceptance limits

- CI now runs the committed Node unit tests and synthetic Chromium harnesses with locked development-only dependencies. Their eventual CI result supersedes the local browser limitation below.
- Real Chromium rendering, iframe navigation/opaque-origin behavior, image request interception and OAuth popup behavior have browser harnesses but were not executed successfully in this cloud environment: Chromium launch requires unavailable Unix sockets. The attempted alternate local preview transfer did not yield browser acceptance either. Do not count DOM unit tests or widget renders as real-browser verification.
- No real-mailbox credentials, OAuth provider authorization, remote images or email sending were used.
- PostgreSQL, native platform builds and signed-device acceptance were not run for this patch.
- Safe HTML is a subset: inline styles/tables/links are supported; stylesheet blocks/media queries, remote fonts, CSS background images and CID/data images remain unsupported. Remote images default blocked and require per-message opt-in. Native clients retain plain-text reading.

## Toolchain safety

An earlier layout-worker Flutter invocation without CI flags was rejected because Flutter's automatic Azure bot detection attempted its metadata endpoint. That invocation was not retried. Subsequent checks explicitly used the SDK-supported `CI=true` and `BOT=true`, which short-circuit the detector before any metadata request, with analytics disabled and local dependencies. No metadata endpoint access was authorized or used.

## Publication

This is the pre-publication validation snapshot. The owner subsequently authorized commit/push/deployment; exact-commit CI is authoritative for the published artifact and server deployment is coordinated separately. No production-server action was performed by this implementation task.
