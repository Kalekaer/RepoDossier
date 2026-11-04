// history-probe.js — 真机（真 Chromium 窗口）验证 file:// 下的 hash 路由与前进/后退
//
// 为什么需要它：check-page.js 是 **JS 逻辑层**（Node/Electron-as-Node 跑，没有真浏览器 ✗），
//   所以「点按钮 → 浏览器后退/前进」这条链路**从未在真机验证过** ✗。
// 本探针用 DSH 自带的 Electron（**真 Chromium**）以 `file://` 打开 overview.html，
//   真的点 DOM、真的调 `webContents.navigationHistory.goBack()/goForward()`，
//   把结果写进 JSON 文件（本环境标准流捕获不可靠 ✗ → 一律落文件 ✓）。
//
// 用法（**不要**设 ELECTRON_RUN_AS_NODE ✗ —— 那会退化成 Node，就不是真浏览器了）：
//   & "E:\DSH Desktop\DSH Desktop.exe" ".\tools\history-probe.js" "<输出json>" "<页面html>"
// 退出码：0 = 全部通过 ｜ 2 = 有失败项 ｜ 1 = 探针自身异常

const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const outFile = process.argv[2] || path.join(__dirname, '..', 'data', '_tmp', 'history-probe.json');
const pageFile = process.argv[3] || path.join(__dirname, '..', 'overview.html');
// Electron 默认把 profile 写进 %APPDATA%（**工作区外** ✗ —— 本工作区硬规矩是只写工作区）
// → 显式把 userData 指到 data/_tmp ✓（必须在 app ready 之前设）
try { app.setPath('userData', path.join(__dirname, '..', 'data', '_tmp', 'electron-probe-profile')); } catch (e) { /* ignore */ }
const log = [];
const rec = (name, ok, detail) => log.push({ name: name, ok: !!ok, detail: String(detail === undefined ? '' : detail) });
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

app.on('window-all-closed', () => app.quit());

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    width: 1366,
    height: 900,
    webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: false }
  });
  // 用绝对路径：相对路径会拼成 `file:///overview.html`（= C:\overview.html，不存在）→ 停在错误页 ✗
  // （2026-10-16 实跑踩到；CDP 版同样修过）
  const loadUrl = 'file:///' + path.resolve(pageFile).replace(/\\/g, '/');
  await win.loadURL(loadUrl);
  const run = (js) => win.webContents.executeJavaScript(js, true);
  const back = () => (win.webContents.navigationHistory ? win.webContents.navigationHistory.goBack() : win.webContents.goBack());
  const fwd = () => (win.webContents.navigationHistory ? win.webContents.navigationHistory.goForward() : win.webContents.goForward());
  await wait(800);

  rec('页面以 file:// 真机加载成功', win.webContents.getURL().startsWith('file://'), win.webContents.getURL());
  const h0 = await run('location.hash');
  // 裸 URL（无 hash）是**刻意的**（页面不规范化 hash：那会多一条历史记录）→ 判据看**视图** ✓
  const v0 = await run(`(document.getElementById('view-home')||{className:''}).className`);
  rec('初始视图 = 总览（裸 URL 无 hash 也算通过）', /view on/.test(String(v0)), 'hash="' + h0 + '" ｜ class=' + v0);

  // 1) 真点导航按钮 → 切到 #/all
  const clickRes = await run(`(() => {
    const els = Array.from(document.querySelectorAll('a,button,[role="tab"],[data-route]'));
    const hit = els.find(e => /#\\/all\\b/.test(e.getAttribute('href') || e.getAttribute('data-route') || '') || /全部|归档|档案|All/i.test((e.textContent || '').trim()));
    if (!hit) return 'no-target';
    hit.click();
    return 'clicked:' + ((hit.getAttribute('href') || hit.getAttribute('data-route') || hit.textContent) || '').trim().slice(0, 24);
  })()`);
  await wait(500);
  const h1 = await run('location.hash');
  rec('点导航按钮 → hash 变到 #/all（真点击）', /#\/all\b/.test(h1), clickRes + ' → ' + h1);

  // 2) 真机浏览器后退 → 应回到上一个视图
  back();
  await wait(600);
  const h2 = await run('location.hash');
  rec('浏览器后退 → 回到上一个视图（真机 history）', h2 === h0 || /#\/home\b/.test(h2), h1 + ' →(back)→ ' + h2);

  // 3) 真机浏览器前进 → 应回到 #/all
  fwd();
  await wait(600);
  const h3 = await run('location.hash');
  rec('浏览器前进 → 回到 #/all（真机 history）', /#\/all\b/.test(h3), h2 + ' →(forward)→ ' + h3);

  // 4) 筛选状态进 URL
  await run(`location.hash = '#/all?tier=S';`);
  await wait(500);
  const h4 = await run('location.hash');
  const bodyLen = await run('document.body.innerText.length');
  rec('筛选写进 URL 且页面仍渲染', /tier=S/.test(h4) && Number(bodyLen) > 200, h4 + ' ｜ body 文本 ' + bodyLen + ' 字');

  // 5) 改 hash（等价分享链接/地址栏）→ hashchange 生效
  await run(`location.hash = '#/picks';`);
  await wait(500);
  const h5 = await run('location.hash');
  rec('直接改 hash 生效（#/picks，等价分享链接）', /#\/picks\b/.test(h5), h5);

  // 6) **记录事实（不是断言）**：file:// 下只改 hash 的 pushState 抛不抛
  //    2026-10-16 实测（CDP 版，Edge 155 headless）：**不抛** → 旧说法「一律抛 SecurityError」被推翻
  //    换路径的情况**未实测**；这里永远记 PASS，只把实测值写进 JSON ✓
  const ps = await run(`(() => { try { history.pushState({}, '', '#/probe'); return 'ok'; } catch (e) { return 'threw:' + e.name; } })()`);
  rec('【记录事实·非断言】file:// 下 hash-only pushState：' + ps + '（换路径未实测）', true, ps);

  // 7) history 条目数（可前进后退的前提）
  const hl = await run('history.length');
  rec('history 有多条记录', Number(hl) >= 2, 'history.length=' + hl);

  // 8) 二次后退仍安全（不会白屏 / 不抛错）
  let backErr = '';
  try { back(); await wait(500); back(); await wait(500); } catch (e) { backErr = String(e && e.message || e); }
  const h6 = await run('location.hash');
  const stillRendered = await run('document.body.innerText.length');
  rec('连续后退不崩、页面仍有内容', !backErr && Number(stillRendered) > 200, 'hash=' + h6 + ' ｜ body ' + stillRendered + ' 字' + (backErr ? ' ｜ err=' + backErr : ''));

  const failed = log.filter((x) => !x.ok);
  fs.writeFileSync(outFile, JSON.stringify({
    page: loadUrl, at: new Date().toISOString(), engine: 'Electron/' + process.versions.electron + ' (Chromium ' + process.versions.chrome + ')',
    passed: log.length - failed.length, failed: failed.length, results: log
  }, null, 2), 'utf8');
  app.exit(failed.length ? 2 : 0);
}).catch((e) => {
  try {
    fs.writeFileSync(outFile, JSON.stringify({ error: String((e && e.stack) || e), results: log }, null, 2), 'utf8');
  } catch (_) { /* 写不了就算了 */ }
  app.exit(1);
});
