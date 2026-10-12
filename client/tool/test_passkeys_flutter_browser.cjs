// Actual compiled Flutter UI -> pinned passkeys plugin -> self-hosted browser
// bridge -> Chromium virtual authenticator -> fresh real Java demo server.
// No direct credential API calls, generated assertion fixtures, or API mocking.
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const BRIDGE_PATH = '/vendor/passkeys/bundle-2.4.0.js';
const BRIDGE_SHA256 = 'dd06b08556f161f0518d701fd0a1bf9b3f5144e2e0d6e1f5c3cac81742c0be49';
const REPORT_DIR = path.resolve(__dirname, '../../test-results/passkeys-flutter-browser');
const DEMO_PASSWORD = 'demo-local-only';
const CREDENTIAL_NAME = 'Synthetic Flutter browser passkey';

function parseOrigin(input) {
  const value = new URL(input);
  assert.equal(value.protocol, 'http:', 'Only isolated HTTP localhost is allowed');
  assert.equal(value.hostname, 'localhost', 'Only isolated localhost is allowed');
  assert.notEqual(value.port, '', 'An explicit temporary port is required');
  assert.equal(value.username + value.password + value.search + value.hash, '');
  assert.equal(value.pathname, '/', 'Pass the origin, without API path');
  return value.origin;
}
function assertDemoHealth(health) {
  assert.equal(health?.status, 'UP', 'Demo server must be ready');
  assert.equal(health?.demoMode, true, 'Refuse real account or production target');
}
function verifyBridge(bytes) {
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), BRIDGE_SHA256,
    'Test the exact pinned upstream browser bridge, never a test substitute');
}
function isAllowedRequest(url, origin) {
  return url.startsWith('data:') || url.startsWith('blob:') || new URL(url).origin === origin;
}

async function run(input) {
  const origin = parseOrigin(input);
  // The guard runs before launching a browser, submitting passwords, or adding
  // any virtual authenticator. The shell fixture always creates an empty DB.
  const healthResponse = await fetch(origin + '/api/v1/health', {redirect: 'error'});
  assert.equal(healthResponse.status, 200);
  assertDemoHealth(await healthResponse.json());
  const indexResponse = await fetch(origin + '/', {redirect: 'error'});
  assert.equal(indexResponse.status, 200);
  const index = await indexResponse.text();
  assert.match(index, /flutter_bootstrap\.js/, 'Integrated JAR must contain compiled Flutter Web');
  assert(index.includes(BRIDGE_PATH.slice(1)), 'Real app index must load the pinned local bridge');
  const bridgeResponse = await fetch(origin + BRIDGE_PATH, {redirect: 'error'});
  assert.equal(bridgeResponse.status, 200);
  verifyBridge(Buffer.from(await bridgeResponse.arrayBuffer()));

  const {chromium, selectors} = require('playwright');
  await selectors.register('semanticValue', require('./semantic_value_selector.cjs'));
  fs.mkdirSync(REPORT_DIR, {recursive: true});
  const checks = [];
  const network = [];
  const externalRequests = [];
  const pageErrors = [];
  let phase = 'launch';
  let browser, page;
  const check = (condition, message) => { assert(condition, message); checks.push(message); };
  const count = (route, method = 'POST') => network.filter(item => item.path === route && item.method === method).length;
  try {
    browser = await chromium.launch({headless: true,
      executablePath: process.env.CHROMIUM_PATH || undefined,
      args: ['--no-sandbox', '--disable-dev-shm-usage']});
    const context = await browser.newContext({viewport: {width: 1440, height: 1100},
      serviceWorkers: 'block'});
    page = await context.newPage();
    page.setDefaultTimeout(20000);
    page.setDefaultNavigationTimeout(30000);
    await page.route('**/*', route => {
      if (isAllowedRequest(route.request().url(), origin)) return route.continue();
      externalRequests.push(new URL(route.request().url()).origin);
      return route.abort();
    });
    // Diagnostics deliberately omit bodies, headers, tokens, challenges,
    // credential IDs, assertions, console messages, traces and HAR files.
    page.on('request', request => {
      const url = new URL(request.url());
      if (url.origin === origin) network.push({path: url.pathname, method: request.method()});
    });
    page.on('pageerror', error => pageErrors.push(error.name));
    const cdp = await context.newCDPSession(page);
    await cdp.send('WebAuthn.enable');
    const {authenticatorId} = await cdp.send('WebAuthn.addVirtualAuthenticator', {options: {
      protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true,
    }});
    const presence = enabled => cdp.send('WebAuthn.setAutomaticPresenceSimulation',
      {authenticatorId, enabled});
    const semantic = text => page.locator('semanticValue=' + JSON.stringify({text}));
    const button = name => page.getByRole('button', {name, exact: true});
    const responseFor = (suffix, method = 'POST') => page.waitForResponse(response =>
      response.url() === origin + '/api/v1' + suffix && response.request().method() === method);
    const frames = () => page.evaluate(() => new Promise(resolve =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const type = async (label, value) => {
      const input = page.getByRole('textbox', {name: new RegExp(label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))});
      await input.waitFor({state: 'visible'});
      await input.click();
      await frames();
      await input.press('ControlOrMeta+A');
      await input.pressSequentially(value, {delay: 10});
      await frames();
      assert.equal(await input.inputValue(), value, 'Real keyboard input reached the Flutter input');
    };
    const mailbox = async () => {
      await button('退出登录').waitFor({state: 'visible'});
      await page.waitForFunction(() => {
        const status = window.HarborNavigation?.status?.();
        return status?.settled && status.location === '/mail' && location.hash === '#/mail';
      });
      await button('写邮件').waitFor({state: 'visible'});
    };
    const signout = async () => {
      const logout = responseFor('/auth/logout');
      await button('退出登录').click();
      assert.equal((await logout).status(), 204);
      await button('使用通行密钥登录').waitFor({state: 'visible'});
      await button('登录').waitFor({state: 'visible'});
    };

    phase = 'compiled-app-password-login';
    await page.goto(origin + '/#/mail', {waitUntil: 'domcontentloaded'});
    await Promise.race([
      page.locator('flt-semantics-placeholder').waitFor({state: 'attached'}),
      page.getByRole('textbox').first().waitFor({state: 'visible'}),
    ]);
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await page.getByRole('textbox').first().waitFor({state: 'visible'});
    check(await page.evaluate(() => isSecureContext), 'Real Flutter app runs in a secure localhost context');
    check(await page.locator(`script[src="${BRIDGE_PATH.slice(1)}"]`).count() === 1,
      'App loads the hash-verified self-hosted passkeys bridge');

    // Observe the real plugin's calls without replacing its implementation,
    // inputs, returned credential bytes, or native browser operations. Persist
    // only counts and policy/shape booleans, never protocol payloads.
    await page.evaluate(() => {
      const bridge = window.PasskeyAuthenticator;
      if (!bridge || typeof bridge.register !== 'function' || typeof bridge.login !== 'function') {
        throw new Error('Pinned passkeys browser runtime is missing');
      }
      window.__harborPasskeyUi = {register: {calls: 0, resolved: 0, rejected: 0},
        login: {calls: 0, resolved: 0, rejected: 0}, cancels: 0};
      for (const method of ['register', 'login']) {
        const original = bridge[method];
        bridge[method] = function(...args) {
          const stats = window.__harborPasskeyUi[method];
          stats.calls++;
          const request = JSON.parse(args[0]);
          const key = request.publicKey;
          stats.rpMatchesHost = (method === 'register' ? key.rp.id : key.rpId) === location.hostname;
          stats.uvRequired = (method === 'register'
            ? key.authenticatorSelection.userVerification : key.userVerification) === 'required';
          if (method === 'register') {
            stats.residentKeyRequired = key.authenticatorSelection.residentKey === 'required';
            stats.attestationNone = key.attestation === 'none';
          } else stats.mediationRequired = request.mediation === 'required';
          return original.apply(this, args).then(value => {
            stats.resolved++;
            const credential = JSON.parse(value);
            stats.standardResponse = credential.type === 'public-key' &&
              typeof credential.id === 'string' && typeof credential.rawId === 'string' &&
              typeof credential.response?.clientDataJSON === 'string' &&
              (method === 'register' ? typeof credential.response.attestationObject === 'string'
                : typeof credential.response.signature === 'string' &&
                  typeof credential.response.authenticatorData === 'string');
            return value;
          }, error => { stats.rejected++; throw error; });
        };
      }
      const cancel = bridge.cancelCurrentAuthenticatorOperation;
      bridge.cancelCurrentAuthenticatorOperation = function(...args) {
        window.__harborPasskeyUi.cancels++;
        return cancel.apply(this, args);
      };
    });
    await type('用户名', 'demo');
    await type('密码', DEMO_PASSWORD);
    const passwordLogin = responseFor('/auth/login');
    const passwordAccounts = responseFor('/accounts', 'GET');
    await button('登录').click();
    assert.equal((await passwordLogin).status(), 200);
    assert.equal((await passwordAccounts).status(), 200);
    await mailbox();
    check(true, 'Password login uses real Flutter controllers and the isolated demo backend');

    phase = 'ui-password-confirmed-registration';
    const initialList = responseFor('/auth/passkeys', 'GET');
    await button('通行密钥').click();
    const initial = await initialList;
    assert.equal(initial.status(), 200);
    assert.deepEqual((await initial.json()).items, [], 'Fresh fixture must start without credentials');
    await button('验证密码并添加通行密钥').waitFor({state: 'visible'});
    // This is the actual settings password-confirmation form, not a harness API.
    await type('通行密钥名称', CREDENTIAL_NAME);
    await type('当前账户密码（仅用于本次确认）', DEMO_PASSWORD);
    const registrationOptions = responseFor('/auth/passkeys/registration/options');
    const registrationVerify = responseFor('/auth/passkeys/registration/verify');
    const registeredList = responseFor('/auth/passkeys', 'GET');
    await button('验证密码并添加通行密钥').click({clickCount: 2});
    assert.equal((await registrationOptions).status(), 200);
    assert.equal((await registrationVerify).status(), 200);
    const entries = await (await registeredList).json();
    assert.equal(entries.items.length, 1);
    assert.equal(entries.items[0].name, CREDENTIAL_NAME);
    await button('移除 ' + CREDENTIAL_NAME).waitFor({state: 'visible'});
    const registration = await page.evaluate(() => window.__harborPasskeyUi.register);
    assert.deepEqual(registration, {calls: 1, resolved: 1, rejected: 0,
      rpMatchesHost: true, uvRequired: true, residentKeyRequired: true,
      attestationNone: true, standardResponse: true});
    assert.equal(count('/api/v1/auth/passkeys/registration/options'), 1);
    assert.equal(count('/api/v1/auth/passkeys/registration/verify'), 1);
    check(true, 'Settings form double-click creates exactly one real virtual-authenticator registration');
    check(true, 'Pinned Flutter plugin preserves RP, required UV/resident key, none attestation and standard response');
    await page.screenshot({path: path.join(REPORT_DIR, 'registered.png')});
    await button('关闭通行密钥设置').click();
    await mailbox();
    await signout();

    phase = 'ui-cancel-and-repeat-login';
    await presence(false);
    const cancelledOptions = responseFor('/auth/passkeys/authentication/options');
    await button('使用通行密钥登录').click({clickCount: 2});
    assert.equal((await cancelledOptions).status(), 200);
    await page.waitForFunction(() => window.__harborPasskeyUi.login.calls === 1);
    await button('取消通行密钥登录').waitFor({state: 'visible'});
    assert.equal(await button('正在等待系统验证…').isEnabled(), false);
    assert.equal(count('/api/v1/auth/passkeys/authentication/options'), 1);
    assert.equal(count('/api/v1/auth/passkeys/authentication/verify'), 0);
    await button('取消通行密钥登录').click();
    await page.waitForFunction(() => window.__harborPasskeyUi.login.rejected === 1);
    await semantic('已取消通行密钥登录。').waitFor({state: 'visible'});
    await button('登录').waitFor({state: 'visible'});
    assert.equal(await button('登录').isEnabled(), true, 'Cancel releases the parent busy state');
    assert.equal(await button('使用通行密钥登录').isEnabled(), true);
    assert.equal(count('/api/v1/auth/passkeys/authentication/verify'), 0);
    check(true, 'Repeated login click starts one ceremony; cancellation aborts actual browser bridge with no verification');

    phase = 'ui-passwordless-login';
    await presence(true);
    const authOptions = responseFor('/auth/passkeys/authentication/options');
    const authVerify = responseFor('/auth/passkeys/authentication/verify');
    const passkeyAccounts = responseFor('/accounts', 'GET');
    await button('使用通行密钥登录').click();
    assert.equal((await authOptions).status(), 200);
    assert.equal((await authVerify).status(), 200);
    assert.equal((await passkeyAccounts).status(), 200);
    await mailbox();
    const runtime = await page.evaluate(() => window.__harborPasskeyUi);
    assert.equal(runtime.login.calls, 2);
    assert.equal(runtime.login.resolved, 1);
    assert.equal(runtime.login.rejected, 1);
    assert.equal(runtime.login.rpMatchesHost, true);
    assert.equal(runtime.login.uvRequired, true);
    assert.equal(runtime.login.mediationRequired, true);
    assert.equal(runtime.login.standardResponse, true);
    assert.equal(count('/api/v1/auth/login'), 1, 'Passkey retry cannot fall back to a hidden password login');
    assert.equal(count('/api/v1/auth/passkeys/authentication/options'), 2);
    assert.equal(count('/api/v1/auth/passkeys/authentication/verify'), 1);
    check(true, 'Passkey login button creates a fresh session and renders the real synthetic mailbox');
    check(true, 'Plugin requests explicit mediation and required UV through the exact local bridge');
    await page.screenshot({path: path.join(REPORT_DIR, 'passkey-mailbox.png')});
    assert.deepEqual(await page.evaluate(() => ({local: Object.keys(localStorage),
      session: Object.keys(sessionStorage)})), {local: [], session: []},
      'Web login never persists session or credential data');
    check(true, 'Browser storage remains empty after password and passkey login');
    await signout();
    assert.deepEqual(externalRequests, [], 'All application resources and authentication remain self-hosted');
    assert.deepEqual(pageErrors, [], 'Compiled Flutter/plugin emits no uncaught page errors');
    check(true, 'Final signout returns to login; no third-party traffic or uncaught runtime errors');
    const result = {result: 'passed', suite: 'actual-flutter-web-passkey-ui', syntheticOnly: true,
      authenticator: 'Chromium CDP virtual', bridge: {path: BRIDGE_PATH, sha256: BRIDGE_SHA256},
      checks, runtime, requestCounts: {passwordLogin: count('/api/v1/auth/login'),
        registrationOptions: count('/api/v1/auth/passkeys/registration/options'),
        registrationVerify: count('/api/v1/auth/passkeys/registration/verify'),
        authenticationOptions: count('/api/v1/auth/passkeys/authentication/options'),
        authenticationVerify: count('/api/v1/auth/passkeys/authentication/verify')}};
    fs.writeFileSync(path.join(REPORT_DIR, 'result.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result));
    await cdp.send('WebAuthn.removeVirtualAuthenticator', {authenticatorId});
    return result;
  } catch (error) {
    if (page) await page.screenshot({path: path.join(REPORT_DIR, 'failure.png')}).catch(() => {});
    fs.writeFileSync(path.join(REPORT_DIR, 'failure.json'), JSON.stringify({
      result: 'failed', suite: 'actual-flutter-web-passkey-ui', syntheticOnly: true,
      phase, error: error.name, network, externalRequests, pageErrors,
      runtime: page ? await page.evaluate(() => window.__harborPasskeyUi ?? null).catch(() => null) : null,
    }, null, 2) + '\n');
    throw error;
  } finally {
    if (browser) await browser.close();
  }
}

module.exports = {parseOrigin, assertDemoHealth, verifyBridge, isAllowedRequest, BRIDGE_PATH, BRIDGE_SHA256};
if (require.main === module) {
  run(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1; });
}
