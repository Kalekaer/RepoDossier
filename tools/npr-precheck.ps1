# npr-precheck.ps1 — M1 新项目召回：16 格预检（只查 total_count，不抽样）
#
# 总体：created 在审计日前 8–30 天、stars≥100、pushed 活跃、非 fork/archived。
# 网格：4 星段 × 4 个 6 天窗口 = 16 格；每格必须 ≤1000 才能直接抽样。
#
# 用法：
#   .\tools\npr-precheck.ps1 -PlanOnly                 # 不联网
#   .\tools\npr-precheck.ps1 -Date 2026-10-25          # 16 次 total_count
#
# 输出：data/audit/npr/precheck-<date>.jsonl / plan-<date>.json / summary-<date>.json

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [switch]$PlanOnly,
  [int]$DelayMs = 6500,
  [string]$Proxy = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
if (-not $OutDir) { $OutDir = P 'data\audit\npr' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$dt = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
$cohortStart = $dt.AddDays(-30)
$cohortEnd = $dt.AddDays(-8)
$pushed = $dt.AddDays(-30).ToString('yyyy-MM-dd')

$bands = @(
  [pscustomobject]@{ id = 'B1'; label = '100..199'; q = 'stars:100..199' },
  [pscustomobject]@{ id = 'B2'; label = '200..499'; q = 'stars:200..499' },
  [pscustomobject]@{ id = 'B3'; label = '500..999'; q = 'stars:500..999' },
  [pscustomobject]@{ id = 'B4'; label = '>999'; q = 'stars:>999' }
)

$totalDays = ($cohortEnd - $cohortStart).Days + 1
$windows = @()
$chunk = [Math]::Ceiling($totalDays / 4.0)
for ($i = 0; $i -lt 4; $i++) {
  $s = $cohortStart.AddDays($i * $chunk)
  $e = $s.AddDays($chunk - 1)
  if ($e -gt $cohortEnd) { $e = $cohortEnd }
  if ($s -gt $cohortEnd) { continue }
  $windows += [pscustomobject]@{ id = ('W{0}' -f ($i + 1)); start = $s; end = $e }
}

$cells = @()
foreach ($b in $bands) {
  foreach ($w in $windows) {
    $cells += [pscustomobject]@{
      id = ('M1|{0}|{1}' -f $b.id, $w.id)
      band = $b.id; band_label = $b.label; window = $w.id
      start = $w.start.ToString('yyyy-MM-dd'); end = $w.end.ToString('yyyy-MM-dd')
      q = ('{0} created:{1}..{2} pushed:>{3} fork:false archived:false' -f $b.q, $w.start.ToString('yyyy-MM-dd'), $w.end.ToString('yyyy-MM-dd'), $pushed)
    }
  }
}

$plan = [ordered]@{
  date = $Date
  population = 'created 8-30d, stars>=100, pushed-30d, fork:false, archived:false'
  cohort = ('{0}..{1}' -f $cohortStart.ToString('yyyy-MM-dd'), $cohortEnd.ToString('yyyy-MM-dd'))
  cells = @($cells | ForEach-Object { [ordered]@{ id = $_.id; band = $_.band; window = $_.window; query = $_.q } })
  generated_at = (Get-Date).ToString('o')
}
$planPath = Join-Path $OutDir ("plan-{0}.json" -f $Date)
[IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
Write-Host ("✓ M1 预检计划：{0} 格 ｜ cohort {1}..{2} ｜ {3}" -f $cells.Count, $cohortStart.ToString('yyyy-MM-dd'), $cohortEnd.ToString('yyyy-MM-dd'), $planPath) -ForegroundColor Green
if ($PlanOnly) { exit 0 }

function Invoke-GitHubSearch([string]$q) {
  $url = 'https://api.github.com/search/repositories'
  $a = @('-s', '-G', $url, '--data-urlencode', "q=$q", '--data-urlencode', 'per_page=1', '-H', 'Accept: application/vnd.github+json', '-H', 'User-Agent: github-daily-picks/npr')
  if ($Proxy) { $a += @('--proxy', $Proxy) }
  if ($env:DSH_GITHUB_TOKEN) { $a += @('-H', "Authorization: Bearer $($env:DSH_GITHUB_TOKEN)") }
  for ($try = 1; $try -le 2; $try++) {
    Start-Sleep -Milliseconds $DelayMs
    $raw = & curl.exe @a 2>$null
    if ($raw) { try { $o = $raw | ConvertFrom-Json; if ($null -ne $o.total_count) { return $o } } catch { } }
    Start-Sleep -Milliseconds 2500
  }
  return $null
}

$path = Join-Path $OutDir ("precheck-{0}.jsonl" -f $Date)
$enc = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, '', $enc)
$bad = 0
foreach ($c in $cells) {
  $r = Invoke-GitHubSearch $c.q
  if ($null -eq $r) {
    $line = [ordered]@{ cell = $c.id; band = $c.band; window = $c.window; query = $c.q; total_count = $null; ok = $false; error = 'api'; checked_at = (Get-Date).ToString('o') }
    $bad++
  } else {
    $n = [int]$r.total_count
    $ok = ($n -le 1000)
    if (-not $ok) { $bad++ }
    $line = [ordered]@{ cell = $c.id; band = $c.band; window = $c.window; query = $c.q; total_count = $n; ok = $ok; checked_at = (Get-Date).ToString('o') }
    Write-Host ("  {0}  N={1}  {2}" -f $c.id, $n, $(if ($ok) { 'OK' } else { '>1000' }))
  }
  [IO.File]::AppendAllText($path, (($line | ConvertTo-Json -Compress) + "`n"), $enc)
}
$sum = [ordered]@{ date = $Date; cells = $cells.Count; bad = $bad; cohort = $plan.cohort; generated_at = (Get-Date).ToString('o') }
[IO.File]::WriteAllText((Join-Path $OutDir ("summary-{0}.json" -f $Date)), ($sum | ConvertTo-Json -Depth 5), $enc)
Write-Host ("✓ 预检 {0} 格 ｜ 超限/错误 {1} ｜ {2}" -f $cells.Count, $bad, $path) -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
if ($bad) { exit 2 }
exit 0
