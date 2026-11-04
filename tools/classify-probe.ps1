# classify-probe.ps1 — 分类与打标签专项探针（只读，可复跑）
#
# 回答三个问题：分类准不准、标签好不好、新项目进来会不会自动有标签。
# 做法：**独立重算**一遍"哪些分类关键词命中了这个项目"（不调用 sync 的分类器），
#       再和投影里已落地的 category 对比 → 找出"没证据的""有更强候选的""仅靠描述猜的"。
# 注意：本探针用的是**统计式**判据（关键词命中计数），与生产分类器的「最长关键词优先」不同，
#       所以它只用来**发现可疑样本**，不用于判定分类器对错。

param([int]$Top = 25, [switch]$Json)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
function Read-Jsonl([string]$p) {
  $out = @()
  if (-not (Test-Path $p)) { return $out }
  Get-Content $p -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { try { $out += ($_ | ConvertFrom-Json) } catch { $null = $_ } }
  return $out
}

$tx   = Get-Content (P 'data\taxonomy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$proj = @(Read-Jsonl (P 'data\projects.jsonl'))
$tags = @(Read-Jsonl (P 'data\human\function-tags.jsonl'))
$gate = @{}
if ($tx.PSObject.Properties['_类目门槛']) {
  foreach ($g in $tx.'_类目门槛'.PSObject.Properties) { $gate[$g.Name] = @($g.Value) }
}

# ---- 1) 建"关键词 → 分类"索引 ----
$kw = @()
foreach ($l1 in $tx.'一级分类'.PSObject.Properties) {
  foreach ($l2 in $l1.Value.children.PSObject.Properties) {
    foreach ($k in @($l2.Value)) {
      if ($k -is [string] -and $k.Trim()) { $kw += [pscustomobject]@{ key = $k.ToLower(); cat = ($l1.Name + '/' + $l2.Name) } }
    }
  }
}
$fallback = $tx.'_其他分类'.'一级' + '/' + $tx.'_其他分类'.'二级'
$kw = @($kw | Sort-Object { -$_.key.Length })     # 长词优先（与生产同思路）

# ---- 2) 逐个项目独立打分 ----
$rows = @()
foreach ($p in $proj) {
  $strong = ((@($p.function_tags)) + (@($p.user_keywords)) + (@($p.synonyms))) -join ' '
  $weak   = ((@($p.description, $p.note, (($p.topics) -join ' ')))) -join ' '
  $sLow = $strong.ToLower(); $wLow = $weak.ToLower()
  $score = @{}; $why = @{}
  foreach ($e in $kw) {
    $hitS = $sLow.Contains($e.key); $hitW = $wLow.Contains($e.key)
    if (-not ($hitS -or $hitW)) { continue }
    if (-not $score.ContainsKey($e.cat)) { $score[$e.cat] = 0; $why[$e.cat] = @() }
    if ($hitS) { $score[$e.cat] += 3; if ($why[$e.cat].Count -lt 3) { $why[$e.cat] += ($e.key + '(强)') } }
    if ($hitW) { $score[$e.cat] += 1; if ($why[$e.cat].Count -lt 3) { $why[$e.cat] += ($e.key + '(弱)') } }
  }
  $assigned = [string]$p.category.l1 + '/' + [string]$p.category.l2
  $aScore = if ($score.ContainsKey($assigned)) { $score[$assigned] } else { 0 }
  $bestCat = ''; $bestScore = 0
  foreach ($k2 in $score.Keys) { if ($score[$k2] -gt $bestScore) { $bestScore = $score[$k2]; $bestCat = $k2 } }
  $flags = @()
  if ($aScore -eq 0) { $flags += 'A_无证据' }
  if ($bestCat -and $bestCat -ne $assigned -and $bestScore -ge ($aScore + 3)) { $flags += 'B_有更强候选' }
  if ($assigned -eq $fallback) { $flags += 'C_兜底' }
  if ($gate.ContainsKey($assigned)) {
    $gHit = $false
    foreach ($t in $gate[$assigned]) { if ($sLow.Contains($t) -or $wLow.Contains($t)) { $gHit = $true; break } }
    if (-not $gHit) { $flags += 'D_门槛无证据' }
  }
  $strongHit = $false
  foreach ($e in $kw) { if ($sLow.Contains($e.key)) { $strongHit = $true; break } }
  if (-not $strongHit -and $aScore -gt 0) { $flags += 'E_仅靠描述猜' }
  $rows += [pscustomobject]@{
    id = [string]$p.id; cat = $assigned; aScore = $aScore; bestCat = $bestCat; bestScore = $bestScore
    margin = ($bestScore - $aScore); flags = ($flags -join ','); why = (($why[$assigned]) -join ' ')
    ft = (@($p.function_tags)).Count; origin = [string]$p.origin; hs = [string]$p.human.status
    one = [string]$p.human.one_liner
  }
}

# ---- 3) 汇总 ----
$agg = [ordered]@{}
foreach ($f in 'A_无证据','B_有更强候选','C_兜底','D_门槛无证据','E_仅靠描述猜') {
  $agg[$f] = @($rows | Where-Object { $_.flags -like ('*' + $f + '*') }).Count
}
$catDist = $rows | Group-Object cat | Sort-Object Count -Descending

# ---- 4) 标签质量 ----
$allTags = @(); foreach ($r in $tags) { $allTags += @($r.function_tags) }
$uniq = @($allTags | Where-Object { $_ } | Sort-Object -Unique)
$junkPat = '本次响应|NOASSERTION|本轮让位|待补|未知|同类$|^把|^半角'
$junk = @($allTags | Where-Object { "$_" -match $junkPat })
$langOnly = @($uniq | Where-Object { $_ -in @('python', 'javascript', 'typescript', 'rust', 'go', 'java', 'c', 'c++', 'swift', 'html', 'css', 'shell', 'ruby', 'php', 'kotlin', 'dart', 'lua', 'jupyter notebook') })
$noTag = @($rows | Where-Object { $_.ft -eq 0 })
$autoPreview = @()
foreach ($r in $noTag) {
  $p = $proj | Where-Object { $_.id -eq $r.id } | Select-Object -First 1
  $cand = @(); foreach ($t in @($p.topics)) { if ("$t".Length -ge 3) { $cand += "$t" } }
  $cand = @($cand | Where-Object { $_ -notin $langOnly })
  if ($cand.Count) { $autoPreview += [pscustomobject]@{ id = $r.id; cand = ($cand | Select-Object -First 3) -join ',' } }
}
$conf = $proj | Group-Object tags_confidence | ForEach-Object { "$(if($_.Name){$_.Name}else{'(空)'})=$($_.Count)" }

$report = [ordered]@{
  checked_at = (Get-Date -Format 's')
  projects = $rows.Count
  flags = $agg
  tag_coverage = "$($tags.Count)/$($rows.Count)"
  tag_total = $allTags.Count
  tag_unique = $uniq.Count
  tag_junk = $junk.Count
  tag_junk_samples = @($junk | Select-Object -First 10)
  confidence = $conf
  gate_categories = @($gate.Keys)
  suspects = @($rows | Where-Object { $_.flags -match 'B_有更强候选' } | Sort-Object margin -Descending | Select-Object -First $Top)
}
$rep = P ('data\_tmp\classify-probe-' + (Get-Date -Format 'yyyy-MM-dd-HHmmss') + '.json')
[System.IO.File]::WriteAllText($rep, ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

if ($Json) { $report | ConvertTo-Json -Depth 6; exit 0 }

Write-Host ''
Write-Host '=== 分类 · 独立复核（229 条）===' -ForegroundColor Cyan
Write-Host ('  有更强候选 (B): {0} 条 ｜ 无证据 (A): {1} 条 ｜ 兜底 (C): {2} 条 ｜ 门槛无证据 (D): {3} 条 ｜ 仅靠描述猜 (E): {4} 条' -f $agg['B_有更强候选'], $agg['A_无证据'], $agg['C_兜底'], $agg['D_门槛无证据'], $agg['E_仅靠描述猜'])
Write-Host ''
Write-Host '  ── 一级/二级分类分布（前 16）──'
$catDist | Select-Object -First 16 | ForEach-Object { Write-Host ('    {0,-26} {1,4}' -f $_.Name, $_.Count) }
Write-Host ''
Write-Host '  ── 疑似错分样本（另一个分类的证据明显更强）──' -ForegroundColor Yellow
$rows | Where-Object { $_.flags -match 'B_有更强候选' } | Sort-Object margin -Descending | Select-Object -First 15 | ForEach-Object {
  Write-Host ('    {0,-42} 现={1,-20} 候选={2,-20} 差={3} ｜ 证据: {4}' -f $_.id, $_.cat, $_.bestCat, $_.margin, $_.why)
}
Write-Host ''
Write-Host '  ── 人工抽查样本（分类是否说得通，看人话层）──' -ForegroundColor Cyan
$rows | Where-Object { -not $_.flags } | Get-Random -Count 12 | ForEach-Object {
  Write-Host ('    [{0,-20}] {1}' -f $_.cat, $_.id)
  Write-Host ('        {0}' -f ($_.one.Substring(0, [Math]::Min(70, $_.one.Length))))
}
Write-Host ''
Write-Host '=== 打标签 ===' -ForegroundColor Cyan
Write-Host ('  覆盖率: {0} 条 ({1}%) ｜ 标签总数 {2} ｜ 去重 {3}' -f $tags.Count, [math]::Round(100.0 * $tags.Count / $rows.Count, 1), $allTags.Count, $uniq.Count)
Write-Host ('  明显垃圾标签: {0} 个 ｜ 样本: {1}' -f $junk.Count, (($junk | Select-Object -First 6) -join ', '))
Write-Host ('  无标签项目: {0} 条 ｜ 其中能从 topics 自动补出"非语言标签"的: {1} 条' -f $noTag.Count, $autoPreview.Count)
Write-Host ('  自动补标签预览（前 8）:')
$autoPreview | Select-Object -First 8 | ForEach-Object { Write-Host ('    {0,-42} → {1}' -f $_.id, $_.cand) }
Write-Host ('  tags_confidence 分布: {0}' -f ($conf -join ' ｜ '))
Write-Host ("`n  报告: " + $rep.Substring($root.Length + 1)) -ForegroundColor DarkGray
