# frame-sample.ps1 — frame 单元抽样/校验（只读审计，不写库）
#
# 设计见 data/audit/frame.md。
# 用法：
#   .\tools\frame-sample.ps1 -PlanOnly                 # 只出计划，不联网
#   .\tools\frame-sample.ps1 -ValidateAll -MaxCells 5  # 校验前 5 个单元的 total_count（联网）
#   .\tools\frame-sample.ps1 -Sample                   # 抽 15 格×20 条（联网）
#
# 退出码：0 成功；1 参数/输入错误；2 抽样框校验失败（有单元 >1000）

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [switch]$PlanOnly,
  [switch]$ValidateAll,
  [switch]$RetryErrors,
  [switch]$Sample,
  [string]$Seed = '',
  [int]$CellsPerStratum = 1,
  [int]$PerCell = 20,
  [int]$DelayMs = 6500,
  [int]$MaxCells = 0,
  [int]$CellStart = 0,
  [string]$Proxy = '',
  [string]$OnlyCell = '',
  [switch]$Append,
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
if (-not $OutDir) { $OutDir = P 'data\audit\frame' }
$outDir = $OutDir
New-Item -ItemType Directory -Force $outDir | Out-Null
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'score.ps1') | Out-Null

$dt = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$d30 = $dt.AddDays(-30).ToString('yyyy-MM-dd')

# ---------- 单元 ----------
$bands = @(
  [pscustomobject]@{ id = 'B1'; label = '200..499'; q = 'stars:200..499' },
  [pscustomobject]@{ id = 'B2'; label = '500..999'; q = 'stars:500..999' },
  [pscustomobject]@{ id = 'B3'; label = '1000..1999'; q = 'stars:1000..1999' },
  [pscustomobject]@{ id = 'B4'; label = '2000..4999'; q = 'stars:2000..4999' },
  [pscustomobject]@{ id = 'B5'; label = '>=5000'; q = 'stars:>=5000' }
)
$months = New-Object System.Collections.ArrayList
for ($y = 2015; $y -le 2026; $y++) {
  for ($m = 1; $m -le 12; $m++) {
    if ($y -eq 2026 -and $m -gt 9) { continue }
    [void]$months.Add([datetime]::new($y, $m, 1))
  }
}
function Get-Era([datetime]$d) {
  if ($d.Year -le 2019) { return 'E1-2015-2019' }
  if ($d.Year -le 2022) { return 'E2-2020-2022' }
  return 'E3-2023-2026'
}
$cells = New-Object System.Collections.ArrayList
foreach ($b in $bands) {
  foreach ($mo in $months) {
    $end = $mo.AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')
    $start = $mo.ToString('yyyy-MM-dd')
    [void]$cells.Add([pscustomobject]@{
      id = ('{0}|{1}' -f $b.id, $mo.ToString('yyyy-MM'))
      band = $b.id; band_label = $b.label; era = (Get-Era $mo)
      month = $mo.ToString('yyyy-MM'); start = $start; end = $end
      q = ('{0} created:{1}..{2} pushed:>{3} fork:false archived:false' -f $b.q, $start, $end, $d30)
    })
  }
}

# ---------- 随机种子 ----------
if (-not $Seed) { $Seed = ($Date -replace '-', '') + 'frame1' }
$sha = [Security.Cryptography.SHA256]::Create()
$seedInt = [BitConverter]::ToInt32($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed)), 0) -band 0x7fffffff
$rng = [Random]::new($seedInt)

function Get-RandomSubset($Arr, [int]$K, $Rng) {
  $pool = New-Object System.Collections.ArrayList
  foreach ($x in @($Arr)) { [void]$pool.Add($x) }
  $out = @()
  for ($i = 0; $i -lt $K -and $pool.Count -gt 0; $i++) {
    $idx = $Rng.Next(0, $pool.Count)
    $out += $pool[$idx]
    $pool.RemoveAt($idx)
  }
  return @($out)
}

# ---------- 选格 ----------
$selected = @()
foreach ($g in @($cells | Group-Object { "$($_.band)|$($_.era)" })) {
  $arr = @($g.Group)
  $k = [Math]::Min($CellsPerStratum, $arr.Count)
  $pool = @($arr)
  for ($i = 0; $i -lt $k; $i++) {
    $idx = $rng.Next(0, $pool.Count)
    $c = $pool[$idx]
    $selected += [pscustomobject]@{ cell = $c; P_c = [math]::Round($k / [double]$arr.Count, 6) }
    $pool = @($pool | Where-Object { $_.id -ne $c.id })
  }
}

$plan = [ordered]@{
  date = $Date; seed = $Seed; seed_int = $seedInt
  population = 'stars>=200, pushed-30d, fork:false, archived:false, created 2015-01..2026-09'
  cells_total = $cells.Count
  selected = @($selected | ForEach-Object { [ordered]@{ cell = $_.cell.id; band = $_.cell.band; era = $_.cell.era; month = $_.cell.month; P_c = $_.P_c; query = $_.cell.q } })
  per_cell = $PerCell; cells_per_stratum = $CellsPerStratum
  generated_at = (Get-Date).ToString('o')
}
$planPath = Join-Path $outDir ("plan-{0}.json" -f $Date)
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host ("✓ 计划：{0} 个单元 / 抽 {1} 格 / 每格 {2} 条 / seed={3}" -f $cells.Count, $selected.Count, $PerCell, $Seed) -ForegroundColor Green
$selected | ForEach-Object { Write-Host ("  {0}  P={1}  {2}" -f $_.cell.id, $_.P_c, $_.cell.q) }
if ($PlanOnly -or (-not $ValidateAll -and -not $Sample -and -not $RetryErrors)) { Write-Host ("  -> {0}" -f $planPath); exit 0 }

# ---------- 网络 ----------
function Invoke-GitHubSearch([string]$q, [int]$perPage, [int]$page = 0) {
  $url = 'https://api.github.com/search/repositories'
  $a = @('-s', '-G', $url, '--data-urlencode', "q=$q", '--data-urlencode', "per_page=$perPage", '--data-urlencode', 'sort=updated', '--data-urlencode', 'order=desc')
  if ($page -gt 0) { $a += @('--data-urlencode', "page=$page") }
  if ($Proxy) { $a += @('--proxy', $Proxy) }
  $a += @('-H', 'Accept: application/vnd.github+json', '-H', 'User-Agent: github-daily-picks/frame')
  if ($env:DSH_GITHUB_TOKEN) { $a += @('-H', "Authorization: Bearer $($env:DSH_GITHUB_TOKEN)") }
  for ($try = 1; $try -le 2; $try++) {
    Start-Sleep -Milliseconds $DelayMs
    $raw = & curl.exe @a 2>$null
    if ($raw) {
      try { $o = $raw | ConvertFrom-Json; if ($null -ne $o.total_count) { return $o } } catch { }
    }
    Start-Sleep -Milliseconds 2500
  }
  return $null
}

# ---------- 重试错误格 ----------
if ($RetryErrors) {
  $path = Join-Path $outDir ("cells-{0}.jsonl" -f $Date)
  if (-not (Test-Path $path)) { Write-Host "✗ 缺 cells 文件" -ForegroundColor Red; exit 1 }
  $rows = @(Read-JsonlSafe $path)
  $bad = @($rows | Where-Object { -not $_.ok })
  Write-Host (" 待重试 {0} 格" -f $bad.Count)
  $fixed = 0
  foreach ($r in $bad) {
    $res = Invoke-GitHubSearch ([string]$r.query) 1 0
    if ($null -ne $res) {
      $r.total_count = [int]$res.total_count
      $r.ok = ($r.total_count -le 1000)
      $r.checked_at = (Get-Date).ToString('o')
      $r.PSObject.Properties.Remove('error')
      $fixed++
      Write-Host ("  {0} N={1}" -f $r.cell, $r.total_count)
    }
  }
  $enc = New-Object Text.UTF8Encoding($false)
  $lines = @($rows | ForEach-Object { $_ | ConvertTo-Json -Compress })
  [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $enc)
  $left = @($rows | Where-Object { -not $_.ok }).Count
  Write-Host ("✓ 重试完成 {0}/{1} ｜ 剩余错误 {2}" -f $fixed, $bad.Count, $left) -ForegroundColor $(if ($left) { 'Red' } else { 'Green' })
  if ($left) { exit 2 }
  exit 0
}
if ($ValidateAll) {
  $list = @($cells)
  if ($CellStart -gt 0) { $list = @($list | Select-Object -Skip $CellStart) }
  if ($MaxCells -gt 0) { $list = @($list | Select-Object -First $MaxCells) }
  $path = Join-Path $outDir ("cells-{0}.jsonl" -f $Date)
  $enc = New-Object Text.UTF8Encoding($false)
  if ($CellStart -eq 0) { [IO.File]::WriteAllText($path, '', $enc) }
  $bad = 0; $i = 0
  foreach ($c in $list) {
    $i++
    $r = Invoke-GitHubSearch $c.q 1 0
    if ($null -eq $r) {
      $line = ([ordered]@{ cell = $c.id; query = $c.q; total_count = $null; ok = $false; error = 'api'; checked_at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
      $bad++
    } else {
      $n = [int]$r.total_count
      $ok = ($n -le 1000)
      if (-not $ok) { $bad++ }
      $line = ([ordered]@{ cell = $c.id; query = $c.q; total_count = $n; ok = $ok; checked_at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress)
      Write-Host ("  [{0}/{1}] {2}  N={3}  {4}" -f $i, $list.Count, $c.id, $n, $(if ($ok) { 'OK' } else { '>1000' }))
    }
    [IO.File]::AppendAllText($path, $line + "`n", $enc)
  }
  Write-Host ("✓ 校验 {0} 格 ｜ 超限 {1} ｜ {2}" -f $list.Count, $bad, $path) -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
  if ($bad) { exit 2 }
  exit 0
}

# ---------- 抽样 ----------
if ($Sample) {
  $planSelectedCount = $selected.Count
  if ($OnlyCell) {
    $selected = @($selected | Where-Object { $_.cell.id -eq $OnlyCell })
    if (-not $selected.Count) { Write-Host "✗ 选中的 15 格里没有 $OnlyCell" -ForegroundColor Red; exit 1 }
  }
  $lib = @{}; foreach ($p in Read-JsonlSafe (P 'data\projects.jsonl')) { if ($p.id) { $lib[[string]$p.id] = $p } }
  $seen = @{}; foreach ($s in Read-JsonlSafe (P 'data\seen.jsonl')) { if ($s.full_name) { $seen[[string]$s.full_name] = $s } }
  $rows = New-Object System.Collections.ArrayList
  $cellsOut = @()
  $samplePath = Join-Path $outDir ("sample-{0}.jsonl" -f $Date)
  $sumPath = Join-Path $outDir ("summary-{0}.json" -f $Date)
  if ($Append -and (Test-Path $samplePath)) {
    foreach ($x in Read-JsonlSafe $samplePath) { [void]$rows.Add($x) }
    if (Test-Path $sumPath) { $prev = Get-Content $sumPath -Raw | ConvertFrom-Json; $cellsOut = @($prev.cells) }
  }
  foreach ($sel in $selected) {
    $c = $sel.cell
    $meta = Invoke-GitHubSearch $c.q 1 0
    if ($null -eq $meta) { Write-Host ("  ! {0} 查询失败" -f $c.id) -ForegroundColor Yellow; continue }
    $N = [int]$meta.total_count
    if ($N -le 0) { continue }
    if ($N -gt 1000) { Write-Host ("  ! {0} N={1} >1000，跳过（需再切分）" -f $c.id, $N) -ForegroundColor Red; continue }
    $pages = [Math]::Max(1, [Math]::Ceiling($N / 100.0))
    $page = $rng.Next(1, $pages + 1)
    $res = Invoke-GitHubSearch $c.q 100 $page
    if ($null -eq $res) { continue }
    $items = @($res.items)
    if ($items.Count -eq 0) { continue }
    $take = [Math]::Min($PerCell, $items.Count)
    $chosen = @(Get-RandomSubset $items $take $rng)
    foreach ($it in $chosen) {
      $rec = ConvertTo-RepoRecord -Item $it -Channel 'frame' -Date $Date
      $reason = Get-EligibilityReason $rec
      if (-not $reason) { $hit = Get-RedlineHit (([string]$rec.id + ' ' + [string]$rec.description)); if (@($hit.硬).Count) { $reason = 'redline' } }
      $rec.eligible = (-not $reason); $rec.exclude_reason = $reason
      $rec.in_library = $lib.ContainsKey($rec.id); $rec.in_seen = $seen.ContainsKey($rec.id)
      $rec | Add-Member -NotePropertyName cell -NotePropertyValue $c.id
      $rec | Add-Member -NotePropertyName band -NotePropertyValue $c.band
      $rec | Add-Member -NotePropertyName era -NotePropertyValue $c.era
      $rec | Add-Member -NotePropertyName month -NotePropertyValue $c.month
      $rec | Add-Member -NotePropertyName pop_n -NotePropertyValue $N
      $rec | Add-Member -NotePropertyName sample_n -NotePropertyValue $take
      $rec | Add-Member -NotePropertyName page -NotePropertyValue $page
      $rec | Add-Member -NotePropertyName P_c -NotePropertyValue $sel.P_c
      $rec | Add-Member -NotePropertyName seed -NotePropertyValue $Seed
      [void]$rows.Add($rec)
    }
    $cellsOut += [ordered]@{ cell = $c.id; pop_n = $N; page = $page; sample_n = $take; P_c = $sel.P_c }
  }
  $out = Join-Path $outDir ("sample-{0}.jsonl" -f $Date)
  [IO.File]::WriteAllText($out, (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n") + $(if ($rows.Count) { "`n" } else { '' }), (New-Object Text.UTF8Encoding($false)))
  $sum = [ordered]@{ date = $Date; seed = $Seed; selected = $planSelectedCount; sampled = $rows.Count; cells = $cellsOut; generated_at = (Get-Date).ToString('o') }
  [IO.File]::WriteAllText((Join-Path $outDir ("summary-{0}.json" -f $Date)), ($sum | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  Write-Host ("✓ 抽样 {0} 条 / {1} 格 → {2}" -f $rows.Count, $cellsOut.Count, $out) -ForegroundColor Green
  exit 0
}
exit 0
