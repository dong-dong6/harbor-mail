// Deterministic History API contract tests; actual Flutter web QA runs separately.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../web/mail_navigation.js'),'utf8');
const flush=async()=>{for(let i=0;i<12;i++)await new Promise(r=>setImmediate(r));};
function fixture(){
 let cursor=0,pop,unload;const entries=[{url:'/#/mail',state:null}];
 const location={pathname:'/',search:'',hash:'#/mail',href:'https://mail.invalid/#/mail'};
 const update=url=>{location.hash=new URL(url,'https://mail.invalid').hash;location.href='https://mail.invalid'+url;};
 const history={get state(){return entries[cursor].state;},replaceState(state,_,url){entries[cursor]={state,url};update(url);},pushState(state,_,url){entries.splice(++cursor,Infinity,{state,url});update(url);},go(delta){const target=cursor+delta;if(target<0||target>=entries.length)return;cursor=target;update(entries[cursor].url);const state=entries[cursor].state;setImmediate(()=>pop({state,stopImmediatePropagation(){}}));}};
 const context={location,history,addEventListener(name,callback){if(name==='popstate')pop=callback;if(name==='beforeunload')unload=callback;}};context.window=context;vm.runInNewContext(source,context);
 return {nav:context.HarborNavigation,history,location,entries,cursor:()=>cursor,unload:()=>{let prevented=false;unload({preventDefault(){prevented=true;}});return prevented;}};
}
(async()=>{
 const f=fixture();let accept=true;f.nav.listen(async()=>accept);
 f.nav.write('/mail/m1');f.nav.write('/mail/m2');assert.equal(f.location.hash,'#/mail/m2');
 f.history.go(-1);await flush();assert.equal(f.location.hash,'#/mail/m1');f.history.go(1);await flush();assert.equal(f.location.hash,'#/mail/m2');
 accept=false;f.history.go(-1);await flush();assert.equal(f.location.hash,'#/mail/m2');assert.equal(f.entries.length,3);assert.equal(f.cursor(),2);
 accept=true;f.history.go(-1);await flush();f.history.go(1);await flush();assert.equal(f.location.hash,'#/mail/m2');
 f.nav.write('/mail/m2');assert.equal(f.entries.length,3);f.nav.write('https://evil.invalid');f.nav.write('//evil.invalid');assert.equal(f.location.hash,'#/mail/m2');
 let resolve;f.nav.listen(()=>new Promise(r=>{resolve=r;}));f.history.go(-1);await flush();assert.equal(f.location.hash,'#/mail/m2');f.history.go(-1);await flush();assert.equal(f.location.hash,'#/mail/m2');resolve(false);await flush();assert.equal(f.cursor(),2);
 f.nav.listen(async()=>{f.nav.write('/mail');return true;});f.history.go(-1);await flush();assert.equal(f.location.hash,'#/mail');assert.equal(f.entries.length,3);
 assert.equal(f.unload(),false);f.nav.protectDocument(()=>true);assert.equal(f.unload(),true);f.nav.protectDocument(()=>false);assert.equal(f.unload(),false);
 const delayed=fixture();let acceptDelayed;
 delayed.nav.listen(()=>new Promise(resolve=>{acceptDelayed=resolve;}));
 delayed.nav.write('/mail/m1');delayed.nav.write('/mail/m2');
 delayed.history.go(-1);
 assert.equal(delayed.location.hash,'#/mail/m1','native hash changes before acceptance');
 assert.equal(delayed.nav.status().location,'/mail/m2','committed route is still prior mail');
 await flush();assert.equal(delayed.nav.status().settled,false);
 assert.equal(delayed.location.hash,'#/mail/m2','prior position restored during async guard');
 delayed.history.go(-1);acceptDelayed(true);await flush();
 assert.equal(delayed.nav.status().settled,true,'acceptance overlapping repeated Back settles');
 assert.equal(delayed.nav.status().location,'/mail/m1');assert.equal(delayed.location.hash,'#/mail/m1');
 delayed.nav.listen(async()=>true);delayed.history.go(1);await flush();
 assert.equal(delayed.location.hash,'#/mail/m2');assert.equal(delayed.nav.status().settled,true);
 const rapid=fixture();rapid.nav.listen(async()=>true);rapid.nav.write('/mail/m1');rapid.nav.write('/mail/m2');
 rapid.history.go(-1);rapid.history.go(1);await flush();
 assert.equal(rapid.nav.status().settled,true,'stale Back event followed by Forward cannot deadlock');
 assert.equal(rapid.location.hash,'#/mail/m2');assert.equal(rapid.nav.status().location,'/mail/m2');
 rapid.history.go(-1);rapid.history.go(-1);await flush();
 assert.equal(rapid.nav.status().settled,true);assert.equal(rapid.location.hash,'#/mail');assert.equal(rapid.nav.status().location,'/mail');
 console.log('PASS async/rapid traversal: temporary hash != committed route, overlapping repeated Back acceptance, stale Back/Forward events, double Back');
 console.log('PASS history bridge Back/Forward, dirty rejection, repeated Back, duplicate suppression, external rejection, canonicalization');
})().catch(e=>{console.error(e);process.exitCode=1;});
