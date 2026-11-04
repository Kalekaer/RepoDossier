# build-weekly.ps1 — 周报页生成器（2026-10-20）
#
# 口径唯一出处：`周报设计-2026-10-20.md` §3（个 / 条、四个集合、星数周增、状态变更）。
# 版式唯一出处：tools/templates/weekly.html（W01 版式，已移除样例数据）。
# 默认使用本期统计事实，显式 Headline/Judgments 可提供人工判断，不沿用旧期文案。
#
# 用法：
#   .\tools\build-weekly.ps1                          # 默认：最近一个完整周（周一至周日）
#   .\tools\build-weekly.ps1 -WeekStart 2026-10-12    # 指定周一
#   .\tools\build-weekly.ps1 -Check -WeekStart 2026-10-12   # 只算统计，与样张对比，不写页
# 输出：data/site/weekly-<周日>.generated.html
# 退出码：0 成功；1 失败

[CmdletBinding()]
param(
  [string]$WeekStart = '',
  [string]$Headline = '',
  [string[]]$Judgments = @(),
  [switch]$Check,
  [string]$OutFile = '',
  [string]$GeneratedOn = '',
  [switch]$Backfill
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function P([string]$rel) { Join-Path $root $rel }
. (P 'tools\weekly-utils.ps1')
if (-not $GeneratedOn) { $GeneratedOn = Get-BeijingDate }
function Fail($m) { Write-Host "✗ $m" -ForegroundColor Red; exit 1 }
$enc = New-Object System.Text.UTF8Encoding($false)
function ReadUtf8($p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) }
function WriteUtf8($p, $t) { [IO.File]::WriteAllText($p, $t, $enc) }

# ---------- 统计区间 ----------
if (-not $WeekStart) {
  # 最近一个完整周：今天所在周一往前推 7 天（若今天就是周一，仍取刚结束的上一周）
  $today = [datetime]::ParseExact($GeneratedOn,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
  $dow = ([int]$today.DayOfWeek + 6) % 7          # 周一=0
  $WeekStart = $today.AddDays(-$dow - 7).ToString('yyyy-MM-dd')
}
$startDt = [datetime]::ParseExact($WeekStart, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
if ($startDt.DayOfWeek -ne [DayOfWeek]::Monday) { Fail "WeekStart 必须是周一：$WeekStart（$($startDt.DayOfWeek)）" }
$endDt = $startDt.AddDays(6)
if (-not $Check -and $endDt -ge [datetime]::ParseExact($GeneratedOn,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)) { Fail '统计区间尚未结束，不能发布周报。' }
$start = $startDt.ToString('yyyy-MM-dd'); $end = $endDt.ToString('yyyy-MM-dd')
$dates = @(0..6 | ForEach-Object { $startDt.AddDays($_).ToString('yyyy-MM-dd') })
$issueNo = [int]((($startDt - [datetime]'2026-10-12').Days) / 7) + 1
if ($issueNo -lt 1) { Fail "统计区间早于 W01（2026-10-12）：$WeekStart" }
$issue = 'W{0:D2}' -f $issueNo
$weekdays = @('周一','周二','周三','周四','周五','周六','周日')

# ---------- 读库 ----------
$projPath = P 'data\projects.jsonl'
if (-not (Test-Path $projPath)) { Fail '找不到 data\projects.jsonl' }
$projs = @{}
$all = New-Object System.Collections.ArrayList
foreach ($l in [IO.File]::ReadAllLines($projPath, [Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($l)) { continue }
  try { $o = $l | ConvertFrom-Json } catch { continue }
  if (-not $o -or -not $o.id) { continue }
  $projs[[string]$o.id] = $o
  [void]$all.Add($o)
}

function Clean([string]$s) {
  if (-not $s) { return '' }
  # 与 build-samples 同一套运行层术语替换（页面数据里不许留旧词）
  return $s.Replace('淘汰原因','D 档原因').Replace('淘汰','剔除').Replace('精品','主推荐').Replace('候选','检索结果').Replace('跟踪','记录').Replace('未评档','SABCD 档')
}
function OneLiner($p) {
  if (-not $p) { return '' }
  $h = $p.human
  if ($h -and $h.one_liner) { return (Clean ([string]$h.one_liner)) }
  return (Clean ([string]$p.description))
}
function Card($id, $tier, $score, $first) {
  $p = $projs[$id]
  $exp = $null
  if ($p -and $p.experience -and $null -ne $p.experience.score) { $exp = [int]$p.experience.score }
  $stars = if ($p -and $p.stars) { [int]$p.stars.current } else { 0 }
  return [ordered]@{
    id = $id; tier = $tier; score = $score; exp = $exp; stars = $stars; one = (OneLiner $p)
  }
}

# ---------- 快照：找到 / 星数周增 ----------
$snapStars = @{}      # date -> @{ id -> stars }
$foundSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($d in $dates) {
  $snapPath = P "data\snapshots\$d.jsonl"
  $map = @{}
  if (Test-Path $snapPath) {
    foreach ($l in [IO.File]::ReadAllLines($snapPath, [Text.Encoding]::UTF8)) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      try { $s = $l | ConvertFrom-Json } catch { continue }
      if (-not $s.full_name) { continue }
      [void]$foundSet.Add([string]$s.full_name)
      if ($null -ne $s.stars) { $map[[string]$s.full_name] = [int]$s.stars }
    }
  }
  $snapStars[$d] = $map
}
$found = $foundSet.Count

# ---------- picks：评分 / 主推荐 / B·C·D ----------
$pickRows = @()        # 区间内全部 picks 行（date+full_name）
$lastTier = @{}        # id -> 最后一次 tier
$tierOrder = @{ S = 0; A = 1; B = 2; C = 3; D = 4; dropped = 4 }
foreach ($d in $dates) {
  $pickPath = P "data\picks\$d.jsonl"
  if (-not (Test-Path $pickPath)) { continue }
  foreach ($l in [IO.File]::ReadAllLines($pickPath, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    try { $pk = $l | ConvertFrom-Json } catch { continue }
    if (-not $pk -or -not $pk.full_name) { continue }
    $t = [string]$pk.tier
    if ($t -eq 'dropped') { $t = 'D' }
    if ($tierOrder.Keys -notcontains $t) { continue }
    $row = [ordered]@{
      date = $d; id = [string]$pk.full_name; tier = $t
      score = if ($null -ne $pk.score) { [int]$pk.score } else { $null }
      repeat = [bool]$pk.repeat
      tier_changed = [bool]$pk.tier_changed
      status = if ($pk.quota_block) { 'quota_block' } else { [string]$pk.daily_status }
    }
    $pickRows += [pscustomobject]$row
    $lastTier[$row.id] = $t
  }
}
# 口径：本期已评分 = 「统计区间找到」∩「统计区间 picks」（设计 §3.2）
$scoredIds = @($lastTier.Keys | Where-Object { $foundSet.Contains($_) })
$scoredTiers = [ordered]@{ S = 0; A = 0; B = 0; C = 0; D = 0 }
foreach ($id in $scoredIds) { $scoredTiers[$lastTier[$id]]++ }
$bcd = [ordered]@{ S = 0; A = 0; B = 0; C = 0; D = 0 }
foreach ($r in $pickRows) { $bcd[$r.tier]++ }

$mainRows = @($pickRows | Where-Object { ($_.tier -eq 'S' -or $_.tier -eq 'A') -and $_.status -notin @('over_quota', 'quota_block') })
$main = $mainRows.Count
$overflow = @($pickRows | Where-Object { ($_.tier -eq 'S' -or $_.tier -eq 'A') -and $_.status -in @('over_quota', 'quota_block') }).Count
$repeat = @($mainRows | Where-Object { $_.repeat }).Count

# ---------- 新入库 / 全库条数 ----------
$newProjs = @($all | Where-Object { [string]$_.first_seen -ge $start -and [string]$_.first_seen -le $end })
$new = $newProjs.Count
$newTiers = [ordered]@{ S = 0; A = 0; B = 0; C = 0; D = 0 }
foreach ($p in $newProjs) {
  $t = [string]$p.tier; if ($t -eq 'dropped') { $t = 'D' }
  if ($newTiers.Contains($t)) { $newTiers[$t]++ }
}
$libraryStart = @($all | Where-Object { [string]$_.first_seen -lt $start -and $_.first_seen }).Count
$libraryEnd = @($all | Where-Object { [string]$_.first_seen -le $end -and $_.first_seen }).Count
$noNew = $found - $scoredIds.Count

# ---------- 状态变更 / 不再看 ----------
$statusLog = @()
$slPath = P 'data\status-log.jsonl'
if (Test-Path $slPath) {
  foreach ($l in [IO.File]::ReadAllLines($slPath, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    try { $s = $l | ConvertFrom-Json } catch { continue }
    if ($s -and [string]$s.date -ge $start -and [string]$s.date -le $end) { $statusLog += $s }
  }
}
$dropLog = @($statusLog | Where-Object { [string]$_.to -eq 'dropped' })
$drops = $dropLog.Count
$dropCats = [ordered]@{}
foreach ($s in $dropLog) {
  $c = [string]$s.reason
  if (-not $c) { $c = '未记录' }
  if ($dropCats.Contains($c)) { $dropCats[$c]++ } else { $dropCats[$c] = 1 }
}
if ($dropCats.Count -eq 0) { $dropCats['未记录'] = 0 }

# ---------- 落盘天数 ----------
$reports = @($dates | Where-Object { Test-Path (P "reports\$_.md") }).Count
$runs = @($dates | Where-Object { Test-Path (P "data\runs\$_.md") }).Count

# ---------- 榜单 / 列表 ----------
$best = @{}
foreach ($r in $mainRows) {
  $id = $r.id
  if (-not $best.ContainsKey($id)) { $best[$id] = $r; continue }
  $b = $best[$id]
  $sb = if ($null -ne $b.score) { $b.score } else { -1 }
  $sn = if ($null -ne $r.score) { $r.score } else { -1 }
  if ($sn -gt $sb) { $best[$id] = $r }
}
$mainTop = @($best.Values | Sort-Object @{ Expression = { if ($null -ne $_.score) { [int]$_.score } else { -1 } }; Descending = $true }, @{ Expression = { $p = $projs[$_.id]; if ($p -and $p.experience -and $null -ne $p.experience.score) { [int]$p.experience.score } else { -1 } }; Descending = $true }, @{ Expression = { $p = $projs[$_.id]; if ($p -and $p.stars) { [int]$p.stars.current } else { 0 } }; Descending = $true }, @{ Expression = { $_.id } } |
  ForEach-Object { Card $_.id $_.tier $_.score $null })

$dailyMain = @($dates | ForEach-Object {
    $d = $_
    $rows = @($mainRows | Where-Object { $_.date -eq $d })
    [ordered]@{ date = $d; S = @($rows | Where-Object { $_.tier -eq 'S' }).Count; A = @($rows | Where-Object { $_.tier -eq 'A' }).Count }
  })
$mainByDay = @($dates | ForEach-Object {
    $d = $_
    $rows = @($mainRows | Where-Object { $_.date -eq $d })
    [ordered]@{ date = $d; items = @($rows | ForEach-Object { $c = Card $_.id $_.tier $_.score $null; [ordered]@{ id = $c.id; tier = $c.tier; score = $c.score; one = $c.one } }) }
  })
$newTrend = @($dates | ForEach-Object {
    $d = $_
    $rows = @($newProjs | Where-Object { [string]$_.first_seen -eq $d })
    $m = [ordered]@{ date = $d; S = 0; A = 0; B = 0 }
    foreach ($p in $rows) { $t = [string]$p.tier; if ($m.Contains($t)) { $m[$t]++ } }
    $m
  })

# 星数周增：周日快照 − 周一快照，两天都有才计算
$starDeltas = @()
$s0 = $snapStars[$dates[0]]; $s1 = $snapStars[$dates[-1]]
foreach ($id in $s0.Keys) {
  if (-not $s1.ContainsKey($id)) { continue }
  $delta = [int]$s1[$id] - [int]$s0[$id]
  if ($delta -le 0) { continue }
  if (-not $projs.ContainsKey($id)) { continue }
  $p = $projs[$id]
  $starDeltas += [pscustomobject]@{ id = $id; delta = $delta; stars = [int]$s1[$id]; tier = [string]$p.tier }
}
$starTop = @($starDeltas | Sort-Object @{ Expression = { $_.delta }; Descending = $true }, @{ Expression = { $_.stars }; Descending = $true }, @{ Expression = { $_.id } } |
  Select-Object -First 5 | ForEach-Object { $card=Card $_.id $_.tier $null $null; $card.delta=$_.delta; $card })

$newList = @($newProjs | Where-Object { @('S', 'A', 'B', 'C') -contains [string]$_.tier } |
  Sort-Object @{ Expression = { [string]$_.first_seen } }, @{ Expression = { $tierOrder[[string]$_.tier] } }, @{ Expression = { [string]$_.id } } |
  ForEach-Object { [ordered]@{ id = [string]$_.id; tier = [string]$_.tier; first_seen = [string]$_.first_seen; one = (OneLiner $_) } })

$scoredList = @($scoredIds | Sort-Object | ForEach-Object {
    $id = $_
    $c = Card $id $lastTier[$id] $null $null
    $p = $projs[$id]
    $drop = if ($p) { Clean ([string]$p.drop_reason) } else { '' }
    [ordered]@{ id = $c.id; tier = $c.tier; score = $c.score; exp = $c.exp; stars = $c.stars; one = $(if ($c.tier -eq 'D' -and $drop) { $(if ($c.one) { $c.one + ' ｜ ' + $drop } else { $drop }) } else { $c.one }) }
  })

$tierChanges = @($pickRows | Where-Object { $_.tier_changed }).Count

$data = [ordered]@{
  dates = $dates; found = $found; scored = $scoredIds.Count; scoredTiers = $scoredTiers
  noNew = $noNew; new = $new; newTiers = $newTiers; main = $main; bcd = $bcd
  overflow = $overflow; repeat = $repeat; tierChanges = $tierChanges; drops = $drops
  libraryStart = $libraryStart; libraryEnd = $libraryEnd; reports = $reports; runs = $runs
  mainTop = $mainTop; dailyMain = $dailyMain; newTrend = $newTrend; starTop = $starTop
  dropCats = $dropCats; newList = $newList; scoredList = $scoredList; mainByDay = $mainByDay
}

# ---------- 只算不写 ----------
if ($Check) {
  Write-Host "=== $issue · $start → $end ===" -ForegroundColor Cyan
  foreach ($k in @('found','scored','noNew','new','main','overflow','repeat','tierChanges','drops','libraryStart','libraryEnd','reports','runs')) {
    "  {0,-13} {1}" -f $k, $data[$k]
  }
  "  scoredTiers   " + (($data.scoredTiers.GetEnumerator() | ForEach-Object { "$($_.Key)$($_.Value)" }) -join ' ')
  "  newTiers      " + (($data.newTiers.GetEnumerator() | ForEach-Object { "$($_.Key)$($_.Value)" }) -join ' ')
  "  bcd           " + (($data.bcd.GetEnumerator() | ForEach-Object { "$($_.Key)$($_.Value)" }) -join ' ')
  "  mainTop {0} ｜ newList {1} ｜ scoredList {2} ｜ mainByDay {3} ｜ starTop {4}" -f $data.mainTop.Count, $data.newList.Count, $data.scoredList.Count, $data.mainByDay.Count, $data.starTop.Count
  Write-Host '  （-Check 不写页面）'
  exit 0
}
# ---------- 生成页面 ----------
$tplPath = P 'tools\templates\weekly.html'
if (-not (Test-Path $tplPath)) { Fail "找不到周报模板 $tplPath" }
$html = ReadUtf8 $tplPath
$html = $html.Replace('<span class="no">01</span>', ('<span class="no">{0:D2}</span>' -f $issueNo))
$html = $html.Replace('2026-10-19 至 2026-10-25',($endDt.AddDays(1).ToString('yyyy-MM-dd')+' 至 '+$endDt.AddDays(7).ToString('yyyy-MM-dd')))
$html = $html.Replace('这周不是“多”，是三条线同时变粗。','统计区间盘点')
$html = $html.Replace('2026-10-20 · W01',($GeneratedOn+' · W01'))

# 换周标签（模板里 W01 与日期是写死的）
$mdRange = "$start`（周一）00:00:00</b> 至 <b>$end`（周日）23:59:59"
$html = $html.Replace('<title>GitHub 周报 · W01 · 样张定稿</title>', "<title>GitHub 周报 · $issue · $start — $end</title>")
$html = $html.Replace('WINDOW</dt><dd>2026-10-12 — 2026-10-18</dd>', "WINDOW</dt><dd>$start — $end</dd>")
$html = $html.Replace('<b>2026-10-12（周一）00:00:00</b> 至 <b>2026-10-18（周日）23:59:59</b>', "<b>$mdRange</b>")
$html = $html.Replace('reports/weekly-2026-10-18.md', "reports/weekly-$end.md")
$html = $html.Replace('DRAWN</dt><dd>2026-10-20 · W01</dd>', "DRAWN</dt><dd>$((Get-Date).ToString('yyyy-MM-dd')) · $issue</dd>")
$html = $html.Replace('2026.10.12 — 10.18', ($startDt.ToString('yyyy.MM.dd')+' — '+$endDt.ToString('yyyy.MM.dd')))
$html = $html.Replace('W01', $issue)
$html = $html.Replace('样张定稿', '周报')

# 判断文案：默认本期统计；人工提供参数时使用人工判断。
if (-not $Headline) { $Headline = "统计区间找到 $found 个项目，已评分 $($scoredIds.Count) 个，主推荐 $main 条。" }
if ($Backfill) { $Headline = '补出 · '+$Headline }
if ($Headline) {
  $html = [regex]::Replace($html, '(?s)<p class="headline">.*?</p>', '<p class="headline">' + [System.Security.SecurityElement]::Escape($Headline) + '</p>')
}
if ($judgments.Count -gt 0) {
  $html = [regex]::Replace($html, '(?s)(<section[^>]*id="judge"[^>]*>.*?<div class="judge-list"[^>]*>).*?(</div>)', {
      param($m)
      $items = ($Judgments | ForEach-Object { '<article class="judge"><p>' + [System.Security.SecurityElement]::Escape($_) + '</p></article>' }) -join "`n"
      $m.Groups[1].Value + $items + $m.Groups[2].Value
    })
}
$data.judgments = @(
  @{n='01';h='统计区间找到与评分';p="找到 $found 个，已评分 $($scoredIds.Count) 个，无新评分 $noNew 个。";ev='依据快照与区间 picks';rep=''},
  @{n='02';h='主推荐与新入库';p="主推荐 $main 条，新入库 $new 个。";ev='主推荐排除达线未刊';rep=''}
)
if ($Judgments.Count) { $data.judgments=@($Judgments|ForEach-Object{@{n='';h='统计区间判断';p=$_;ev='';rep=''}}) }
$data.period = @{issue=$issue;start=$start;end=$end;generated_on=$GeneratedOn;backfill=[bool]$Backfill}
$data.stateChanges = @($statusLog | Where-Object { $_.to -and $_.to -ne 'dropped' } | ForEach-Object { ([string]$_.date)+' '+([string]$_.full_name)+' → '+([string]$_.to) })
$missingReports = @($dates | Where-Object { -not (Test-Path (P "reports\$_.md")) })
$quality = if ($missingReports.Count) { '缺失日报日期：'+($missingReports -join '、') } else { '统计区间日报均已落盘；查询失败与限流事实见各日运行日志。' }
$html = [regex]::Replace($html,'(?s)(<div class="qi"><b>查询异常</b>).*?(</div>)',('${1}'+[Security.SecurityElement]::Escape($quality)+'${2}'))
$html = [regex]::Replace($html,'(?s)(<div class="next-grid">).*?(</div>\s*</section>)','${1}<article class="next-card"><span class="tag">数据复核</span><h3>复核记录与证据</h3><p>按统计区间的观察项与数据缺口继续核对；未核实的判断不自动沿用上一期。</p></article>${2}')
$html = $html.Replace('主推荐全部 38 →',"主推荐全部 $main →").Replace('入库名单 183 →',"入库名单 $($newList.Count) →").Replace('本期评分 77 →',"本期评分 $($scoredIds.Count) →").Replace('星数榜 5 →',"星数榜 $($starTop.Count) →")
$html = $html.Replace('<section class="sec lead" id="lead">', ('<section class="sec lead" id="lead"><p class="note">'+$(if($issueNo -eq 1){'首期'}else{'上一期 W{0:D2}' -f ($issueNo-1)})+'</p>'))

# 换数据 JSON
$json = ($data | ConvertTo-Json -Depth 8 -Compress)
$json = $json.Replace('</', '<\/')
$m = [regex]::Match($html, '(?s)var D = \{.*?\};\s*\r?\n')
if (-not $m.Success) { Fail '模板里找不到 var D = {...};' }
$html = $html.Substring(0, $m.Index) + 'var D = ' + $json + ';' + "`n" + $html.Substring($m.Index + $m.Length)

# 生产路径：设计样张用 ../assets，data/site 要 ../../assets；首页链接换成生成页名。
$html = $html.Replace('../../assets/', '../assets/').Replace('../assets/', '../../assets/')
$html = $html.Replace('首页-报刊亭.html', 'home-brutal-token.generated.html')
$outName = if ($OutFile) { $OutFile } else { "weekly-$end.generated.html" }
$outPath = P "data\site\$outName"
WriteUtf8 $outPath $html
$reportPath = P "reports\weekly-$end.md"
if (-not (Test-Path $reportPath)) {
  $md = "# GitHub 周报 · $start（周一）00:00:00 至 $end（周日）23:59:59（北京时间，UTC+8） · $issue`n`n$Headline`n`n| 指标 | 数量 |`n|---|---:|`n| 找到 | $found |`n| 已评分 | $($scoredIds.Count) |`n| 主推荐 | $main |`n| 新入库 | $new |`n| 日报落盘 | $reports/7 |`n`n$quality`n`n[完整周报](../data/site/$outName)`n"
  WriteUtf8 $reportPath $md
}
$kb = [math]::Round((Get-Item $outPath).Length / 1KB, 1)
Write-Host ("✓ {0}  {1} KB  {2} · {3} → {4}" -f $outName, $kb, $issue, $start, $end) -ForegroundColor DarkGreen
Write-Host ("  found {0} ｜ scored {1} ｜ 主推荐 {2} ｜ 新入库 {3} ｜ 全库 {4}→{5}" -f $found, $scoredIds.Count, $main, $new, $libraryStart, $libraryEnd)
exit 0
