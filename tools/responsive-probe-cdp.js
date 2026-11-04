// responsive-probe-cdp.js — 620 / 打印 / reduced-motion 三档真机验收（2026-10-20）
//
// 为什么：1440 与 390 已过；交接 §6 点名 620、打印、reduced-motion 还没逐页复验。
//   这三档的共同点是「CSS 媒体查询在起作用」，静态检查看不出来，只能真浏览器量。
//
// 用法：
//   $env:ELECTRON_RUN_AS_NODE='1'; & 'E:\DSH Desktop\DSH Desktop.exe' tools/responsive-probe-cdp.js
//   （需要一次性 danger-full-access）
// 退出码：0 全过；1 有失败；2 环境限制

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'data', '_tmp', 'responsive-probe.json');
const PORT = 9504;
const PROFILE = path.join(require('os').tmpdir(), 'dsh-resp-' + Date.now());
const EDGE = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  (process.env.LOCALAPPDATA || '') + '\\Microsoft\\Edge\\Application\\msedge.exe'
].find((p) => { try { return fs.existsSync(p); } catch (e) { return false; } });

const PAGES = [
  ['home', 'data/site/home-brutal-token.generated.html'],
  ['daily-22', 'data/site/daily-2026-10-22.generated.html'],
  ['daily-21', 'data/site/daily-2026-10-21.generated.html'],
  ['daily-20', 'data/site/daily-2026-10-20.generated.html'],
  ['daily-19', 'data/site/daily-2026-10-19.generated.html'],
  ['weekly', 'data/site/weekly-2026-10-18.generated.html'],
  ['library', 'data/site/library-notebook.generated.html'],
  ['plans', 'data/site/plans-shelf.generated.html']
];

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const fileUrl = (rel) => 'file:///' + path.join(ROOT, rel).replace(/\\/g, '/');
const results = [];
let pass = 0; const fails = [];
function ok(name, cond, detail) {
  results.push({ name, ok: !!cond, detail: detail == null ? '' : String(detail) });
  if (cond) { pass++; console.log('  ✓ ' + name + (detail ? '  （' + detail + '）' : '')); }
  else { fails.push(name + (detail ? '  ← ' + detail : '')); console.log('  ✗ ' + name + '  ← ' + detail); }
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
    '--window-size=1440,900', '--remote-debugging-port=' + PORT,
    '--user-data-dir=' + PROFILE,
    fileUrl(PAGES[0][1])
  ], { stdio: 'ignore' });

  let target = null;
  for (let i = 0; i < 40 && !target; i++) {
    await wait(500);
    try {
      const list = await (await fetch('http://127.0.0.1:' + PORT + '/json/list')).json();
      target = list.find((x) => x.type === 'page');
    } catch (e) {}
  }
  if (!target) {
    console.log('❌ 无法连接浏览器（沙箱内起不来？）');
    writeResult({ error: 'no-target' });
    try { p.kill(); } catch (e) {}
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
    setTimeout(() => { if (pend.has(i)) { pend.delete(i); rej(new Error('CDP 超时：' + method)); } }, 15000);
  });
  const ev = async (expr) => {
    const m = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
    if (m && m.error) return undefined;
    const r = m && m.result;
    if (r && r.exceptionDetails) { console.log('    ⚠ 页面表达式异常：' + (r.exceptionDetails.text || '')); return undefined; }
    return r ? r.result.value : undefined;
  };
  const metrics = () => ev(`(function(){
    var de=document.documentElement;
    var running=0;
    try { running=(document.getAnimations?document.getAnimations():[]).filter(function(a){return a.playState==='running'}).length; } catch(e){}
    var fold=document.querySelector('.foldbtn');
    return {
      overflow: de.scrollWidth - window.innerWidth,
      width: window.innerWidth,
      text: (document.body.innerText||'').length,
      running: running,
      fold: fold ? getComputedStyle(fold).display : 'none',
      spine: (function(){var s=document.querySelector('.spine');return s?getComputedStyle(s).display:'none'})()
    };
  })()`);

  const load = async (rel) => {
    pageErrors = [];
    await send('Page.navigate', { url: fileUrl(rel) });
    await wait(1500);
  };
  const setWidth = (w) => send('Emulation.setDeviceMetricsOverride', { width: w, height: 1000, deviceScaleFactor: 1, mobile: false });
  const setPrint = () => send('Emulation.setEmulatedMedia', { media: 'print', features: [] });
  const setScreen = (features) => send('Emulation.setEmulatedMedia', { media: 'screen', features: features || [] });
  const resetWidth = () => send('Emulation.clearDeviceMetricsOverride');

  await send('Page.enable');
  await send('Runtime.enable');
  await wait(1200);

  console.log('=== 620px（窄窗口）===');
  await setWidth(620);
  const m620 = {};
  for (const [name, rel] of PAGES) {
    await load(rel);
    const m = await metrics();
    m620[name] = m;
    if (!m) { ok(name + ' 620 可读', false); continue; }
    ok(name + ' 620 无横向溢出', m.overflow <= 2, 'overflow=' + m.overflow);
    ok(name + ' 620 有内容', m.text > 300, 'text=' + m.text);
    ok(name + ' 620 无控制台错误', pageErrors.length === 0, pageErrors.join(','));
  }

  console.log('=== 打印（media=print）===');
  await resetWidth();
  await setPrint();
  const mPrint = {};
  for (const [name, rel] of PAGES) {
    await load(rel);
    const m = await metrics();
    mPrint[name] = m;
    if (!m) { ok(name + ' 打印可读', false); continue; }
    ok(name + ' 打印无横向溢出', m.overflow <= 2, 'overflow=' + m.overflow);
    ok(name + ' 打印隐藏折叠按钮', m.fold === 'none', 'fold=' + m.fold);
    ok(name + ' 打印隐藏侧脊', m.spine === 'none', 'spine=' + m.spine);
  }

  console.log('=== reduced-motion ===');
  await setScreen([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
  const mRM = {};
  for (const [name, rel] of PAGES) {
    await load(rel);
    const m = await metrics();
    mRM[name] = m;
    if (!m) { ok(name + ' reduced-motion 可读', false); continue; }
    ok(name + ' reduced-motion 无运行中的动画', m.running === 0, 'running=' + m.running);
    ok(name + ' reduced-motion 无横向溢出', m.overflow <= 2, 'overflow=' + m.overflow);
  }

  writeResult({ m620, mPrint, mRM });
  console.log('');
  console.log('================ 620 / 打印 / reduced-motion：' + pass + ' 通过 / ' + fails.length + ' 失败 ================');
  fails.forEach((f) => console.log('  ✗ ' + f));
  closing = true;
  try { await send('Browser.close'); } catch (e) {}
  await wait(500); try { p.kill(); } catch (e) {}
  try { fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); } catch (e) {}
  process.exit(fails.length ? 1 : 0);
})();
