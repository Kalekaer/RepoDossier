# fetch-daily.ps1 — 当天检索的「计划 + 登记」层（**不联网**）
#
# 为什么：检索式以前只活在文档里，Agent 每次手拼 URL、也没有地方存原始返回。
# 现在：
#   1. -PlanOnly（默认）：从 data/queries.json 生成当天该跑的 URL 清单 → data/raw/<date>/r<N>/plan.json
#   2. -Import <Q> -File <json>：把宿主 HTTP 工具取回的响应登记成 raw，并更新 meta.json
# 脚本本身**不发任何网络请求**；Codex 可用 curl.exe/gh api 取回 JSON，DSH 可用 web_fetch。
#
# 用法：
#   & .\tools\fetch-daily.ps1 -PlanOnly
#   & .\tools\fetch-daily.ps1 -Date 2026-10-23 -PlanOnly
#   & .\tools\fetch-daily.ps1 -Import Q2b -File data\_tmp\q2b.json
#   & .\tools\fetch-daily.ps1 -PlanOnly -Json
#
# 退出码：0 = 正常；1 = 参数/文件问题；2 = 真源缺失

param(
  [string]$Date = '',
  [int]$Round = 0,
  [switch]$PlanOnly,
  [string]$Import = '',
  [string]$File = '',
  [string]$RequestUrl = '',
  [string]$QueryTask = '',
  [int]$HttpStatus = 0,
  [string]$HeaderFile = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P($r) { Join-Path $root $r }
. (P 'tools\query-partitions.ps1')
$enc = New-Object System.Text.UTF8Encoding($false)

if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host "✗ 日期格式：$Date" -ForegroundColor Red; exit 1 }

$specPath = P 'data\queries.json'
if (-not (Test-Path $specPath)) { Write-Host '✗ 缺 data/queries.json' -ForegroundColor Red; exit 2 }
$spec = Get-Content $specPath -Raw -Encoding UTF8 | ConvertFrom-Json

$dt = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$wd = [string]$(if ([int]$dt.DayOfWeek -eq 0) { 7 } else { [int]$dt.DayOfWeek })
$dayCfg = $spec.weekdays.$wd
. (P 'tools/query-contract.ps1')
. (P 'tools/github-transport.ps1')

function Get-RoundDir([int]$r) { P ("data\raw\{0}\r{1}" -f $Date, $r) }
function Get-MaxRound {
  $base = P ("data\raw\{0}" -f $Date)
  if (-not (Test-Path $base)) { return 0 }
  $dirs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^r(\d+)$' }
  if (-not $dirs) { return 0 }
  return ($dirs | ForEach-Object { [int]($_.Name -replace '^r', '') } | Measure-Object -Maximum).Maximum
}

# ---------- Import ----------
function Extract-Json([string]$text) {
  $a = $text.IndexOf('{'); $b = $text.LastIndexOf('}')
  if ($a -lt 0 -or $b -le $a) { throw '文件里找不到 JSON' }
  return $text.Substring($a, $b - $a + 1)
}

if ($Import) {
  if (-not $File) { Write-Host '✗ -Import 需要 -File' -ForegroundColor Red; exit 1 }
  $fp = if ([IO.Path]::IsPathRooted($File)) { $File } else { P $File }
  if (-not (Test-Path $fp)) { Write-Host "✗ 找不到 $fp" -ForegroundColor Red; exit 1 }
  $raw = [IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8)
  $resp = $null
  try { $resp = Extract-Json $raw | ConvertFrom-Json } catch { }
  $r = if ($Round -gt 0) { $Round } else { $max = Get-MaxRound; if ($max -eq 0) { 1 } else { $max } }
  $dir = Get-RoundDir $r
  New-Item -ItemType Directory -Force -Path $dir | Out-Null

  $ok = ($resp -and $resp.PSObject.Properties['items'])
  if ($Import -notmatch '^Q[A-Za-z0-9]+$') { throw 'Invalid query ID' }
  if ($ok) { Assert-QueryImport -Root $root -Date $Date -Round $r -Id $Import -RequestUrl $RequestUrl -QueryTask $QueryTask -Body (Extract-Json $raw) }

  $items = if ($ok) { @($resp.items) } else { @() }

  # attempt 自增：同一 Q 重试不覆盖旧文件（raw 只增不改）
  $metaPath = Join-Path $dir 'meta.json'
  $meta = if (Test-Path $metaPath) { Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{ date = $Date; round = $r; imports = @() } }
  $list = @($meta.imports)
  $prev = @($list | Where-Object { [string]$_.id -eq $Import })
  $next = 1
  if ($prev.Count) { $next = ([int](($prev | ForEach-Object { [int]$_.attempt }) | Measure-Object -Maximum).Maximum) + 1 }
  $fileName = if ($ok) { "$Import.$next.json" } else { "$Import.$next.error.json" }
  if (Test-Path (Join-Path $dir $fileName)) { throw 'Raw response already exists; refusing overwrite.' }
  if ($ok) {
    [IO.File]::WriteAllText((Join-Path $dir $fileName), (Extract-Json $raw), $enc)
  } else {
    $errorBody=if(Test-QueryContractRequired $spec $Date){'{"query_response_rejected":true}'}else{$raw.Substring(0, [Math]::Min(2000, $raw.Length))}
    [IO.File]::WriteAllText((Join-Path $dir $fileName), $errorBody, $enc)
  }
  $newFaces = $null
  $queryTotal = if($ok){[int]$resp.total_count}else{$null}
  if ($ok -and $Import -eq 'Q3') {
    $seen = @{}
    if (Test-Path (P 'data\seen.jsonl')) { foreach ($line in (Get-Content (P 'data\seen.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() })) { try { $o = $line | ConvertFrom-Json; $seen[([string]$o.full_name).ToLower()] = 1 } catch { } } }
    $q3Ids=@{};foreach($item in $items){$q3Ids[([string]$item.full_name).ToLowerInvariant()]=$true}
    foreach($old in @($list|Where-Object{$_.id -eq 'Q3' -and $_.ok})){
      $oldPath=Join-Path $dir $old.file
      if($old.sha256 -and (Get-FileHash -LiteralPath $oldPath).Hash -ne $old.sha256){throw 'Previous Q3 raw changed'}
      foreach($item in @((Get-Content $oldPath -Raw|ConvertFrom-Json).items)){$q3Ids[([string]$item.full_name).ToLowerInvariant()]=$true}
      $queryTotal=[math]::Max($queryTotal,[int]$old.total_count)
    }
    $newFaces = @($q3Ids.Keys | Where-Object { -not $seen.ContainsKey($_) }).Count
  }
  $list += [pscustomobject]@{
    id = $Import; attempt = $next; at = (Get-Date).ToString('s'); ok = [bool]$ok
    items = $items.Count; total_count = if ($ok) { [int]$resp.total_count } else { $null }
    newFaces = $newFaces
    file = $fileName
    sha256 = (Get-FileHash -LiteralPath (Join-Path $dir $fileName) -Algorithm SHA256).Hash
    request_url = $RequestUrl
    query_task = $QueryTask
    query_total_count = $queryTotal
    plan_sha256 = $(if(Test-Path (Join-Path $dir 'plan.json')){(Get-FileHash (Join-Path $dir 'plan.json')).Hash}else{$null})
  }
  $meta | Add-Member -NotePropertyName imports -NotePropertyValue $list -Force
  [IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 8), $enc)

  $nextPath=Join-Path $dir 'next-request.json'
  if(Test-Path $nextPath){
    $pending=Get-Content $nextPath -Raw|ConvertFrom-Json
    if($pending.kind -eq 'request' -and $pending.query -eq $Import -and $pending.url -eq $RequestUrl -and [int]$pending.attempt -eq $next){
      $headers=if($HeaderFile -and (Test-Path $HeaderFile)){Get-GitHubResponseHeaders ([IO.File]::ReadAllText($HeaderFile))}else{@{}}
      $status=if($HttpStatus){$HttpStatus}elseif($ok){200}else{0}
      $policy=Get-GitHubRetryPolicy $status $headers $raw
      $delay=if($status -eq 0 -or $policy.Fatal){60}else{[math]::Max(7,$policy.Delay)}
      @{next_allowed=[datetimeoffset]::UtcNow.AddSeconds($delay).ToString('o');date=$Date;round=$r;reason=$(if($policy.Limited){'host-rate-limit'}elseif($ok){'host-pace'}else{'host-error'});source='host-file'}|ConvertTo-Json|Set-Content (P 'data/raw/.collector-state.json') -Encoding UTF8
      @{id=$Import;at=[datetimeoffset]::UtcNow.ToString('o');channel='host-file';http_status=$status;status_inferred=(-not [bool]$HttpStatus);reservation=$pending.reservation;items=$items.Count;ok=[bool]$ok;request_url=$RequestUrl;query_task=$QueryTask}|ConvertTo-Json -Compress|Add-Content (Join-Path $dir 'requests.jsonl') -Encoding UTF8
    }
  }

  if(Test-QueryContractRequired $spec $Date){
    $coverage=& (P 'tools/check-queries.ps1') -Date $Date -Root $root -Json|ConvertFrom-Json
    Write-Host ("查询登记进度：成功 {0} / 计划 {1}；未完成 {2}。登记一条不代表日报完成。" -f $coverage.successful,$coverage.planned,(@($coverage.unfinished)-join ', '))
  }

  if ($Json) { [ordered]@{ ok = $ok; id = $Import; round = $r; items = $items.Count } | ConvertTo-Json -Compress }
  if ($ok) { Write-Host ("✓ 已登记 {0}：{1} 条 → {2}" -f $Import, $items.Count, (Split-Path $dir -Leaf)) -ForegroundColor Green }
  else { Write-Host ("✗ {0} 不是合法的 search 响应（缺 items）→ 已记 error" -f $Import) -ForegroundColor Red; exit 1 }
  exit 0
}

# ---------- PlanOnly ----------
$r = if ($Round -gt 0) { $Round } else {
  $max = Get-MaxRound
  if ($max -eq 0) { 1 }
  else {
    $dir = Get-RoundDir $max
    $hasRaw = @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Q\d|^Q[0-9]' }).Count -gt 0
    if ($hasRaw) { $max + 1 } else { $max }
  }
}
$dir = Get-RoundDir $r
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$planPath = Join-Path $dir 'plan.json'
$items = @(Get-DailyQueryPlanItems -Root $root -Date $Date -Spec $spec)
$plan = [ordered]@{
  date = $Date; round = $r; weekday = [int]$wd
  topic = [string]$dayCfg.topic; topic2 = [string]$dayCfg.topic2
  generated_at = (Get-Date).ToString('s')
  items = $items
  spec_sha256 = (Get-FileHash $specPath).Hash
}
if (Test-Path $planPath) { throw 'Plan already exists; use a new round instead of overwriting history.' }
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 8), $enc)

if ($Json) { $plan | ConvertTo-Json -Depth 8; exit 0 }
Write-Host ("计划 {0} · r{1} · 周{2} · topic={3}" -f $Date, $r, $wd, $dayCfg.topic) -ForegroundColor Cyan
foreach ($i in $items) {
  Write-Host ("  [{0}] {1}  {2}" -f $i.id, $(if ($i.kind -eq 'search') { '搜索' } elseif ($i.kind -eq 'probe') { '实验' } else { '条件' }), $(if ($i.url) { $i.url } else { '—' }))
}
Write-Host ("→ {0}" -f $planPath) -ForegroundColor DarkGray
exit 0
