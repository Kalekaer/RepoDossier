// site-smoke-cdp.js — 新站点真机巡检（真实 Edge + CDP）
//
// 检查：根 shell 路由（home/daily C/all/plans）+ 4 个生成页的直接加载
//       + 控制台错误 + 横向溢出 + 基础渲染 + 页面性能指标
//
// 用法：
//   $env:ELECTRON_RUN_AS_NODE=0? 不需要；直接 node/Electron 都行：
//   node tools\site-smoke-cdp.js
//   （沙箱内起不了浏览器 → 需要一次性放开权限；check-page.ps1 -Real 已证明可跑）
// 退出码：0 全过；1 有失败；2 无法启动（环境限制，不是页面缺陷）

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'data', '_tmp', 'site-smoke-cdp.json');
const PORT = 9502;
const PROFILE = path.join(ROOT, 'data', '_tmp', 'dsh-site-smoke-' + Date.now());
const EDGE = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  (process.env.LOCALAPPDATA || '') + '\\Microsoft\\Edge\\Application\\msedge.exe'
].find((p) => { try { return fs.existsSync(p); } catch (e) { return false; } });

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const fileUrl = (rel) => 'file:///' + path.join(ROOT, rel).replace(/\\/g, '/');
const results = [];
let pass = 0; const fails = [];
function ok(name, cond, detail) {
  results.push({ name, ok: !!cond, detail: detail == null ? '' : String(detail) });
  if (cond) { pass++; console.log('  ✓ ' + name + (detail ? '  （' + detail + '）' : '')); }
  else { fails.push(name + (detail ? ' ｜ ' + detail : '')); console.log('  ✗ ' + name + (detail ? '  （' + detail + '）' : '')); }
}
function writeResult(extra) {
  try {
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, JSON.stringify(Object.assign({
      at: new Date().toISOString(), browser: EDGE, passed: pass, failed: fails.length, results
    }, extra || {}), null, 2), 'utf8');
  } catch (e) { console.log('  ⚠ 结果落盘失败：' + ((e && e.message) || e)); }
}
process.on('uncaughtException', (e) => { console.log('  ✗ 探针异常：' + ((e && e.stack) || e)); writeResult({ error: String(e) }); process.exit(1); });
process.on('unhandledRejection', (e) => { console.log('  ✗ 探针异常：' + ((e && e.stack) || e)); writeResult({ error: String(e) }); process.exit(1); });

(async () => {
  if (!EDGE) { console.log('❌ 找不到 Edge'); process.exit(2); }
  const p = spawn(EDGE, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--window-size=1400,2000', '--remote-debugging-port=' + PORT,
    '--user-data-dir=' + PROFILE,
    fileUrl('index.html')
  ], { stdio: 'ignore', windowsHide: true });

  let target = null;
  for (let i = 0; i < 40 && !target; i++) {
    await wait(500);
    try {
      const r = await fetch('http://127.0.0.1:' + PORT + '/json/list');
      const list = await r.json();
      target = list.find((x) => x.type === 'page');
    } catch (e) {}
  }
  if (!target) {
    console.log('❌ 无法连接浏览器（沙箱内起不来？）');
    writeResult({ error: 'no-target' });
    try { p.kill(); } catch (e) {}
    try { fs.rmSync(PROFILE, { recursive: true, force: true }); } catch (e) {}
    process.exit(2);
  }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('WS 连接失败')); });
  let closing = false, id = 0; const pend = new Map(); let pageErrors = [];
  ws.onclose = () => { if (!closing) console.log('  ⚠ WebSocket 已关闭'); };
  ws.onmessage = (e) => {
    let m; try { m = JSON.parse(e.data); } catch (err) { return; }
    if (m.id && pend.has(m.id)) { const cb = pend.get(m.id); pend.delete(m.id); cb(m); }
    if (m.method === 'Runtime.consoleAPICalled' && m.params && m.params.type === 'error') pageErrors.push('console.error');
    if (m.method === 'Runtime.exceptionThrown') pageErrors.push('exception:' + (((m.params || {}).exceptionDetails || {}).text || ''));
  };
  const send = (method, params) => new Promise((res, rej) => {
    const i = ++id; pend.set(i, res);
    ws.send(JSON.stringify({ id: i, method, params: params || {} }));
    setTimeout(() => { if (pend.has(i)) { pend.delete(i); rej(new Error('CDP 超时 15s：' + method)); } }, 15000);
  });
  const ev = async (expr) => {
    const m = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
    if (m && m.error) return undefined;
    const r = m && m.result;
    if (r && r.exceptionDetails) return undefined;
    return r ? r.result.value : undefined;
  };
  const evCtx = async (expr, contextId) => {
    const m = await send('Runtime.evaluate', { expression: expr, returnByValue: true, contextId });
    if (m && m.error) return undefined;
    const r = m && m.result;
    if (r && r.exceptionDetails) return undefined;
    return r ? r.result.value : undefined;
  };
  const load = async (url) => {
    pageErrors = [];
    await send('Page.navigate', { url });
    await wait(1200);
  };
  const metrics = async () => ev(`(function(){
    var n = performance.getEntriesByType('navigation')[0] || {};
    return {
      dcl: n.domContentLoadedEventEnd || 0,
      load: n.loadEventEnd || 0,
      transfer: n.transferSize || 0,
      resources: performance.getEntriesByType('resource').length,
      heap: (performance.memory && performance.memory.usedJSHeapSize) || null,
      nodes: document.querySelectorAll('[data-pid],.pcard').length,
      overflow: document.documentElement.scrollWidth - window.innerWidth,
      text: (document.body.innerText || '').length
    };
  })()`);
  const finish = async () => {
    console.log('');
    console.log('================ 新站点真机巡检：' + pass + ' 通过 / ' + fails.length + ' 失败 ================');
    fails.forEach((f) => console.log('  ✗ ' + f));
    writeResult();
    closing = true;
    try { await send('Browser.close'); } catch (e) {}
    await wait(600); try { p.kill(); } catch (e) {}
    try { fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); } catch (e) {}
    process.exit(fails.length ? 1 : 0);
  };

  await send('Page.enable');
  await send('Runtime.enable');
  await wait(1500);
  console.log('=== 根 shell 路由（真机）===');

  const shell = await ev(`(function(){var f=document.querySelector('#view');return {iframe:!!f,src:f?f.getAttribute('src'):'',title:document.title}})()`);
  ok('shell 首屏有 iframe 且指向首页', shell && shell.iframe && /home-brutal-token/.test(shell.src || ''), shell && shell.src);
  const routes = [
    ['#/daily', /daily-layout-c/],
    ['#/all', /library-notebook/],
    ['#/plans', /plans-shelf/]
  ];
  for (const [hash, re] of routes) {
    await ev(`location.hash='${hash}'`);
    await wait(900);
    const src = await ev(`(document.querySelector('#view')||{}).getAttribute?document.querySelector('#view').getAttribute('src'):''`);
    ok('shell 路由 ' + hash + ' → 对应页面', re.test(src || ''), src);
  }

  /* 首页四个入口必须能真实点击；只测 location.hash 会漏掉 postMessage 路由。
     file:// 下父页拿不到 iframe document，用 CDP 在 iframe 的隔离世界执行 click。 */
  console.log('=== 首页菜单真实点击 ===');
  const menu = [
    ['#/daily', 'daily', /daily-layout-c/],
    ['#/all', 'all', /library-notebook/],
    ['#/plans', 'plans', /plans-shelf/],
    ['#/legend', 'legend', /home-brutal-token/]
  ];
  for (const [href, name, re] of menu) {
    await ev(`location.hash='#/home'`);
    await wait(700);
    let clicked = false;
    try {
      const ft = await send('Page.getFrameTree');
      const child = ft.result.frameTree.childFrames[0].frame;
      const iw = await send('Page.createIsolatedWorld', { frameId: child.id, worldName: 'menu-smoke', grantUniveralAccess: true });
      const r = await evCtx(`(function(){var a=document.querySelector('a[href="${href}"]');if(!a)return false;a.click();return true;})()`, iw.result.executionContextId);
      clicked = r === true;
    } catch (e) { clicked = false; }
    await wait(800);
    const st = await ev(`(function(){var f=document.querySelector('#view');return {hash:location.hash,src:f?f.getAttribute('src'):'',legend:document.getElementById('legend').classList.contains('on')}})()`);
    const routeOk = name === 'legend' ? (st && st.legend) : !!(st && re.test(st.src || ''));
    ok('首页菜单 ' + href + ' 可点击并进入', clicked && routeOk, st && (st.hash + ' → ' + st.src));
  }

  console.log('=== 直接加载 4 个生成页（真机 + 性能）===');
  const pages = [
    ['home', 'data/site/home-brutal-token.generated.html', /home-brutal-token/],
    ['library', 'data/site/library-notebook.generated.html', /library-notebook/],
    ['daily-c', 'data/site/daily-layout-c-finsara.generated.html', /daily-layout-c/],
    ['plans', 'data/site/plans-shelf.generated.html', /plans-shelf/]
  ];
  const perf = {};
  const weeklyFile = fs.readdirSync(path.join(ROOT, 'data', 'site')).filter(n => /^weekly-\d{4}-\d{2}-\d{2}\.generated\.html$/.test(n)).sort().pop();
  if (weeklyFile) pages.push(['weekly', 'data/site/' + weeklyFile, /weekly-/]);
  for (const [name, rel, re] of pages) {
    await load(fileUrl(rel));
    const url = await ev('location.href');
    ok(name + ' 加载到目标页', re.test(url || ''), url && url.split('/').pop());
    const m = await metrics();
    perf[name] = m;
    if (name === 'library') {
      const dbg = await ev(`(function(){var w=document.getElementById('wSections');return {ready:document.readyState,cards:document.querySelectorAll('.pcard').length,ws:w?w.innerHTML.length:-1,proj:(typeof PROJ!=='undefined'?PROJ.length:0)}})()`);
      ok('library 首屏卡片 ≥ 3', dbg && dbg.cards >= 3, dbg && dbg.cards);
      ok('library PROJ ≥ 256', dbg && dbg.proj >= 256, dbg && dbg.proj);
    }
    ok(name + ' 无横向溢出', m && m.overflow <= 2, m && ('overflow=' + m.overflow));
    ok(name + ' 无控制台错误', pageErrors.length === 0, pageErrors.join(','));
    if (name === 'daily-c' || name === 'daily-d') ok(name + ' 有卡片/数据', m && m.text > 1000, m && ('text=' + m.text));
    if (name === 'daily-c') {
      const weeklyEntry = await ev(`(function(){var date=String(D.iso||D.date||'').slice(0,10);return {date:date,monday:new Date(date+'T00:00:00Z').getUTCDay()===1,entry:!!document.querySelector('.weekly-entry')}})()`);
      ok('日报仅周一显示周报入口', weeklyEntry && weeklyEntry.entry === weeklyEntry.monday, JSON.stringify(weeklyEntry));
      const cap = await ev(`(function(){return {b:document.querySelectorAll('#bGrid .b-cell:not(.b-blank)').length,cd:document.querySelectorAll('#cdBand .cd-row').length,mem:document.querySelectorAll('#mem .mem-row').length,fold:!!document.querySelector('#bFoldBtn')||!!document.querySelector('#cdFoldBtn')||!!document.querySelector('#memFoldBtn')}})()`);
      ok('daily-c B 展示 ≤ 4', cap && cap.b <= 4, cap && ('b=' + cap.b));
      ok('daily-c C/D 展示 ≤ 8', cap && cap.cd <= 8, cap && ('cd=' + cap.cd));
      ok('daily-c 老朋友展示 ≤ 5', cap && cap.mem <= 5, cap && ('mem=' + cap.mem));
    }
    if (name === 'home') ok('home 有首屏内容', m && m.text > 500, m && ('text=' + m.text));
    if (name === 'plans') ok('plans 有内容', m && m.text > 300, m && ('text=' + m.text));
    if (name === 'weekly') {
      const weekly = await ev(`(function(){return {period:D.period,dates:D.dates,number:document.querySelector('h1 .no').textContent.trim(),text:document.body.innerText,stars:(D.starTop||[]).every(function(x){return Number.isFinite(x.delta)})}})()`);
      ok('周报日期/封面期号一致', weekly && weekly.period && weekly.number === weekly.period.issue.slice(1) && weekly.text.includes(weekly.period.start) && weekly.text.includes(weekly.period.end));
      ok('周报周增值完整且无 NaN', weekly && weekly.stars && !weekly.text.includes('NaN'));
      const shot = await send('Page.captureScreenshot', {format:'png'});
      if (shot.result && shot.result.data) fs.writeFileSync(path.join(ROOT, 'data', '_tmp', 'weekly-render.png'), Buffer.from(shot.result.data, 'base64'));
    }
  }
  console.log('');
  console.log('  页面性能（file://，冷加载一次）');
  for (const [name] of pages) {
    const m = perf[name] || {};
    console.log('   ' + name.padEnd(8) + ' DCL=' + Math.round(m.dcl || 0) + 'ms  load=' + Math.round(m.load || 0) + 'ms  heap=' + (m.heap ? Math.round(m.heap / 1048576) + 'MB' : 'n/a') + '  resources=' + (m.resources || 0) + '  cards=' + (m.nodes || 0));
  }
  writeResult({ perf });
  await finish();
})();
