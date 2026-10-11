# Safe HTML mail reading

The Web reader preserves email HTML tables, inline presentation styles, text hierarchy and links. Gmail, Microsoft Graph and IMAP retain separate plain/HTML MIME alternatives; HTML is never concatenated into a provided plain alternative. Stored bodies from older versions are refreshed on first open, and subsequent metadata sync retains the body cache.

## Trust boundary

- `bodyHtml` is untrusted email input in the JSON detail API. Never insert it into the app DOM or render it without the bundled reader.
- The reader parses into an inert template and copies an allowlist of elements, attributes and inline CSS. Scripts, event handlers, forms, SVG, frames, external stylesheets, CSS URLs and executable URLs are discarded.
- The result is a sandboxed `srcdoc` iframe with neither `allow-scripts` nor `allow-same-origin`. CSP blocks scripts, forms, connections, fonts, media and frames. Only HTTP(S)/mailto links are retained, opening a separate tab with `noopener noreferrer`.
- Remote images are blocked by default. “显示本封邮件的远程图片” opts in for the current opened message only, with no referrer. Clicking may notify the sender that the email was read. Switching messages resets the choice. Blocking again cannot retract requests already made.
- Both plain text and HTML remain available; text is used for reply/forward composition. Non-Web builds retain selectable plain text.

## Deliberate limits

The reader is a safe presentation subset, not a browser clone of Gmail. Stylesheet blocks/media queries, remote fonts, CSS background images, active embedded content, data images and CID inline attachment images are not rendered. CID images show an alt-text placeholder and remain available as attachments when supplied by the provider. Wide mail tables remain scrollable inside the isolated reader; the reader has its own bounded scroll area. Sender HTML exceeding server body limits is rejected rather than partially cached.

## Synthetic checks

- `flutter analyze --no-pub`, `flutter test --no-pub`, `flutter build web --no-pub`
- Maven provider/API tests cover body selection, size limits and cache upgrades.
- Locked Node unit tests: `npm ci --prefix client/tool --ignore-scripts`, then `npm test --prefix client/tool`.
- Browser integration: install the locked Playwright Chromium, then `npm run test:browser --prefix client/tool` (set both `CHROMIUM` and `CHROMIUM_PATH` to the executable). CI runs these synthetic browser checks. Uses synthetic fixtures, intercepts remote requests, checks default zero-request policy, sandbox separation and explicit image opt-in, and writes desktop/mobile screenshots to `docs/screenshots/`.

No real email credentials, sender tracking links or mailbox content are required by these checks.
