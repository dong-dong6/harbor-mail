'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const harness = require('./test_passkeys_flutter_browser.cjs');
let checks = 0;
for (const input of [
  'https://mail.example.test', 'https://localhost:8443', 'http://127.0.0.1:9000',
  'http://localhost', 'http://localhost:9000/api/v1', 'http://localhost:9000/?token=x',
  'http://localhost:9000/#/mail', 'http://user:password@localhost:9000',
]) {
  assert.throws(() => harness.parseOrigin(input)); checks++;
}
assert.equal(harness.parseOrigin('http://localhost:9000'), 'http://localhost:9000'); checks++;
for (const health of [null, {}, {status: 'UP'}, {status: 'UP', demoMode: false}, {status: 'DOWN', demoMode: true}]) {
  assert.throws(() => harness.assertDemoHealth(health)); checks++;
}
harness.assertDemoHealth({status: 'UP', demoMode: true}); checks++;
assert(harness.isAllowedRequest('http://localhost:9000/main.dart.js', 'http://localhost:9000')); checks++;
assert(!harness.isAllowedRequest('http://localhost:9001/main.dart.js', 'http://localhost:9000')); checks++;
assert(!harness.isAllowedRequest('https://external.example/script.js', 'http://localhost:9000')); checks++;
harness.verifyBridge(fs.readFileSync(path.join(__dirname, '../web', harness.BRIDGE_PATH))); checks++;
assert.throws(() => harness.verifyBridge(Buffer.from('test substitute'))); checks++;
const manifest = {schemaVersion: 1, available: true,
  downloadPath: '/downloads/android/app.apk', fileName: 'harbor-mail-dev.apk',
  packageName: 'dev.harbor.harbor_mail.dev', versionName: '0.3.0', versionCode: 6,
  sizeBytes: 12345678, sha256: 'a'.repeat(64),
  signing: {classification: 'development-debug', certificateSha256: 'b'.repeat(64)}};
harness.assertDownloadManifest(manifest); checks++;
harness.assertDownloadManifest({...manifest, releaseNotes: 'Synthetic build notes'}); checks++;
for (const change of [
  {schemaVersion: 2}, {available: false}, {downloadPath: 'https://external.example/app.apk'},
  {fileName: 'production.apk'}, {packageName: 'dev.harbor.harbor_mail'},
  {versionName: 'preview'}, {versionCode: 0}, {versionCode: 1.5},
  {sizeBytes: 0}, {sizeBytes: 257 * 1024 * 1024}, {sha256: 'wrong'},
  {signing: {classification: 'production', certificateSha256: 'b'.repeat(64)}},
  {signing: {classification: 'development-debug', certificateSha256: 'wrong'}},
  {releaseNotes: null}, {releaseNotes: 'x'.repeat(4001)},
]) {
  assert.throws(() => harness.assertDownloadManifest({...manifest, ...change})); checks++;
}
const desktop = {viewport: {width: 1440, height: 900},
  username: {x: 230, y: 380, width: 410, height: 56},
  login: {x: 230, y: 520, width: 410, height: 48},
  heading: {x: 824, y: 190, width: 362, height: 32},
  download: {x: 824, y: 385, width: 156, height: 40},
  warning: {x: 824, y: 270, width: 362, height: 60},
  pageMetrics: {innerWidth: 1440, documentWidth: 1440, bodyWidth: 1440}};
// Mobile heading/login are captured before scrolling; download/warning bounds
// are captured after revealing the card. Only horizontal comparisons span them.
const mobile = {viewport: {width: 390, height: 844},
  username: {x: 24, y: 270, width: 342, height: 56},
  login: {x: 24, y: 405, width: 342, height: 48},
  heading: {x: 48, y: 630, width: 294, height: 32},
  download: {x: 48, y: 640, width: 156, height: 40},
  warning: {x: 48, y: 520, width: 294, height: 80},
  pageMetrics: {innerWidth: 390, documentWidth: 390, bodyWidth: 390}};
for (const layout of [desktop, mobile]) {
  harness.assertLoginLayoutGeometry(layout); checks++;
}
for (const [sourceLayout, mutate] of [
  [desktop, value => { value.login.width = 520; }],
  [desktop, value => { value.heading.x = 230; value.heading.y = 650; }],
  [desktop, value => { value.download.x = 600; }],
  [desktop, value => { value.login.width = 300; value.username.width = 300; }],
  [desktop, value => { value.heading.y = 650; }],
  [desktop, value => { value.username = null; }],
  [desktop, value => { value.username.x = Number.NaN; }],
  [mobile, value => { value.heading.y = 300; }],
  [mobile, value => { value.heading.x = 200; }],
  [mobile, value => { value.download.width = 390; }],
  [mobile, value => { value.warning.x = -10; }],
  [mobile, value => { value.username.width = 410; }],
  [mobile, value => { value.pageMetrics.documentWidth = 480; }],
  [mobile, value => { value.pageMetrics.bodyWidth = 480; }],
  [mobile, value => { value.viewport.height = 900; }],
]) {
  const bad = structuredClone(sourceLayout);
  mutate(bad);
  assert.throws(() => harness.assertLoginLayoutGeometry(bad)); checks++;
}
const source = fs.readFileSync(path.join(__dirname, 'test_passkeys_flutter_browser.cjs'), 'utf8');
assert(!source.includes('navigator.credentials.'), 'UI harness must not call WebAuthn directly'); checks++;
assert(!source.includes('route.fulfill('), 'UI harness must not substitute API or app content'); checks++;
assert(!source.includes('WebAuthn.getCredentials'), 'Do not export private virtual authenticator keys'); checks++;
assert(source.includes('await page.setViewportSize({width: 1440, height: 1100})'),
  'Responsive checks restore the existing passkey workflow viewport'); checks++;
console.log(`PASS ${checks} Flutter passkey harness guards, manifest and responsive geometry checks (not a browser execution)`);
