// history-probe-cdp.js — 真机验证 file:// 下的 hash 路由与**浏览器前进/后退**
//
// 为什么是它：check-page.js 只覆盖 JS 逻辑层 ✗；DSH Desktop.exe 是打包版，不接受外部 app 脚本 ✗。
// 本探针用 **真实 Edge/Chromium**（headless=new）+ **CDP**（零依赖：Node 24 自带 fetch / WebSocket）：
//   * 真窗口加载 `file:///…/overview.html` ✓
//   * **真鼠标事件**（Input.dispatchMouseEvent，按元素坐标）点导航按钮 ✓ —— 不是 JS .click() 糊弄
//   * **真浏览器历史**：Page.getNavigationHistory + Page.navigateToHistoryEntry（= 浏览器后退/前进按钮所做的事）✓
//   * 页面内 history.back()/forward() 也验证一遍 ✓
// 运行（由 PowerShell 用 ELECTRON_RUN_AS_NODE=1 当 Node 调起）：
//   node history-probe-cdp.js <输出json> <页面html> [edge路径] [端口]
// 退出码：0 全通过 ｜ 2 有失败 ｜ 1 探针异常

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const outFile = process.argv[2] || path.join(__dirname, '..', 'data', '_tmp', 'history-probe-cdp.json');
const pageFile = process.argv[3] || path.join(__dirname, '..', 'overview.html');
// 自己找浏览器（不依赖传参：Start-Process 不会给带空格的路径加引号 ✗）
const EDGE_CANDS = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  process.env.LOCALAPPDATA + '\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  process.env.LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe'
];
const edge = EDGE_CANDS.find((p) => { try { return fs.existsSync(p); } catch (e) { return false; } });
if (!edge) { fs.writeFileSync(outFile, JSON.stringify({ error: '找不到 Edge/Chrome', candidates: EDGE_CANDS }, null, 2), 'utf8'); process.exit(1); }
const port = Number(process.argv[4] || 9411);

const log = [];
const rec = (name, ok, detail) => log.push({ name: name, ok: !!ok, detail: String(detail === undefined ? '' : detail) });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
// 浏览器 profile 放**工作区内**（`data/_tmp`）：本工作区的硬规矩是"只在工作区里写文件"。
// 原版用 os.tmpdir() 会写到系统临时目录 ✗（2026-10-16 改为工作区内，并自动建目录）
const profile = path.join(__dirname, '..', 'data', '_tmp', 'history-probe-profile-' + port);
try { fs.mkdirSync(profile, { recursive: true }); } catch (e) { /* 已存在 */ }
const pageUrl = 'file:///' + path.resolve(pageFile).replace(/\\/g, '/');

let child = null, ws = null, msgId = 0;
const pending = new Map();

function send(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++msgId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id: id, method: method, params: params || {} }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error('CDP 超时: ' + method)); } }, 15000);
  });
}
async function evaluate(expr) {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error('页面 JS 抛错: ' + JSON.stringify(r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text));
  return r.result ? r.result.value : undefined;
}
async function realClickAt(x, y) {
  const base = { x: Math.round(x), y: Math.round(y), button: 'left', clickCount: 1, buttons: 1 };
  await send('Input.dispatchMouseEvent', Object.assign({ type: 'mouseMoved' }, base));
  await send('Input.dispatchMouseEvent', Object.assign({ type: 'mousePressed' }, base));
  await wait(40);
  await send('Input.dispatchMouseEvent', Object.assign({ type: 'mouseReleased' }, base));
}
async function historyList() {
  const r = await send('Page.getNavigationHistory');
  return r;
}
async function gotoEntry(entryId) { await send('Page.navigateToHistoryEntry', { entryId: entryId }); }

(async () => {
  try {
    child = spawn(edge, [
      '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
      '--remote-debugging-port=' + port, '--user-data-dir=' + profile,
      pageUrl
    ], { stdio: 'ignore', detached: false });

    // 等 CDP 起来
    let target = null;
    for (let i = 0; i < 60 && !target; i++) {
      await wait(500);
      try {
        const res = await fetch('http://127.0.0.1:' + port + '/json/list');
        const list = await res.json();
        target = list.find((t) => t.type === 'page' && /overview\.html/.test(t.url)) || list.find((t) => t.type === 'page');
      } catch (e) { /* 还没起来 */ }
    }
    if (!target) { rec('启动真 Edge 并连上 CDP', false, '60 次轮询未拿到页面目标'); throw new Error('no-target'); }
    rec('启动真 Edge 并连上 CDP', true, target.url.slice(0, 60));

    ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = (e) => rej(new Error('WS 连接失败')); });
    ws.onmessage = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && pending.has(m.id)) {
        const p = pending.get(m.id); pending.delete(m.id);
        if (m.error) p.reject(new Error(JSON.stringify(m.error))); else p.resolve(m.result);
      }
    };
    await send('Page.enable'); await send('Runtime.enable');
    await wait(800);

    rec('真机 file:// 加载成功', String(await evaluate('location.href')).startsWith('file://'), String(await evaluate('location.protocol')));
    // **早停护栏**（2026-10-16 实跑踩到）：若 URL 拼错（如传了相对路径 → file:///overview.html
    // → C:\overview.html 不存在），浏览器会停在 chrome-error 页；此时后面的断言会因为
    // "两边都空"而**假绿** ✗（实测 3 项 PASS 全是假的）→ 一旦不是目标页就立刻停，不给假结论 ✓
    const hrefNow = String(await evaluate('location.href'));
    // 浏览器会把中文路径**百分号编码**（file:///E:/%E5%B7%A5…）→ 两边都 decode 再比，
    // 否则会拿编码串去比原串 → 假 FAIL ✗（2026-10-16 实测踩到）
    const hrefBase = decodeURIComponent(hrefNow.replace(/#.*$/, ''));
    const wantBase = decodeURIComponent(pageUrl);
    if (hrefBase !== wantBase) {
      rec('加载到了目标页（不是错误页）', false, '实际=' + hrefNow + ' ｜ 期望=' + pageUrl);
      throw new Error('page-not-loaded:' + hrefNow);
    }
    rec('加载到了目标页', true, hrefBase.slice(-46));
    const h0 = await evaluate('location.hash');
    // 裸 URL（无 hash）是**刻意的**：页面不把裸 URL 规范化成 #/home —— 那会**多出一条历史记录**，
    // 用户按后退会"看起来没反应" ✗。所以判据是"初始**视图** = 总览"，而不是"hash 非空" ✓
    //（原版断言 hash 非空 → 误报；另外原注释说"file:// 没有 replaceState"，见第 7 项实测：不准确）
    const viewHomeCls = await evaluate(`(document.getElementById('view-home')||{className:''}).className`);
    rec('初始视图 = 总览（裸 URL 无 hash 也算通过）', /view on/.test(String(viewHomeCls)), 'hash="' + h0 + '" ｜ class=' + viewHomeCls);

    // 1) 真鼠标点导航按钮 → #/all
    const box = await evaluate(`(() => {
      const els = Array.from(document.querySelectorAll('a,button,[role="tab"],[data-route]'));
      const hit = els.find(e => /#\\/all\\b/.test(e.getAttribute('href') || e.getAttribute('data-route') || '') || /全部|归档|档案|All/i.test((e.textContent||'').trim()));
      if (!hit) return null;
      hit.scrollIntoView({ block: 'center' });
      const r = hit.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, label: ((hit.getAttribute('href') || hit.getAttribute('data-route') || hit.textContent) || '').trim().slice(0, 24) };
    })()`);
    if (box && typeof box.x === 'number') {
      await realClickAt(box.x, box.y);
      await wait(600);
    }
    const h1 = await evaluate('location.hash');
    const viewAllCls = await evaluate(`(document.getElementById('view-all')||{className:''}).className`);
    // 只验 hash 不够：hash 变了但视图没切（或其它的区还开着）也算坏 ✓（原版只看 hash）
    rec('真鼠标点击导航 → #/all 且视图真的切了', /#\/all\b/.test(h1) && /view on/.test(String(viewAllCls)),
      (box ? box.label : 'no-target') + ' → ' + h1 + ' ｜ class=' + viewAllCls);

    // 2) 真浏览器历史：后退（等价点浏览器后退按钮）
    let hist = await historyList();
    const idx1 = hist.currentIndex;
    rec('浏览器历史记录了这次导航', hist.entries.length >= 2 && idx1 >= 1, 'entries=' + hist.entries.length + ' index=' + idx1);
    if (idx1 >= 1) { await gotoEntry(hist.entries[idx1 - 1].id); await wait(700); }
    const h2 = await evaluate('location.hash');
    rec('浏览器后退 → 回到上一个视图', h2 === h0 || /#\/home\b/.test(h2), h1 + ' →(CDP back)→ ' + h2);

    // 3) 真浏览器历史：前进
    hist = await historyList();
    if (hist.currentIndex < hist.entries.length - 1) { await gotoEntry(hist.entries[hist.currentIndex + 1].id); await wait(700); }
    const h3 = await evaluate('location.hash');
    rec('浏览器前进 → 回到 #/all', /#\/all\b/.test(h3), h2 + ' →(CDP forward)→ ' + h3);

    // 4) 页面内 history.back()（脚本式）
    await evaluate('history.back()'); await wait(700);
    const h4 = await evaluate('location.hash');
    rec('页面内 history.back() 生效', h4 !== h3, h3 + ' →(history.back)→ ' + h4);
    await evaluate('history.forward()'); await wait(700);
    const h5 = await evaluate('location.hash');
    rec('页面内 history.forward() 生效', h5 === h3, h4 + ' →(history.forward)→ ' + h5);

    // 5) 筛选进 URL
    await evaluate(`location.hash = '#/all?tier=S';`); await wait(600);
    const h6 = await evaluate('location.hash');
    const bodyLen = await evaluate('document.body.innerText.length');
    rec('筛选写进 URL 且页面仍渲染', /tier=S/.test(h6) && Number(bodyLen) > 200, h6 + ' ｜ body ' + bodyLen + ' 字');

    // 6) hashchange 生效（等价分享链接）
    await evaluate(`location.hash = '#/picks';`); await wait(600);
    const h7 = await evaluate('location.hash');
    rec('直接改 hash 生效（#/picks）', /#\/picks\b/.test(h7), h7);

    // 7) **记录事实（不是断言）**：file:// 下"只改 hash"的 pushState 到底抛不抛。
    //    2026-10-16 实测 Edge 155.0.4283.60 headless：**不抛**（返回 ok）→ 旧说法「pushState 在
    //    file:// 一律抛 SecurityError」被推翻。这里永远记 PASS、把实测值写进 JSON —— 不能把一个
    //    **错误前提**做成断言（原版就是这么写的，于是"绿"取决于一个假命题 ✗）。换路径的情况**未实测** ✓
    const ps = await evaluate(`(() => { try { history.pushState({}, '', '#/probe'); return 'ok'; } catch (e) { return 'threw:' + e.name; } })()`);
    rec('【记录事实·非断言】file:// 下 hash-only pushState：' + ps + '（换路径未实测）', true, ps);

    // 8) 连续后退到底不崩
    let err = '';
    try { for (let i = 0; i < 4; i++) { await evaluate('history.back()'); await wait(350); } } catch (e) { err = String((e && e.message) || e); }
    const stillLen = await evaluate('document.body.innerText.length');
    const hEnd = await evaluate('location.hash');
    rec('连续后退到底不崩、页面仍完整', !err && Number(stillLen) > 200, 'hash=' + hEnd + ' ｜ body ' + stillLen + ' 字' + (err ? ' ｜ err=' + err : ''));

    const failed = log.filter((x) => !x.ok);
    fs.writeFileSync(outFile, JSON.stringify({
      page: pageUrl, at: new Date().toISOString(),
      browser: 'Edge/Chromium (CDP) ｜ ' + edge,
      passed: log.length - failed.length, failed: failed.length, results: log
    }, null, 2), 'utf8');
    try { await send('Browser.close'); } catch (e) { /* ignore */ }
    // 收尾：等真浏览器退干净、杀掉残留子进程、**删掉本次的临时 profile** ✓
    // （原来只 Browser.close ⇒ `data/_tmp/history-probe-profile-<port>` 会一直攒着 ✗ 2026-10-17 修）
    await wait(600);
    try { if (child) child.kill(); } catch (e) { /* ignore */ }
    // Edge 退出后仍会短暂占用 profile 里的文件 ⇒ **重试删除** ✓
    // （实测：不等就删会 EBUSY 被 catch 静默吞掉 ✗，一次跑就留下 23.7 MB / 469 文件）
    for (let t = 0; t < 12; t++) {
      try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); break; }
      catch (e) { await wait(300); }
    }
    process.exit(failed.length ? 2 : 0);
  } catch (e) {
    try { fs.writeFileSync(outFile, JSON.stringify({ error: String((e && e.stack) || e), results: log }, null, 2), 'utf8'); } catch (_) {}
    try { if (ws) ws.close(); } catch (_) {}
    try { if (child) child.kill(); } catch (_) {}
    try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 300 }); } catch (_) {}   // 连不上浏览器时也清掉空 profile ✓
    process.exit(1);
  }
})();
