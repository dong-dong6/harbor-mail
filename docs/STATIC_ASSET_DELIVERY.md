# Public web asset delivery

Private responses retain `Cache-Control: no-store`, including API successes and
errors, login, OAuth completion HTML, mail, attachments and image proxy responses.
The normal security filter runs before public-resource delivery.

`scripts/prepare-web-assets.py` copies Flutter output into the server and writes
an exact public-file manifest outside the public resource tree. Only listed
GET/HEAD requests can opt into public caching. Source maps, `.symbols` and hidden
metadata are omitted. Arbitrary/runtime paths never become publicly cacheable
merely because they end in `.js`, `.wasm` or another static extension. Backend-only
builds without this manifest retain the default no-store behavior.

All listed public files use `public, no-cache, must-revalidate`. Stable Flutter
URLs are **not** advertised as immutable: browsers can retain bytes but must
validate before reuse. SHA-256 ETags change with the actual build content;
unchanged representations return 304 with no response body. Index, bootstrap,
service-worker script, manifests and version metadata follow the same rule.

Compressible files receive deterministic gzip sidecars at build time. Gzip is
served only when accepted by the client and smaller than identity. Each encoding
has its own ETag. `Vary: Accept-Encoding` and `Vary: Origin` keep encoding and CORS
variants distinct, including requests without Origin. GET and HEAD agree on
headers. This needs only Python's standard library and the existing JDK; no new
Brotli/native dependency or reverse-proxy change. Sidecars increase packaged JAR
size in exchange for lower transfer and runtime compression costs.

The full Noto Sans SC OTF and native font configuration are unchanged. Dynamic
Chinese messages need full glyph coverage, so no UI-only subset is introduced.
A full-coverage WOFF2 conversion would need separately verified tooling and a
compatible loading path; it is outside this change.

## Checks

- `python3 scripts/test-prepare-web-assets.py`: reproducibility, gzip round-trip,
  changed-build ETags, deleted-file cleanup and metadata/auth-page exclusion.
- Maven `PublicWebAssetsTest`: real HTTP, cold/warm requests, encoding quality,
  HEAD, query strings, retained headers and authenticated/private cache isolation.
  Shared `TestDatabases` selects H2 or the configured PostgreSQL test schema.
- `python3 scripts/smoke-static-assets.py --url http://127.0.0.1:8080`: real packaged
  JS/font/WASM and startup resources; verifies gzip bytes, expected build ETags,
  warm 304, stale validators, HEAD and private API no-store.

Use fresh output from these checks for the current source revision. Prior build
results do not validate reconstructed or subsequently modified files. Exact cold
and warm bytes are recorded by the smoke script; renderer variants or browser
extension traffic must not be counted as one application page load. A production
reverse proxy can alter HTTP headers, so validate responses after deployment.
