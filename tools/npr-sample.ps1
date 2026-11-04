# npr-sample.ps1 — M1 新项目召回抽样（16 格，100 条，只写 data/audit/npr）
#
# 前置：先跑 npr-precheck.ps1（16 格全部 ≤1000）。
# 设计：16 格全部入样（无 cell 选择概率）；每格 6 条，最大的 4 格 +1 条 = 100。
# 权重：w = 1 / (选页概率 × 页内抽样概率)，含不足100条的尾页；分 auto/user_found。
#
# 用法：.\tools\npr-sample.ps1 -Date 2026-10-25 -Seed 20261025

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$Seed = '20261025',
  [int]$PerCell = 6,
  [int]$Extra = 4,
  [int]$DelayMs = 6500,
  [string]$Proxy = '',
  [string]$OnlyCell = '',
  [switch]$Append,
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
if (-not $OutDir) { $OutDir = P 'data\audit\npr' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'score.ps1') | Out-Null

$prePath = Join-Path $OutDir ("precheck-{0}.jsonl" -f $Date)
if (-not (Test-Path $prePath)) { Write-Host "✗ 先跑 npr-precheck -Date $Date" -ForegroundColor Red; exit 1 }
$cells = @(Read-JsonlSafe $prePath | Where-Object { $_.ok })
if (-not $cells.Count) { Write-Host "✗ 预检无合格格" -ForegroundColor Red; exit 1 }

# 每格 6 条，最大 4 格 +1
$plan = @()
foreach ($c in $cells) { $plan += [pscustomobject]@{ c = $c; n = $PerCell } }
$top = @($cells | Sort-Object total_count -Descending | Select-Object -First $Extra)
foreach ($t in $top) { ($plan | Where-Object { $_.c.cell -eq $t.cell }).n++ }
$planSelected = $plan.Count
if ($OnlyCell) { $plan = @($plan | Where-Object { $_.c.cell -eq $OnlyCell }); if (-not $plan.Count) { Write-Host "✗ 没有 $OnlyCell" -ForegroundColor Red; exit 1 } }
$totalPlanned = ($plan | Measure-Object n -Sum).Sum

# 可复现 RNG
$sha = [Security.Cryptography.SHA256]::Create()
$seedInt = [BitConverter]::ToInt32($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed)), 0) -band 0x7fffffff
$rng = [Random]::new($seedInt)

function Invoke-GitHubSearch([string]$q, [int]$perPage, [int]$page = 0) {
  $url = 'https://api.github.com/search/repositories'
  $a = @('-s', '-G', $url, '--data-urlencode', "q=$q", '--data-urlencode', "per_page=$perPage", '--data-urlencode', 'sort=updated', '--data-urlencode', 'order=desc')
  if ($page -gt 0) { $a += @('--data-urlencode', "page=$page") }
  if ($Proxy) { $a += @('--proxy', $Proxy) }
  $a += @('-H', 'Accept: application/vnd.github+json', '-H', 'User-Agent: github-daily-picks/npr')
  if ($env:DSH_GITHUB_TOKEN) { $a += @('-H', "Authorization: Bearer $($env:DSH_GITHUB_TOKEN)") }
  for ($try = 1; $try -le 2; $try++) {
    Start-Sleep -Milliseconds $DelayMs
    $raw = & curl.exe @a 2>$null
    if ($raw) { try { $o = $raw | ConvertFrom-Json; if ($null -ne $o.total_count) { return $o } } catch { } }
    Start-Sleep -Milliseconds 2500
  }
  return $null
}
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

$lib = @{}; foreach ($p in Read-JsonlSafe (P 'data\projects.jsonl')) { if ($p.id) { $lib[[string]$p.id] = $p } }
$seen = @{}; foreach ($s in Read-JsonlSafe (P 'data\seen.jsonl')) { if ($s.full_name) { $seen[[string]$s.full_name] = $s } }

$rows = New-Object System.Collections.ArrayList
$cellsOut = @()
$samplePath = Join-Path $OutDir ("sample-{0}.jsonl" -f $Date)
$sumPath = Join-Path $OutDir ("sample-summary-{0}.json" -f $Date)
if ($Append -and (Test-Path $samplePath)) { foreach ($x in Read-JsonlSafe $samplePath) { [void]$rows.Add($x) }; if (Test-Path $sumPath) { $prev = Get-Content $sumPath -Raw | ConvertFrom-Json; $cellsOut = @($prev.cells) } }
foreach ($p in $plan) {
  $c = $p.c; $N = [int]$c.total_count
  if ($N -le 0) { continue }
  if ($N -gt 1000) { Write-Host ("  ! {0} N={1} >1000，跳过" -f $c.cell, $N) -ForegroundColor Red; continue }
  $pages = [Math]::Max(1, [Math]::Ceiling($N / 100.0))
  $page = $rng.Next(1, $pages + 1)
  $res = Invoke-GitHubSearch ([string]$c.query) 100 $page
  if ($null -eq $res) { Write-Host ("  ! {0} 查询失败" -f $c.cell) -ForegroundColor Yellow; continue }
  $items = @($res.items)
  if (-not $items.Count) { continue }
  $take = [Math]::Min([int]$p.n, $items.Count)
  $chosen = @(Get-RandomSubset $items $take $rng)
  foreach ($it in $chosen) {
    $rec = ConvertTo-RepoRecord -Item $it -Channel 'npr' -Date $Date
    $reason = Get-EligibilityReason $rec
    if (-not $reason) { $hit = Get-RedlineHit (([string]$rec.id + ' ' + [string]$rec.description)); if (@($hit.硬).Count) { $reason = 'redline' } }
    $rec.eligible = (-not $reason); $rec.exclude_reason = $reason
    $rec.in_library = $lib.ContainsKey($rec.id)
    $rec.in_seen = $seen.ContainsKey($rec.id)
    $origin = if ($seen.ContainsKey($rec.id)) { [string]$seen[$rec.id].origin } else { '' }
    $rec | Add-Member -NotePropertyName cell -NotePropertyValue $c.cell
    $rec | Add-Member -NotePropertyName band -NotePropertyValue $c.band
    $rec | Add-Member -NotePropertyName window -NotePropertyValue $c.window
    $rec | Add-Member -NotePropertyName pop_n -NotePropertyValue $N
    $rec | Add-Member -NotePropertyName sample_n -NotePropertyValue $take
    $rec | Add-Member -NotePropertyName page -NotePropertyValue $page
    $probability=Get-PageSampleProbability -Population $N -Page $page -SampleN $take
    $rec | Add-Member -NotePropertyName inclusion_probability -NotePropertyValue $probability
    $rec | Add-Member -NotePropertyName weight -NotePropertyValue (1.0/$probability)
    $rec | Add-Member -NotePropertyName weight_method -NotePropertyValue 'random-page-then-random-row-v2'
    $rec | Add-Member -NotePropertyName origin -NotePropertyValue $origin
    $rec | Add-Member -NotePropertyName auto_found -NotePropertyValue ($origin -eq 'auto')
    $rec | Add-Member -NotePropertyName user_found -NotePropertyValue ($origin -eq 'user')
    [void]$rows.Add($rec)
  }
  $cellsOut += [ordered]@{ cell = $c.cell; band = $c.band; window = $c.window; pop_n = $N; sample_n = $take; page = $page }
}

[IO.File]::WriteAllText($samplePath, (($rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n") + $(if ($rows.Count) { "`n" } else { '' }), (New-Object Text.UTF8Encoding($false)))
$sum = [ordered]@{
  date = $Date; seed = $Seed; planned = 100; sampled = $rows.Count
  cells = $cellsOut
  generated_at = (Get-Date).ToString('o')
}
[IO.File]::WriteAllText((Join-Path $OutDir ("sample-summary-{0}.json" -f $Date)), ($sum | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host ("✓ M1 抽样 {0} 条 / {1} 格（计划 {2}）→ {3}" -f $rows.Count, $cellsOut.Count, $totalPlanned, $samplePath) -ForegroundColor Green
exit 0
