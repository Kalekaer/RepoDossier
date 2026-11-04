// check-page.js — 真跑 overview.html 内嵌 JS，逐个项目点一遍，抓前端运行时报错
//
// 为什么需要它：overview.html 是单文件内嵌页，JS 出错时**页面照常渲染**，
// 只有点击/交互才暴露（2026-10-13「卡片点不了」就是这么来的：数据里混进 [null]，
// p.un.map(x=>x.date) 抛 TypeError，面板永远打不开，而卡片显示完全正常）。
// 语法检查 + 数据检查都抓不到这种错，只有真跑一遍才行。
//
// 用法：node check-page.js <page-js-file> <result-file>
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
log('JS 长度: ' + src.length);

// ① 语法检查
try { new Function(src); log('① 语法: OK'); }
catch (e) { log('① 语法错误: ' + e.message); finish(1); }

// ② 极简 DOM 桩，真跑页面脚本（含 render/buildCat/buildToday 等初始化）
const els = {};
function makeEl(id) {
  const el = {
    id, innerHTML: '', textContent: '', value: '', style: {}, _classes: new Set(),
    classList: {
      add(c) { el._classes.add(c); },
      remove(c) { el._classes.delete(c); },
      contains(c) { return el._classes.has(c); }
    },
    focus() {}, addEventListener() {}, querySelector() { return null; }
  };
  return el;
}
global.document = {
  getElementById(id) { if (!els[id]) els[id] = makeEl(id); return els[id]; },
  addEventListener() {}, activeElement: null
};
// P2-9：页面有 hash 路由，需要 location 桩才能真跑（没有它路由会走"无 location 兜底"分支）
// hash 用普通对象属性模拟：写 hash 不会自动触发 hashchange，测试里显式调 cap.route() ✓
global.location = { hash: '' };
global.window = { onerror: null, addEventListener() {} };

let cap = {};
try {
  new Function(src + '\n;globalThis.__cap = { detail: detail, P: P, E: E, PLANS: PLANS, WS: WS, render: render, buildCat: buildCat, toggleCmp: toggleCmp, showCompare: showCompare, clearCmp: clearCmp, toggleGroup: toggleGroup, addGap: addGap, clearGaps: clearGaps, showPlan: showPlan, buildPlans: buildPlans, buildWorkspaces: buildWorkspaces, showWorkspace: showWorkspace, route: route, setHash: setHash, getHash: getHash, setL1: setL1, openLegend: openLegend, closeLegend: closeLegend, getView: function(){ return curView; }, getFilter: function(){ return f; } };')();
  cap = globalThis.__cap || {};
  log('② 初始化: OK（P 条数=' + (cap.P ? cap.P.length : '?') + '）');
} catch (e) {
  log('② 初始化报错: ' + e.message + '\n' + (e.stack || ''));
  finish(1);
}

// ③ 逐个打开每个项目详情（这是「点击卡片」真正执行的路径）
const P = cap.P || [];
let ok = 0; const fails = [];
for (const p of P) {
  try {
    cap.detail(p.id);
    const html = els['panel'].innerHTML;
    if (!html || html.length < 50) throw new Error('面板内容为空');
    if (!els['panel']._classes.has('open')) throw new Error('面板未打开（缺 open 类）');
    ok++;
  } catch (e) {
    fails.push(p.id + ' → ' + e.message);
  }
}
log('③ 详情页逐个打开: ' + ok + '/' + P.length + ' 成功');
fails.slice(0, 10).forEach(f => log('   ❌ ' + f));
if (fails.length > 10) log('   ...（共 ' + fails.length + ' 条失败）');

// ④ 搜索/筛选路径
let filterOk = true;
try {
  cap.render();
} catch (e) { filterOk = false; log('④ render() 报错: ' + e.message); }
if (filterOk) log('④ 渲染/筛选: OK');

// ⑤ 数据完整性：数组字段里不得有 null 元素（就是这次踩的坑）
const nullFields = [];
for (const p of P) {
  for (const k of ['un', 'ft', 't', 'fn']) {
    const v = p[k];
    if (Array.isArray(v) && v.some(x => x === null)) nullFields.push(p.id + '.' + k);
  }
}
log('⑤ 数组字段 null 元素: ' + nullFields.length + ' 处' + (nullFields.length ? '（' + nullFields.slice(0, 5).join(', ') + '）' : '（干净）'));

// ⑥ 页内项目对比（勾选两个 → 对比表）
let cmpOk = false;
try {
  if (typeof cap.toggleCmp !== 'function' || typeof cap.showCompare !== 'function') {
    throw new Error('页面里没有对比功能函数');
  }
  cap.clearCmp();
  cap.toggleCmp({ stopPropagation() {} }, P[0].id);
  cap.toggleCmp({ stopPropagation() {} }, P[1].id);
  cap.showCompare();
  const html = els['panel'].innerHTML;
  const rows = (html.match(/<tr>/g) || []).length;
  const hasSug = html.indexOf('怎么选') >= 0;
  const hasBoth = html.indexOf(P[0].id) >= 0 && html.indexOf(P[1].id) >= 0;
  cmpOk = rows >= 14 && hasSug && hasBoth && els['panel']._classes.has('open');
  log('⑥ 页内对比: ' + (cmpOk ? ('OK（' + rows + ' 行 + 怎么选 + 两个项目名）') : ('❌ rows=' + rows + ' 建议=' + hasSug + ' 双方=' + hasBoth)));
  cap.clearCmp();
} catch (e) {
  log('⑥ 页内对比: ❌ ' + e.message);
}

// ⑦ 搜索优先级 + 按用途分组（v3.1 第五、八节）
let grpOk = false;
try {
  const q = document.getElementById('q');
  q.value = 'AI';          // 用分类词搜索，保证有命中
  cap.render();
  const hit = els['list'].innerHTML.length > 0;
  // 搜索优先级：搜项目简称应能排到最前
  const sample = P.find(x => x.id && x.id.indexOf('/') > 0);
  const shortName = sample.id.split('/')[1];
  q.value = shortName;
  cap.render();
  const firstCardId = (els['list'].innerHTML.match(/detail\('([^']+)'\)/) || [])[1];
  const nameFirst = firstCardId === sample.id;
  // 按用途分组
  q.value = '';
  cap.render();
  cap.toggleGroup();
  const grouped = els['list'].innerHTML.indexOf('grpHead') >= 0 || els['list'].innerHTML.indexOf('按用途分组') >= 0;
  cap.toggleGroup();
  grpOk = hit && grouped && nameFirst;
  log('⑦ 搜索优先级/按用途分组: ' + (grpOk ? 'OK（搜简称「' + shortName + '」命中该条；分组视图可用）' : ('❌ 命中=' + hit + ' 分组=' + grouped + ' 简称优先=' + nameFirst)));
} catch (e) {
  log('⑦ 搜索优先级/按用途分组: ❌ ' + e.message);
}

// ⑧ 分词搜索 / 错字容错 / 缺口记录（v3.1 第五节 + 词表自适应）
let searchOk = false;
try {
  const q = document.getElementById('q');
  // 取同一个项目一句话里的**两个真词**（不要取固定切片——切片可能落在标点上，测试自己会脆）
  let two = null, toks = null;
  for (const cand of P) {
    const one = cand.one || '';
    if (one.length < 12) continue;
    const m = one.match(/[\u4e00-\u9fff]{2,4}|[A-Za-z0-9][A-Za-z0-9\-]{3,}/g);
    if (m && m.length >= 2 && m[0] !== m[1]) { two = cand; toks = m; break; }
  }
  if (!two) throw new Error('找不到可用的多词测试样本');
  const w1 = toks[0], w2 = toks[1];
  q.value = w1; cap.render();
  const n1 = (els['list'].innerHTML.match(/class="card/g) || []).length;
  q.value = w1 + ' ' + w2; cap.render();
  const n2 = (els['list'].innerHTML.match(/class="card/g) || []).length;
  // 多词 AND：两个词都必须命中 → 结果应 ≥1（该条自身）且不多于单词命中数
  const andOk = n1 > 0 && n2 > 0 && n2 <= n1;
  // **B2 验收**：搜索框里写给用户的示例词，必须都能搜到东西（否则等于骗用户）
  const PH_WORDS = ['画图','做PPT','替代PS','聊天机器人','本地运行AI'];
  const phMiss = PH_WORDS.filter(w => { q.value = w; cap.render(); return (els['list'].innerHTML.match(/class="card/g) || []).length === 0; });
  // 小库不强求：示例词是按「完整库（≥50 条）」写的，15 条的测试库可能一个都搜不到
  const phOk = (P.length < 50) ? true : (phMiss.length === 0);
  // ---- §2 搜索矩阵（v5.1.0 测试补齐）：只**打印**结果数，不参与判定（避免"正常 0 命中"被误判成 FAIL）----
  const MCASES = [
    ['普通','AI'],['普通','图片'],['普通','视频'],['普通','代码'],['普通','文件'],
    ['普通','ppt'],['普通','做PPT'],['普通','PPT'],['普通','幻灯片'],
    ['需求','我想做PPT'],['需求','我要画图'],['需求','我要写代码'],['需求','我要找AI助手'],['需求','我要管理文件'],
    ['容错','comfui'],['容错','comfy'],['容错','photshop'],['容错','githb'],
    ['多词','AI 视频'],['多词','本地 AI'],['多词','图片 编辑'],['异常','<script>alert(1)</script>'],['异常','']
  ];
  const MRES = MCASES.map(function(c){
    q.value = c[1]; cap.render();
    const n = (els['list'].innerHTML.match(/class="card/g) || []).length;
    return c[0] + ':' + (c[1]===''?'(空串)':c[1]) + '=' + n;
  });
  console.log('MATRIX ' + MRES.join(' | '));
  const NEED = MCASES.filter(function(c){ return c[0]==='需求'; });
  const NZ = NEED.filter(function(c){ q.value=c[1]; cap.render(); return (els['list'].innerHTML.match(/class="card/g)||[]).length===0; });
  console.log('NEEDZERO 需求式 0 命中的句子: ' + (NZ.length? NZ.map(function(c){return c[1];}).join('、') : '无') + ' （' + NZ.length + '/' + NEED.length + '）');
  // 错字容错：把一个英文标签的末位改掉，仍应命中
  let fuzzyOk = true;
  const withTag = P.find(x => (x.ft || []).some(t => /^[a-z\-]{7,}$/.test(String(t))));
  if (P.length >= 50 && withTag) {
    const tag = withTag.ft.find(t => /^[a-z\-]{7,}$/.test(String(t)));
    const typo = tag.slice(0, tag.length - 1) + 'x';
    q.value = typo; cap.render();
    fuzzyOk = (els['list'].innerHTML.match(/class="card"/g) || []).length > 0;
  }
  // 缺口记录：搜一个不存在的词 → 空态应有「记下这个词」，调用后缺口条出现
  q.value = 'zzz不存在的词zzz'; cap.render();
  const emptyHasGapBtn = els['list'].innerHTML.indexOf('记下这个词') >= 0;
  cap.addGap('zzz不存在的词zzz');
  const chipShown = els['gapChip'].style.display !== 'none' && els['gapChip'].textContent.indexOf('搜索缺口') >= 0;
  cap.clearGaps();
  q.value = ''; cap.render();
  searchOk = andOk && fuzzyOk && emptyHasGapBtn && chipShown && phOk;
  log('⑧ 分词/容错/缺口记录: ' + (searchOk ? ((P.length < 50 && phMiss.length) ? ('OK（多词 AND、错字可命中、缺口可记；小库 ' + P.length + ' 条，示例词不强求）') : 'OK（多词 AND、错字可命中、缺口可记、5 个示例词全命中）')
      : ('❌ 示例词未命中=' + phMiss.join('/') + ' AND=' + andOk + '(n1=' + n1 + ',n2=' + n2 + ') 容错=' + fuzzyOk + ' 缺口按钮=' + emptyHasGapBtn + ' 缺口条=' + chipShown)));
} catch (e) {
  log('⑧ 分词/容错/缺口记录: ❌ ' + e.message);
}

// ⑨ 方案（v3.1 第八节）：选场景 → 出角色 + 为什么需要 + 自动配好工具
let planOk = false;
try {
  const PL = cap.PLANS || [];
  if (typeof cap.showPlan !== 'function' || !PL.length) throw new Error('页面里没有方案功能');
  cap.buildPlans();
  const grid = els['planGrid'].innerHTML;
  const chips = (grid.match(/showPlan\(/g) || []).length;
  cap.showPlan(PL[0].id);
  const html = els['panel'].innerHTML;
  const whyCount = (html.match(/为什么需要这一步/g) || []).length;
  const tables = (html.match(/<table class="cmpt">/g) || []).length;
  const hasIntro = html.indexOf(PL[0].name) >= 0 && html.indexOf('为什么需要这一步') >= 0;
  planOk = chips >= 1 && hasIntro && whyCount >= 2;   // B10：稀疏库里可能一组工具都配不出，页面行为仍正确
  // 批次 6：#/plans 工单口径 —— 有候选工具的角色必须标「已配齐」（planRoleAll 返回数字，写 .length 会让它恒为假 ✗）
  // 必须看**数字**：只数"状态块存在"是假断言 —— bug 塞回去时它照样通过 ✗（已实测）
  const woM=/已配齐 (\d+) \/ (\d+)/.exec(els['panel'].innerHTML);
  const woOkN = woM ? parseInt(woM[1],10) : -1;
  planOk = planOk && woOkN >= 1;
  log('⑨ 方案视图: ' + (planOk
    ? ('OK（' + PL.length + ' 个场景；「' + PL[0].name + '」= ' + whyCount + ' 个角色说明 + ' + tables + ' 组自动配好的工具）')
    : ('❌ 场景按钮=' + chips + ' 角色说明=' + whyCount + ' 工具组=' + tables + ' 标题=' + hasIntro)));
} catch (e) {
  log('⑨ 方案视图: ❌ ' + e.message);
}

// §6 方案匹配清单（v5.1.0 测试补齐）：打印每个场景**实际匹配到的工具**，供人工判断「宽标签误配」
try {
  const PL6 = cap.PLANS || [];
  const rows = [];
  for (const pl of PL6) {
    cap.showPlan(pl.id);
    const h6 = els['panel'].innerHTML;
    const tables6 = h6.match(/<table class="cmpt">[\s\S]*?<\/table>/g) || [];   // 只量工具表格内的链接（原来把面板里所有链接都算了，尺子不准）
    const ids = Array.from(new Set((tables6.join(' ').match(/github\.com\/[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+/g) || []).map(function(s){ return s.replace('https://github.com/',''); })));
    if (!tables6.length && !ids.length) { /* 该场景无可配工具 */ }
    rows.push(pl.name + '(' + ids.length + '): ' + (ids.join(' + ') || '无'));
  }
  console.log('PLANS6 ' + rows.join(' || '));
} catch (e) { console.log('PLANS6 FAIL ' + e.message); }
// §6 分数明细（诊断）：为什么某个不相关的工具会进某个场景？**忠实复刻 planRoleTools 的规则**
try {
  const TARGET = ['ARahim3/DigUp','freestylefly/WeChatBridge','linbei0/EcomGen','storytold/photocraft'];
  const PLD = cap.PLANS || [];
  const rows = [];
  for (const pl of PLD) {
    const roles = pl.roles || pl.steps || [];
    for (let ri = 0; ri < roles.length; ri++) {
      const role = roles[ri];
      const rname = role.name || role.title || ('角色' + (ri+1));
      (P || []).forEach(function(p){
        if (TARGET.indexOf(p.id) < 0) return;
        let sc = 0; const why = [];
        if (role.l2 && role.l2.length && p.l2 && role.l2.indexOf(p.l2) >= 0) { sc += 3; why.push('l2命中[' + p.l2 + ']'); }
        if (role.ft && role.ft.length) {
          (p.ft || []).forEach(function(f){
            const fl = String(f).toLowerCase();
            role.ft.forEach(function(x){
              const xl = String(x).toLowerCase();
              if (fl.indexOf(xl) >= 0) { sc += 2; why.push('ft[' + f + ']⊃[' + x + ']'); }
              else if (fl.length >= 3 && xl.indexOf(fl) >= 0) { sc += 2; why.push('ft[' + x + ']⊃[' + f + ']'); }
            });
          });
        }
        if (sc >= 3) rows.push(pl.name + ' / ' + rname + ' × ' + p.id + ' = ' + sc + ' {' + why.join(' ; ') + '}');
      });
    }
  }
  console.log('PLANSCORE ' + (rows.join(' || ') || '(无)'));
} catch (e) { console.log('PLANSCORE FAIL ' + e.message); }
// ⑩ 收藏 / 工作区 / 首页引导（GPT 评审 2026-10-13：收藏与生命周期解耦 + 工作区 + 冷启动）
let libOk = false;
try {
  // 收藏功能已整体撤销（用户 2026-10-13 决定）：页面里不该再有任何收藏元素
  const noFav = els['list'].innerHTML.indexOf('已收藏') < 0 && els['list'].innerHTML.indexOf('收藏') < 0;
  const savedLeft = P.filter(p => p.status === 'saved').length;   // 迁移后应为 0

  // 工作区：卡片能点开，面板要包含工作区名 + 工具表
  cap.buildWorkspaces();
  const wsChips = (els['wsGrid'].innerHTML.match(/showWorkspace\(/g) || []).length;
  let wsOk = true;
  if (wsChips > 0) {
    cap.showWorkspace(cap.WS[0].id);
    const ph = els['panel'].innerHTML;
    wsOk = ph.indexOf(cap.WS[0].name) >= 0 && ph.indexOf('这个工作区用到的工具') >= 0;
  }

  // 待补全条目：不隐藏，但要有低权重标记
  const thin = P.filter(p => p.hs !== 'complete').length;
  const q = document.getElementById('q');
  q.value = ''; cap.render();
  const thinMarked = (els['list'].innerHTML.match(/详细介绍待补全/g) || []).length;
  const thinOk = thin === 0 || thinMarked > 0;

  // 首页引导是**静态 HTML**（不是 JS 生成的），假 DOM 里查不到 —— 由 audit.ps1 直接读 overview.html 校验。
  // 这里只验证 JS 侧能力：卡片上有收藏按钮。
  // **反断言**：页面里不允许出现「点了没用」的假按钮（收藏按钮已按用户要求撤掉）
  const noFakeBtn = els['list'].innerHTML.indexOf('favCmd(') < 0;

  libOk = noFav && savedLeft === 0 && wsOk && thinOk && noFakeBtn;
  log('⑩ 工作区/待补全/无假按钮: ' + (libOk
    ? ('OK（无收藏残留=' + noFav + '、status=saved 残留 ' + savedLeft + '、工作区 ' + wsChips + ' 个、待补全标记 ' + thinMarked + ' 处、无假按钮）')
    : ('❌ 无收藏残留=' + noFav + ' saved残留=' + savedLeft + ' 工作区=' + wsOk + ' 待补全标记=' + thinOk + ' 无假按钮=' + noFakeBtn)));
} catch (e) {
  log('⑩ 收藏/工作区/引导: ❌ ' + e.message);
}

// ⑪⑫⑬ hash 路由（P2-9；设计 §7「新增断言」里的 ①②③）
// 为什么要真跑：路由是纯交互能力，"后退能不能回到上一个视图""筛选链接能不能复原"
// 静态检查一句都看不出来；而 file:// 下路由一旦坏掉，用户看到的是"点了没反应"。
let routeOk = false, facetOk = false, legendOk = false;
try {
  const H = global.location;
  const jump = function (h) { H.hash = h; cap.route(); };
  const navOn = function (v) { return els['nav-' + v]._classes.has('on'); };
  const viewShown = function (v) { return els['view-' + v]._classes.has('on'); };

  // ⑪ 进入 / 后退 / 刷新一致（同一 hash 反复进入结果必须一致）+ 未知路由回总览不白屏
  jump('#/picks'); const v1 = cap.getView();
  jump('#/all');   const v2 = cap.getView();
  jump('#/picks'); const v3 = cap.getView();      // 后退：回到上一个 hash
  jump('#/all');   const v4 = cap.getView();      // 前进
  jump('#/nonsense'); const v5 = cap.getView();
  const seqOk = (v1 === 'picks' && v2 === 'all' && v3 === 'picks' && v4 === 'all');
  routeOk = seqOk && v5 === 'home' && navOn('home') && viewShown('home') && !viewShown('picks');
  log('⑪ hash 路由进入/后退/刷新一致: ' + (routeOk
    ? 'OK（picks→all→picks→all 一致；未知路由回总览）'
    : ('❌ ' + [v1, v2, v3, v4, v5].join('→') + ' nav/视图类=' + navOn('home') + '/' + viewShown('home'))));

  // ⑫ facet 组合写进 URL，且用该 URL 能复原同一视图
  const l1 = (P.find(x => x.l1) || {}).l1;
  if (!l1) throw new Error('库里没有带一级分类的项目，无法测 facet');
  jump('#/all');
  cap.setL1(l1);                                   // 用户点了分类 chip
  const h1 = H.hash;
  const wroteCat = h1.indexOf('cat=' + encodeURIComponent(l1)) >= 0;
  const n1 = (els['list'].innerHTML.match(/class="card/g) || []).length;
  jump('#/all');                                   // 相当于换了个干净链接 → 筛选被清空
  const cleared = cap.getFilter().l1 === '';
  jump(h1);                                        // 用刚才那条链接复原
  const restored = cap.getFilter().l1 === l1;
  const n2 = (els['list'].innerHTML.match(/class="card/g) || []).length;
  facetOk = wroteCat && cleared && restored && n1 > 0 && n1 === n2;
  log('⑫ facet 写进 URL 且可复原: ' + (facetOk
    ? ('OK（' + h1 + ' → 命中 ' + n1 + ' 条，复原后 ' + n2 + ' 条）')
    : ('❌ wroteCat=' + wroteCat + ' cleared=' + cleared + ' restored=' + restored + ' n1=' + n1 + ' n2=' + n2)));

  // ⑬ #/legend 是叠加层：打开不改变当前区，关闭后回到原区
  jump('#/all'); const before = cap.getView();
  jump('#/legend');
  const opened = els['legend']._classes.has('open');
  const after = cap.getView();
  const viewVisible = ['home', 'picks', 'all', 'plans'].some(v => els['view-' + v]._classes.has('on'));
  cap.closeLegend(); cap.route();
  const closed = !els['legend']._classes.has('open');
  // **冷启动护栏**：直接以 `#/legend` 打开（分享链接 / 刷新）时 curView 还是空，若不在
  // route() 里垫一个区，四个 .view 全是 display:none → 抽屉背后白屏。2026-10-17 由真实
  // Edge headless 实测发现；这里用「全新作用域再跑一遍页面 JS」复现同一条路径。
  H.hash = '#/legend';
  new Function(src + '\n;globalThis.__capBlank = { getView: function(){ return curView; } };')();
  const blankView = globalThis.__capBlank.getView();
  const blankVisible = ['home', 'picks', 'all', 'plans'].some(v => els['view-' + v]._classes.has('on'));
  legendOk = opened && before === 'all' && after === 'all' && closed && cap.getView() === 'all'
    && viewVisible && blankView === 'home' && blankVisible;
  log('⑬ #/legend 不改当前区 + 冷启动不白屏: ' + (legendOk
    ? 'OK（打开不改区；关闭回 all；直接载入 #/legend 垫总览）'
    : ('❌ opened=' + opened + ' before=' + before + ' after=' + after + ' closed=' + closed + ' now=' + cap.getView() + ' 区可见=' + viewVisible + ' 冷启动=' + blankView + '/' + blankVisible)));
} catch (e) {
  log('⑪⑫⑬ hash 路由: ❌ ' + e.message + '\n' + (e.stack || ''));
}

// ⑭ 工作区 / 方案深链能打开面板（`#/ws/<id>`、`#/plans/<id>`）
// 为什么单独测：这两条是"分享出去的链接要能直接看到东西"，光切区不算成功。
let deepOk = false;
try {
  const ws = cap.WS[0], pl = cap.PLANS[0];
  const openPanel = function (hash, expect) {
    els['panel']._classes.delete('open');
    global.location.hash = hash;
    cap.route();
    return els['panel']._classes.has('open') && els['panel'].innerHTML.indexOf(expect) >= 0;
  };
  const wsHit = ws ? openPanel('#/ws/' + encodeURIComponent(ws.id), ws.name) : null;
  const planHit = pl ? openPanel('#/plans/' + encodeURIComponent(pl.id), pl.name) : null;
  deepOk = (wsHit === null || wsHit) && (planHit === null || planHit) && cap.getView() === 'plans';
  log('⑭ 工作区/方案深链打开面板: ' + (deepOk
    ? ('OK（#/ws/' + (ws ? ws.id : '-') + ' ｜ #/plans/' + (pl ? pl.id : '-') + '）')
    : ('❌ ws=' + wsHit + ' plan=' + planHit + ' 区=' + cap.getView())));
} catch (e) {
  log('⑭ 深链: ❌ ' + e.message);
}

// ⑮ 封面 `#hero` 不得被历史 localStorage 标记隐藏（2026-10-16 **用户实测报障**）
// 真因：老版「知道了，收起」把 `dsh-lib-hero=off` 写进 localStorage（file:// 下按源**持久**保存），
// 封面在批次 6 升级为首页主体后，这个历史标记会让整块刊头**永久消失** ✗
// → 必须：① 清掉该标记 ② 不隐藏封面。
// ⚠️ 桩的元素是**懒创建**的（`getElementById` 调过才存在）→ 必须在页面作用域里**主动取一次** `#hero`
//    （我第一版直接读 `els['hero']`，修好后没人调用它 → 假红 ✗）
let heroOk = false;
try {
  const calls = [];
  global.localStorage = {
    getItem: function (k) { return k === 'dsh-lib-hero' ? 'off' : null; },
    setItem: function (k) { calls.push('set:' + k); },
    removeItem: function (k) { calls.push('remove:' + k); }
  };
  new Function(src + '\n;globalThis.__capHero = function(){ var e = document.getElementById("hero"); return e ? String(e.style.display || "") : "MISSING"; };')();
  const disp = globalThis.__capHero();
  const cleared = calls.indexOf('remove:dsh-lib-hero') >= 0;
  heroOk = cleared && disp !== 'none' && disp !== 'MISSING';
  log('⑮ 封面不被历史标记隐藏: ' + (heroOk
    ? 'OK（已清掉 dsh-lib-hero=off，封面 display=' + (disp || '默认') + '）'
    : ('❌ 清理标记=' + cleared + ' 封面 display=' + JSON.stringify(disp) + ' 调用=' + JSON.stringify(calls))));
} catch (e) { log('⑮ 封面护栏: ❌ ' + e.message); }
delete global.localStorage;// ⑯ #/picks 官方侧栏：库里存在 official 条目时**必须列出来**（2026-10-16 我自己写错过过滤值，
// 页面于是谎称"还没有校订过的官方条目" ✗ —— 数据里其实有 8 条，这是"页面说假话"级别的问题）
let offOk = false;
try {
  const offN = (P || []).filter(function(p){ return p.oc === 'official'; }).length;
  global.location.hash = '#/picks'; cap.route();   // 用页面导出的 route（jump 是别的断言块里的局部函数，这里取不到 ✗）
  const html = els['todayOff'] ? els['todayOff'].innerHTML : '';
  const shown = (html.match(/github\.com\//g) || []).length;
  const claimsEmpty = html.indexOf('还没有校订过') >= 0;
  offOk = offN === 0 ? claimsEmpty : (shown > 0 && !claimsEmpty);
  log('⑯ 官方侧栏与数据一致: ' + (offOk
    ? ('OK（official ' + offN + ' 条 → 侧栏列出 ' + shown + ' 条）')
    : ('❌ official=' + offN + ' 列出=' + shown + ' 声称空=' + claimsEmpty)));
} catch (e) { log('⑯ 官方侧栏: ❌ ' + e.message); }// ⑰ P2-2 徽章筛选：选中「冷门」后列表只剩带该徽章的条目，且筛选可写进链接/被链接复原
let badgeOk = false;
try {
  const fb = document.getElementById('fb');
  fb.value = 'gem'; cap.render();
  const cards = (els['list'].innerHTML.match(/class="card/g) || []).length;
  const gems  = (els['list'].innerHTML.match(/b-gem/g) || []).length;
  global.location.hash = '#/all?badge=gem'; cap.route();
  const back = (document.getElementById('fb') || {}).value;
  badgeOk = cards > 0 && gems === cards && back === 'gem';
  log('⑰ 徽章筛选: ' + (badgeOk
    ? ('OK（冷门 ' + cards + ' 条，全部带 🧊；链接 badge=gem 可复原）')
    : ('❌ 卡片=' + cards + ' 带冷门=' + gems + ' 链接复原=' + back)));
  fb.value = ''; cap.render();
} catch (e) { log('⑰ 徽章筛选: ❌ ' + e.message); }const passed = heroOk && offOk && badgeOk && fails.length === 0 && filterOk && nullFields.length === 0 && cmpOk && grpOk && searchOk && planOk && libOk && routeOk && facetOk && legendOk && deepOk;
log(passed ? 'RESULT: PASS' : 'RESULT: FAIL');
finish(passed ? 0 : 1);
