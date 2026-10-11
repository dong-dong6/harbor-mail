const {JSDOM}=require('jsdom');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const dom=new JSDOM('<!doctype html><html><body></body></html>',{runScripts:'outside-only',url:'https://mail.example.invalid'});
dom.window.eval(fs.readFileSync(path.join(__dirname,'../web/mail_renderer.js'),'utf8'));
const render=dom.window.harborRenderMail;
const cases=[
 ['scripts', '<script>alert(1)</script><p onclick="alert(1)">safe</p>', s=>!s.includes('alert')&&s.includes('<p>safe</p>')],
 ['URLs', '<a href="javascript:alert(1)">x</a><a href="data:text/html,x">y</a><a href="https://example.com?a=1">read</a>',s=>!s.includes('javascript:')&&!s.includes('data:text')&&s.includes('noopener noreferrer')],
 ['remote images', '<img src="https://tracking.invalid/pixel" srcset="https://tracking.invalid/2x 2x"><video poster="https://tracking.invalid/poster"></video>',s=>!s.includes('src=')&&!s.includes('srcset')&&!s.includes('poster')],
 ['CSS', '<p style="color:red;position:fixed;background:url(https://tracking.invalid);width:50%;border-radius:24px">x</p>',s=>s.includes('color:red')&&s.includes('border-radius:24px')&&!s.includes('position:')&&!s.includes('url(')],
 ['active elements','<svg><a xlink:href="javascript:x">x</a></svg><iframe src="https://tracking.invalid"></iframe><form><input></form><object></object><base href="https://tracking.invalid"><meta http-equiv="refresh">',s=>!s.includes('<svg')&&!s.includes('<iframe')&&!s.includes('<form')&&!s.includes('<object')&&!s.includes('<base')&&!s.includes('refresh')],
 ['tables','<table width="600" bgcolor="#edf9df"><tr><td style="padding:24px">A</td><td>B</td></tr></table>',s=>s.includes('<table')&&s.includes('bgcolor="#edf9df"')&&s.includes('padding:24px')&&s.includes('<td>B</td>')],
 ['embedded images','<img src="cid:local" alt="diagram"><img src="data:image/svg+xml,x">',s=>s.includes('[diagram]')&&!s.includes('src=')],
 ['CSP','<p>hello</p>',s=>s.includes("script-src 'none'")&&s.includes("img-src 'none'")&&s.includes("form-action 'none'")],
 ['malformed nesting','<math><mtext><table><mglyph><style><!--</style><img title="--><img src=x onerror=alert(1)>">',s=>!s.includes('<math')&&!s.includes('onerror=')],
];
for(const [name,input,check] of cases){assert(check(render(input,false)),name);console.log('PASS '+name)}
const allowed=render('<img src="https://example.com/image" onerror="alert(1)"><img src="data:image/png;base64,x">',true);
assert(allowed.includes('src="https://example.com/image"'));assert(allowed.includes('referrerpolicy="no-referrer"'));assert(!allowed.includes('onerror'));assert(!allowed.includes('data:image'));
assert(!render('<img src="https://example.com/image">',false).includes('src='));
console.log('PASS explicit opt-in and reset');
console.log('10 sanitizer checks passed (DOM unit tests; not browser integration).');
