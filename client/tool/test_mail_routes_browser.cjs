// Built Flutter app + real History API + native HTML iframe. Synthetic data only.
const {chromium,selectors}=require('playwright');
const {createServer}=require('node:http');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../build/web'),out=path.resolve(__dirname,'../../test-results/mail-routes');fs.mkdirSync(out,{recursive:true});
const mail=id=>({id,accountId:'demo',fromName:'Synthetic sender',fromAddress:'sender@example.invalid',subject:id==='m1'?'ROUTE SUBJECT ONE':'ROUTE SUBJECT TWO',receivedAt:'2026-10-11T10:42:00Z',to:[{name:'Synthetic recipient',address:'recipient@example.invalid'}],cc:[{name:'Synthetic copy',address:'copy@example.invalid'}],bodyHtml:'<h1>BODY START</h1><div style="height:360px;background:#eef">SYNTHETIC HTML BODY</div>',bodyText:'SYNTHETIC PLAINTEXT BODY',attachments:[],isRead:true,revision:1});
const accounts=[{id:'demo',displayName:'Synthetic',email:'demo@example.invalid',provider:'GMAIL',status:'DEMO',canDisconnect:true}];
let delayed=false;
const server=createServer((req,res)=>{
 const p=new URL(req.url,'http://localhost').pathname;
 if(p.startsWith('/api/v1')){
  let body={items:[]};
  if(p.endsWith('/auth/login'))body={accessToken:'synthetic-token'};
  if(p.endsWith('/accounts'))body={items:accounts};
  if(p.endsWith('/settings/capabilities'))body={demoMode:true,providers:[],features:{html:true,oauthSettings:true}};
  if(p.endsWith('/settings/oauth'))body={demoMode:true,readOnly:true,items:['GMAIL','OUTLOOK','EXCHANGE'].map(provider=>({provider,source:'ENVIRONMENT',revision:0,clientId:'synthetic-id',redirectUri:'https://mail.invalid/callback',tenant:provider==='GMAIL'?'':'consumers',hasClientSecret:false,configured:false,validationErrors:[]}))};
  if(p.endsWith('/messages'))body={items:[mail('m1'),mail('m2')],hasMore:false};
  if(/\/messages\/m[12]$/.test(p))body=mail(p.split('/').pop());
  if(p.endsWith('/messages/missing')){res.statusCode=404;body={code:'NOT_FOUND',message:'邮件不存在或没有访问权限'};}
  res.setHeader('content-type','application/json');const send=()=>res.end(JSON.stringify(body));
  if(delayed&&p.endsWith('/messages/m2'))setTimeout(send,800);else send();return;
 }
 const file=path.join(root,p==='/'?'index.html':p);
 res.setHeader('content-type',({'.js':'text/javascript','.wasm':'application/wasm','.json':'application/json','.otf':'font/otf','.ttf':'font/ttf','.png':'image/png'})[path.extname(file)]||'text/html');
 try{res.end(fs.readFileSync(file));}catch{res.statusCode=404;res.end();}
});
(async()=>{
 // Flutter SelectableText exposes semantics values/labels, not necessarily DOM
 // text. Match the actual accessible payload exactly, without visual OCR or
 // accepting unrelated ancestor text. Bounds still come from the matched node.
 await selectors.register('semanticValue', require('./semantic_value_selector.cjs'));
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const base=`http://127.0.0.1:${server.address().port}`;
 const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 try{
  for(const width of [1440,390]){
   const page=await browser.newPage({viewport:{width,height:1100}});const errors=[],consoleLog=[],network=[];page.on('pageerror',e=>errors.push(String(e)));page.on('console',m=>consoleLog.push({type:m.type(),text:m.text()}));page.on('response',r=>network.push({url:r.url(),status:r.status()}));page.on('requestfailed',r=>network.push({url:r.url(),failure:r.failure()}));
   await page.route('**/*',r=>r.request().url().startsWith(base)||r.request().url().startsWith('data:')?r.continue():r.abort());
   const semantic=(text,prefix=false,line=false)=>page.locator('semanticValue='+JSON.stringify({text,prefix,line}));
   const hash=route=>page.waitForFunction(value=>location.hash===value,'#'+route);
   const login=async()=>{const placeholder=page.locator('flt-semantics-placeholder');await Promise.race([placeholder.waitFor({state:'attached'}),page.getByRole('textbox').first().waitFor({state:'visible'})]);await page.evaluate(()=>document.querySelector('flt-semantics-placeholder')?.click());await page.getByRole('textbox').first().waitFor({state:'visible'});await page.getByRole('textbox').first().fill('owner');await page.getByRole('textbox').nth(1).fill('synthetic-only');await page.getByRole('button',{name:'登录',exact:true}).click();};
   const back=()=>page.evaluate(()=>history.back()),forward=()=>page.evaluate(()=>history.forward());
   const reveal=async locator=>{
    for(let n=0;n<12;n++){
     const box=await locator.boundingBox({timeout:1000}).catch(()=>null);
     if(box&&box.y>=0&&box.y+Math.min(box.height,80)<1050)return;
     // Wheel within the reader's padding, not inside its opaque iframe and not
     // outside the scrollable card. This works at both tested viewport widths.
     const frame=await page.locator('iframe[title="邮件正文"]').boundingBox({timeout:1000}).catch(()=>null);
     await page.mouse.move(frame?Math.max(1,frame.x-8):width-40,850);
     await page.mouse.wheel(0,box&&box.y<0?-450:450);await page.waitForTimeout(120);
    }
    throw new Error('Reader control did not become visible after scrolling: '+locator);
   };
   try {
   console.log(`CHECK ${width}: copied link and header`);
   await page.goto(base+'/#/mail/m2');await login();await hash('/mail/m2');
   await semantic('ROUTE SUBJECT TWO').waitFor();
   await semantic('发件人：Synthetic sender <sender@example.invalid>').waitFor();
   await semantic('收件人：Synthetic recipient <recipient@example.invalid>').waitFor();
   await semantic('抄送：Synthetic copy <copy@example.invalid>').waitFor();
   await semantic('接收时间：2026-10-11 10:42:00',true).waitFor();
   const iframe=page.locator('iframe[title="邮件正文"]');await iframe.waitFor();
   const subjectBox=await semantic('ROUTE SUBJECT TWO').boundingBox();const bodyBox=await iframe.boundingBox();
   assert(subjectBox.y>=0&&bodyBox.y>subjectBox.y+subjectBox.height,'mail header stays above HTML iframe');
   assert(bodyBox.x>=0&&bodyBox.x+bodyBox.width<=width+1,'iframe respects viewport');
   assert.equal(await iframe.evaluate(e=>e.contentDocument),null,'HTML body stays opaque sandboxed');
   await page.screenshot({path:path.join(out,`header-${width}.png`)});
   await page.getByRole('button',{name:'返回列表',exact:true}).click();await hash('/mail');
   await page.getByRole('button',{name:/\bROUTE SUBJECT ONE\b/}).click();await hash('/mail/m1');
   await back();await hash('/mail');await forward();await hash('/mail/m1');
   console.log(`CHECK ${width}: browser history and inline editor`);
   const reply=page.getByRole('button',{name:'回复',exact:true});await reveal(reply);await reply.click();
   const body=page.getByRole('textbox',{name:'回复正文',exact:true});await reveal(body);await body.fill('KEEP REPLY THROUGH BROWSER BACK');
   assert.equal(await page.locator('[role="dialog"],[role="alertdialog"]').count(),0,'reply is inline rather than modal');
   if(width===1440){
    const warned=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('Missing dirty beforeunload warning')),10000);page.once('dialog',async d=>{try{assert.equal(d.type(),'beforeunload');await d.dismiss();clearTimeout(timer);resolve();}catch(e){clearTimeout(timer);reject(e);}});});
    await Promise.all([warned,page.reload({waitUntil:'domcontentloaded'}).catch(()=>{})]);
    assert.equal(await body.inputValue(),'KEEP REPLY THROUGH BROWSER BACK','cancelled document reload preserves inline reply');
   }
   assert.equal(await iframe.evaluate(e=>e.style.pointerEvents),'auto','iframe is interactive outside dialogs');
   await reveal(page.getByRole('button',{name:'显示原邮件',exact:true}));await page.getByRole('button',{name:'显示原邮件',exact:true}).click();await page.getByRole('button',{name:'收起原邮件',exact:true}).click();
   await back();await page.getByRole('alertdialog').waitFor();await semantic('放弃未保存的更改？',false,true).waitFor();await hash('/mail/m1');assert.equal(await iframe.evaluate(e=>e.style.pointerEvents),'none','dialog shields native HTML iframe');
   await page.getByRole('button',{name:'继续编辑',exact:true}).click();assert.equal(await body.inputValue(),'KEEP REPLY THROUGH BROWSER BACK');
   await back();await page.getByRole('button',{name:'放弃更改',exact:true}).click();await hash('/mail');await forward();await hash('/mail/m1');
   console.log(`CHECK ${width}: refresh and resume`);
   await page.reload();await login();await hash('/mail/m1');await semantic('ROUTE SUBJECT ONE').waitFor();
   assert.deepEqual(await page.evaluate(()=>Object.keys(localStorage).filter(k=>/token|auth|password/i.test(k))),[]);
   if(width===1440){
    await page.getByRole('button',{name:'账户与设置',exact:true}).last().click();await hash('/settings/accounts');
    await page.getByRole('button',{name:'添加邮箱',exact:true}).click();await hash('/settings/add');
    await back();await hash('/settings/accounts');
    await page.getByRole('button',{name:'系统 OAuth 设置',exact:true}).click();await hash('/settings/oauth');
    await semantic('演示环境 · 仅可查看配置状态。所有输入和保存均已禁用，请勿输入真实密钥。',false,true).waitFor();
    await back();await hash('/settings/accounts');await back();await hash('/mail/m1');
   }
   await page.evaluate(()=>{location.hash='/mail/missing';});await page.getByRole('button',{name:'加载失败，重试',exact:true}).waitFor();await hash('/mail/missing');
   assert.equal(errors.length,0,errors.join('\n'));
   } catch(e) { console.error('Route failure URL:',page.url());
    await page.screenshot({path:path.join(out,`failure-${width}.png`)}).catch(()=>{});
    fs.writeFileSync(path.join(out,`failure-${width}.html`),await page.content().catch(()=>''));
    fs.writeFileSync(path.join(out,`failure-${width}-aria.yml`),await page.locator('body').ariaSnapshot().catch(e=>String(e)));
    const dom=await page.evaluate(()=>{const nodes=[];const collect=root=>{nodes.push(...root.querySelectorAll('flt-semantics,[aria-label],input,textarea,iframe'));for(const el of root.querySelectorAll('*'))if(el.shadowRoot)collect(el.shadowRoot);};collect(document);return nodes.map(el=>({tag:el.tagName,role:el.getAttribute('role'),label:el.getAttribute('aria-label'),value:el.type==='password'?'[redacted]':el.value,text:el.textContent,rect:el.getBoundingClientRect().toJSON(),pointerEvents:getComputedStyle(el).pointerEvents,attributes:Object.fromEntries(Array.from(el.attributes).map(a=>[a.name,a.value]))}));}).catch(e=>String(e));
    fs.writeFileSync(path.join(out,`failure-${width}-diagnostics.json`),JSON.stringify({url:page.url(),errors,console:consoleLog,network,dom},null,2));
    throw e; } finally { await page.close(); }
  }
  console.log('PASS built Flutter routing/header/inline at desktop and mobile: deep link login, browser Back/Forward, dirty keep/discard, refresh resume, settings/add, unavailable mail, sandbox and native editable reply');
 }finally{await browser.close();server.close();}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
