# Existing time-series entry point, sharing durable HTTP tasks and cooldown.
param([ValidateRange(0,200)][int]$MaxRequests=50,[int]$MinRemaining=5,[double]$DelaySeconds=1,
 [string]$SeriesDate='',[string]$Proxy='',[switch]$NoProxy,[switch]$WaitForReset,
 [int]$Simulate=0,[switch]$DryRun,[switch]$Json,[string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
# Resolve locally before selecting the SLA. Never inherit a caller's $token.
$readCredential=Get-GitHubReadCredential -Root $Root
$sla=if($readCredential){@{hot=1;warm=3;cold=14}}else{@{hot=4;warm=7;cold=30}}
if(-not $SeriesDate){$SeriesDate=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
$null=[datetime]::ParseExact($SeriesDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
if(-not $DryRun -and $Simulate -le 0 -and $SeriesDate -ne [datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')){throw 'Live series observations must use the current Beijing date'}
$projects=@(Read-EvidenceRows (Join-Path $Root 'data/projects.jsonl'))
$dir=Join-Path $Root 'data/series';$target=Join-Path $dir ($SeriesDate+'.jsonl');$statePath=Join-Path $dir '_state.json'
$state=if(Test-Path $statePath){Get-Content $statePath -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
$done=@{};foreach($r in Read-EvidenceRows $target){if($r.ok){$done[$r.id]=$true}}
$now=[datetimeoffset]::UtcNow;$todo=@();$tiers=@{};$demand=0.0;$coolingCount=0
foreach($p in $projects){
 $tier=if($p.status -eq 'dropped' -or $p.archived){'cold'}elseif($p.status -in @('active','using') -or $p.recommended -or $p.origin -eq 'user'){'hot'}else{'warm'}
 $tiers[[string]$p.id]=$tier;$demand+=1.0/$sla[$tier]
 $last=$state[[string]$p.id];$age=if($last.last_ok_at){($now-(ConvertTo-EvidenceInstant $last.last_ok_at)).TotalDays}else{99999}
 $cooling=$last.next_retry_at -and (ConvertTo-EvidenceInstant $last.next_retry_at) -gt $now
 if($cooling){$coolingCount++}
 if(-not $done.ContainsKey([string]$p.id) -and -not $cooling -and $age -ge $sla[$tier]){$todo+=@{id=[string]$p.id;tier=$tier;age=$age}}
}
$todo=@($todo|Sort-Object @{Expression='age';Descending=$true},id)
$plan=@{date=$SeriesDate;authenticated=[bool]$readCredential;sla=$sla;due=$todo.Count;cooling_projects=$coolingCount;max_requests=$MaxRequests;already_done=$done.Count;estimated_daily_requests=[math]::Round($demand,2)}
if($Simulate -gt 0){
 $runs=@();foreach($quota in @(50,200,5000)){
  $lastDay=@{};foreach($id in $tiers.Keys){$lastDay[$id]=0}
  for($day=1;$day -le 14;$day++){
   $dueIds=@($tiers.Keys|Where-Object{($day-$lastDay[$_]) -ge $sla[$tiers[$_]]}|Sort-Object {$lastDay[$_]})
   foreach($id in @($dueIds|Select-Object -First $quota)){$lastDay[$id]=$day}
  }
  $runs+=@{daily_quota=$quota;overdue_at_end=@($tiers.Keys|Where-Object{(15-$lastDay[$_]) -gt 1.5*$sla[$tiers[$_]]}).Count}
 }
 $plan.simulation=@{days=14;results=$runs;note='Capacity simulation only; no measured network or guaranteed SLA'}
}
if($DryRun -or $Simulate -gt 0){
 if($Json){$plan|ConvertTo-Json -Depth 6}else{Write-Host "刷新计划：到期 $($todo.Count)，已成功 $($done.Count)，认证 $([bool]$readCredential)，周期 $($sla.hot)/$($sla.warm)/$($sla.cold) 天。";if($Simulate -gt 0){$plan.simulation|ConvertTo-Json -Depth 5|Write-Host}}
 exit 0
}
New-Item -ItemType Directory -Force $dir|Out-Null
$guard=[IO.File]::Open((Join-Path $dir '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$store=$null
try{
 $done=@{};foreach($r in Read-EvidenceRows $target){if($r.ok){$done[$r.id]=$true}}
 $todo=@($todo|Where-Object{-not $done.ContainsKey($_.id)})
 $store=Open-EvidenceStore $Root
 $scheduled=@($todo|Select-Object -First $MaxRequests);$taskIds=@();$beforeAttempts=@{}
 foreach($r in $scheduled){$t=Add-EvidenceTask $store $r.id 'metadata' ('series-'+$SeriesDate) 'scheduled metadata refresh';$taskIds+=$t.id;$beforeAttempts[$t.id]=$t.attempts}
 Save-EvidenceStore $store
 $Proxy=Get-GitHubProxy -Proxy $Proxy -NoProxy:$NoProxy
 $result=if($scheduled.Count){Invoke-EvidenceTasks $store -Repos @($scheduled|ForEach-Object id) -Kinds metadata -TaskIds $taskIds -MaxRequests $MaxRequests -Proxy $Proxy -MaxWaitSeconds $(if($WaitForReset){60}else{0}) -MinRemaining $MinRemaining -DelaySeconds $DelaySeconds}else{@{requests=0;stop='complete'}}
 $ok=0;$attempted=0
 foreach($r in $scheduled){
  $key=Get-EvidenceHash ($r.id.ToLowerInvariant()+'|metadata|series-'+$SeriesDate);$task=$store.state.tasks[$key]
  if(-not $task -or ($task.attempts -eq $beforeAttempts[$key] -and -not $task.reused)){continue}
  $c=$task.result;$rec=@{id=$r.id;ok=($task.state -eq 'succeeded');fetched_at=[datetimeoffset]::UtcNow.ToString('o');task=$key}
  if($rec.ok){
   $j=Get-Content (Get-EvidencePath $Root $c.path) -Raw|ConvertFrom-Json
   $rec.fetched_at=$c.fetched_at;$rec.checked_at=$c.checked_at;$rec.status=$c.http_status;$rec.source=$c.path;$rec.sha256=$c.sha256
   $rec.stars=$j.stargazers_count;$rec.forks=$j.forks_count;$rec.open_issues=$j.open_issues_count;$rec.pushed_at=$j.pushed_at;$rec.archived=$j.archived;$rec.default_branch=$j.default_branch
   $state[$r.id]=@{last_ok_at=$c.checked_at;tier=$r.tier;fails=0};$ok++
  }else{
   $rec.error='Evidence task '+$task.state;$previous=$state[$r.id];$fails=[int]$previous.fails+1
   $retry=if($task.state -eq 'blocked'){$now.AddDays($(if($fails -ge 3){$sla.cold}else{1})).ToString('o')}else{$task.next_attempt}
   $state[$r.id]=@{last_ok_at=$previous.last_ok_at;tier=$r.tier;fails=$fails;next_retry_at=$retry}
  }
  [IO.File]::AppendAllText($target,(($rec|ConvertTo-Json -Depth 8 -Compress)+"`n"),[Text.UTF8Encoding]::new($false));$attempted++
 }
 $tmp=$statePath+'.tmp';[IO.File]::WriteAllText($tmp,($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$statePath,$true)
 Update-EvidenceReviews $store;Save-EvidenceStore $store
 $summary=@{ran_at=$now.ToString('o');date=$SeriesDate;authenticated=[bool]$readCredential;sla=$sla;requests=$result.requests;observations=$attempted;ok=$ok;remaining_todo=($todo.Count-$ok);cooling_projects=$coolingCount;estimated_daily_requests=$plan.estimated_daily_requests;stop=$result.stop}
 $summary|ConvertTo-Json -Depth 6|Set-Content (Join-Path $dir ('_measure-'+$now.ToString('yyyyMMdd-HHmmss')+'.json')) -Encoding UTF8
 Write-Host "时间序列刷新：请求 $($result.requests)，成功 $ok，剩余 $($summary.remaining_todo)，周期 $($sla.hot)/$($sla.warm)/$($sla.cold) 天。"
 if($summary.remaining_todo -gt 0 -or $coolingCount -gt 0){exit 2}
}finally{if($store){$store.guard.Dispose()};$guard.Dispose()}
exit 0
