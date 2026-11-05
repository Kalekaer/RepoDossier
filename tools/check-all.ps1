# check-all.ps1 — 一次跑完全部门禁（以后“全绿”只能来自这里）
#
# 用法：.\tools\check-all.ps1
# 退出码：0 = 全部通过；1 = 有失败
#
# 为什么要有：audit 168 项不检查日期格式；只跑 audit 就报“全绿”会漏掉
# validate-lib / verify-handoff 的失败。这个入口强制包含数据契约与交接基准。

param([string]$Root = (Split-Path -Parent $PSScriptRoot),[switch]$Publish,[string]$Date='')
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
$script:results = @()

function Run-Gate([string]$Name, [string]$Script, [hashtable]$GateArgs = @{}) {
  $out = @()
  $global:LASTEXITCODE = 0
  $code = 0
  try { $out = & (P $Script) @GateArgs *>&1; $code = $global:LASTEXITCODE } catch { $out = @($_ | Out-String); $code = 1 }
  if ($null -eq $code) { $code = 0 }
  $logDir = P 'data\_tmp\check-all'
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $out | Out-String -Width 240 | Set-Content -LiteralPath (Join-Path $logDir "$Name.log") -Encoding UTF8
  $script:results += [pscustomobject]@{ name = $Name; code = $code; tail = (($out | Select-Object -Last 2) -join ' / ') }
  Write-Host ("[{0}] {1}" -f $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
}

Run-Gate 'validate-lib' 'tools\validate-lib.ps1'
if(Test-Path (P 'distribution.json')) {
  # A distribution has its own portable checks, never inferred from missing files.
  Run-Gate 'distribution-integrity' 'tools\check-distribution.ps1'
  Run-Gate 'check-config' 'tools\check-config.ps1'
  Run-Gate 'audit' '.dsh\skills\github-daily-picks\audit.ps1'
  Run-Gate 'portable-tests' 'tests\distribution-tests.ps1'
  Run-Gate 'check-page' 'tools\check-page.ps1'
  Run-Gate 'check-queries-static' 'tools\check-queries.ps1' @{Static=$true}
  Run-Gate 'term-check' 'tools\term-check.ps1'
  if($Publish){Run-Gate 'release-readiness' 'tools\release-readiness.ps1' @{Date=$Date;Root=$Root}}
  $bad=@($script:results|Where-Object code -ne 0)
  Write-Host ("== distribution check-all: {0} passed / {1} failed / 0 skipped ==" -f ($script:results.Count-$bad.Count),$bad.Count)
  if(-not $Publish){Write-Host 'Distribution checks do not certify a daily report. Use -Publish -Date YYYY-MM-DD for a real daily publication.'}
  if($bad.Count){exit 1};exit 0
}
Run-Gate 'verify-handoff' 'tools\verify-handoff.ps1'
Run-Gate 'audit' '.dsh\skills\github-daily-picks\audit.ps1'
Run-Gate 'run-tests' 'tests\run-tests.ps1'
Run-Gate 'check-drift' 'tools\check-drift.ps1'
Run-Gate 'check-queries-static' 'tools\check-queries.ps1' @{ Static = $true }
Run-Gate 'check-queries-2026-10-24' 'tools\check-queries.ps1' @{ Date = '2026-10-24' }
$latestRaw = Get-ChildItem (P 'data\raw') -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name | Select-Object -Last 1
if ($latestRaw) { Run-Gate 'discovery-refresh' 'tools\discovery-refresh.ps1' @{ Date = $latestRaw.Name; Root = $Root } }
if ($latestRaw) { Run-Gate 'candidate-accounting' 'tools\candidate-ledger.ps1' @{ Action = 'check'; Date = $latestRaw.Name; Root = $Root } }
if ($latestRaw) { Run-Gate 'review-health' 'tools\review-health.ps1' @{ Date = $latestRaw.Name; Root = $Root } }
Run-Gate 'term-check' 'tools\term-check.ps1'
Run-Gate 'evidence-integrity' 'tools\evidence-queue.ps1' @{Action='check';Root=$Root}
if($Publish){Run-Gate 'release-readiness' 'tools\release-readiness.ps1' @{Date=$Date;Root=$Root}}

$bad = @($script:results | Where-Object { $_.code -ne 0 })
Write-Host ""
Write-Host ("== check-all: {0} 通过 / {1} 失败 ==" -f ($script:results.Count - $bad.Count), $bad.Count) -ForegroundColor $(if ($bad.Count) { 'Red' } else { 'Green' })
foreach ($r in $script:results) { Write-Host ("  {0,-24} {1}  {2}" -f $r.name, $r.code, $r.tail) }
if(-not $Publish){Write-Host '以上是工程验收；发布验收请运行 check-all -Publish -Date YYYY-MM-DD。'}
if ($bad.Count) { exit 1 }
exit 0
