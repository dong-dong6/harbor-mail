const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../web/oauth_bridge.js'), 'utf8');
function fixture({complete = false, hash = '', blocked = false, channel = true} = {}) {
  const listeners = new Map(), timers = new Map(), channels = [], outcomes = [], navigations = [];
  let seq = 0;
  const popup = { closed: false, location: { replace: x => navigations.push(x) }, close() { this.closed = true; }, postMessage: (...args) => outcomes.push(args) };
  class Channel {
    constructor(name) { this.name = name; channels.push(this); }
    postMessage(data) { this.sent = data; }
    close() { this.closed = true; }
  }
  const status = {textContent: ''};
  const context = {
    location: {origin:'https://mail.example.test', pathname:complete?'/oauth-complete.html':'/', search:'', hash, replace: x => navigations.push(x)},
    history:{ replaceState: (...args) => { context.location.hash = ''; context.history.last = args[2]; } },
    crypto: {getRandomValues: a => { a.fill(42); return a; }}, Uint8Array, URL,
    document:{ documentElement:{dataset:{oauthComplete:String(complete)}}, getElementById: () => status },
    setTimeout: (fn, ms) => { const id=++seq; timers.set(id,{fn,ms}); return id; }, clearTimeout: id => timers.delete(id),
    BroadcastChannel: channel ? Channel : undefined,
    open: () => blocked ? null : popup, focus: () => {}, close: () => {context.closed = true;}, opener: popup,
    addEventListener: (type, fn) => listeners.set(type, fn), removeEventListener: (type, fn) => { if (listeners.get(type) === fn) listeners.delete(type); }
  };
  context.window = context; vm.runInNewContext(source, context);
  return {context,popup,listeners,timers,channels,outcomes,navigations,status, api:context.HarborOAuth,
    fire: ms => { for (const [id,t] of [...timers]) if (t.ms===ms) {timers.delete(id);t.fn();} },
    message: data => listeners.get('message')?.(data)};
}
const id = '2a'.repeat(16);
test('reserves synchronously, HTTPS only, cancel cleans up', () => {
  const f=fixture(); assert.equal(f.api.prepare(()=>{}),id);
  assert.equal(f.api.open(id,'javascript:alert(1)'),false);
  assert.equal(f.api.open(id,'https://accounts.example.test/oauth'),true);
  f.api.cancel(id); assert.equal(f.popup.closed,true); assert.equal(f.listeners.size,0); assert.equal(f.timers.size,0);
  assert.equal(f.api.open(id,'https://example.test'),false);
});
test('blocked popup has no flow, timer or listeners', () => {
  const f=fixture({blocked:true}); assert.equal(f.api.prepare(()=>{}),''); assert.equal(f.listeners.size,0); assert.equal(f.timers.size,0);
});
test('wrong origin, source and correlation never complete; correct message completes once', () => {
  const f=fixture(); let count=0; f.api.prepare(()=>count++);
  const good={origin:f.context.location.origin, source:f.popup, data:{type:'harbor-mail-connected',id}};
  f.message({...good,origin:'https://evil.example'}); f.message({...good,source:{}}); f.message({...good,data:{...good.data,id:'00'.repeat(16)}});
  assert.equal(count,0); const listener=f.listeners.get('message'); f.message(good); listener(good);
  assert.equal(count,1); assert.deepEqual(f.outcomes[0][0].type,'harbor-mail-connected-ack'); assert.equal(f.timers.size,0);
});
test('same-origin BroadcastChannel completes without opener, ignores unknown message and duplicates', () => {
  const f=fixture(); let count=0; f.api.prepare(()=>count++); const c=f.channels[0];
  assert.equal(c.name,'harbor-mail-oauth-'+id); c.onmessage({data:'anything'}); assert.equal(count,0);
  c.onmessage({data:'harbor-mail-connected'}); c.onmessage({data:'harbor-mail-connected'});
  assert.equal(count,1); assert.equal(c.sent,'harbor-mail-connected-ack'); assert.equal(c.closed,true);
});
test('timeout reports incomplete once and removes listeners', () => {
  const f=fixture(); const result=[]; f.api.prepare(x=>result.push(x)); f.fire(600000); f.fire(600000);
  assert.deepEqual(result,[false]); assert.equal(f.listeners.size,0); assert.equal(f.api.open(id,'https://example.test'),false);
});
test('completion scrubs fragment, sends only fixed event/id, requires matching ack', () => {
  const f=fixture({complete:true,hash:'#'+id}); assert.equal(f.context.history.last,'/oauth-complete.html');
  assert.equal(f.channels[0].sent,'harbor-mail-connected'); assert.deepEqual(Object.keys(f.outcomes[0][0]),['type','id']);
  f.message({origin:'https://evil.example',source:f.popup,data:{type:'harbor-mail-connected-ack',id}}); assert.equal(f.context.closed,undefined);
  f.message({origin:f.context.location.origin,source:{},data:{type:'harbor-mail-connected-ack',id}}); assert.equal(f.context.closed,undefined);
  f.channels[0].onmessage({data:'harbor-mail-connected-ack'}); assert.equal(f.context.closed,true);
  f.fire(1500); assert.deepEqual(f.navigations,[]); assert.match(f.status.textContent,/原邮箱窗口正在刷新/);
});
test('legacy and absent original return only to fixed clean URL without repeating callbacks', () => {
  for (const hash of ['#connected','#'+id,'#https://evil.example?code=private']) {
    const f=fixture({complete:true,hash}); f.fire(1500); assert.deepEqual(f.navigations,['/#oauth-connected']);
    assert.equal(f.context.history.last,'/oauth-complete.html');
  }
});
test('postMessage works when BroadcastChannel unavailable', () => {
  const f=fixture({complete:true,hash:'#'+id,channel:false}); assert.equal(f.channels.length,0);
  f.message({origin:f.context.location.origin,source:f.popup,data:{type:'harbor-mail-connected-ack',id}});
  assert.equal(f.context.closed,true);
});
test('return notice is consumed once without credentials/storage', () => {
  const f=fixture({hash:'#oauth-connected'}); assert.equal(f.api.consumeReturn(),true); assert.equal(f.api.consumeReturn(),false); assert.equal(f.context.history.last,'/');
});
