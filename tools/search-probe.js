// search-probe.js — 搜索专项探针：真跑 overview.html 的内嵌 JS，量化"搜得到、搜得准、搜得快"
//
// 用法：electron(ELECTRON_RUN_AS_NODE=1) search-probe.js <page-js-file> <result-file>
// 判定：不产出 PASS/FAIL，只产出**可核对的数字**（命中数、Top3、精度、耗时），供人工与 audit 使用。
// 为什么不做硬断言：搜索质量有主观成分；把"看起来对不对"变成数字，再由人/标准判定。

const fs = require('fs');
const jsPath = process.argv[2];
const resPath = process.argv[3];
const out = [];
function log(s) { out.push(s); }
function finish(code) {
  try { fs.writeFileSync(resPath, out.join('\n'), 'utf8'); } catch (e) {}
  process.exit(code || 0);
}

let src;
try { src = fs.readFileSync(jsPath, 'utf8'); } catch (e) { log('READ ERROR: ' + e.message); finish(1); }

// ---- DOM 桩（与 check-page.js 同构） ----
const els = {};
function makeEl(id) {
  const el = {
    id, innerHTML: '', textContent: '', value: '', style: {}, _classes: new Set(),
    classList: { add(c) { el._classes.add(c); }, remove(c) { el._classes.delete(c); }, contains(c) { return el._classes.has(c); } },
    focus() {}, addEventListener() {}, querySelector() { return null; }
  };
  return el;
}
global.document = { getElementById(id) { if (!els[id]) els[id] = makeEl(id); return els[id]; }, addEventListener() {}, activeElement: null };
global.window = { onerror: null };

try {
  new Function(src + '\n;globalThis.__cap={P:P,render:render,matchScore:matchScore,hay:hay,parseQuery:parseQuery,f:f,detail:detail,SYN:SYN};')();
} catch (e) { log('INIT ERROR: ' + e.message + '\n' + (e.stack || '')); finish(1); }
const cap = globalThis.__cap || {};
const P = cap.P || [];
const q = () => document.getElementById('q');

function run(query) {
  q().value = query;
  const t0 = Date.now();
  cap.render();
  const ms = Date.now() - t0;
  const html = els['list'].innerHTML;
  const ids = [];
  const re = /detail\('([^']+)'\)/g; let m;
  while ((m = re.exec(html))) { if (ids.indexOf(m[1]) < 0) ids.push(m[1]); }
  const cards = (html.match(/class="card/g) || []).length;
  return { ms: ms, cards: cards, ids: ids, html: html };
}
const byId = {};
P.forEach(p => { byId[p.id] = p; });

log('=== 搜索专项探针 · 库内 ' + P.length + ' 条 ===');
log('同义词组: ' + ((cap.SYN || []).length) + ' 组；总词数: ' + ((cap.SYN || []).reduce((a, g) => a + ((g.terms || []).length), 0)));

// ---------- A. 需求式（中文整句） ----------
log('');
log('--- A. 需求式搜索（中文整句，应该有结果） ---');
const A = ['我要画图', '我想做PPT', '我要写代码', '我要找AI助手', '我要管理文件', '抠图', '下载视频', '翻译', '本地跑大模型', '做网站', '记账', '截图', '剪视频', '语音转文字', '找素材', '自动化', '数据库', '爬虫'];
const aZero = [];
A.forEach(function (x) {
  const r = run(x);
  const top3 = r.ids.slice(0, 3).map(function (id) { return id + (byId[id] && byId[id].one ? '（' + String(byId[id].one).slice(0, 22) + '）' : ''); });
  if (!r.cards) aZero.push(x);
  log('  ' + (r.cards ? '✓' : '✗0命中') + ' 「' + x + '」 = ' + r.cards + ' 条 ｜ ' + (top3.join(' ; ') || '—'));
});
log('  A 小计: 0 命中 ' + aZero.length + '/' + A.length + (aZero.length ? '（' + aZero.join('、') + '）' : ''));

// ---------- B. 排序正确性 ----------
log('');
log('--- B. 排序：搜「项目简称」是否把它排到第 1 ---');
const samples = P.filter(function (p) { return p.id && p.id.indexOf('/') > 0; }).slice(0, 12);
let bOk = 0; const bBad = [];
samples.forEach(function (p) {
  const short = p.id.split('/')[1];
  const r = run(short);
  const first = r.ids[0];
  if (first === p.id) bOk++; else bBad.push(short + '→' + (first || '无'));
});
log('  简称精确匹配排第一: ' + bOk + '/' + samples.length + (bBad.length ? ' ｜ 例外: ' + bBad.slice(0, 5).join(', ') : ''));

log('');
log('--- B2. 精度：搜功能标签 / 分类词，Top20 里有多少真的带该标签/属于该分类 ---');
[['dsh-plugin', 'tag'], ['ai-agent', 'tag'], ['mcp', 'tag'], ['AI', 'cat'], ['效率', 'cat'], ['开发', 'cat']].forEach(function (c) {
  const r = run(c[0]);
  const top = r.ids.slice(0, 20);
  let hit = 0;
  top.forEach(function (id) {
    const p = byId[id]; if (!p) return;
    if (c[1] === 'tag') { if ((p.ft || []).some(function (t) { return String(t).toLowerCase().indexOf(c[0].toLowerCase()) >= 0; })) hit++; }
    else { if (String(p.l1) === c[0] || String(p.l2) === c[0]) hit++; }
  });
  log('  ' + (c[1] === 'tag' ? '标签' : '分类') + '「' + c[0] + '」: 命中 ' + r.cards + ' 条，Top' + top.length + ' 精度 ' + hit + '/' + top.length);
});

// ---------- C. 错字容错 ----------
log('');
log('--- C. 错字容错（改 1 个字母 / 少 1 个字母） ---');
const C = [['photshop', 'photoshop'], ['comfui', 'comfyui'], ['comfy', 'comfy'], ['githb', 'github'], ['vscoe', 'vscode'], ['pyhton', 'python'], ['dockerr', 'docker'], ['obsidain', 'obsidian'], ['excle', 'excel'], ['figmaa', 'figma'], ['telegrama', 'telegram'], ['kubernets', 'kubernetes']];
let cOk = 0; const cBad = [];
C.forEach(function (pair) {
  const r = run(pair[0]);
  if (r.cards > 0) cOk++; else cBad.push(pair[0] + '（想搜 ' + pair[1] + '）');
  log('  ' + (r.cards ? '✓' : '✗') + ' 「' + pair[0] + '」 = ' + r.cards + ' 条');
});
log('  C 小计: 容错成功 ' + cOk + '/' + C.length + (cBad.length ? ' ｜ 失败: ' + cBad.join('、') : ''));

// ---------- D. 多词 AND ----------
log('');
log('--- D. 多词（应当收窄，不应放大） ---');
[['AI', 'AI 视频'], ['本地', '本地 AI'], ['图片', '图片 编辑'], ['dsh', 'dsh plugin'], ['视频', '视频 下载'], ['ppt', 'ppt 模板']].forEach(function (pair) {
  const n1 = run(pair[0]).cards, n2 = run(pair[1]).cards;
  log('  「' + pair[0] + '」=' + n1 + ' → 「' + pair[1] + '」=' + n2 + (n2 <= n1 ? ' ✓收窄' : ' ✗放大'));
});

// ---------- E. 边界与注入 ----------
log('');
log('--- E. 边界 / 注入 ---');
const longq = 'a'.repeat(200);
const E = [['(空串)', ''], ['(空格)', '   '], ['<script>alert(1)</script>', '<script>alert(1)</script>'], ['<img src=x onerror=alert(1)>', '<img src=x onerror=alert(1)>'], ['!!!', '!!!'], ['200 字符', longq], ['emoji', '🎨'], ['大小写 AI/ai', 'ai']];
E.forEach(function (pair) {
  const r = run(pair[1]);
  const rawScript = r.html.indexOf('<script>alert(1)') >= 0;
  const rawImg = r.html.indexOf('<img src=x') >= 0;
  log('  「' + pair[0] + '」 = ' + r.cards + ' 条 ｜ 原样回显HTML: script=' + rawScript + ' img=' + rawImg + ' ｜ ' + r.ms + 'ms');
});

// ---------- F. 性能 ----------
log('');
log('--- F. 性能（内部渲染耗时，不含浏览器布局） ---');
const perf = ['', 'a', 'AI', '我要画图', '本地 AI 视频 编辑'];
perf.forEach(function (x) {
  let best = 9999, worst = 0, n = 0;
  for (let i = 0; i < 5; i++) { const r = run(x); best = Math.min(best, r.ms); worst = Math.max(worst, r.ms); n = r.cards; }
  log('  「' + (x || '(空)') + '」 渲染 ' + n + ' 条卡：最快 ' + best + 'ms / 最慢 ' + worst + 'ms');
});
log('  规模外推：单条渲染成本 ≈ ' + (function () { const t0 = Date.now(); for (let i = 0; i < 5; i++) run(''); return Math.round((Date.now() - t0) / 5 / Math.max(1, P.length) * 1000) / 1000; })() + ' ms/条 → 5000 条约 ' + (function () { const t0 = Date.now(); for (let i = 0; i < 5; i++) run(''); const per = (Date.now() - t0) / 5 / Math.max(1, P.length); return Math.round(per * 5000); })() + ' ms');

// ---------- G. 词表与缺口机制 ----------
log('');
log('--- G. 词表与反馈闭环 ---');
log('  可容错词表大小: ' + (function () { try { return (typeof buildVocab === 'function' ? buildVocab().length : '不可见'); } catch (e) { return '不可见'; } })());
const g = run('zzz不存在的词zzz');
log('  空态是否有「记下这个词」按钮: ' + (g.html.indexOf('记下这个词') >= 0));

log('');
log('=== 探针结束 ===');
finish(0);
