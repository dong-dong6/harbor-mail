> Historical component snapshot. The final integrated verification results are in [COMBINED_FIX_TEST_REPORT.md](COMBINED_FIX_TEST_REPORT.md); its successful Flutter tests and Web build supersede the pending stages below. Browser acceptance remains unverified.

# OAuth completion return (review patch)

Base: `0ffea0a83de28086745c25e0c0d6193174459d2e` (v0.2.1). No push or deployment performed.

## Behavior

- The web Connect gesture synchronously reserves a popup before making the authenticated start request, avoiding asynchronous popup blocking. Blocked popups produce a clear retry message without creating an OAuth start request.
- A random 128-bit, non-authentication completion identifier is stored alongside existing encrypted, one-use OAuth state. It is not sent to the provider and cannot authorize a connection.
- Only after the existing callback validation, token exchange, identity lookup and account persistence succeed does the callback return HTTP 303 to the fixed same-origin `/oauth-complete.html` page. OAuth state, code, provider credentials and mailbox identity are never put in this destination or UI messages.
- The completion page notifies the original page through a per-attempt same-origin BroadcastChannel, with an origin-and-source-checked postMessage fallback. The existing in-memory login survives. Settings closes and the existing mailbox refresh fetches connected accounts. Duplicate notifications are ignored.
- Providers that remove `window.opener` are supported by BroadcastChannel. If neither communication path reaches the original window, the completion page returns to the same-origin root and explains that re-login is needed. No credentials are persisted to work around this limitation.
- If automatic close is refused, a Chinese success message and return link remain. A no-JavaScript return link is also present. The completion identifier is scrubbed from the displayed URL.
- Incomplete/closed authorization can be canceled and retried; the pending flow times out after the server's 10-minute authorization window. Closing settings cleans up listeners. Server error callbacks retain existing errors and never emit success or redirect.
- Native builds retain their external-browser flow and manual return guidance.

## Verification in cloud workspace

Passed:

- Full Maven test suite with Java 21 and H2: 102 tests, zero failures/errors/skips. Includes new return-controller tests, completion binding/persistence and malicious completion input tests, plus existing OAuth security/regression coverage.
- `dart analyze`: no issues found.
- `node --test client/tool/oauth_bridge_test.cjs`: 9 tests passed. Covers HTTPS-only launch, popup blocking, origin/source/id validation, one-shot message handling, BroadcastChannel fallback, cancel/timeout cleanup, fixed navigation, fragment scrubbing and one-time login notice.
- `node --check client/web/oauth_bridge.js` and `git diff --check`.

Browser test harness: `node client/tool/oauth_browser_smoke.cjs` (requires Playwright and Chromium) contains 9 synthetic local-browser scenarios. Execution was attempted, but Chromium could not create its process-singleton socket in this cloud execution environment, including an approved escalated attempt. These real-browser scenarios are **not claimed as passed**. No real provider authorization or mailbox content was accessed.

Flutter unit tests and web release build are being verified in the combined OAuth/HTML change set; this report does not claim them before that result is available. No PostgreSQL or native platform test was run for this patch.

## Before deployment

Build backend and web together using `scripts/build.sh`; the new completion HTML and JS must ship with the integrated JAR. Do not deploy only the backend redirect. Run the checked-in browser harness where Chromium can launch, then use a synthetic/staging provider flow to check same-tab, popup, denied consent, blocked popup and lost-opener behavior. A real Google consent test requires the user's own authorized browser and is not part of this patch's completed verification.
