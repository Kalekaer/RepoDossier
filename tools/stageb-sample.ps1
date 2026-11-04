# stageb-sample.ps1 — 从池里抽 Stage B 样本（不评分，只出清单）
# 用法：.\tools\stageb-sample.ps1 -Date 2026-10-25 -N 20
# 输出：data/audit/stageb/<date>-sample.jsonl
param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [int]$N = 20,
  [string]$PoolFile = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
if (-not $PoolFile) { $PoolFile = P ("data\audit\pool\{0}.jsonl" -f $Date) }
if (-not (Test-Path $PoolFile)) { Write-Host "✗ 找不到池：$PoolFile" -ForegroundColor Red; exit 1 }
$outDir = P 'data\audit\stageb'
New-Item -ItemType Directory -Force $outDir | Out-Null

$rows = @(Read-JsonlSafe $PoolFile | Where-Object { $_.eligible -and -not $_.in_library } |
  Sort-Object stars -Descending | Select-Object -First $N)
$out = Join-Path $outDir ("{0}-sample.jsonl" -f $Date)
$lines = @()
foreach ($r in $rows) {
  $lines += ([ordered]@{
    id = $r.id
    stars = $r.stars
    layer = $r.layer
    description = $r.description
    url = ('https://github.com/' + $r.id)
    created_at = $r.created_at
    pushed_at = $r.pushed_at
    score = $null
    tier = $null
    note = $null
  } | ConvertTo-Json -Compress -Depth 4)
}
[IO.File]::WriteAllText($out, (($lines -join "`n") + $(if ($lines.Count) { "`n" } else { '' })), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("✓ Stage B 样本 {0} 条（未评分）→ {1}" -f $rows.Count, $out) -ForegroundColor Green
exit 0
