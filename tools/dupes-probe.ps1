# dupes-probe.ps1 — P2-4 相似度去重**侦察**（离线 / 零安装 / **只产候选，绝不自动合并**）
#
# 为什么需要它：日报精品上限 8 条，"同一个东西换个名字/马甲"会白占名额（也影响同 owner 冷却的公平性）。
#   人工把 229 条两两比对不现实 ⇒ 先机器算相似度、**只产候选清单**，再由人确认 ✓
#
# 它**不做**什么（都是刻意的，别顺手加上 ✗）：
#   · 不改 `data/projects.jsonl`、不改任何原始层 ✓ —— 写坏的唯一来源就是这类"自动合并"
#   · 不自动合并、不自动删条目 —— 只写**新增的**候选 / 确认 / 否决台账 ✓
#   · 不联网、不装东西（不上 embedding 服务、不下载模型）✓
#
# 信号与权重（可解释、可复算；**全部写进输出**，便于人工复核 —— 别凭感觉调权重 ✗）
#   text 0.40 ｜ 人话层中文（一句话 + 痛点 + 例子）字符二元组 Jaccard
#   tag  0.25 ｜ function_tags 集合 Jaccard
#   name 0.20 ｜ 仓库名（owner 之后那段）字符二元组 Jaccard
#   cat  0.15 ｜ 同二级分类记 1，否则 0
#   另：**同名不同 owner**（仓库名归一化后相同）⇒ 分数抬到 ≥90 并标 `exact-name` ✓（fork / 改名马甲的第一信号）
#
# 用法：
#   & ".\tools\dupes-probe.ps1"                          # 分析 + 打印 Top 候选 + 写候选台账
#   & ".\tools\dupes-probe.ps1" -MinScore 70 -Top 20     # 收紧阈值
#   & ".\tools\dupes-probe.ps1" -Only owner/repo         # 只看某一条的候选
#   & ".\tools\dupes-probe.ps1" -Json                    # 机器可读
#   & ".\tools\dupes-probe.ps1" -SelfTest                # 用内置 fixture 自检打分器（不读写库）
#   & ".\tools\dupes-probe.ps1" -Confirm A B -Note "同一项目换了 owner"
#   & ".\tools\dupes-probe.ps1" -Reject  A B -Note "只是同类工具，不是重复"
# 退出码：0 正常（含"没找到候选"）；1 输入/参数有问题
#
# ⚠️ 三条**亲身踩过**的实现坑（2026-10-17，前两条都是自检抓出来的 —— 所以自检别省 ✗）：
#   ① 函数返回 HashSet **必须**写 return ,$set：PS 会把集合「解包」成元素（空集合→$null、单元素→标量）⇒ .Contains() 立刻炸
#   ② 参数名 $A/$B 会和自检里的 $a/$b **撞成同一个变量**（PS 变量名不区分大小写 ✗，见交接 §5 #4），
#      而它们带 [string] 约束 ⇒ 赋进去的 pscustomobject 被**静默转成字符串** ⇒ 所有信号取到 $null ⇒ 全 0 分（最难查的一类）
#      ⇒ 参数改名 $Left/$Right + [Alias('A')]/[Alias('B')] 保住命令行写法；自检 fixture 变量一律带 fx 前缀 ✓
#   ③ 短名缩写可能撞内置别名（隔离测试时 gc = Get-Content，把结论骗了一轮 ✗）⇒ 函数名用完整英文词 ✓
#
# 产物（前两个是**派生物**每次整份重写；后两个是**原始层**append-only）：
#   data/dupes-candidates.jsonl   候选对（score / 四个信号 / 为什么）
#   data/dupes-clusters.json      连通簇（≥2 条）
#   data/dupes-confirmed.jsonl    人工确认（append-only）
#   data/dupes-rejected.jsonl     人工否决（append-only，用来"别再打扰我"）
#
# ⚠️ 这四份都**不参与页面生成**（sync-projects 不读它们）⇒ 不需要重建页面 ✓
#    若 audit 的「页面比所有数据新」变红，说明它扫到了 data 全目录（踩坑 #25）→ 要把它加进白名单 ✗

param(
  [int]$MinScore = 55,
  [int]$Top = 25,
  [string]$Only = '',
  [switch]$Json,
  [switch]$SelfTest,
  [switch]$Confirm,
  [switch]$Reject,
  [Alias('A')][string]$Left = '',
  [Alias('B')][string]$Right = '',
  [string]$Note = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
$enc = New-Object System.Text.UTF8Encoding($false)   # 与其它 data/*.jsonl 一致：UTF-8 **无 BOM** ✓

# ---------- 相似度原语 ----------
function Get-Clean([string]$s) {
  if (-not $s) { return '' }
  # 只留字母 / 数字 / 中日韩字符；其余（空格、标点、emoji）一律丢掉 → 比对不受排版影响 ✓
  return ([regex]::Replace($s.ToLowerInvariant(), '[^\p{L}\p{Nd}\p{IsCJKUnifiedIdeographs}]', ''))
}
function Get-Bigrams([string]$s) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($s.Length -lt 2) { if ($s.Length -eq 1) { [void]$set.Add($s) }; return $set }
  for ($i = 0; $i -lt $s.Length - 1; $i++) { [void]$set.Add($s.Substring($i, 2)) }
  return ,$set   # ⚠️ 逗号**不能省**：PS 会把函数返回的集合"解包"成元素（空集合→$null、单元素→标量），.Contains() 立刻炸 ✗ 2026-10-17 自检抓到
}
function Get-Jac($setA, $setB) {
  # 兜底：空集合被解包后可能是 $null ⇒ 显式当 0 处理，别让上万次比对炸在这里 ✓
  if ($null -eq $setA -or $null -eq $setB) { return 0.0 }
  if ($setA.Count -eq 0 -and $setB.Count -eq 0) { return 0.0 }
  $inter = 0
  foreach ($x in $setA) { if ($setB.Contains($x)) { $inter++ } }
  $union = $setA.Count + $setB.Count - $inter
  if ($union -le 0) { return 0.0 }
  return [double]$inter / [double]$union
}
function Get-Tokens([string]$s) {
  if (-not $s) { return @() }
  return @($s -split '[\s,，、;；]+' | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
function Get-RepoName([string]$id) { $p = $id -split '/'; if ($p.Count -ge 2) { return $p[1] } else { return $id } }

# 一对的相似度（返回信号明细；权重写死在这里，与文件头一致 ✓）
function Measure-Pair($x, $y) {
  $textSim = Get-Jac $x.TextSet $y.TextSet
  $tagSim = Get-Jac $x.TagSet $y.TagSet
  $nameSim = Get-Jac $x.NameSet $y.NameSet
  $sameCat = ($x.L2 -and $y.L2 -and $x.L2 -eq $y.L2)
  $exact = ($x.NameKey -and $x.NameKey -eq $y.NameKey)
  $score = 100.0 * (0.40 * $textSim + 0.25 * $tagSim + 0.20 * $nameSim + 0.15 * $(if ($sameCat) { 1.0 } else { 0.0 }))
  if ($exact) { $score = [Math]::Max($score, 90.0) }
  return [pscustomobject]@{
    score = [Math]::Round($score, 1)
    text = [Math]::Round($textSim, 2); tag = [Math]::Round($tagSim, 2)
    name = [Math]::Round($nameSim, 2); sameCat = [bool]$sameCat; exact = [bool]$exact
  }
}

function New-Item2([string]$id, $h, [string]$tags, [string]$l2, [int]$stars) {
  $text = (([string]$h.one_liner) + ' ' + ([string]$h.problem) + ' ' + ([string]$h.example)).Trim()
  $nm = Get-RepoName $id
  # 标签集在**这里**就填好（原来留给调用方填 ⇒ 自检 fixture 忘了填、标签信号恒 0 ✗ 2026-10-17 自检抓到）
  $tagSet = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($t in (Get-Tokens $tags)) { if ($t) { [void]$tagSet.Add($t) } }
  return [pscustomobject]@{
    Id = $id; L2 = $l2; Stars = $stars
    TextSet = Get-Bigrams (Get-Clean $text)
    TagSet = $tagSet
    NameSet = Get-Bigrams (Get-Clean $nm)
    NameKey = (Get-Clean $nm)
    Tags = $tags
  }
}

# ---------- 自检（内置 fixture，不读写库）----------
if ($SelfTest) {
  Write-Host '=== dupes-probe 自检（内置 fixture）==='
  $ok = 0; $bad = 0
  function Chk([string]$n, [bool]$fx3) { if ($fx3) { $script:ok++; Write-Host ("  ✓ {0}" -f $n) -ForegroundColor Green } else { $script:bad++; Write-Host ("  ✗ {0}" -f $n) -ForegroundColor Red } }

  $mk = { param($id, $text, $tags, $l2) New-Item2 $id ([pscustomobject]@{ one_liner = $text; problem = ''; example = '' }) $tags $l2 100 }
  # 同文本 → 100
  $fx1 = & $mk 'o1/tool' '一个把 PDF 转成 Markdown 的本地工具，不联网。' 'PDF 转换' '办公/PDF 与阅读'
  $fx2 = & $mk 'o2/tool' '一个把 PDF 转成 Markdown 的本地工具，不联网。' 'PDF 转换' '办公/PDF 与阅读'
  $r1 = Measure-Pair $fx1 $fx2
  Chk ("同文本 + 同名 → 100 分且标 exact-name（实测 {0} ｜ exact={1}）" -f $r1.score, $r1.exact) ($r1.score -eq 100 -and $r1.exact)
  # 完全不同 → 低分
  $fx3 = & $mk 'o3/other' '一个给无人机用的飞控固件。' '飞控 固件' '其他/其他工具'
  $r2 = Measure-Pair $fx1 $fx3
  Chk ("毫不相干 → 分数 < 40（实测 {0}）" -f $r2.score) ($r2.score -lt 40)
  # 文本/标签/分类全同、只有名字不同 ⇒ 上限 = 100×(0.40+0.25+0.15) = 80（name 权重拿不到）
  $fx4 = & $mk 'o4/another' '一个把 PDF 转成 Markdown 的本地工具，不联网。' 'PDF 转换' '办公/PDF 与阅读'
  $r3 = Measure-Pair $fx1 $fx4
  Chk ("同文本/同标签/同分类、仅名字不同 → 80 分且不标 exact-name（实测 {0}）" -f $r3.score) ($r3.score -ge 80 -and -not $r3.exact)
  # 空文本不该崩
  $fx5 = & $mk 'o5/empty' '' '' ''
  $r4 = Measure-Pair $fx5 $fx1
  Chk ("空文本不崩且分数为 0（实测 {0}）" -f $r4.score) ($null -ne $r4 -and $r4.score -eq 0)
  Write-Host ''
  if ($bad) { Write-Host ("自检：{0} 通过 / {1} 失败" -f $ok, $bad) -ForegroundColor Red; exit 1 }
  Write-Host ("自检：{0} 通过 / 0 失败 ✓" -f $ok) -ForegroundColor Green
  exit 0
}

# ---------- 追加台账（只新增，不改）----------
function Add-Ledger([string]$file, [string]$idA, [string]$idB, [string]$note) {
  $p = P $file
  $line = (@{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); a = $idA; b = $idB; note = $note } | ConvertTo-Json -Compress)
  [System.IO.File]::AppendAllText($p, $line + "`n", $enc)
  Write-Host ("已追加 → {0}`n  {1}" -f $file, $line) -ForegroundColor Green
}
if ($Confirm -or $Reject) {
  if (-not $Left -or -not $Right) { Write-Host '❌ -Confirm / -Reject 需要同时给 -A 与 -B（都是 owner/repo）' -ForegroundColor Red; exit 1 }
  if ($Left -eq $Right) { Write-Host '❌ A 与 B 不能是同一条' -ForegroundColor Red; exit 1 }
  # 归一化顺序，保证 (A,B) 与 (B,A) 是同一条记录 ✓
  $pair = @($Left, $Right) | Sort-Object
  if ($Confirm) { Add-Ledger 'data\dupes-confirmed.jsonl' $pair[0] $pair[1] $Note } else { Add-Ledger 'data\dupes-rejected.jsonl' $pair[0] $pair[1] $Note }
  exit 0
}

# ---------- 读库 ----------
$libPath = P 'data\projects.jsonl'
if (-not (Test-Path $libPath)) { Write-Host '❌ 找不到 data\projects.jsonl' -ForegroundColor Red; exit 1 }
$raw = @(Get-Content $libPath -Encoding UTF8 | Where-Object { $_.Trim() })
if ($raw.Count -eq 0) { Write-Host '❌ data\projects.jsonl 是空的（先跑 sync-projects.ps1）' -ForegroundColor Red; exit 1 }

$items = New-Object System.Collections.Generic.List[object]
$badItems = @()
foreach ($ln in $raw) {
  try {
    $o = $ln | ConvertFrom-Json
    # 投影层的**真实形状**（2026-10-17 实测，别想当然 ✗）：
    #   stars    = 对象 {current, first, delta_7d…} ⇒ 取 .current
    #   category = 对象 {l1, l2}                    ⇒ 取 .l2
    #   function_tags = 数组                        ⇒ join 成字符串
    $h = if ($o.human) { $o.human } else { [pscustomobject]@{} }
    $starsNow = 0; if ($o.stars -and $o.stars.current) { $starsNow = [int]$o.stars.current }
    $l2Now = ''; if ($o.category -and $o.category.l2) { $l2Now = [string]$o.category.l2 }
    $tagsTxt = (@($o.function_tags) -join ' ')
    $it = New-Item2 $o.id $h $tagsTxt $l2Now $starsNow
    $it | Add-Member -NotePropertyName Tier -NotePropertyValue ([string]$o.tier) -Force
    $items.Add($it)
  } catch {
    # **一条一报**（不是每对都炸一遍 ✗）；有失败就在最后大声退出 ✓
    $badItems += ('{0}：{1}' -f $(if ($o) { $o.id } else { '?' }), $_.Exception.Message.Split([char]10)[0])
  }
}

if ($badItems.Count) {
  Write-Host ("❌ {0} 条项目无法解析（投影形状变了？下面最多列 3 条）" -f $badItems.Count) -ForegroundColor Red
  $badItems | Select-Object -First 3 | ForEach-Object { Write-Host ('  - ' + $_) -ForegroundColor Red }
  Write-Host '  本工具**没有**修改任何数据，修好输入重跑即可 ✓' -ForegroundColor DarkGray
  exit 1
}

# 已确认 / 已否决（用来不再打扰）
$done = @{}
foreach ($f in @('data\dupes-confirmed.jsonl', 'data\dupes-rejected.jsonl')) {
  $fp = P $f
  if (Test-Path $fp) {
    foreach ($ln in @(Get-Content $fp -Encoding UTF8 | Where-Object { $_.Trim() })) {
      try { $o = $ln | ConvertFrom-Json; $done[(@($o.a, $o.b) | Sort-Object) -join '|'] = $o } catch { }
    }
  }
}

# ---------- 两两比对 ----------
$pairs = New-Object System.Collections.Generic.List[object]
$compared = 0
for ($i = 0; $i -lt $items.Count; $i++) {
  for ($j = $i + 1; $j -lt $items.Count; $j++) {
    $x = $items[$i]; $y = $items[$j]
    if ($Only -and $x.Id -ne $Only -and $y.Id -ne $Only) { continue }
    $compared++
    $m = Measure-Pair $x $y
    if ($m.score -lt $MinScore) { continue }
    $key = (@($x.Id, $y.Id) | Sort-Object) -join '|'
    $pairs.Add([pscustomobject]@{
        a           = $x.Id; b = $y.Id; score = $m.score
        text        = $m.text; tag = $m.tag; name = $m.name
        same_l2     = $m.sameCat; exact_name = $m.exact
        a_stars     = $x.Stars; b_stars = $y.Stars
        a_l2        = $x.L2; b_l2 = $y.L2
        ledger      = $(if ($done.ContainsKey($key)) { 'ledger' } else { 'new' })
      })
  }
}
$pairs = @($pairs | Sort-Object -Property score -Descending)

# ---------- 连通簇（union-find，仅用于"看一眼规模"；不合并 ✓）----------
$parent = @{}
foreach ($it in $items) { $parent[$it.Id] = $it.Id }
function Find-Root([string]$x) { while ($script:parent[$x] -ne $x) { $x = $script:parent[$x] }; return $x }
foreach ($p in $pairs) {
  $ra = Find-Root $p.a; $rb = Find-Root $p.b
  if ($ra -ne $rb) { $parent[$rb] = $ra }
}
$clusters = @()
$groups = $pairs | Group-Object { Find-Root $_.a }
foreach ($g in $groups) {
  $members = @($g.Group | ForEach-Object { $_.a; $_.b } | Sort-Object -Unique)
  if ($members.Count -ge 2) {
    $clusters += [pscustomobject]@{ size = $members.Count; maxScore = ($g.Group | Measure-Object score -Maximum).Maximum; members = $members }
  }
}
$clusters = @($clusters | Sort-Object -Property size, maxScore -Descending)

# ---------- 落盘（派生物整份重写）----------
$candPath = P 'data\dupes-candidates.jsonl'
$lines = @($pairs | ForEach-Object { $_ | ConvertTo-Json -Compress })
[System.IO.File]::WriteAllText($candPath, (($lines -join "`n") + $(if ($lines.Count) { "`n" } else { '' })), $enc)
$cluPath = P 'data\dupes-clusters.json'
[System.IO.File]::WriteAllText($cluPath, (@{
      at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); minScore = $MinScore; projects = $items.Count
      compared_pairs = $compared; candidate_pairs = $pairs.Count; clusters = $clusters
    } | ConvertTo-Json -Depth 6), $enc)

# ---------- 报告 ----------
if ($Json) {
  @{ minScore = $MinScore; projects = $items.Count; compared_pairs = $compared; candidate_pairs = $pairs.Count
     exact_name_pairs = @($pairs | Where-Object { $_.exact_name }).Count; clusters = $clusters.Count; top = @($pairs | Select-Object -First $Top) } | ConvertTo-Json -Depth 6
  exit 0
}

Write-Host ''
Write-Host '=== 相似度去重侦察（P2-4，只产候选）===' -ForegroundColor Cyan
$exact = @($pairs | Where-Object { $_.exact_name })
$ledger = @($pairs | Where-Object { $_.ledger -eq 'ledger' })
Write-Host ("  库 {0} 条 ｜ 比对 {1:N0} 对 ｜ ≥{2} 分候选 {3} 对（其中同名不同 owner {4} 对 ｜ 已在台账 {5} 对）｜ 连通簇 {6} 组" -f `
    $items.Count, $compared, $MinScore, $pairs.Count, $exact.Count, $ledger.Count, $clusters.Count)
Write-Host ("  确认台账 {0} 行 ｜ 否决台账 {1} 行" -f `
    $(if (Test-Path (P 'data\dupes-confirmed.jsonl')) { @(Get-Content (P 'data\dupes-confirmed.jsonl') | Where-Object { $_.Trim() }).Count } else { 0 }), `
    $(if (Test-Path (P 'data\dupes-rejected.jsonl')) { @(Get-Content (P 'data\dupes-rejected.jsonl') | Where-Object { $_.Trim() }).Count } else { 0 }))

if ($pairs.Count -eq 0) {
  Write-Host ''
  Write-Host ("  ✓ 没有 ≥{0} 分的候选 —— 库里没有明显重复（这是**结论**，不是失败）" -f $MinScore) -ForegroundColor Green
} else {
  Write-Host ''
  Write-Host ("  ── Top {0} 候选（分数 ｜ 信号 ｜ 为什么）──" -f [Math]::Min($Top, $pairs.Count)) -ForegroundColor Yellow
  $byId = @{}; foreach ($it in $items) { $byId[$it.Id] = $it }
  foreach ($p in @($pairs | Select-Object -First $Top)) {
    Write-Host ("    [{0,5}] {1}  ↔  {2}" -f $p.score, $p.a, $p.b)
    Write-Host ("            text {0} ｜ tag {1} ｜ name {2} ｜ 同二级分类 {3} ｜ 同名 {4} ｜ ★{5} vs ★{6}{7}" -f `
        $p.text, $p.tag, $p.name, $p.same_l2, $p.exact_name, $p.a_stars, $p.b_stars, $(if ($p.ledger -eq 'ledger') { ' ｜ **已在台账**' } else { '' }))
  }
  if ($exact.Count) {
    Write-Host ''
    Write-Host '  ── 同名不同 owner（fork / 改名马甲的第一信号，优先人工看）──' -ForegroundColor Yellow
    foreach ($p in $exact) { Write-Host ("    [{0,5}] {1}  ↔  {2}" -f $p.score, $p.a, $p.b) }
  }
  if ($clusters.Count) {
    Write-Host ''
    Write-Host '  ── 连通簇（≥2 条；只是"看起来像一团"，**不是**合并建议）──' -ForegroundColor Yellow
    $n = 0
    foreach ($c in @($clusters | Select-Object -First 8)) {
      $n++
      Write-Host ("    簇 {0}（{1} 条，最高 {2} 分）：{3}" -f $n, $c.size, $c.maxScore, (($c.members | Select-Object -First 6) -join ' / '))
    }
  }
}

Write-Host ''
Write-Host ("  产物：data\dupes-candidates.jsonl（{0} 对）｜ data\dupes-clusters.json（{1} 组）" -f $pairs.Count, $clusters.Count) -ForegroundColor Green
Write-Host '  下一步（人工）：看中的用 `-Confirm A B -Note "…"` 记确认；只是同类工具用 `-Reject A B` 记否决 ✓' -ForegroundColor DarkGray
Write-Host '  ⚠️ 本工具**不改任何现有数据**；相似 ≠ 重复，确认前不要合并 ✗' -ForegroundColor DarkGray
exit 0
