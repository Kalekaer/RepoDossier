# channel-report.ps1 — 多通道候选池的渠道贡献报告（只读）
#
# 用法：.\tools\channel-report.ps1 -Date 2026-10-25
# 输入：data/audit/pool/<date>-all.jsonl（discovery-pool -AllQueries 产出）
# 输出：data/audit/channel-report-<date>.md / .json
#
# 回答：每个通道带来多少条、多少条是该通道独有、多少在库、多少合格。

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$PoolFile = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
. (Join-Path $PSScriptRoot 'score.ps1')
if (-not $PoolFile) { $PoolFile = P ("data\audit\pool\{0}-all.jsonl" -f $Date) }
if (-not (Test-Path $PoolFile)) { Write-Host "✗ 找不到池：$PoolFile" -ForegroundColor Red; exit 1 }
$rows = @(Read-JsonlSafe $PoolFile)
if (-not $rows.Count) { Write-Host "✗ 池为空" -ForegroundColor Red; exit 1 }

$grades=@{}
$seen=@{};foreach($s in Read-EvidenceRows (P 'data/seen.jsonl')){$seen[[string]$s.full_name]=$s}
foreach($file in @(Get-ChildItem (P 'data/picks') -File -Filter '*.jsonl' -ErrorAction SilentlyContinue|Where-Object{$_.BaseName -le $Date}|Sort-Object Name)){
 foreach($pick in Read-EvidenceRows $file.FullName){
  if($pick.full_name -and $null -ne $pick.score -and (Get-Tier $pick.score) -eq $pick.tier){$grades[[string]$pick.full_name]=$pick}
 }
}
$measurements=@(Read-EvidenceRows (P 'data/audit/review-metrics.jsonl')|Where-Object{$_.reviewed_at -and ((ConvertTo-EvidenceInstant $_.reviewed_at).AddHours(8).ToString('yyyy-MM-dd')) -le $Date})
foreach($m in $measurements){
 $mp=Get-EvidencePath $Root $m.evidence_file
 if((Get-FileHash -LiteralPath $mp).Hash -ne $m.evidence_sha256){throw 'Measured review evidence changed'}
}
$channels = @{}
foreach ($r in $rows) {
  $chs = @($r.channels)
  if (-not $chs.Count) { $chs = @([string]$r.channel) }
  $chs=@($chs|Where-Object{$_}|Sort-Object -Unique)
  foreach ($ch in $chs) {
    if (-not $ch) { continue }
    if (-not $channels.ContainsKey($ch)) { $channels[$ch] = [pscustomobject]@{ id = $ch; total = 0; unique = 0; eligible = 0; in_lib = 0;scored=0;sa=0;sa_unique=0;new_sa=0;new_sa_unique=0;reviewed=0;measured_cost_records=0;review_cost_seconds=$null;error_audited=0;confirmed_errors=0;confirmed_error_rate=$null;observed_sa_yield=$null } }
    $x = $channels[$ch]
    $x.total++
    if ($chs.Count -eq 1) { $x.unique++ }
    if ($r.eligible) { $x.eligible++ }
    if ($r.in_library) { $x.in_lib++ }
    $g=$grades[[string]$r.id]
    $metrics=@($measurements|Where-Object id -eq $r.id)
    if($g){$x.scored++;if($g.tier -in @('S','A')){$x.sa++;if($chs.Count -eq 1){$x.sa_unique++}}}
    $s=$seen[[string]$r.id]
    if($g.tier -in @('S','A') -and $g.date -eq $Date -and $s.first_seen -eq $Date -and $s.origin -ne 'user'){$x.new_sa++;if($chs.Count -eq 1){$x.new_sa_unique++}}
    if($g -or $metrics.Count){$x.reviewed++}
    foreach($m in $metrics){
      if($null -ne $m.elapsed_seconds){if($null -eq $x.review_cost_seconds){$x.review_cost_seconds=0};$x.review_cost_seconds+=$m.elapsed_seconds;$x.measured_cost_records++}
      if($m.phase -eq 'adjudication' -and $null -ne $m.error_confirmed){$x.error_audited++;if($m.error_confirmed){$x.confirmed_errors++}}
    }
  }
}
$list = @($channels.Values | Sort-Object id)
foreach($x in $list){if($x.scored){$x.observed_sa_yield=$x.sa/[double]$x.scored};if($x.error_audited){$x.confirmed_error_rate=$x.confirmed_errors/[double]$x.error_audited}}
$out = [ordered]@{
  date = $Date; pool = $rows.Count; eligible = @($rows | Where-Object eligible).Count
  in_library = @($rows | Where-Object in_library).Count
  channels = $list
  quality_scope='Historical rule scores of currently observed projects; not independent population recall. Multi-channel attribution overlaps.'
  cost_scope='Only recorded elapsed_seconds; missing costs stay null. Error rate requires explicit evidence-backed adjudications.'
  new_sa_scope='Daily valid S/A scores for auto-origin projects first admitted on this date; does not mean main recommendation. Attribution overlaps.'
  generated_at = (Get-Date).ToString('o')
}
$jsonPath = P ("data\audit\channel-report-{0}.json" -f $Date)
[IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

$md = @()
$md += "# 通道贡献 · $Date"
$md += ""
$md += ("- 池：{0} 条 ｜ 合格 {1} ｜ 在库 {2}" -f $out.pool, $out.eligible, $out.in_library)
$md += ""
$md += "| 通道 | 命中 | 独有 | 初筛可审 | 在库 | 有规则分 | 有S/A评分 | 独有S/A | 当日新入库S/A | 独有新入库S/A | 实测审阅秒数 | 已裁定错误/抽查记录 |"
$md += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
foreach ($x in $list) { $md += ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |" -f $x.id,$x.total,$x.unique,$x.eligible,$x.in_lib,$x.scored,$x.sa,$x.sa_unique,$x.new_sa,$x.new_sa_unique,$(if($null -eq $x.review_cost_seconds){'未记录'}else{$x.review_cost_seconds}),$(if($x.error_audited){"$($x.confirmed_errors)/$($x.error_audited)"}else{'未测量'})) }
$md += ""
$md += "> 「独有」= 该仓库只被这一条查询命中；用于判断通道是否带来增量。"
$md += '> S/A来自检索项目已有的有效规则评分，包含历史评分；不是当天主推荐或独立质量真值。成本缺失不填0，评审分歧不自动计作误判。多通道贡献不可直接相加；上述指标不代表总体召回。'
$mdPath = P ("data\audit\channel-report-{0}.md" -f $Date)
[IO.File]::WriteAllText($mdPath, ($md -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host ("✓ {0} 通道 ｜ 池 {1} ｜ {2}" -f $list.Count, $rows.Count, $mdPath) -ForegroundColor Green
exit 0
