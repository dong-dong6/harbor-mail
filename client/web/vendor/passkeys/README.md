# Self-hosted Flutter passkeys browser bridge

Unmodified official browser bridge release 2.4.0, required by `passkeys` 2.23.1.

- Source: https://github.com/corbado/flutter-passkeys/releases/download/2.4.0/bundle.js
- Package documentation: https://pub.dev/packages/passkeys/versions/2.23.1
- Retrieved: 2026-10-12
- SHA-256: `dd06b08556f161f0518d701fd0a1bf9b3f5144e2e0d6e1f5c3cac81742c0be49`
- BSD-3-Clause package license is preserved in `LICENSE`; embedded TypeScript helper copyright/permission notice is preserved in the bundle. The bundled `@github/webauthn-json` MIT notice is included in `LICENSE-webauthn-json` (source: https://github.com/github/webauthn-json/blob/main/LICENSE.md).

The bridge calls only browser WebAuthn APIs. No Corbado hosted service, signup,
external script/CDN runtime dependency, restore credential API, PRF secret, or
credential synchronization API is used by Harbor Mail. Browser registration
cancellation is not implemented by this upstream bridge; application lifecycle
guards reject late results and the OS/browser controls its sheet dismissal.

Do not hand-edit this cryptographic protocol bridge. Update from a verified
upstream release and retest the complete isolated virtual-authenticator flow.
