# discovery-refresh.ps1 — 每日收工后刷新候选池 + 渠道贡献（只读审计）
#
# 目的：把 A 层做成一个固定入口，避免每天手工拼命令。
# 用法：.\tools\discovery-refresh.ps1 -Date 2026-10-25
# 前置：data/raw/<date>/r*/Q*.json 已由 fetch-daily -Import 落盘。
# 输出：data/audit/pool/<date>-all.jsonl、channel-report-<date>.md/.json

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
$rawDir = P ("data\raw\{0}" -f $Date)
if (-not (Test-Path $rawDir)) { Write-Host "✗ 没有 raw：$rawDir（先跑 fetch-daily -Import）" -ForegroundColor Red; exit 1 }
$files = @(Get-ChildItem $rawDir -Recurse -File -Filter 'Q*.json' -ErrorAction SilentlyContinue)
if (-not $files.Count) { Write-Host "✗ raw 里没有 Q*.json：$rawDir" -ForegroundColor Red; exit 1 }
$poolDir = P 'data\audit\pool'
New-Item -ItemType Directory -Force $poolDir | Out-Null
$pool = Join-Path $poolDir ("{0}-all.jsonl" -f $Date)

& (Join-Path $PSScriptRoot 'discovery-pool.ps1') -AllQueries -Date $Date -OutFile $pool -Root $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $PSScriptRoot 'channel-report.ps1') -Date $Date -PoolFile $pool -Root $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $PSScriptRoot 'candidate-ledger.ps1') -Action sync -Date $Date -Root $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host ("✓ 发现层刷新完成：{0}" -f $pool) -ForegroundColor Green
exit 0
