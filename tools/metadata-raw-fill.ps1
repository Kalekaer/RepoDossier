# metadata-raw-fill.ps1 — 用已有 raw 搜索结果补 created_at / pushed_at / license（不联网）
#
# 背景：projects 里 57 条缺 created/pushed、105 条缺 license；data/raw 的历史搜索结果里有这些字段。
# 本脚本从 raw 里取（按文件时间取最新），只补缺失字段；写 data/meta/<today>.jsonl 后重投影。
#
# 用法：
#   .\tools\metadata-raw-fill.ps1 -List       # 只报告可补多少
#   .\tools\metadata-raw-fill.ps1 -Apply      # 追加 meta 行 + sync-projects
#   .\tools\metadata-raw-fill.ps1 -Apply -NoSync

param([switch]$List, [switch]$Apply, [switch]$NoSync, [string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'date-utils.ps1')
$enc = New-Object System.Text.UTF8Encoding($false)

function Norm-Date($v) {
  ConvertTo-GitHubTimestamp $v
}

# ---------- 1) raw → field map ----------
$map = @{}
$files = @(Get-ChildItem (P 'data\raw') -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
foreach ($f in $files) {
  try {
    $o = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it in @($o.items)) {
      if (-not $it.full_name) { continue }
      $lic = $null
      if ($it.license) { if ($it.license.spdx_id) { $lic = [string]$it.license.spdx_id } elseif ($it.license.name) { $lic = [string]$it.license.name } }
      $map[[string]$it.full_name] = [pscustomobject]@{
        created_at = Norm-Date $it.created_at
        pushed_at  = Norm-Date $it.pushed_at
        license    = $lic
        description= [string]$it.description
        topics     = @($it.topics)
        archived   = [bool]$it.archived
        stars      = [int]$it.stargazers_count
        forks      = [int]$it.forks_count
        fetched_at = $f.LastWriteTime.ToUniversalTime().ToString('o')
      }
    }
  } catch { }
}

# ---------- 2) 找缺失 ----------
$rows = @()
foreach ($line in [IO.File]::ReadAllLines((P 'data\projects.jsonl'), [Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try { $p = $line | ConvertFrom-Json } catch { continue }
  if (-not $p -or -not $p.id) { continue }
  $rows += $p
}
$fix = @()
foreach ($p in $rows) {
  if (-not $map.ContainsKey([string]$p.id)) { continue }
  $m = $map[[string]$p.id]
  $need = @()
  if (-not $p.stars.created_at -and $m.created_at) { $need += 'created_at' }
  if (-not $p.pushed_at -and $m.pushed_at) { $need += 'pushed_at' }
  if (-not $p.license -and $m.license) { $need += 'license' }
  if ($need.Count) { $fix += [pscustomobject]@{ p = $p; m = $m; need = $need } }
}

Write-Host ("raw 可匹配 {0} 条 ｜ 可补 {1} 条 ｜ created={2} pushed={3} license={4}" -f `
  @($rows | Where-Object { $map.ContainsKey([string]$_.id) }).Count, $fix.Count,
  @($fix | Where-Object { $_.need -contains 'created_at' }).Count,
  @($fix | Where-Object { $_.need -contains 'pushed_at' }).Count,
  @($fix | Where-Object { $_.need -contains 'license' }).Count) -ForegroundColor Cyan
$fix | Select-Object -First 10 | ForEach-Object { Write-Host ("  {0}  → {1}" -f $_.p.id, ($_.need -join ',')) }
if ($List -or -not $Apply) { Write-Host "（-List / dry-run：未写盘）"; exit 0 }
if (-not $fix.Count) { Write-Host "没有可补字段"; exit 0 }

# ---------- 3) 写 meta ----------
$today = (Get-Date).ToString('yyyy-MM-dd')
$metaPath = P ("data\meta\{0}.jsonl" -f $today)
$existing = @{}
if (Test-Path $metaPath) {
  foreach ($line in [IO.File]::ReadAllLines($metaPath, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $x = $line | ConvertFrom-Json; if ($x.full_name) { $existing[[string]$x.full_name] = $true } } catch { }
  }
}
$added = 0
$lines = @()
foreach ($f in $fix) {
  if ($existing.ContainsKey([string]$f.p.id)) { continue }
  $p = $f.p; $m = $f.m
  $row = [ordered]@{
    full_name = [string]$p.id
    description = if ($p.description) { $p.description } else { $m.description }
    license = if ($p.license) { $p.license } else { $m.license }
    topics = if (@($p.topics).Count) { @($p.topics) } else { @($m.topics) }
    archived = [bool]$p.archived
    pushed_at = if ($p.pushed_at) { $p.pushed_at } else { $m.pushed_at }
    stars = if ($p.stars.current) { $p.stars.current } else { $m.stars }
    forks = if ($p.stars.forks) { $p.stars.forks } else { $m.forks }
    open_issues = $null
    created_at = if ($p.stars.created_at) { $p.stars.created_at } else { $m.created_at }
    fetched_at = $m.fetched_at
  }
  $lines += ($row | ConvertTo-Json -Compress -Depth 4)
  $added++
}
if ($added) { [IO.File]::AppendAllText($metaPath, (($lines -join "`n") + "`n"), $enc) }
Write-Host ("已追加 meta {0} 行 → {1}" -f $added, $metaPath) -ForegroundColor Green
if (-not $NoSync) { & (Join-Path $PSScriptRoot 'sync-projects.ps1') | Out-Null; Write-Host "已重投影" -ForegroundColor Green }
exit 0
