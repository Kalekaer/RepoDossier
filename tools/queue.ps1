# queue.ps1 — 检索结果队列（data/candidates.jsonl）：发现吞吐与评分吞吐之间的缓冲
#
# 用法：
#   .\tools\queue.ps1 add -FromPool data\audit\pool\2026-10-25.jsonl
#   .\tools\queue.ps1 list
#   .\tools\queue.ps1 set -Id owner/repo -State scored -Reason "score=72 tier=A"
#   .\tools\queue.ps1 due
#
# 纪律：队列只写审计目录，不写 seen/projects；入库仍走 add-repo/picks。
param(
  [Parameter(Mandatory=$true)][ValidateSet('add','list','set','due','prune')][string]$Action,
  [string]$FromPool = '',
  [string]$Id = '',
  [string]$State = '',
  [string]$Reason = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
$qPath = P 'data\candidates.jsonl'
$rows = @(Read-JsonlSafe $qPath)
$states = @('new','screened','scored','accepted','rejected','deferred','known')
$enc = New-Object System.Text.UTF8Encoding($false)

function Save-Queue($Rows) {
  $lines = @($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 })
  [IO.File]::WriteAllText($qPath, ($(if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' })), $enc)
}

switch ($Action) {
  'add' {
    if (-not $FromPool -or -not (Test-Path $FromPool)) { Write-Host "✗ 找不到池：$FromPool" -ForegroundColor Red; exit 1 }
    $pool = @(Read-JsonlSafe $FromPool)
    $exist = @{}; foreach ($r in $rows) { if ($r.id) { $exist[[string]$r.id] = $true } }
    $added = 0
    foreach ($p in $pool) {
      if (-not $p.eligible) { continue }
      if (-not $p.id) { continue }
      if ($exist.ContainsKey([string]$p.id)) { continue }
      $st = if ($p.in_library -or $p.in_seen) { 'known' } else { 'new' }
      $rows += [pscustomobject][ordered]@{
        id = [string]$p.id
        state = $st
        channel = [string]$p.channel
        discovered_at = [string]$p.discovered_at
        score = $null
        tier = $null
        reason = $(if ($st -eq 'known') { 'already in library/seen' } else { $null })
        updated_at = (Get-Date).ToString('o')
      }
      $exist[[string]$p.id] = $true
      $added++
    }
    Save-Queue $rows
    Write-Host ("✓ 队列 +{0} 条（共 {1}）" -f $added, $rows.Count) -ForegroundColor Green
  }
  'list' {
    $g = @($rows | Group-Object state | Sort-Object Name)
    if (-not $g.Count) { Write-Host "队列为空" } else { $g | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.Name, $_.Count) } }
    Write-Host ("  合计 {0}" -f $rows.Count)
  }
  'set' {
    if (-not $Id -or -not $State) { Write-Host "✗ 需要 -Id 与 -State" -ForegroundColor Red; exit 1 }
    if ($states -notcontains $State) { Write-Host "✗ 非法状态：$State" -ForegroundColor Red; exit 1 }
    $hit = @($rows | Where-Object { $_.id -eq $Id })
    if (-not $hit.Count) { Write-Host "✗ 队列里没有 $Id" -ForegroundColor Red; exit 1 }
    $cur = [string]$hit[0].state
    if (-not (Test-QueueTransition $cur $State)) { Write-Host ("✗ 非法迁移：{0} -> {1}" -f $cur, $State) -ForegroundColor Red; exit 1 }
    $hit[0].state = $State
    $hit[0].reason = $Reason
    $hit[0].updated_at = (Get-Date).ToString('o')
    Save-Queue $rows
    Write-Host ("✓ {0}: {1} -> {2}" -f $Id, $cur, $State) -ForegroundColor Green
  }
  'due' {
    $cut = (Get-Date).AddDays(-7)
    $due = @($rows | Where-Object { $_.state -in @('new','screened') -and $_.discovered_at -and ([datetime]$_.discovered_at) -lt $cut })
    if (-not $due.Count) { Write-Host "✓ 没有超 SLA 的检索结果" -ForegroundColor Green }
    else { $due | ForEach-Object { Write-Host ("  {0} ｜ {1} ｜ {2}" -f $_.id, $_.state, $_.discovered_at) } }
  }
  'prune' {
    Write-Host '处置账为审计证据，不再按时间删除；延期项目用 candidate-ledger 复核。'
  }
}
exit 0
