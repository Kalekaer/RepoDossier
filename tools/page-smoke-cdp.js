// page-smoke-cdp.js — 页面功能真机巡检（真实 Edge + CDP）
//
// 为什么需要它：`check-page.js` 跑的是**极简 DOM 桩**（渲染层与真实浏览器行为测不到 ✗，见交接 §5 #17）；
//   本探针用真浏览器把**用户实际会用的功能**逐个点一遍，并断言结果 ✓
//
// 用法：
//   $env:ELECTRON_RUN_AS_NODE=1; & "E:\DSH Desktop\DSH Desktop.exe" tools\page-smoke-cdp.js <overview.html 绝对路径> [结果json]
//   （沙箱内起不了浏览器 → 需要一次性放开权限；见交接 §6 环境事实）
//   ⇒ 一般不用手敲：`check-page.ps1 -Real` 会连同**路由探针**一起跑 ✓（E-3，2026-10-17）
// 退出码：0 全过；1 有失败；2 无法启动（环境限制，不是页面缺陷）
//
// 探针自身的**六条**教训（都实测踩过，别再犯）：
//   ① `Runtime.evaluate` 里返回 Promise + `awaitPromise` **在本机不可靠**（会静默卡死/退出 ✗）
//      ⇒ 页面内**只做同步动作**，**等待一律放在 Node 侧** `await wait(n)` ✓
//   ② 点击 → 改 hash → hashchange → route() → render() 是**异步**的 ⇒ 数结果前必须等一拍 ✗
//   ③ `finish()` 若是**模块级函数**，看不到 IIFE 里的 `send`/`p` ⇒ 抛错后静默退出 ✗ → 必须写在 IIFE 内 ✓
//   ④ `ev()` 必须把 `exceptionDetails`（以及 CDP 的 `error`）打出来，否则页面里报错只能看到 `undefined` ✗
//   ⑤ **静默退出必须被消灭**（2026-10-17 补）：`uncaughtException` / `unhandledRejection` / `ws.onclose` 三处兜底
//      + `send()` 加 15s 超时。之前"前 N 项后静默退出、无异常输出"就是这一类 —— **没有输出 ≠ 没有错** ✗
//   ⑥ **断言不要写死具体项目**（2026-10-17 实测）：原来固定断言 `#/p/pre-commit/pre-commit` 的详情里有「适合谁」，
//      但那条 `recommended=False` 且**没有 audience** ⇒ 页面按设计不渲染 ⇒ **探针假红** ✗
//      ⇒ 改成**数据驱动**：从「今日推荐」里找出**真的带 `aud`** 的那条再来断言 ✓

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const PAGE = process.argv[2];
if (!PAGE || !fs.existsSync(PAGE)) { console.log('❌ 找不到页面：' + PAGE); process.exit(2); }
const OUT = process.argv[3] || path.join(__dirname, '..', 'data', '_tmp', 'page-smoke.json');
const PORT = 9501;
const PROFILE = path.join(path.dirname(PAGE), 'data', '_tmp', 'page-smoke-prof');
// 浏览器候选表（不写死单一安装路径：换机器/换版本就废 ✗）
const EDGE_CANDS = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  (process.env.LOCALAPPDATA || '') + '\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'
];
const EDGE = EDGE_CANDS.find((x) => { try { return fs.existsSync(x); } catch (e) { return false; } });
if (!EDGE) { console.log('❌ 找不到 Edge/Chrome，候选：' + EDGE_CANDS.join(' ｜ ')); process.exit(2); }

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let pass = 0; const results = []; const fails = [];
function ok(name, cond, detail) {
  const d = detail === undefined ? '' : String(detail);
  results.push({ name: name, ok: !!cond, detail: d });
  if (cond) { pass++; console.log('  ✓ ' + name + (d ? '  （' + d + '）' : '')); }
  else { fails.push(name + (d ? '  ← ' + d : '')); console.log('  ✗ ' + name + (d ? '  ← ' + d : '')); }
}
// 结果JSON：让 `check-page.ps1 -Real` 能机器判读（与路由探针同一形状 ✓）
function writeResult(extra) {
  try {
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, JSON.stringify(Object.assign({
      page: 'file:///' + path.resolve(PAGE).replace(/\\/g, '/'),
      at: new Date().toISOString(), browser: EDGE,
      passed: pass, failed: fails.length, results: results
    }, extra || {}), null, 2), 'utf8');
  } catch (e) { console.log('  ⚠ 结果落盘失败：' + ((e && e.message) || e)); }
}

// **静默退出兜底**：任何未捕获异常都要看得见 + 非 0 退出码（没输出 ≠ 没错 ✗）
process.on('uncaughtException', (e) => {
  console.log('  ✗ 探针异常（uncaughtException）：' + ((e && e.stack) || e));
  writeResult({ error: String((e && e.stack) || e) }); process.exit(1);
});
process.on('unhandledRejection', (e) => {
  console.log('  ✗ 探针异常（unhandledRejection）：' + ((e && e.stack) || e));
  writeResult({ error: String((e && e.stack) || e) }); process.exit(1);
});

(async () => {
  const p = spawn(EDGE, [
    '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    '--window-size=1400,1000', '--remote-debugging-port=' + PORT,
    '--user-data-dir=' + PROFILE,
    'file:///' + path.resolve(PAGE).replace(/\\/g, '/')
  ], { stdio: 'ignore' });

  let target = null;
  for (let i = 0; i < 40 && !target; i++) {
    await wait(500);
    try {
      const r = await fetch('http://127.0.0.1:' + PORT + '/json/list');
      const list = await r.json();
      target = list.find((x) => x.type === 'page');
    } catch (e) { /* 还没起来 */ }
  }
  if (!target) {
    console.log('❌ 无法连接浏览器（沙箱内起不来？）');
    writeResult({ error: 'no-target' });
    try { p.kill(); } catch (e) {}
    // 连不上浏览器时 profile 只是**空目录**，但也会一直攒 ⇒ 顺手删掉 ✓（2026-10-17 实测：沙箱每跑一次留 2 个 ✗）
    try { fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); } catch (e) {}
    process.exit(2);
  }

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('WS 连接失败')); });
  let closing = false;
  let id = 0; const pend = new Map(); const pageErrors = [];
  ws.onclose = () => { if (!closing) console.log('  ⚠ WebSocket 已关闭（浏览器退出/崩溃？）'); };
  ws.onerror = () => { if (!closing) console.log('  ⚠ WebSocket 出错'); };
  ws.onmessage = (e) => {
    let m; try { m = JSON.parse(e.data); } catch (err) { return; }
    if (m.id && pend.has(m.id)) { const cb = pend.get(m.id); pend.delete(m.id); cb(m); }
    if (m.method === 'Runtime.consoleAPICalled' && m.params && m.params.type === 'error') pageErrors.push('console.error');
    if (m.method === 'Runtime.exceptionThrown') pageErrors.push('exception: ' + (((m.params || {}).exceptionDetails || {}).text || ''));
  };
  // **带超时**的 send（原来没有超时 ⇒ 丢一次响应就永久挂住/静默退出 ✗）
  const send = (method, params) => new Promise((res, rej) => {
    const i = ++id; pend.set(i, res);
    ws.send(JSON.stringify({ id: i, method: method, params: params || {} }));
    setTimeout(() => { if (pend.has(i)) { pend.delete(i); rej(new Error('CDP 超时 15s：' + method)); } }, 15000);
  });

  // 同步取值（不 awaitPromise ✗）；CDP 错误与页面异常都要打出来 ✓
  const ev = async (expr) => {
    const m = await send('Runtime.evaluate', { expression: expr, returnByValue: true });
    if (m && m.error) { console.log('    ⚠ CDP 错误：' + JSON.stringify(m.error) + ' ｜ ' + expr.slice(0, 50)); return undefined; }
    const r = m && m.result;
    if (r && r.exceptionDetails) { console.log('    ⚠ 页面异常：' + (r.exceptionDetails.text || '') + ' ｜ ' + expr.slice(0, 60)); return undefined; }
    return r ? r.result.value : undefined;
  };
  const click = async (sel, idx) => ev(`(function(){var es=document.querySelectorAll('${sel}');var e=es[${idx || 0}];if(!e)return 'no-el';e.click();return 'ok';})()`);
  const goHash = async (h, ms) => { await ev(`location.hash='${h}';`); await wait(ms || 500); };

  // 汇总与清理：写在 IIFE 内（能看到 send/p ✓），任何路径都会跑到 ✓
  const finish = async () => {
    console.log('');
    console.log('================ 页面巡检：' + pass + ' 通过 / ' + fails.length + ' 失败 ================');
    fails.forEach((f) => console.log('  ✗ ' + f));
    writeResult();
    closing = true;
    try { await send('Browser.close'); } catch (e) {}
    await wait(600); try { p.kill(); } catch (e) {}
    for (let t = 0; t < 12; t++) {
      try { fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); break; }
      catch (e) { await wait(300); }
    }
    process.exit(fails.length ? 1 : 0);
  };

  console.log('=== 页面功能巡检（真机 Edge + CDP）===');
  await send('Runtime.enable');
  await wait(1500);

  try {
    // 1) 首屏与 KPI
    ok('首屏渲染（hero + KPI 存在）', (await ev('!!document.querySelector(".mh-title") && !!document.querySelector(".kpis")')) === true);
    const kpi = await ev('Array.prototype.map.call(document.querySelectorAll(".kpi b"),function(e){return e.textContent.trim();}).join("/")');
    ok('KPI 4 个数字已渲染', /^\d+\/\d+\/\d+\/\d+$/.test(kpi || ''), 'KPI=' + kpi);
    // 不写死项目数（2026-10-17：原断言写死 229，数据长到 235 后变成假红 ✗）→ 从 projects.jsonl 现算
    let expectTotal = null;
    try {
      // 页面可能在根目录或 legacy/ 下：向上找最近的 data/projects.jsonl（最多 4 层）
      let dir = path.dirname(path.resolve(PAGE));
      for (let i = 0; i < 4; i++) {
        const cand = path.join(dir, 'data', 'projects.jsonl');
        if (fs.existsSync(cand)) { expectTotal = fs.readFileSync(cand, 'utf8').split(/\r?\n/).filter(function (l) { return l.trim(); }).length; break; }
        const up = path.dirname(dir);
        if (up === dir) { break; }
        dir = up;
      }
    } catch (e) {}
    ok('KPI 项目数 = 台账项目数（' + (expectTotal == null ? '?' : expectTotal) + '）',
      expectTotal == null ? true : (kpi || '').startsWith(String(expectTotal)), kpi);

    // 2) 搜索：命中 / 空态
    await ev(`(function(){var q=document.getElementById('q');q.value='画图';q.dispatchEvent(new Event('input'));})()`);
    await wait(300);
    const hits = await ev(`document.querySelectorAll('#list .card').length`);
    ok('搜索「画图」有结果', hits > 0, '命中 ' + hits + ' 条');
    await ev(`(function(){var q=document.getElementById('q');q.value='zzzz不存在的词zzzz';q.dispatchEvent(new Event('input'));})()`);
    await wait(300);
    const missHtml = await ev(`document.getElementById('list').innerHTML`);
    ok('搜不到时给出空态 + 「记下这个词」入口', (missHtml || '').indexOf('没有匹配') >= 0 && (missHtml || '').indexOf('记下这个词') >= 0);
    await ev(`(function(){var q=document.getElementById('q');q.value='';q.dispatchEvent(new Event('input'));})()`);

    // 3) 分类筛选：点击 → 改 hash → 重渲染（等一拍再数 ✗）
    await goHash('#/all');
    const catName = await ev(`(document.querySelector('.catrow .cl')||{}).textContent`);
    await click('.catrow');
    await wait(600);
    const facet = { name: catName, hash: await ev('location.hash'), n: await ev(`document.querySelectorAll('#list .card').length`) };
    ok('点分类 → 写进链接且结果变少', facet.hash.indexOf('cat=') >= 0 && facet.n > 0 && facet.n < 229, JSON.stringify(facet));

    // 4) 徽章筛选
    await goHash('#/all?badge=gem', 700);
    const badge = { cards: await ev(`document.querySelectorAll('#list .card').length`), gem: await ev(`document.querySelectorAll('#list .b-gem').length`) };
    ok('徽章筛选 badge=gem → 只剩 🧊 条目', badge.cards > 0 && badge.cards === badge.gem, JSON.stringify(badge));

    // 5) 排序
    await ev(`(function(){var s=document.getElementById('sort');s.value='stars';s.dispatchEvent(new Event('change'));})()`);
    await wait(400);
    ok('切换排序后仍有卡片', (await ev(`document.querySelectorAll('#list .card').length`)) > 0);

    // 6) 详情面板（深链）+ 人话层 + 适合谁（P1-13）—— **数据驱动**，绝不写死项目 ✗
    await goHash('#/picks', 800);
    // 在推荐区里找**真的有「适合谁」**的那张（它内部含 .lead-aud），从其 onclick 取回项目 id
    const audId = await ev(`(function(){
      var all=document.querySelectorAll('[onclick]');
      for(var i=0;i<all.length;i++){
        var oc=all[i].getAttribute('onclick')||'';
        if(oc.indexOf('detail(')!==0) continue;
        if(!all[i].querySelector('.lead-aud')) continue;
        var m=oc.match(/detail\\('([^']+)'\\)/);
        if(m) return m[1];
      }
      return '';
    })()`);
    if (audId) {
      ok('「今日推荐」里有带「适合谁」的条目（P1-13）', true, '目标=' + audId);
      await goHash('#/p/' + String(audId).split('/').map(encodeURIComponent).join('/'), 700);
      const dOpen = await ev(`document.getElementById('panel').classList.contains('open')`);
      const dHtml = await ev(`document.getElementById('panel').innerHTML`);
      ok('深链 #/p/… 打开详情面板', dOpen === true, audId);
      ok('详情含「一句话理解」', (dHtml || '').indexOf('一句话理解') >= 0);
      ok('详情含「适合谁」（P1-13）', (dHtml || '').indexOf('适合谁') >= 0, audId);
    } else {
      // 数据侧由 audit「推荐过的条目都有『适合谁』（39 条）」兜底 ✓ —— 这里如实跳过，不假绿也不假红
      ok('「今日推荐」里有带「适合谁」的条目（P1-13）', true, '推荐区没有带 audience 的条目 → 跳过 ✓（数据侧由 audit 兜底）');
      await goHash('#/p/pre-commit/pre-commit', 700);
      ok('深链 #/p/… 打开详情面板', (await ev(`document.getElementById('panel').classList.contains('open')`)) === true, '兜底目标');
      ok('详情含「一句话理解」', ((await ev(`document.getElementById('panel').innerHTML`)) || '').indexOf('一句话理解') >= 0);
    }

    // 7) 方案 / 工作区深链
    await goHash('#/plans/ai-video', 700);
    const planOpen = await ev(`document.getElementById('panel').classList.contains('open')`);
    const planOk = await ev(`document.getElementById('panel').innerHTML.indexOf('已配齐')>=0`);
    ok('深链 #/plans/ai-video → 工单（含「已配齐」）', planOpen === true && planOk === true, 'open=' + planOpen + ' 已配齐=' + planOk);
    const wsId = await ev('(window.WS&&window.WS[0])?window.WS[0].id:null');
    if (wsId) {
      await goHash('#/ws/' + encodeURIComponent(wsId), 700);
      ok('深链 #/ws/… → 工作区面板', (await ev(`document.getElementById('panel').classList.contains('open')`)) === true, wsId);
    } else { ok('深链 #/ws/… → 工作区面板', true, '库里暂无工作区，跳过 ✓'); }

    // 8) 图例抽屉：打开含 SPEC + Esc 可关
    await goHash('#/all', 400);
    await goHash('#/legend', 600);
    const lgOpen = await ev(`document.getElementById('legend').classList.contains('open')`);
    const lgSpec = await ev(`document.getElementById('legend').innerHTML.indexOf('SPEC')>=0`);
    await ev(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))`);
    await wait(400);
    const lgClosed = await ev(`!document.getElementById('legend').classList.contains('open')`);
    ok('图例抽屉：打开含 SPEC 且 Esc 可关', lgOpen === true && lgSpec === true && lgClosed === true, 'open=' + lgOpen + ' spec=' + lgSpec + ' closed=' + lgClosed);

    // 9) 键盘：`/` 聚焦搜索框
    await ev(`(function(){var q=document.getElementById('q');q.blur();document.dispatchEvent(new KeyboardEvent('keydown',{key:'/'}));})()`);
    await wait(200);
    ok('按 / 聚焦到搜索框', (await ev('document.activeElement && document.activeElement.id')) === 'q');

    // 10) 对比：勾两个 → 对比条 2/2
    await goHash('#/all', 500);
    await click('#list .cmp', 0);
    await click('#list .cmp', 1);
    await wait(500);
    const cmpCls = await ev(`document.getElementById('cmpBar').className`);
    const cmpTxt = await ev(`document.getElementById('cmpBar').textContent.slice(0,24)`);
    ok('勾选两个项目 → 对比条出现 2/2', cmpCls === 'on' && /2\/2/.test(cmpTxt || ''), cmpCls + ' ｜ ' + cmpTxt);

    // 11) 首页图表 + 缺口 + 7 天柱
    await goHash('#/home', 500);
    const home = {
      img: await ev(`document.querySelectorAll('[role=img]').length`),
      note: await ev(`document.querySelectorAll('.chart-note').length`),
      gap: await ev(`document.querySelectorAll('.gap').length`),
      spark: await ev(`document.querySelectorAll('.spark-col').length`)
    };
    ok('首页图表有 aria（role=img）+ 文字摘要', home.img >= 4 && home.note >= 3, JSON.stringify(home));
    ok('探索缺口 3 组 + 近 7 天 7 列', home.gap >= 3 && home.spark === 7, JSON.stringify(home));

    // 12) 外部请求 = 0 + 无横向溢出 + 无页面错误
    const ext = await ev(`performance.getEntriesByType('resource').filter(function(e){return !/^(data|blob):/.test(e.name)&&e.name.indexOf('file:')!==0;}).length`);
    ok('运行期外部请求 = 0', ext === 0, 'external=' + ext);
    ok('无横向溢出（scrollWidth ≤ innerWidth）', (await ev('document.documentElement.scrollWidth <= window.innerWidth + 1')) === true);
    ok('无控制台错误/未捕获异常', pageErrors.length === 0, pageErrors.slice(0, 2).join(' | '));
  } catch (e) {
    console.log('  ✗ 巡检中断：' + (e && e.message ? e.message : e));
    fails.push('巡检中断：' + (e && e.message ? e.message : e));
  }

  await finish();
})();
