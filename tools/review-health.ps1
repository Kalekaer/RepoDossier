# Operational debt is visible independently of engineering and publication readiness.
param([string]$Date='', [string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
$day=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
$rows=@();$ids=@{}
foreach($line in [IO.File]::ReadAllLines((Join-Path $Root 'data/candidates.jsonl'))){
 if(-not $line.Trim()){continue};$r=ConvertFrom-Json $line -ErrorAction Stop
 if(-not $r.id -or $ids.ContainsKey([string]$r.id)){throw 'Invalid or duplicate review identity'}
 $ids[$r.id]=$true;$rows+=$r
}
$pending=@($rows|Where-Object state -in @('new','screened','deferred'))
$due=@($pending|Where-Object{$_.state -eq 'deferred' -and $_.review_after -le $Date})
$oldest=0
foreach($r in $pending){$age=($day-[datetime]::ParseExact($r.discovered_at,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)).Days;if($age -gt $oldest){$oldest=$age}}
$repeated=@($pending|Where-Object{@($_.history|Where-Object to -eq 'deferred').Count -gt 1})
$since=$day.AddDays(-6).ToString('yyyy-MM-dd')
$arrivals=@($rows|Where-Object{$_.discovered_at -ge $since -and $_.discovered_at -le $Date})
$unresolvedArrivals=@($arrivals|Where-Object state -in @('new','screened','deferred'))
$warnings=@()
$capacity=$null;$batches=$null
$policy=Join-Path $Root 'data/search-policy.json'
if(Test-Path $policy){$capacity=[int](Get-Content $policy -Raw|ConvertFrom-Json).review_batch_size}
if($capacity -gt 0){
 $batches=[int][math]::Ceiling($pending.Count/[double]$capacity)
 if($unresolvedArrivals.Count -gt 7*$capacity){$warnings+='retained-inflow-exceeds-declared-review-capacity'}
}
if($due.Count){$warnings+='due-review-promises'}
if($oldest -ge 7){$warnings+='retained-results-aging'}
if($repeated.Count){$warnings+='repeated-deferrals'}
$out=Join-Path $Root 'data/audit/review-health';New-Item -ItemType Directory -Force $out|Out-Null
@{date=$Date;pending=$pending.Count;due=$due.Count;oldest_pending_days=$oldest;repeated_deferrals=$repeated.Count;arrivals_last_7_days=$arrivals.Count;unresolved_arrivals_last_7_days=$unresolvedArrivals.Count;declared_batch_capacity=$capacity;backlog_batches_at_declared_capacity=$batches;warnings=$warnings;quality_recall=$null;next_command="& .\tools\review-workbench.ps1 prepare -Date $Date -Backlog";due_ids=@($due|Sort-Object review_after,id|ForEach-Object id)}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $out "$Date.json") -Encoding UTF8
Write-Host "审阅运行状况：待处理 $($pending.Count)；到期 $($due.Count)；最老 $oldest 天；重复延期 $($repeated.Count)。"
if($warnings.Count){Write-Host ('需处理：'+($warnings -join ', '))}
Write-Host '此检查核对运行债务，不代表项目质量审阅或总体召回已完成。'
exit 0
