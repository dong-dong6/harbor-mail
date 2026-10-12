// Real WebAuthn protocol with Chromium's isolated virtual authenticator only.
// Refuses non-localhost/non-demo targets before login or credential generation.
const assert = require('node:assert/strict');
const {chromium} = require('playwright');

(async () => {
  const base = new URL(process.argv[2]);
  assert.equal(base.hostname, 'localhost');
  assert.equal(base.protocol, 'http:');
  assert.equal(base.pathname, '/api/v1');
  assert.equal(base.username + base.password + base.search + base.hash, '');
  const health = await (await fetch(`${base}/health`)).json();
  assert.equal(health.demoMode, true, 'Refuse real account/production target');
  const browser = await chromium.launch({headless: true,
    executablePath: process.env.CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--disable-dev-shm-usage']});
  try {
    const page = await browser.newPage();
    await page.goto(base.origin, {waitUntil: 'domcontentloaded'});
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('WebAuthn.enable');
    await cdp.send('WebAuthn.addVirtualAuthenticator', {options: {
      protocol: 'ctap2', transport: 'internal', hasResidentKey: true,
      hasUserVerification: true, isUserVerified: true,
      automaticPresenceSimulation: true,
    }});
    const result = await page.evaluate(async (apiBase) => {
      const checks = [];
      const requireValue = (condition, description) => {
        if (!condition) throw new Error(description);
        checks.push(description);
      };
      const b64 = value => btoa(String.fromCharCode(...new Uint8Array(value)))
        .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      const bytes = value => Uint8Array.from(atob(value.replaceAll('-', '+')
        .replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4)), c => c.charCodeAt(0));
      async function call(path, body, token, method = 'POST') {
        const response = await fetch(apiBase + path, {method,
          headers: {'Content-Type': 'application/json',
            ...(token ? {Authorization: `Bearer ${token}`} : {})},
          ...(method === 'GET' ? {} : {body: JSON.stringify(body)}),
          redirect: 'error', cache: 'no-store'});
        return {status: response.status, data: response.status === 204 ? {} : await response.json()};
      }
      function serialize(credential) {
        const response = credential.response;
        return {id: credential.id, rawId: b64(credential.rawId), type: credential.type,
          clientExtensionResults: credential.getClientExtensionResults(),
          response: {clientDataJSON: b64(response.clientDataJSON),
            ...(response.attestationObject ? {attestationObject: b64(response.attestationObject),
              transports: response.getTransports()} : {
              authenticatorData: b64(response.authenticatorData), signature: b64(response.signature),
              userHandle: response.userHandle ? b64(response.userHandle) : null})}};
      }
      async function assertion() {
        const options = await call('/auth/passkeys/authentication/options', {});
        requireValue(options.status === 200, 'public authentication options');
        const publicKey = options.data.publicKey;
        requireValue(publicKey.rpId === 'localhost' && publicKey.userVerification === 'required',
          'trusted RP and required user verification');
        publicKey.challenge = bytes(publicKey.challenge);
        if (publicKey.allowCredentials) publicKey.allowCredentials = publicKey.allowCredentials
          .map(c => ({...c, id: bytes(c.id)}));
        const credential = await navigator.credentials.get({publicKey});
        return {requestId: options.data.requestId, credential: serialize(credential)};
      }
      const login = await call('/auth/login', {username: 'demo', password: 'demo-local-only'});
      requireValue(login.status === 200, 'synthetic owner login');
      const ownerToken = login.data.accessToken;
      const options = await call('/auth/passkeys/registration/options',
        {password: 'demo-local-only', name: 'Synthetic Chromium authenticator'}, ownerToken);
      requireValue(options.status === 200, 'password-confirmed registration options');
      const publicKey = options.data.publicKey;
      requireValue(publicKey.rp.id === 'localhost' && publicKey.authenticatorSelection.userVerification === 'required',
        'registration RP and required UV');
      publicKey.challenge = bytes(publicKey.challenge);
      publicKey.user.id = bytes(publicKey.user.id);
      publicKey.excludeCredentials = (publicKey.excludeCredentials || []).map(c => ({...c, id: bytes(c.id)}));
      const credential = await navigator.credentials.create({publicKey});
      const registered = await call('/auth/passkeys/registration/verify',
        {requestId: options.data.requestId, credential: serialize(credential)}, ownerToken);
      requireValue(registered.status === 200, 'actual virtual WebAuthn registration');
      const entryId = registered.data.id;
      const list = await call('/auth/passkeys', undefined, ownerToken, 'GET');
      requireValue(list.status === 200 && list.data.items.some(item => item.id === entryId), 'registered credential listed');
      await call('/auth/logout', {}, ownerToken);
      const signed = await assertion();
      const authenticated = await call('/auth/passkeys/authentication/verify', signed);
      requireValue(authenticated.status === 200 && authenticated.data.permission === 'OWNER_FULL_ACCESS',
        'actual virtual WebAuthn passwordless login');
      const passkeyToken = authenticated.data.accessToken;
      requireValue(passkeyToken && passkeyToken !== ownerToken, 'independent passkey session');
      const accounts = await call('/accounts', undefined, passkeyToken, 'GET');
      requireValue(accounts.status === 200 && Array.isArray(accounts.data.items), 'passkey session reads synthetic mailbox');
      const replay = await call('/auth/passkeys/authentication/verify', signed);
      requireValue(replay.status >= 400 && replay.status < 500, 'assertion replay rejected');
      const wrongOrigin = await assertion();
      const original = structuredClone(wrongOrigin);
      const clientData = JSON.parse(new TextDecoder().decode(bytes(wrongOrigin.credential.response.clientDataJSON)));
      clientData.origin = 'https://evil.invalid';
      wrongOrigin.credential.response.clientDataJSON = b64(new TextEncoder().encode(JSON.stringify(clientData)));
      const rejected = await call('/auth/passkeys/authentication/verify', wrongOrigin);
      requireValue(rejected.status >= 400 && rejected.status < 500, 'foreign origin rejected');
      const consumed = await call('/auth/passkeys/authentication/verify', original);
      requireValue(consumed.status >= 400 && consumed.status < 500, 'failed verification still consumes challenge');
      const pending = await assertion();
      const removed = await call(`/auth/passkeys/${entryId}/delete`, {password: 'demo-local-only'}, passkeyToken);
      requireValue(removed.status === 204, 'password-confirmed credential removal');
      const obsolete = await call('/auth/passkeys/authentication/verify', pending);
      requireValue(obsolete.status >= 400 && obsolete.status < 500, 'removed credential outstanding request rejected');
      await call('/auth/logout', {}, passkeyToken);
      return {result: 'passed', syntheticOnly: true, authenticator: 'Chromium CDP virtual', checks};
    }, base.toString().replace(/\/$/, ''));
    console.log(JSON.stringify(result));
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
