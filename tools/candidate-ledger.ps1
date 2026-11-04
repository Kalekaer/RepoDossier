# Every observed candidate has a durable disposition. No edits to library/picks.
param([ValidateSet('sync','check','list','set','sample','evaluate')][string]$Action='check',
 [string]$Date='', [string]$Root=(Split-Path -Parent $PSScriptRoot),
 [string]$Id='', [string]$State='', [string]$Reason='', [string]$Evidence='',
 [string]$ReviewAfter='', [switch]$Publish, [int]$N=24, [int]$Seed=20261029,
 [string]$Labels='', [string[]]$ScopeIds=@())
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'score.ps1')
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
$null=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
$path=Join-Path $Root 'data/candidates.jsonl'
$audit=Join-Path $Root 'data/audit/candidates'
New-Item -ItemType Directory -Force $audit | Out-Null
# Unlike tolerant research readers, a disposition ledger must never silently drop bad rows.
$rows=@(); if(Test-Path $path){foreach($line in [IO.File]::ReadAllLines($path)){if($line.Trim()){$rows+=ConvertFrom-Json $line -ErrorAction Stop}}}
$idx=@{}; foreach($r in $rows){if($idx.ContainsKey($r.id)){throw 'Duplicate candidate id'};$idx[$r.id]=$r}
function Save-Ledger {
 $tmp=$path+'.tmp'; $lines=@($script:rows|ForEach-Object{ConvertTo-Json $_ -Depth 12 -Compress})
 [IO.File]::WriteAllText($tmp,($lines -join "`n")+$(if($lines.Count){"`n"}else{''}),[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Set-Field($Object,[string]$Key,$Value){$Object|Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force}
function Read-Pool([string]$File){
 if(-not(Test-Path $File)){throw 'Candidate pool missing'}
 $out=@();foreach($line in [IO.File]::ReadAllLines($File)){if($line.Trim()){$p=ConvertFrom-Json $line -ErrorAction Stop;if(-not $p.id){throw 'Pool row missing id'};$out+=$p}}
 return $out
}
if($Action -in @('sync','set')){
 $guard=[IO.File]::Open(($path+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try {
  # Reload inside the lock to avoid lost updates.
  $rows=@();$idx=@{}; if(Test-Path $path){foreach($line in [IO.File]::ReadAllLines($path)){if($line.Trim()){$r=ConvertFrom-Json $line -ErrorAction Stop;if($idx.ContainsKey($r.id)){throw 'Duplicate candidate id'};$rows+=$r;$idx[$r.id]=$r}}}
  if(Test-Path $path){$backup=Join-Path $Root ('data/_backup/candidates/'+[datetime]::UtcNow.ToString('yyyy-MM-dd'));New-Item -ItemType Directory -Force $backup|Out-Null;Copy-Item -LiteralPath $path -Destination (Join-Path $backup ([guid]::NewGuid().ToString('N')+'.jsonl'))}
  if($Action -eq 'sync'){
   $poolPath=Join-Path $Root "data/audit/pool/$Date-all.jsonl"
   if(-not(Test-Path $poolPath)){throw 'Candidate pool missing; refresh discovery first.'}
   $picks=@{};foreach($file in @(Get-ChildItem (Join-Path $Root 'data/picks') -File -Filter '*.jsonl' -ErrorAction SilentlyContinue|Sort-Object Name)){
    foreach($p in Read-JsonlSafe $file.FullName){$p|Add-Member -NotePropertyName ledger_evidence_file -NotePropertyValue ('data/picks/'+$file.Name) -Force;$picks[[string]$p.full_name]=$p}
   }
   $pool=Read-Pool $poolPath
   foreach($p in $pool){
    if(-not $p.id){throw 'Pool row missing id'}
    $r=$idx[[string]$p.id]
    if(-not $r){
     $r=[pscustomobject]@{id=[string]$p.id;state='new';discovered_at=$Date;last_seen=$Date;channels=@();dates=@();reason='Awaiting evidence review';evidence=$null;score=$null;tier=$null;review_after=$null;history=@()}
     $rows+=$r;$idx[$r.id]=$r
     if($p.in_library -or $p.in_seen){$r.state='known';$r.reason='Existing library/seen record; not a new recommendation'}
    }
    if(-not $r.last_seen -or $Date -gt $r.last_seen){Set-Field $r 'last_seen' $Date}
    if($Date -lt $r.discovered_at){$r.discovered_at=$Date}
    Set-Field $r 'dates' @((@($r.dates)+$Date)|Where-Object{$_}|Sort-Object -Unique)
    Set-Field $r 'channels' @((@($r.channels)+@($p.channels)+$p.channel)|Where-Object{$_}|Sort-Object -Unique)
    Set-Field $r 'screening_flag' $p.exclude_reason
    Set-Field $r 'review_flags' @($p.review_flags)
    Set-Field $r 'stars' $p.stars
    # A coarse flag is a review lead, never an automatic rejection.
    if($picks.ContainsKey($r.id) -and ($r.state -in @('new','screened','known') -or $r.reason -eq 'Existing scored evidence')){
     $pick=$picks[$r.id];$r.score=$pick.score;$r.tier=$pick.tier
     $validScore=$null -ne $pick.score -and $pick.tier -in @('S','A','B','C','D') -and (Get-Tier $pick.score) -eq $pick.tier
     $libraryKnown=$p.in_library -or $p.in_seen
     $r.state=if($validScore){'scored'}elseif($libraryKnown){'known'}else{'screened'}
     $r.reason=if($validScore){'Existing scored evidence'}elseif($libraryKnown){'Existing library tier; historical score is not a current daily rule score'}else{'Historical score evidence incomplete/inconsistent; needs review'}
     Set-Field $r 'evidence' $pick.ledger_evidence_file
    }
    Set-Field $r 'updated_at' ([datetimeoffset]::UtcNow.ToString('o'))
   }
   Save-Ledger
   Write-Host "检索结果已登记：$($pool.Count) 个观察项；总队列 $($rows.Count)"
  } else {
   if(-not $idx.ContainsKey($Id)){throw 'Unknown candidate'}
   if($State -notin @('screened','scored','accepted','rejected','deferred','known')){throw 'Invalid disposition'}
   if(-not $Reason.Trim()){throw 'Reason is required'}
   if($State -in @('scored','accepted','rejected') -and -not $Evidence.Trim()){throw 'Evidence is required'}
   if($Evidence){$ev=[IO.Path]::GetFullPath((Join-Path $Root $Evidence));if(-not $ev.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $ev)){throw 'Evidence must exist inside workspace'}}
   $verifiedScore=$null
   if($State -in @('scored','accepted')){
    $verifiedScore=@(Read-JsonlSafe $ev|Where-Object{($_.full_name -eq $Id -or $_.id -eq $Id) -and $_.tier -in @('S','A','B','C','D') -and $null -ne $_.score -and $_.score -ge 0 -and $_.score -le 100}|Select-Object -Last 1)
    if(-not $verifiedScore.Count -or (Get-Tier $verifiedScore[0].score) -ne $verifiedScore[0].tier){throw 'Scored disposition requires matching score/tier evidence for this candidate'}
    if($State -eq 'accepted' -and ($verifiedScore[0].tier -notin @('S','A') -or $verifiedScore[0].risk -eq '高')){throw 'Accepted requires eligible S/A evidence'}
   }
   if($State -eq 'known' -and -not @(Read-JsonlSafe (Join-Path $Root 'data/seen.jsonl')|Where-Object full_name -eq $Id).Count){throw 'Known requires an existing seen record'}
   if($State -eq 'deferred'){
    $review=[datetime]::ParseExact($ReviewAfter,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    if($ReviewAfter -le $Date -or $review -gt ([datetime]::Parse($Date)).AddDays(7)){throw 'Deferred review date must be within the next seven days'}
    $previous=@($idx[$Id].history|Where-Object to -eq 'deferred')
    if(($idx[$Id].state -eq 'deferred' -or $previous.Count) -and -not $Evidence){throw 'Renewed deferral requires new workspace evidence; a new date alone is not progress'}
    if($previous.Count -and $previous[-1].evidence -eq $Evidence){throw 'Renewed deferral must provide different evidence from the last deferral'}
    if($previous.Count -and $previous[-1].evidence_sha256 -and (Get-FileHash -LiteralPath $ev).Hash -eq $previous[-1].evidence_sha256){throw 'Renaming unchanged evidence does not justify another deferral'}
   }
   $r=$idx[$Id];$old=$r.state
   Set-Field $r 'history' @(@($r.history)+[pscustomobject]@{at=[datetimeoffset]::UtcNow.ToString('o');from=$old;to=$State;reason=$Reason;evidence=$Evidence;evidence_sha256=$(if($Evidence -and (Test-Path -LiteralPath $ev -PathType Leaf)){(Get-FileHash -LiteralPath $ev).Hash}else{$null})})
   $r.state=$State;$r.reason=$Reason;$r.evidence=$Evidence;Set-Field $r 'review_after' $ReviewAfter
   if($verifiedScore){$r.score=$verifiedScore[0].score;$r.tier=$verifiedScore[0].tier}
   Save-Ledger
  }
 } finally {$guard.Dispose()}
}
if($Action -in @('sync','check','list')){
 $poolPath=Join-Path $Root "data/audit/pool/$Date-all.jsonl"
 $missing=0;$bad=0;$pending=0;$overdue=0;$deferred=0
 $seenIds=@{};foreach($known in Read-JsonlSafe (Join-Path $Root 'data/seen.jsonl')){$seenIds[[string]$known.full_name]=$true}
 $evidenceCache=@{}
 $allPending=0
 foreach($p in @(Read-Pool $poolPath)){
  if($idx[[string]$p.id].state -in @('new','screened')){$allPending++}
  if($ScopeIds.Count -and $p.id -notin $ScopeIds){continue}
  $r=$idx[[string]$p.id];if(-not $r){$missing++;continue}
  if($r.state -notin @('new','screened','scored','accepted','rejected','deferred','known')){$bad++}
  if($r.state -in @('new','screened')){$pending++}
  if($r.state -eq 'deferred' -and (-not $r.reason -or -not $r.review_after)){$bad++}
  if($r.state -eq 'deferred'){$deferred++}
  if($r.state -eq 'deferred' -and $r.review_after -le $Date){$overdue++}
  if($r.state -in @('accepted','rejected','scored') -and (-not $r.reason -or -not $r.evidence)){$bad++}
  if($r.state -in @('accepted','scored') -and ($null -eq $r.score -or $r.tier -notin @('S','A','B','C','D') -or (Get-Tier $r.score) -ne $r.tier)){$bad++}
  if($r.state -in @('accepted','scored')){
    $ep=[IO.Path]::GetFullPath((Join-Path $Root ([string]$r.evidence)))
    if(-not $ep.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $ep)){$bad++}
    else{
      if(-not $evidenceCache.ContainsKey($ep)){$evidenceCache[$ep]=@(Read-JsonlSafe $ep)}
      if(-not @($evidenceCache[$ep]|Where-Object{($_.id -eq $r.id -or $_.full_name -eq $r.id) -and $_.score -eq $r.score -and $_.tier -eq $r.tier}).Count){$bad++}
    }
  }
  if($r.state -eq 'known' -and -not $seenIds.ContainsKey([string]$r.id)){$bad++}
 }
 $reportPath=Join-Path $Root "reports/$Date.md"
 # Expired work remains due even if it no longer appears in today's search window.
 $dueRows=@($rows|Where-Object{
   ($_.state -eq 'deferred' -and $_.review_after -and $_.review_after -le $Date) -or
   ($_.state -in @('new','screened') -and $_.discovered_at -and ([datetime]::Parse($Date)-[datetime]::Parse($_.discovered_at)).TotalDays -ge 7)
 })
 $overdue=@($dueRows|Where-Object{-not $ScopeIds.Count -or $_.id -in $ScopeIds}).Count
 if($Publish -and $deferred -gt 0 -and (Test-Path $reportPath) -and ([IO.File]::ReadAllText($reportPath) -notmatch ('延期复核[：:]\s*'+$deferred+'(?!\d)'))){$bad++;Write-Host "日报需如实披露：延期复核：$deferred"}
 $result=@{date=$Date;ledger=$rows.Count;missing=$missing;invalid=$bad;pending=$pending;deferred=$deferred;overdue=$overdue;discovery_pending=$allPending;discovery_overdue=$dueRows.Count;scope=$(if($ScopeIds.Count){'declared editorial batch'}else{'all observed results'});publish_ready=($missing+$bad+$pending+$overdue -eq 0);states=@($rows|Group-Object state|Select-Object Name,Count)}
 $result|ConvertTo-Json -Depth 5|Set-Content (Join-Path $audit "$Date.json") -Encoding UTF8
 Write-Host "检索结果对账：缺登记 $missing；无效 $bad；待处理 $pending；延期到期 $overdue"
 if(-not(Test-Path $poolPath)){Write-Host 'Pool missing';exit 1}
 if($missing+$bad -gt 0 -or ($Publish -and $pending+$overdue -gt 0)){exit 1}
}
if($Action -eq 'sample'){
 $samplePath=Join-Path $audit "blind-$Date-$Seed.jsonl"
 if(Test-Path $samplePath){Write-Host '已有盲评样本保留；需要新的独立样本时显式更换 Seed。';exit 0}
 # Independent audit frame: deliberately includes known/rejected, hides stars and prior grades.
 $rng=[Random]::new($Seed);$pool=@($rows|Sort-Object id);$sample=@()
 foreach($g in @($pool|Group-Object {if($_.stars -lt 200){'low'}elseif($_.stars -le 800){'mid'}else{'high'}})){
  $items=[Collections.Generic.List[object]]::new();foreach($r in $g.Group){$items.Add($r)}
  $take=[math]::Min($items.Count,[int][math]::Ceiling($N/3.0))
  for($i=0;$i -lt $take;$i++){$j=$rng.Next($items.Count);$r=$items[$j];$items.RemoveAt($j);$sample+=[pscustomobject]@{id=$r.id;stratum=$g.Name;population=$g.Count;sample_n=$take;inclusion_probability=$take/[double]$g.Count;reviewer1=$null;tier1=$null;evidence1=$null;reviewer2=$null;tier2=$null;evidence2=$null}}
 }
 $sample|ForEach-Object{ConvertTo-Json $_ -Compress}|Set-Content $samplePath -Encoding UTF8
 @{version=1;date=$Date;seed=$Seed;frame_sha256=(Get-FileHash $samplePath).Hash;population='observed ledger; not all GitHub'}|ConvertTo-Json|Set-Content ($samplePath+'.manifest.json') -Encoding UTF8
 Write-Host "盲评表 $($sample.Count) 条；这是已观测检索结果的质量评估，不是 GitHub 总体召回。"
}
if($Action -eq 'evaluate'){
 if(-not $Labels){throw 'Labels required'}
 $labelsRows=Read-JsonlSafe $Labels
 if(-not $labelsRows.Count){throw 'Empty labels'}
 $invalid=@($labelsRows|Where-Object{-not ([string]$_.reviewer1).Trim() -or -not ([string]$_.reviewer2).Trim() -or ([string]$_.reviewer1).Trim() -eq ([string]$_.reviewer2).Trim() -or $_.tier1 -notin @('S','A','B','C','D') -or $_.tier2 -notin @('S','A','B','C','D') -or -not $_.evidence1 -or -not $_.evidence2 -or $_.inclusion_probability -le 0 -or $_.inclusion_probability -gt 1})
 if($invalid.Count){throw 'Two distinct reviewers, complete labels/evidence and valid inclusion probabilities are required. No proxy labels.'}
 $framePath=Join-Path $audit "blind-$Date-$Seed.jsonl"
 $frameManifest=$framePath+'.manifest.json'
 if(-not(Test-Path $frameManifest)){throw 'A sealed pre-review sampling frame is required; legacy forms cannot establish a quality evaluation'}
 $seal=Get-Content $frameManifest -Raw|ConvertFrom-Json
 if((Get-FileHash $framePath).Hash -ne $seal.frame_sha256){throw 'Blind sampling frame changed'}
 $frame=@(Read-Pool $framePath);$labelIds=@($labelsRows|ForEach-Object id)
 if($labelIds.Count -ne @($labelIds|Sort-Object -Unique).Count -or $labelIds.Count -ne $frame.Count){throw 'Quality evaluation requires unique labels for the complete sealed sample'}
 foreach($label in $labelsRows){
  $f=@($frame|Where-Object id -eq $label.id)
  if($f.Count -ne 1 -or [double]$f[0].inclusion_probability -ne [double]$label.inclusion_probability){throw 'Label identity or sampling probability differs from the sealed frame'}
  foreach($e in @($label.evidence1,$label.evidence2)){
   $p=[IO.Path]::GetFullPath((Join-Path $Root ([string]$e)))
   if(-not $p.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $p -PathType Leaf)){throw 'Reviewer evidence must be an existing workspace file'}
  }
 }
 $agreement=@($labelsRows|Where-Object{$_.tier1 -eq $_.tier2}).Count/$labelsRows.Count
 @{sample=$labelsRows.Count;exact_agreement=$agreement;disagreements=@($labelsRows|Where-Object{$_.tier1 -ne $_.tier2}|ForEach-Object id);population='observed candidate ledger only';overall_github_recall=$null}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $audit "evaluation-$Date.json") -Encoding UTF8
}
exit 0
