// Synthetic local browser tests; no provider login, tokens, or mailbox data.
// Run: node client/tool/oauth_browser_smoke.cjs (requires Playwright + Chromium).
const { chromium } = require('playwright');
const { createServer } = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const web = path.resolve(__dirname, '../web');
const fixture = `<!doctype html><script src="/oauth_bridge.js"></script>
<button id="start">Start</button><script>
window.count = 0; window.outcomes = [];
document.querySelector('button').onclick = () => {
 window.flowId = HarborOAuth.prepare(ok => { count++; outcomes.push(ok); });
};
</script>`;
const server = createServer((req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname;
  if (pathname === '/oauth_bridge.js' || pathname === '/oauth-complete.html') {
    res.setHeader('Content-Type', pathname.endsWith('.js') ? 'text/javascript' : 'text/html');
    res.end(fs.readFileSync(path.join(web, pathname)));
  } else { res.setHeader('Content-Type', 'text/html'); res.end(fixture); }
});
(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
  let passed = 0;
  const check = async (name, fn) => {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(base);
    try { await fn(page, context); console.log('PASS ' + name); passed++; }
    finally { await context.close(); }
  };
  async function start(page) {
    const popupEvent = page.waitForEvent('popup');
    await page.click('#start');
    return { popup: await popupEvent, id: await page.evaluate(() => flowId) };
  }
  async function expectClosed(popup) {
    // Chromium reports closure asynchronously, after the page's close() call.
    if (!popup.isClosed()) await popup.waitForEvent('close', { timeout: 5000 });
    assert.equal(popup.isClosed(), true);
  }
  try {
    await check('popup returns once to original in-memory page', async page => {
      await page.evaluate(() => { window.sessionFixture = 'synthetic-memory-only'; });
      const { popup, id } = await start(page);
      await popup.goto(base + '/oauth-complete.html#' + id).catch(e => { if (!popup.isClosed()) throw e; });
      await page.waitForFunction(() => count === 1);
      assert.equal(await page.evaluate(() => sessionFixture), 'synthetic-memory-only');
      assert.deepEqual(await page.evaluate(() => outcomes), [true]);
      await page.evaluate(id => { const b = new BroadcastChannel('harbor-mail-oauth-' + id); b.postMessage('harbor-mail-connected'); b.close(); }, id);
      await page.waitForTimeout(100);
      assert.equal(await page.evaluate(() => count), 1);
      await expectClosed(popup);
    });
    await check('provider removes opener: same-origin channel still returns', async page => {
      const { popup, id } = await start(page);
      await popup.evaluate(() => { window.opener = null; });
      await popup.goto(base + '/oauth-complete.html#' + id).catch(e => { if (!popup.isClosed()) throw e; });
      await page.waitForFunction(() => count === 1);
      await expectClosed(popup);
    });
    await check('postMessage fallback verifies origin and source', async page => {
      await page.evaluate(() => { window.BroadcastChannel = undefined; });
      const { popup, id } = await start(page);
      await page.evaluate(id => {
        dispatchEvent(new MessageEvent('message', { origin: location.origin, source: window, data: { type:'harbor-mail-connected', id } }));
        dispatchEvent(new MessageEvent('message', { origin:'https://evil.example', source: window, data: { type:'harbor-mail-connected', id } }));
      }, id);
      assert.equal(await page.evaluate(() => count), 0);
      await popup.goto(base + '/oauth-complete.html#' + id).catch(e => { if (!popup.isClosed()) throw e; });
      await page.waitForFunction(() => count === 1);
    });
    await check('popup blocked creates no pending flow', async page => {
      await page.evaluate(() => { window.open = () => null; });
      await page.click('#start');
      assert.equal(await page.evaluate(() => flowId), '');
      assert.equal(await page.evaluate(() => count), 0);
    });
    await check('unsafe authorization URL rejected; cancellation cleans up', async page => {
      const { popup, id } = await start(page);
      assert.equal(await page.evaluate(id => HarborOAuth.open(id, 'javascript:alert(1)'), id), false);
      await page.evaluate(id => HarborOAuth.cancel(id), id);
      await expectClosed(popup);
      assert.equal(await page.evaluate(id => HarborOAuth.open(id, 'https://example.test'), id), false);
      assert.equal(await page.evaluate(() => count), 0);
    });
    await check('missing original / same-tab flow returns to clean fixed URL', async page => {
      await page.goto(base + '/oauth-complete.html#0123456789abcdef0123456789abcdef');
      await page.waitForURL(base + '/#oauth-connected');
      assert.equal(await page.evaluate(() => HarborOAuth.consumeReturn()), true);
      assert.equal(page.url(), base + '/');
      assert.equal(await page.evaluate(() => HarborOAuth.consumeReturn()), false);
    });
    await check('legacy flow and malicious fragment cannot redirect off-origin', async page => {
      await page.goto(base + '/oauth-complete.html#https://evil.example/?code=secret');
      await page.waitForURL(base + '/#oauth-connected');
      assert.equal(new URL(page.url()).origin, base);
      assert.ok(!page.url().includes('secret'));
    });
    await check('close blocked leaves readable fallback and manual return', async page => {
      const { popup, id } = await start(page);
      await popup.addInitScript(() => { window.close = () => {}; });
      await popup.goto(base + '/oauth-complete.html#' + id);
      await page.waitForFunction(() => count === 1);
      await popup.waitForTimeout(1700);
      assert.match(await popup.locator('#status').innerText(), /原邮箱窗口正在刷新/);
      assert.equal(popup.url(), base + '/oauth-complete.html');
      await popup.locator('a').click();
      await popup.waitForURL(base + '/#oauth-connected');
    });
    await check('interrupted flow times out without reporting success', async page => {
      await page.evaluate(() => { const real = window.setTimeout; window.setTimeout = (fn, ms, ...args) => real(fn, ms === 600000 ? 100 : ms, ...args); });
      const { id } = await start(page);
      await page.waitForFunction(() => count === 1);
      assert.deepEqual(await page.evaluate(() => outcomes), [false]);
      assert.equal(await page.evaluate(id => HarborOAuth.open(id, 'https://example.test'), id), false);
    });
    console.log(`${passed} OAuth browser checks passed.`);
  } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
