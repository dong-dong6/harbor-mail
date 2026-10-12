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
const source = fs.readFileSync(path.join(__dirname, 'test_passkeys_flutter_browser.cjs'), 'utf8');
assert(!source.includes('navigator.credentials.'), 'UI harness must not call WebAuthn directly'); checks++;
assert(!source.includes('route.fulfill('), 'UI harness must not substitute API or app content'); checks++;
assert(!source.includes('WebAuthn.getCredentials'), 'Do not export private virtual authenticator keys'); checks++;
console.log(`PASS ${checks} Flutter passkey harness guards/integrity checks (not a browser execution)`);
