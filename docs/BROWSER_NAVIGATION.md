# Browser navigation

The client owns hash URLs so packaged/static servers do not need SPA path fallback:

- `#/mail/{messageId}` opens one authenticated message.
- Optional `account`, `folder` and `filter` query fields preserve list context inside the fragment.
- `#/settings/accounts`, `#/settings/add` and `#/settings/oauth` select separate settings pages.

A copied URL or page reload requires login again, then resumes the internal route. Authentication remains in memory only; the URL and browser storage never receive login tokens, passwords, search text or message contents. Unknown/external paths normalize to the mailbox. Missing accounts fall back to the unified mailbox; inaccessible/deleted messages have a recoverable error with message commands disabled. Server authorization still decides access.

Browser Back/Forward first restores the prior history position while the existing inline-reply/account/OAuth discard guard runs. Cancelling retains the forward stack and unsaved text. Pending writes and uncertain-send results cannot be dismissed through browser navigation. New navigation invalidates stale asynchronous list/detail results. Flutter's default browser history integration is disabled before `runApp` so it cannot compete with the app's own history bridge.

Document exit/reload also requests the browser’s native unsaved-work warning when an editor has unsaved work or an operation is busy/uncertain. Browser support and user-gesture requirements apply. If the user chooses to leave, the memory-only session ends; save drafts explicitly before doing so.

## Verification

- `flutter test test/mail_route_test.dart test/mail_browser_route_test.dart`: URL validation, copied-link login, visible navigation, dirty and uncertain-send guards, stale results, account fallback and missing mail.
- `node tool/mail_navigation_test.cjs`: deterministic History API contract coverage, including rejected/repeated Back, Forward retention and canonicalization without duplicate history entries.
- After a release web build, `npm run test:mail-routes --prefix client/tool`: real Chromium UI, iframe/header/inline reply and browser Back/Forward on desktop/mobile. Synthetic HTTP fixtures only; no real mail or external account access.

A passed widget/Node test is not a passed browser test. Local Chromium may be blocked by environment IPC permissions; the real-browser gate must pass in CI before release acceptance.
