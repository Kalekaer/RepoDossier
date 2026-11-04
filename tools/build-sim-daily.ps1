# build-sim-daily.ps1 — 生成 7 个「模拟日报」独立页面（不写 data/、不碰真实站点）
# 用法： & .\tools\build-sim-daily.ps1
# 输出： 模拟日报\01-...html ... 07-...html + README.md

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
$enc = New-Object System.Text.UTF8Encoding($false)

# ---------- 读库（只读） ----------
$proj = @{}
foreach ($l in (Get-Content (P 'data\projects.jsonl') -Encoding UTF8)) {
  if (-not $l.Trim()) { continue }
  try { $o = $l | ConvertFrom-Json; $proj[$o.id] = $o } catch { $null = $_ }
}

function New-Card([string]$id, [string]$tier, $score, [string]$risk, [string]$action, [string]$drop) {
  $p = $proj[$id]
  if (-not $p) { throw "库里没有：$id" }
  $h = $p.human
  $fn = $null; if ($h) { $fn = $h.feature_note }
  $what = ''; $feats = @(); $uses = @(); $cases = @(); $unfit = @()
  if ($fn) {
    $what = [string]$fn.'是什么'
    $feats = @($fn.'核心功能' | Where-Object { $_ })
    $uses = @($fn.'常见用途' | Where-Object { $_ })
    $cases = @($fn.'使用案例' | Where-Object { $_ })
    $unfit = @($fn.'不适合' | Where-Object { $_ })
  }
  $statusMap = @{ watching = '观望'; active = '活跃'; using = '在用'; dropped = '已弃'; researching = '调研中'; saved = '收藏' }
  $st = [string]$p.status
  $stCn = if ($statusMap.ContainsKey($st)) { $statusMap[$st] } else { $st }
  $note = [string]$p.note
  if ($note.Length -gt 1000) { $note = $note.Substring(0, 1000) + '…' }
  [ordered]@{
    id = $id; url = 'https://github.com/' + $id; tier = $tier; score = $score; risk = $risk; action = $action
    stars = if ($p.stars) { [int]$p.stars.current } else { 0 }
    d7 = if ($p.stars) { [int]$p.stars.delta_7d } else { 0 }
    forks = if ($p.stars) { [int]$p.stars.forks } else { 0 }
    lic = [string]$p.license; lang = [string]$p.language
    l1 = [string]$p.category.l1; l2 = [string]$p.category.l2
    one = if ($h -and $h.one_liner) { [string]$h.one_liner } else { [string]$p.description }
    problem = if ($h) { [string]$h.problem } else { '' }
    example = if ($h) { [string]$h.example } else { '' }
    aud = if ($h) { [string]$h.audience } else { '' }
    what = $what; feats = $feats; uses = $uses; cases = $cases; unfit = $unfit
    note = $note
    exp = [ordered]@{
      stars = if ($p.experience) { $p.experience.stars } else { $null }
      score = if ($p.experience) { $p.experience.score } else { $null }
      parts = if ($p.experience) { $p.experience.parts } else { $null }
    }
    first = [string]$p.first_seen; last = [string]$p.last_seen
    pushed = if ($p.pushed_at) { ([string]$p.pushed_at).Substring(0, 10) } else { '' }
    created = if ($p.stars) { [string]$p.stars.created_at } else { '' }
    evc = [int]$p.events_count
    topics = @($p.topics | Where-Object { $_ } | Select-Object -First 8)
    tags = @($p.function_tags | Where-Object { $_ } | Select-Object -First 12)
    kw = @($p.user_keywords | Where-Object { $_ } | Select-Object -First 12)
    syn = @($p.synonyms | Where-Object { $_ } | Select-Object -First 12)
    rec = [bool]$p.recommended; status = $stCn; drop = $drop
  }
}

function S12($c, $n) {
  $cmd = if ($c.example) { $c.example } else { "git clone https://github.com/$($c.id)`ncd $($c.id)`n# 按 README 快速开始" }
  $feat = if ($c.feats.Count) { $c.feats -join '；' } else { '见 README' }
  $use = if ($c.uses.Count) { $c.uses -join '；' } else { '见 README' }
  @"
### $n. $($c.id) · S 档 · $($c.lang) · $($c.stars)★

> 🔗 直接打开：https://github.com/$($c.id)

1. **项目名**：$($c.id)
2. **一句话定位**：$($c.one)
3. **30 秒判断**：$($c.risk) 风险 ｜ 行动：$($c.action) ｜ $($c.l1) / $($c.l2)。
4. **基本信息**：<https://github.com/$($c.id)> ｜ $($c.lang) ｜ **$($c.lic)** ｜ ★$($c.stars) ｜ $($c.pushed) 有推送 ｜ 未归档 ｜ 是否需要账号/密钥：以 README 为准。
5. **分类标签**：$($c.l1) / $($c.l2) / $($c.risk)。
6. **它到底干啥**：$($c.problem) **核心功能**：$feat。**常见用途**：$use。
7. **怎么用**：

   ```bash
$cmd
   ```
8. **亮点**：$feat。
9. **风险与注意**：$($c.risk) 风险；许可 $($c.lic)；上生产前先在分支/沙箱试。
10. **适合谁 / 不适合谁**：适合：$($c.aud)；不适合：$(if ($c.unfit.Count) { $c.unfit -join '；' } else { '无特殊限制' })。
11. **学习成本**：看懂 5 分钟 ｜ 跑起来 15 分钟 ｜ 用熟 1 小时（模拟估算）。
12. **总结**：$($c.one) —— 建议 **$($c.action)**。
"@
}

function ABullet($c) {
  $cmd = if ($c.example) { $c.example } else { "见 README" }
  "- **$($c.id)** — $($c.one) 为什么：$($c.problem) 上手：$cmd 许可与成本：$($c.lic)，以 README 为准。行动：$($c.action)。链接：<https://github.com/$($c.id)>"
}

# ---------- 场景 ----------
$oldNormal = @(
  @{ id='storytold/photocraft'; d='+3,120★'; note='纯 Rust 照片编辑器，本周涨得最猛' },
  @{ id='wheresryan22/anatomy'; d='+2,450★'; note='等距机械插画 skill' },
  @{ id='Niko1221/Strata'; d='+1,870★'; note='消费级硬件跑本地大模型' },
  @{ id='yetone/magpie'; d='+1,240★'; note='各家 agent 的统一入口' }
)
$oldMax = @(
  @{ id='storytold/photocraft'; d='+4,010★'; note='纯 Rust 照片编辑器' },
  @{ id='storytold/wordcraft'; d='+2,880★'; note='Word 的 Rust 替代' },
  @{ id='wheresryan22/anatomy'; d='+2,120★'; note='等距机械插画 skill' },
  @{ id='yetone/magpie'; d='+1,960★'; note='agent 统一入口' },
  @{ id='storytold/pdfcraft'; d='+1,540★'; note='PDF 阅读/编辑器' }
)
$oldZero = @(
  @{ id='storytold/filmcraft'; d='+980★'; note='非线性视频编辑器' },
  @{ id='Niko1221/Strata'; d='+860★'; note='本地大模型' },
  @{ id='yetone/magpie'; d='+720★'; note='agent 统一入口' }
)
$oldOwner = @(
  @{ id='storytold/photocraft'; d='+6,420★'; note='全家桶里涨得最猛的一个' },
  @{ id='wheresryan22/anatomy'; d='+1,890★'; note='等距机械插画' },
  @{ id='Niko1221/Strata'; d='+1,110★'; note='本地大模型' }
)

$scenarios = @(
  @{
    n=1; file='01-常规日'; date='2026-10-19'; week='周一'; issue='01'
    cand=34; s=2; a=3; b=4; rej=2; api='4 次（Q1/Q2/Q2b/Q3）'; limit='正常'
    picks=@(
      @{id='deeplethe/solid-glass'; tier='S'; score=88; risk='中'; action='试玩'},
      @{id='Aryanutkarsh/SeeCode'; tier='S'; score=84; risk='低'; action='试玩'},
      @{id='feder-cr/git-ai'; tier='A'; score=76; risk='中'; action='研究'},
      @{id='jev-chat/jev-chat-jarvis'; tier='A'; score=74; risk='中'; action='研究'},
      @{id='3aKHP/prts-mcp'; tier='A'; score=69; risk='低'; action='收藏'}
    )
    rejects=@(@{id='Caho1/open-claude-ui'; reason='MIT 与「仅供学习研究」自相矛盾，不按 MIT 当生产依赖'}, @{id='Supermedo/uncharted_pc'; reason='需自备商业游戏本体，版权类硬排除'})
    old=$oldNormal
    notes=@('本轮 Q1 10 / Q2 10 / Q2b 9 / Q3 5，去重后 34 条。', 'S 档均补调 README 核实安装方式（3 次，均成功）。', '30 天冷却：2 条老面孔在冷却期内，未进推荐区。')
  }
  @{
    n=2; file='02-满额日'; date='2026-10-20'; week='周二'; issue='02'
    cand=41; s=3; a=5; b=6; rej=2; api='4 次（Q1/Q2/Q2b/Q3）'; limit='正常'
    picks=@(
      @{id='deeplethe/solid-glass'; tier='S'; score=88; risk='中'; action='试玩'},
      @{id='Aryanutkarsh/SeeCode'; tier='S'; score=84; risk='低'; action='试玩'},
      @{id='storytold/photocraft'; tier='S'; score=81; risk='低'; action='试玩'},
      @{id='feder-cr/git-ai'; tier='A'; score=78; risk='中'; action='研究'},
      @{id='jev-chat/jev-chat-jarvis'; tier='A'; score=76; risk='中'; action='研究'},
      @{id='yetone/magpie'; tier='A'; score=73; risk='中'; action='研究'},
      @{id='Niko1221/Strata'; tier='A'; score=70; risk='中'; action='研究'},
      @{id='wheresryan22/anatomy'; tier='A'; score=66; risk='低'; action='收藏'}
    )
    rejects=@(@{id='storytold/wordcraft'; reason='同 owner 3 天内已推荐 photocraft，降权 −10 后未达 A 线'}, @{id='jiwoochris/artex-global'; reason='AI 自主渗透测试框架，合规红线'})
    old=$oldMax
    notes=@('今日触到硬上限：S+A = 8（S 3 / A 5），不再取第 9 条。', 'owner 冷却：`storytold` 3 天内只推 1 个；wordcraft 降权后落到 B 档。', 'Q2b 中间星段贡献 4 条新面孔，其中 2 条达线。')
  }
  @{
    n=3; file='03-冷清日'; date='2026-10-21'; week='周三'; issue='03'
    cand=18; s=0; a=0; b=7; rej=4; api='4 次（Q1/Q2/Q2b/Q3）'; limit='正常'
    picks=@()
    rejects=@(
      @{id='jiwoochris/artex-global'; reason='AI 自主渗透测试框架，合规红线'},
      @{id='Supermedo/uncharted_pc'; reason='需自备商业游戏本体，版权类硬排除'},
      @{id='Caho1/open-claude-ui'; reason='MIT 与「仅供学习研究」冲突，不推荐用于生产'},
      @{id='nanaism/yomiyasu'; reason='日语润色 skill，对中文用户无用'}
    )
    old=$oldZero
    notes=@('今天没有达到推荐线的项目：18 条候选里 14 条在 30 天冷却或已淘汰，4 条新面孔均未过线。', '按 RUBRIC「宁可少，不可注水」：推荐 0 条。', 'B 档 7 条进台账观察，S+A 为 0。')
  }
  @{
    n=4; file='04-抓取失败'; date='2026-10-22'; week='周四'; issue='04'
    cand=7; s=0; a=0; b=0; rej=0; api='2 次尝试，Q1/Q2 403，Q3 成功' ; limit='触顶 / 403'
    picks=@()
    rejects=@()
    old=@()
    notes=@('Q1 与 Q2 均返回 403（API rate limit exceeded），按规则最多重试 1 次，仍失败。', 'Q3 成功返回 7 条，其中 5 条是老面孔、2 条已淘汰；没有新的 S/A。', '数据不完整：本轮**不产出推荐**，也不写「今天没有好项目」的结论；如实标注抓取失败。', '额度：匿名 search 10/分钟，本轮触发限流；建议间隔重跑或换 token。')
  }
  @{
    n=5; file='05-风险日'; date='2026-10-23'; week='周五'; issue='05'
    cand=26; s=0; a=1; b=3; rej=3; api='4 次（Q1/Q2/Q2b/Q3）'; limit='正常'
    picks=@(@{id='3aKHP/prts-mcp'; tier='A'; score=71; risk='低'; action='收藏'})
    rejects=@(
      @{id='jiwoochris/artex-global'; reason='AI 自主渗透测试框架，命中合规红线（不列举、不给链接）'},
      @{id='Supermedo/uncharted_pc'; reason='需自备商业游戏本体，版权类硬排除'},
      @{id='Caho1/open-claude-ui'; reason='README 写 MIT 又写「仅供学习研究」，许可自相矛盾'}
    )
    old=@{}
    notes=@('本轮主题是「风险筛查」：3 条候选被硬排除，1 条许可冲突只入台账观察。', '唯一 A 档 `prts-mcp` 风险低、命令可核实；S 档为空。', '按规则：红线仓库不列举、不给链接、不表扬。')
  }
  @{
    n=6; file='06-owner冷却'; date='2026-10-24'; week='周六'; issue='06'
    cand=29; s=1; a=1; b=5; rej=2; api='4 次（Q1/Q2/Q2b/Q3）'; limit='正常'
    picks=@(
      @{id='storytold/photocraft'; tier='S'; score=83; risk='低'; action='试玩'},
      @{id='deeplethe/solid-glass'; tier='A'; score=72; risk='中'; action='研究'}
    )
    rejects=@(
      @{id='storytold/wordcraft'; reason='同 owner 3 天内已推荐 photocraft，降权 −10 后 62 分（B）'},
      @{id='storytold/pdfcraft'; reason='同 owner 降权后未达 A 线，且与 wordcraft 功能重叠'}
    )
    old=$oldOwner
    notes=@('`storytold` 一家今天有 3 个候选：按 owner 冷却只推 1 个（photocraft）。', 'wordcraft / pdfcraft 降权 −10 后落到 B 档，只进台账；不是“整族消失”。', '30 天冷却：photocraft 上次推荐已超过 30 天，本轮可进。')
  }
  @{
    n=7; file='07-周报日'; date='2026-10-25'; week='周日'; issue='07'
    cand=31; s=1; a=2; b=4; rej=1; api='5 次（Q1/Q2/Q2b/Q3/Q3s）'; limit='正常'
    picks=@(
      @{id='deeplethe/solid-glass'; tier='S'; score=86; risk='中'; action='试玩'},
      @{id='Aryanutkarsh/SeeCode'; tier='A'; score=78; risk='低'; action='试玩'},
      @{id='feder-cr/git-ai'; tier='A'; score=74; risk='中'; action='研究'}
    )
    rejects=@(@{id='nanaism/yomiyasu'; reason='日语润色 skill，对中文用户无用'})
    official=@(@{id='apache/maka'; note='Apache Maka（Incubating）：高性能 agent 工作区，保留完整执行记录'})
    old=$oldNormal
    notes=@('周日额外产出周报：本周 7/7 天成功，推荐 35 条（S 8 / A 27）。', 'Q3s 星段兜底今天触发：Q3 新面孔只有 2 条，加跑后补到 3 条。', '本周 Top：photocraft +19,566★、anatomy +12,343★、wordcraft +9,035★。')
    weekly=$true
  }
)

# ---------- 渲染 ----------
$outDir = P '模拟日报'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$tpl = [IO.File]::ReadAllText((P 'tools\daily-layout-c-finsara.html'), [Text.Encoding]::UTF8)
$detailCss = [IO.File]::ReadAllText((P 'tools\_detail.css'), [Text.Encoding]::UTF8)
$detailJs = [IO.File]::ReadAllText((P 'tools\_detail.js'), [Text.Encoding]::UTF8)
$baseD = $null
try {
  $cur = [IO.File]::ReadAllText((P 'data\site\daily-layout-c-finsara.generated.html'), [Text.Encoding]::UTF8)
  $m = [regex]::Match($cur, 'var D = (\{.*?\});\s*\r?\n')
  if ($m.Success) { $baseD = $m.Groups[1].Value | ConvertFrom-Json }
} catch { $null = $_ }
if (-not $baseD) { throw '读不到当前 C 页的 D 模板（cats/imgs）' }

$summary = @()
foreach ($sc in $scenarios) {
  $picks = @(); foreach ($x in @($sc.picks)) { $picks += New-Card $x.id $x.tier $x.score $x.risk $x.action '' }
  $rejs = @()
  foreach ($x in @($sc.rejects)) { $rejs += [ordered]@{ id = $x.id; reason = $x.reason } }
  $oldCards = @(); foreach ($x in @($sc.old)) { if ($x.id) { $oldCards += New-Card $x.id 'B' 60 '中' '观察' '' } }
  $officialCards = @(); foreach ($x in @($sc.official)) { if ($x -and $x.id) { $officialCards += New-Card $x.id 'D' $null '低' '看看' '' } }

  # 相关项目（picks + 退稿 + 老朋友 + 官方，去重）
  $rel = @()
  foreach ($c in $picks) { $rel += $c }
  foreach ($x in $rejs) { if ($proj[$x.id]) { $rel += New-Card $x.id 'dropped' $null '高' '放弃' $x.reason } }
  foreach ($c in $oldCards) { $rel += $c }
  foreach ($c in $officialCards) { $rel += $c }
  $seen = @{}; $rel2 = @(); foreach ($c in $rel) { if (-not $seen.ContainsKey($c.id)) { $seen[$c.id] = $true; $rel2 += $c } }
  $rel = $rel2

  # D
  $iso = $sc.date
  $short = $sc.date -replace '-', '.'
  $stats = [ordered]@{
    cand = [int]$sc.cand; rec = $picks.Count; s = [int]$sc.s; a = [int]$sc.a; b = [int]$sc.b
    rej = $rejs.Count; un = [Math]::Max(0, [int]$sc.cand - $picks.Count - $rejs.Count); total = 239; cats = 11; tags = 30
  }
  $d = [ordered]@{
    date = $sc.date; iso = $iso; shortDate = $short; week = $sc.week; issue = $sc.issue
    band = ("$($sc.date.Substring(0,4)) · $($sc.date.Substring(5,2)) · $($sc.date.Substring(8,2)) · $($sc.week) — NO.$($sc.issue)")
    stats = $stats; picks = @($picks); rejects = @($rejs); cats = $baseD.cats; imgs = $baseD.imgs; open = $baseD.open; related = @($rel); official = @($officialCards)
    emptyTitle = if ($sc.n -eq 4) { '本轮抓取失败' } else { '' }
    empty = if ($sc.n -eq 4) { 'Q1/Q2 返回 403（限流），Q3 只有少量老面孔；数据不完整，本轮不产出推荐，也不下「今天没有好项目」的结论。' } else { '' }
  }
  $dJson = ($d | ConvertTo-Json -Depth 12 -Compress).Replace('</', '<\/')

  # 报告 markdown
  $recN = $picks.Count
  $head = @"
# GitHub 每日实用榜 · $($sc.date)（$($sc.week)）

> ⚠️ **模拟样张**：以下为按 `RUBRIC.md` 构造的演示数据，不是真实抓取结果；仅用于检查日报/网页流程。
> 候选 **$($sc.cand) 条** → 新面孔 **$(if ($sc.cand -gt 0) { [Math]::Min(9, [int]$sc.cand) } else { 0 }) / 老朋友 $(if ($sc.cand -gt 0) { [Math]::Max(0, [int]$sc.cand - 9) } else { 0 })** → 推荐 **$recN 条（S $($sc.s) / A $($sc.a)）** ｜ GitHub API **$($sc.api)** ｜ 数据源：GitHub Search API（**匿名**）｜ 抓取时间 $($sc.date) 09:00 +08:00 ｜ 限流：$($sc.limit)
"@
  $body = @()
  $body += $head
  if ($picks.Count -eq 0) {
    $body += "## ⭐ 今日推荐`n`n今天没有达到推荐线的项目——**宁可少，不可注水**。"
  } else {
    $sIdx = 0; $sArr = @($picks | Where-Object { $_.tier -eq 'S' }); $aArr = @($picks | Where-Object { $_.tier -eq 'A' })
    if ($sArr.Count) {
      $body += "## ⭐ 重点推荐（S 档 · 完整版）"
      foreach ($c in $sArr) { $sIdx++; $body += (S12 $c $sIdx) }
    }
    if ($aArr.Count) {
      $body += "## ⭐ 次级推荐（A 档 · 简条）"
      foreach ($c in $aArr) { $body += (ABullet $c); $body += "  > 🔗 直接打开：https://github.com/$($c.id)" }
    }
    $body += "**S + A 合计 $recN 条**（上限 8；S ≤ 3）。"
  if ($officialCards.Count) {
    $body += "## 🏢 官方 / 大厂动态（特别栏目 · 最多 3 条）`n`n> 只收白名单大厂 / 官方的新发布（``owner_class=official``）。``tier=D``，标「🆕 刚发布 · 未达主推荐线」，**不计入 S/A/B，也不计入推荐计数**。`n"
    foreach ($x in @($sc.official)) {
      $p = $proj[$x.id]
      $body += "- **$($x.id)** · 🏢 官方 · 🆕 —— $($x.note)。链接：https://github.com/$($x.id)"
    }
  }
  }
  if ($oldCards.Count) {
    $rows = foreach ($x in @($sc.old)) { $c = $proj[$x.id]; "| $($x.id) | $($x.d) | $($x.note) |" }
    $body += "## 👀 老朋友动态`n`n| 仓库 | 本周 | 一句话 |`n|---|---|---|`n" + ($rows -join "`n")
  }
  if ($rejs.Count) {
    $body += "## 🗑 本轮淘汰（仅备注，不给链接）`n"
    foreach ($x in $rejs) { $body += "- ``$($x.id)`` —— $($x.reason)" }
  }
  if ($sc.weekly) {
    $body += "## 📅 周报摘要`n`n- 本周成功运行 **7/7** 天；推荐 **35 条**（S 8 / A 27）。`n- 周增 Top：photocraft +19,566★、anatomy +12,343★、wordcraft +9,035★。`n- 下周关注：中间星段 Q2b 的新面孔质量、owner 冷却是否过严。"
  }
  $body += "## 🧾 运行备注`n"
  foreach ($n in @($sc.notes)) { $body += "- $n" }
  $body += "## 🔗 一键入口`n`n- 🏠 本机工具库总览：``overview.html`` → **02 每日精选**（模拟页不写入真实站点）"
  if ($picks.Count) {
    $body += "- 🔍 今日推荐直链："
    foreach ($c in $picks) { $body += "  - [$($c.id)](https://github.com/$($c.id))" }
  }
  $md = ($body -join "`n")
  $reportHtml = ($md | ConvertFrom-Markdown).Html

  $relHtml = ($rel | ForEach-Object { '<button type="button" class="relchip" data-pid="' + [Security.SecurityElement]::Escape($_.id) + '">' + [Security.SecurityElement]::Escape($_.id) + '</button>' }) -join ''
  if (-not $relHtml) { $relHtml = '<span class="relempty">（本轮没有可链接条目）</span>' }

  $html = $tpl.Replace('/*__DAILY__*/null', $dJson).Replace('/*__DAILY__*/', $dJson).Replace('/*__FULLREPORT__*/', $reportHtml).Replace('/*__RELATED__*/', $relHtml).Replace('/*__DETAIL_CSS__*/', $detailCss).Replace('/*__DETAIL_JS__*/', $detailJs)
  $html = $html.Replace('../../assets/', '../assets/')
  $flag = '<style>.simflag{position:fixed;left:16px;top:14px;z-index:9999;background:#ff1f6b;color:#fff;font:700 10px/1.3 SFMono-Regular,Consolas,monospace;letter-spacing:.12em;padding:6px 9px;box-shadow:4px 4px 0 #111}</style><div class="simflag">SIMULATED · 模拟样张（非真实日报）</div>'
  $html = $html.Replace('<body>', "<body>`n$flag")
  $out = Join-Path $outDir ($sc.file + '.html')
  [IO.File]::WriteAllText($out, $html, $enc)
  $summary += [pscustomobject]@{ 文件 = $sc.file + '.html'; 推荐 = $recN; S = $sc.s; A = $sc.a; 相关 = $rel.Count; KB = [math]::Round((Get-Item $out).Length / 1KB, 1) }
}

foreach ($s in $summary) { Write-Host ("  {0,-16} 推荐 {1} ｜ S{2}/A{3} ｜ 相关 {4} ｜ {5} KB" -f $s.文件, $s.推荐, $s.S, $s.A, $s.相关, $s.KB) }
$readme = @"
# 模拟日报（7 页）

> ⚠️ 这些是按 `RUBRIC.md` / `TEMPLATES/daily.md` 构造的**模拟样张**，不是真实抓取结果；只用于检查日报与网页流程。**不写入 `data/`、不影响真实站点。**

| 页 | 场景 | 验证点 |
|---|---|---|
| 01 | 常规日 | S2 + A3、老朋友、退稿 |
| 02 | 满额日 | S3 + A5 = 8（硬上限）、owner 降权 |
| 03 | 冷清日 | 0 推荐、候选饱和、如实说 |
| 04 | 抓取失败 | Q1/Q2 403、数据不完整、不产出结论 |
| 05 | 风险日 | 红线 / 版权 / 许可冲突、只留 1 条 A |
| 06 | owner 冷却 | 同 owner 3 仓库只推 1 个，其余降权到 B |
| 07 | 周报日 | 周日周报、Q3s 兜底、7/7 |

所有页面都用 C 版日报模板；顶部有 SIMULATED 标记。点底部/完整日报里的「本日报相关」可打开详情卡。
"@
[IO.File]::WriteAllText((Join-Path $outDir 'README.md'), $readme, $enc)
Write-Host "`n✅ 已生成 $($summary.Count) 页 → 模拟日报\" -ForegroundColor Green
