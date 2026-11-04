# discovery-pool.ps1 — 把 Q7/试点结果整理成候选池（只写 data/audit，不进库）
#
# 用法：
#   .\tools\discovery-pool.ps1 -PilotFile data\_tmp\dsh-pool.json -Date 2026-10-25
#   .\tools\discovery-pool.ps1 -Date 2026-10-28                 # 读 data/raw/<date>/r*/Q7*.json
#   .\tools\discovery-pool.ps1 -Date 2026-10-25 -RawDir data\_tmp\q7
#
# 输出：data/audit/pool/<date>.jsonl
# 退出码：0 成功；1 输入缺失；2 数据不合法

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$PilotFile = '',
  [string]$RawDir = '',
  [string]$OutDir = '',
  [switch]$AllQueries,
  [string]$OutFile = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'score.ps1') | Out-Null
if (-not $OutDir) { $OutDir = P 'data\audit\pool' }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ---------- 台账 / 库 ----------
$lib = @{}
foreach ($p in Read-JsonlSafe (P 'data\projects.jsonl')) { if ($p.id) { $lib[[string]$p.id] = $p } }
$seen = @{}
foreach ($s in Read-JsonlSafe (P 'data\seen.jsonl')) { if ($s.full_name) { $seen[[string]$s.full_name] = $s } }

# ---------- 读候选 ----------
$items = @()
if ($PilotFile) {
  if (-not (Test-Path $PilotFile)) { Write-Host "✗ 找不到 pilot：$PilotFile" -ForegroundColor Red; exit 1 }
  $raw = Get-Content $PilotFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $items = @($raw.items)
  $channel = 'pilot'
} else {
  if (-not $RawDir) { $RawDir = P ("data\raw\{0}" -f $Date) }
  $filter = if ($AllQueries) { 'Q*.json' } else { 'Q7*.json' }
  $files = @(Get-ChildItem $RawDir -Recurse -File -Filter $filter -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.error.json' })
  if (-not $files.Count) { Write-Host "✗ 没有 raw：$RawDir" -ForegroundColor Red; exit 1 }
  foreach ($f in $files) {
    try {
      $registration = Join-Path $f.DirectoryName 'meta.json'
      if (Test-Path $registration) {
        $registered = @((Get-Content $registration -Raw -Encoding UTF8 | ConvertFrom-Json).imports |
          Where-Object { $_.ok -and $_.file -eq $f.Name })
        if (-not $registered.Count) { continue }
        $entry = $registered[-1]
        if ($entry.sha256 -and (Get-FileHash -LiteralPath $f.FullName).Hash -ne $entry.sha256) { throw 'raw checksum mismatch' }
      }
      $raw = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($raw.incomplete_results) { throw 'incomplete search response' }
      if (-not $raw.PSObject.Properties['items'] -or $raw.items -isnot [array]) { throw 'not a search response' }
      $qid = ($f.Name -split '\.')[0]
      foreach ($it in @($raw.items)) {
        $items += [pscustomobject]@{ item = $it; channel = $qid }
      }
    } catch { Write-Host ("✗ 解析失败：{0}" -f $f.Name) -ForegroundColor Red; exit 2 }
  }
}

# ---------- 归一化 + 资格 ----------
$rows = New-Object System.Collections.ArrayList
$byReason = @{}
$byId = @{}
foreach ($entry in $items) {
  $it = if ($entry.PSObject.Properties['item']) { $entry.item } else { $entry }
  $ch = if ($entry.PSObject.Properties['channel']) { [string]$entry.channel } else { 'pilot' }
  $rec = ConvertTo-RepoRecord -Item $it -Channel $ch -Date $Date
  $rec['review_flags'] = @()
  if([string]::IsNullOrWhiteSpace([string]$rec.description)) { $rec.review_flags += 'readme_required' }
  $reason = Get-EligibilityReason $rec
  if (-not $reason) {
    $hit = Get-RedlineHit (([string]$rec.id + ' ' + [string]$rec.description))
    if (@($hit.硬).Count -gt 0) { $reason = 'redline' }
  }
  if ($reason) {
    $rec.eligible = $false
    $rec.exclude_reason = $reason
    if (-not $byReason.ContainsKey($reason)) { $byReason[$reason] = 0 }
    $byReason[$reason]++
  }
  $rec.layer = Get-DshLayer $rec
  $rec.in_library = $lib.ContainsKey($rec.id)
  $rec.in_seen = $seen.ContainsKey($rec.id)
  if ($byId.ContainsKey($rec.id)) {
    $prev = $byId[$rec.id]
    $prev.hit_count = [int]$prev.hit_count + 1
    if (@($prev.channels) -notcontains $ch) { $prev.channels = @($prev.channels) + $ch }
    continue
  }
  $rec['channels'] = @($ch)
  $rec['hit_count'] = 1
  $obj = [pscustomobject]$rec
  $byId[$rec.id] = $obj
  [void]$rows.Add($obj)
}

# ---------- 写池 ----------
$out = if ($OutFile) { $OutFile } else { Join-Path $OutDir ("{0}.jsonl" -f $Date) }
$enc = New-Object System.Text.UTF8Encoding($false)
$lines = $rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }
[IO.File]::WriteAllText($out, (($lines -join "`n") + "`n"), $enc)

$eligible = @($rows | Where-Object { $_.eligible })
$known = @($eligible | Where-Object { $_.in_library }).Count
$share = if ($eligible.Count) { [math]::Round($known / [double]$eligible.Count, 4) } else { 0 }
Write-Host ("✓ pool {0} 条 ｜ 合格 {1} ｜ 在库 {2} ｜ known_share {3:P1}" -f $rows.Count, $eligible.Count, $known, $share) -ForegroundColor Green
if ($byReason.Count) { Write-Host ("  排除：" + (($byReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')) }
Write-Host ("  -> {0}" -f $out)
exit 0
