# Bounded daily refresh; explicit network action. Called before evidence review.
param([string]$Date='',[string]$Root=(Split-Path -Parent $PSScriptRoot),
  [ValidateRange(0,200)][int]$SeriesRequests=5,[ValidateRange(0,200)][int]$EvidenceRequests=15,[switch]$PlanOnly,
  [string]$Proxy='',[switch]$NoProxy)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
if($Date -ne [datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd') -and -not $PlanOnly){throw 'Live refresh must use current Beijing date; historical runs must not label current API facts as historical'}
$steps=@{}
if(-not $PlanOnly){
 $budget=Reserve-GitHubRequest $Root 'maintenance-plan' -Peek
 $reserve=5;$config=Join-Path $Root 'config.json';if(Test-Path $config){$v=(Get-Content $config -Raw|ConvertFrom-Json).sources.verify_max_calls;if($null -ne $v){$reserve=[int]$v}}
 $available=[math]::Max(0,$budget.remaining-$reserve)
 $SeriesRequests=[math]::Min($SeriesRequests,$available)
 $EvidenceRequests=[math]::Min($EvidenceRequests,[math]::Max(0,$available-$SeriesRequests))
}
& (Join-Path $PSScriptRoot 'fetch-series.ps1') -Root $Root -SeriesDate $Date -MaxRequests $SeriesRequests -WaitForReset -DryRun:$PlanOnly -Proxy $Proxy -NoProxy:$NoProxy
$steps.series=$LASTEXITCODE
if(-not $PlanOnly){
 & (Join-Path $PSScriptRoot 'evidence-queue.ps1') sync-events -Root $Root;$steps.events=$LASTEXITCODE
 if($EvidenceRequests -gt 0){& (Join-Path $PSScriptRoot 'evidence-queue.ps1') run -Root $Root -MaxRequests $EvidenceRequests -MaxWaitSeconds 60 -Proxy $Proxy -NoProxy:$NoProxy;$steps.evidence=$LASTEXITCODE}
 else{
  $store=Open-EvidenceStore $Root
  try{$steps.evidence=$(if(@($store.state.tasks.Values|Where-Object state -in @('pending','retry','running','blocked')).Count){2}else{0})}finally{$store.guard.Dispose()}
 }
 $out=Join-Path $Root 'data/audit/maintenance';New-Item -ItemType Directory -Force $out|Out-Null
 @{date=$Date;at=[datetimeoffset]::UtcNow.ToString('o');steps=$steps;budgets=@{series=$SeriesRequests;evidence=$EvidenceRequests};complete=(@($steps.Values|Where-Object{$_ -ne 0}).Count -eq 0)}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out ($Date+'.json')) -Encoding UTF8
}
if(@($steps.Values|Where-Object{$_ -eq 1 -or $_ -gt 2}).Count){exit 1}
if(@($steps.Values|Where-Object{$_ -eq 2}).Count){Write-Host '维护预算内尚有未完成任务，断点保留；不得据此声称全量刷新完成。';exit 2}
exit 0
