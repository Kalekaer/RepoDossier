# Compatibility entry point; generation lives in build-samples/weekly-utils.
[CmdletBinding()]
param([string]$MondayDate='', [switch]$DryRun, [string]$Page='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'weekly-utils.ps1')
if (-not $MondayDate) { $MondayDate=Get-BeijingDate }
$period=Get-WeeklyPeriod $MondayDate
if (-not $period.IsMonday -or $period.Number -lt 1) { throw 'MondayDate must be a Monday after the first reporting week.' }
if ($DryRun) { Write-Host "$MondayDate : $($period.Issue), $($period.Start) — $($period.End)"; exit 0 }
if ($Page) {
  $html=Set-DailyWeeklyEntry -Html ([IO.File]::ReadAllText((Resolve-Path $Page).Path)) -DailyDate $MondayDate -Root $root
  [IO.File]::WriteAllText((Join-Path $root 'data/_tmp/monday-entry-test.html'),$html,[Text.UTF8Encoding]::new($false))
  exit 0
}
if (-not (Test-Path (Join-Path $root "reports/$MondayDate.md")) -or -not (Test-Path (Join-Path $root "data/picks/$MondayDate.jsonl"))) { throw 'Generate the Monday report and picks first.' }
& (Join-Path $PSScriptRoot 'build-samples.ps1') -Date $MondayDate
exit $LASTEXITCODE
