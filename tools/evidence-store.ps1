# Durable local evidence tasks. Facts and review decisions remain separate.
. (Join-Path $PSScriptRoot 'github-transport.ps1')
function Get-EvidenceHash([string]$Text){
 $h=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','')}finally{$h.Dispose()}
}
function Get-EvidenceVersion($Timestamp){
 if(-not $Timestamp){return 'latest'}
 if($Timestamp -is [datetime]){return $Timestamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')}
 return ([datetimeoffset]::Parse([string]$Timestamp,[Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
function ConvertTo-EvidenceInstant($Value){
 if($Value -is [datetimeoffset]){return $Value.ToUniversalTime()}
 if($Value -is [datetime]){return [datetimeoffset]::new($Value.ToUniversalTime())}
 return ([datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime()
}
function Get-EvidencePath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
 $target=if([IO.Path]::IsPathRooted($Relative)){$Relative}else{Join-Path $base $Relative}
 $p=[IO.Path]::GetFullPath($target)
 if(-not $p.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence path outside workspace'}
 return $p
}
function Read-EvidenceRows([string]$Path){
 $rows=@();if(Test-Path -LiteralPath $Path){foreach($l in [IO.File]::ReadAllLines($Path)){if($l.Trim()){$rows+=ConvertFrom-Json $l -ErrorAction Stop}}};return $rows
}
function Open-EvidenceStore([string]$Root){
 $dir=Get-EvidencePath $Root 'data/evidence';New-Item -ItemType Directory -Force $dir|Out-Null
 $guard=[IO.File]::Open((Join-Path $dir '.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $path=Join-Path $dir 'state.json'
  $state=if(Test-Path $path){Get-Content $path -Raw|ConvertFrom-Json -AsHashtable}else{@{version=1;tasks=@{};cache=@{};reviews=@{};events=@{};next_allowed='2000-01-01T00:00:00Z'}}
  if($state.version -ne 1){throw 'Unsupported evidence store version'}
  return @{root=[IO.Path]::GetFullPath($Root);path=$path;guard=$guard;state=$state}
 }catch{$guard.Dispose();throw}
}
function Save-EvidenceStore($Store){
 $tmp=$Store.path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllText($tmp,($Store.state|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
 [IO.File]::Move($tmp,$Store.path,$true)
}
function Get-EvidenceCache($Store,[string]$Repo,[string]$Kind){
 $key=$Repo.ToLowerInvariant()+'|'+$Kind;$c=$Store.state.cache[$key]
 if($c){
  $path=Get-EvidencePath $Store.root $c.path
  if(-not(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ne $c.sha256){throw 'Cached evidence missing or changed'}
 }
 return $c
}
function Add-EvidenceTask($Store,[string]$Repo,[string]$Kind,[string]$Version='latest',[string]$Reason='review evidence',[switch]$Force){
 if($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Repo.Split('/') -contains '..' -or $Repo.Split('/') -contains '.'){throw 'Invalid repository identity'}
 if($Kind -notin @('metadata','readme','license','releases','issues')){throw 'Unknown evidence kind'}
 $key=$Repo.ToLowerInvariant()+'|'+$Kind;$c=Get-EvidenceCache $Store $Repo $Kind
 $id=Get-EvidenceHash ($key+'|'+$Version)
 if(-not $Store.state.tasks.ContainsKey($id)){
  $Store.state.tasks[$id]=@{id=$id;repo=$Repo;kind=$Kind;version=$Version;reason=$Reason;state='pending';attempts=0;failures=0;next_attempt='2000-01-01T00:00:00Z';created_at=[datetimeoffset]::UtcNow.ToString('o');history=@();result=$null}
 }
 $t=$Store.state.tasks[$id]
 $fresh=$c -and (ConvertTo-EvidenceInstant $c.expires_at) -gt [datetimeoffset]::UtcNow -and ($Version -eq 'latest' -or $c.version -eq $Version)
 if($fresh -and -not $Force){$t.state='succeeded';$t.result=$c;$t.reused=$true}
 elseif($t.state -in @('succeeded','missing') -or $Force){$t.state='pending';$t.next_attempt='2000-01-01T00:00:00Z'}
 return $t
}
function Save-EvidenceResult($Store,$Task,[string]$Body,[hashtable]$Headers,[string]$Outcome,[int]$Status,[double]$Seconds=0){
 $digest=Get-EvidenceHash $Body;$rel='data/evidence/blobs/'+$digest+'.json';$path=Get-EvidencePath $Store.root $rel
 New-Item -ItemType Directory -Force (Split-Path $path)|Out-Null
 if(Test-Path $path){if((Get-FileHash $path).Hash -ne $digest){throw 'Evidence blob changed'}}else{[IO.File]::WriteAllText($path,$Body,[Text.UTF8Encoding]::new($false))}
 $now=[datetimeoffset]::UtcNow;$ttl=if($Task.kind -in @('readme','license')){168}else{24};if($Outcome -eq 'absent'){$ttl=24}
 $c=@{repo=$Task.repo;kind=$Task.kind;version=$Task.version;path=$rel;sha256=$digest;etag=$Headers['etag'];outcome=$Outcome;http_status=$Status;fetched_at=$now.ToString('o');checked_at=$now.ToString('o');expires_at=$now.AddHours($ttl).ToString('o')}
 $old=Get-EvidenceCache $Store $Task.repo $Task.kind
 $Store.state.cache[$Task.repo.ToLowerInvariant()+'|'+$Task.kind]=$c
 $Task.result=$c;$Task.state='succeeded';$Task.failures=0;$Task.reused=$false
 $Task.history+=@{at=$now.ToString('o');status=$Status;outcome=$Outcome;sha256=$digest;seconds=$Seconds}
 $meaningful=$old -and $old.sha256 -ne $digest -and $Task.kind -ne 'issues'
 if($meaningful -and $old.outcome -eq 'present' -and $Outcome -eq 'present'){
  $before=Get-Content (Get-EvidencePath $Store.root $old.path) -Raw|ConvertFrom-Json;$after=ConvertFrom-Json $Body
  if($Task.kind -in @('readme','license')){$meaningful=$before.sha -ne $after.sha}
  if($Task.kind -eq 'releases'){$meaningful=$before.id -ne $after.id -or $before.tag_name -ne $after.tag_name -or $before.published_at -ne $after.published_at -or $before.body -ne $after.body}
  if($Task.kind -eq 'metadata'){
   $meaningful=$before.license.spdx_id -ne $after.license.spdx_id -or $before.archived -ne $after.archived -or $before.default_branch -ne $after.default_branch
   if($before.pushed_at -ne $after.pushed_at){foreach($kind in @('readme','releases')){$null=Add-EvidenceTask $Store $Task.repo $kind ([string]$after.pushed_at) 'repository push changed'}}
   if($before.license.spdx_id -ne $after.license.spdx_id){$null=Add-EvidenceTask $Store $Task.repo 'license' $digest 'license metadata changed'}
  }
 }
 if($meaningful){
  $reviewKey=Get-EvidenceHash ($Task.repo.ToLowerInvariant()+'|'+$Task.kind+'|'+$old.sha256+'|'+$digest)
  $Store.state.reviews[$reviewKey]=@{id=$reviewKey;repo=$Task.repo;state='ready-for-review';reason=$Task.kind+' evidence changed';old_sha256=$old.sha256;new_sha256=$digest;evidence=$rel;task_ids=@($Task.id);created_at=$now.ToString('o')}
 }
 return $c
}
function Test-EvidenceBody([string]$Body,[string]$Kind,[string]$Repo){
 try{
  $o=ConvertFrom-Json -InputObject $Body -NoEnumerate -ErrorAction Stop
  switch($Kind){
   metadata {return $o.full_name -ieq $Repo -and $o.private -eq $false -and $null -ne $o.stargazers_count}
   readme {return $o.encoding -eq 'base64' -and $o.type -eq 'file' -and [bool]$o.sha -and [bool]$o.content -and [Convert]::FromBase64String($o.content).Length -gt 0}
   license {return $o.encoding -eq 'base64' -and [bool]$o.sha -and [bool]$o.content -and [Convert]::FromBase64String($o.content).Length -gt 0}
   releases {return [bool]$o.id -and $o.draft -eq $false -and [bool]$o.published_at}
   issues {return $o -is [array] -and @($o|Where-Object{-not $_.id -or -not $_.created_at}).Count -eq 0}
  }
 }catch{return $false};return $false
}
function Invoke-EvidenceTasks($Store,[string[]]$Repos=@(),[string[]]$Kinds=@(),[int]$MaxRequests=20,[string]$Proxy='',[int]$MaxWaitSeconds=0,[int]$MinRemaining=0,[double]$DelaySeconds=1,[string[]]$TaskIds=@()){
 $token=Get-GitHubReadCredential;$count=0;$waited=0;$stop='complete'
 $queue=@($Store.state.tasks.Values|Where-Object{$_.state -in @('pending','retry','running') -and (-not $Repos.Count -or $_.repo -in $Repos) -and (-not $Kinds.Count -or $_.kind -in $Kinds) -and (-not $TaskIds.Count -or $_.id -in $TaskIds)}|Sort-Object @{Expression={if($_.kind -eq 'metadata'){0}else{1}}},created_at,id)
 foreach($t in $queue){
  if($count -ge $MaxRequests){$stop='request-budget';break}
  if($t.state -eq 'retry' -and (ConvertTo-EvidenceInstant $t.next_attempt) -gt [datetimeoffset]::UtcNow){continue}
  $delay=[int][math]::Ceiling(((ConvertTo-EvidenceInstant $Store.state.next_allowed)-[datetimeoffset]::UtcNow).TotalSeconds)
  if($delay -gt 0){if($waited+$delay -gt $MaxWaitSeconds){$stop='cooldown';break};while($delay -gt 0){$sleep=[math]::Min(30,$delay);Start-Sleep -Seconds $sleep;$waited+=$sleep;$delay-=$sleep}}
  $suffix=switch($t.kind){metadata{''}readme{'/readme'}license{'/license'}releases{'/releases/latest'}issues{'/issues/comments?per_page=100&sort=created&direction=desc'}}
  $url='https://api.github.com/repos/'+$t.repo+$suffix
  $c=Get-EvidenceCache $Store $t.repo $t.kind
  $tmp=Get-EvidencePath $Store.root ('data/evidence/http/'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force (Split-Path $tmp)|Out-Null
  $t.state='running';$t.attempts++;Save-EvidenceStore $Store
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $r=Invoke-GitHubPublicGet -Root $Store.root -Url $url -BodyPath ($tmp+'.json') -HeaderPath ($tmp+'.headers') -Token $token -Proxy $Proxy -ETag $(if($c){$c.etag}else{''})
  if($r.BudgetExhausted){$t.attempts--;$t.state='pending';Save-EvidenceStore $Store;$stop='daily-api-budget';break}
  $timer.Stop();$count++
  $headers=if(Test-Path ($tmp+'.headers')){Get-GitHubResponseHeaders ([IO.File]::ReadAllText($tmp+'.headers'))}else{@{}}
  $body=if(Test-Path ($tmp+'.json')){[IO.File]::ReadAllText($tmp+'.json')}else{''}
  $policy=Get-GitHubRetryPolicy $r.Status $headers $body $t.failures
  $Store.state.next_allowed=[datetimeoffset]::UtcNow.AddSeconds([math]::Max($DelaySeconds,$policy.Delay)).ToString('o')
  $accepted=$false
  if($r.ExitCode -eq 0 -and $r.Status -eq 304 -and $c){
   $checked=[datetimeoffset]::UtcNow;$c.checked_at=$checked.ToString('o');$c.expires_at=$checked.AddHours($(if($c.outcome -eq 'present' -and $t.kind -in @('readme','license')){168}else{24})).ToString('o');$c.version=$t.version
   $t.state='succeeded';$t.result=$c;$t.failures=0;$t.reused=$true;$t.history+=@{at=$checked.ToString('o');status=304;outcome='not-modified';sha256=$c.sha256;seconds=$timer.Elapsed.TotalSeconds};$accepted=$true
  }elseif($r.ExitCode -eq 0 -and $r.Status -eq 200 -and (Test-EvidenceBody $body $t.kind $t.repo)){
   $null=Save-EvidenceResult $Store $t $body $headers 'present' 200 $timer.Elapsed.TotalSeconds;$accepted=$true
  }elseif($r.ExitCode -eq 0 -and $r.Status -eq 404 -and $t.kind -in @('license','releases','readme')){
   $null=Save-EvidenceResult $Store $t '{"verified_absence":true}' $headers 'absent' 404 $timer.Elapsed.TotalSeconds;$accepted=$true
  }
  if(-not $accepted){
   $t.failures++;$t.state=if($r.Status -in @(401,403,404,422) -and -not $policy.Limited){'blocked'}elseif($t.failures -ge 3 -and -not $policy.Limited){'blocked'}else{'retry'}
   $t.next_attempt=[datetimeoffset]::UtcNow.AddSeconds([math]::Max($policy.Delay,60*[math]::Pow(2,[math]::Min(5,$t.failures-1)))).ToString('o')
   $t.history+=@{at=[datetimeoffset]::UtcNow.ToString('o');status=$r.Status;outcome='failed';seconds=$timer.Elapsed.TotalSeconds}
   # Invalid/private/error bodies are never persisted as usable evidence.
   if(Test-Path ($tmp+'.json')){[IO.File]::WriteAllText(($tmp+'.json'),'{"evidence_response_rejected":true}')}
  }
  Save-EvidenceStore $Store
  Write-Host ("证据 {0} {1}：{2} (HTTP {3})" -f $t.repo,$t.kind,$t.state,$r.Status)
  if($policy.Limited -or $r.Status -in @(401,403,422)){$stop='http-pause';break}
  if($headers.ContainsKey('x-ratelimit-remaining') -and [int]$headers['x-ratelimit-remaining'] -le $MinRemaining){$stop='remaining-budget';break}
 }
 return @{requests=$count;stop=$stop;pending=@($Store.state.tasks.Values|Where-Object{$_.state -in @('pending','retry','running','blocked') -and (-not $Repos.Count -or $_.repo -in $Repos) -and (-not $Kinds.Count -or $_.kind -in $Kinds)}).Count}
}
function Sync-EvidenceEvents($Store,[string]$EventsFile){
 $added=0
 # Older events keep their own review reasons, but share latest resource fetches.
 # Never refetch the same present-day resource once for every historical event.
 foreach($r in @($Store.state.reviews.Values)){
  if($r.state -eq 'resolved' -or -not $r.task_version -or $r.task_version -eq 'changes'){continue}
  $legacy=@($Store.state.tasks.Values|Where-Object{$_.repo -ieq $r.repo -and $_.version -eq $r.task_version})
  foreach($t in $legacy){$next=Add-EvidenceTask $Store $r.repo $t.kind 'changes' 'coalesced change evidence';$t.state='superseded';$t.superseded_by=$next.id}
  $r.task_version='changes'
 }
 foreach($e in Read-EvidenceRows $EventsFile){
  if($e.type -notin @('license_changed','archived_changed','metadata_updated','release_detected')){continue}
  $repo=if($e.full_name){$e.full_name}else{$e.id}
  $key=Get-EvidenceHash ($repo.ToLowerInvariant()+'|'+$e.date+'|'+$e.type+'|'+$e.detail)
  if($Store.state.events.ContainsKey($key)){continue}
  $kinds=switch($e.type){license_changed{@('metadata','license')}archived_changed{@('metadata')}metadata_updated{@('metadata','readme')}release_detected{@('metadata','releases')}}
  foreach($kind in $kinds){$null=Add-EvidenceTask $Store $repo $kind 'changes' ('event '+$e.type) -Force}
  $Store.state.reviews[$key]=@{id=$key;repo=$repo;state='awaiting-evidence';reason=$e.type;source_event_date=$e.date;source_event_detail=$e.detail;task_version='changes';created_at=[datetimeoffset]::UtcNow.ToString('o');note='release_detected is a push-based hint, not a verified release'}
  $Store.state.events[$key]=$true;$added++
 }
 return $added
}
function Update-EvidenceReviews($Store){
 foreach($r in $Store.state.reviews.Values){
  if($r.state -eq 'resolved' -or (-not $r.task_version -and -not $r.task_ids)){continue}
  $tasks=if($r.task_ids){@($Store.state.tasks.Values|Where-Object{$_.id -in $r.task_ids})}else{@($Store.state.tasks.Values|Where-Object{$_.repo -ieq $r.repo -and $_.version -eq $r.task_version})}
  foreach($t in $tasks){if($t.state -eq 'succeeded' -and $t.result -and (ConvertTo-EvidenceInstant $t.result.expires_at) -le [datetimeoffset]::UtcNow){$t.state='pending';$t.reused=$false}}
  $r.state=if($tasks.Count -and @($tasks|Where-Object state -ne 'succeeded').Count -eq 0){'ready-for-review'}else{'awaiting-evidence'}
 }
}
