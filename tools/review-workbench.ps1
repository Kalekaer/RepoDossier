# Prepare reproducible evidence, not inferred grades. Never consumes repository instructions.
param([ValidateSet('prepare','verify')][string]$Action='prepare',[string]$Root=(Split-Path -Parent $PSScriptRoot),
 [string]$Date='',[ValidateRange(1,500)][int]$N=24,[string]$Batch='',[switch]$Backlog,[string]$SampleFile='',[switch]$Changes)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
function Hash-File($p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
if($Action -eq 'prepare'){
 $rows=@(Read-JsonlSafe (Join-Path $Root 'data/candidates.jsonl')|Where-Object{ $_.state -in @('new','screened') -or ($_.state -eq 'deferred' -and $_.review_after -and $_.review_after -le $Date)})
 # Oldest first within each star band; round robin prevents a star-sorted head monopolizing review.
 $scope=Join-Path $Root "data/audit/editorial/$Date.json"
 if($Changes){
  $eventStore=Open-EvidenceStore $Root
  try{Update-EvidenceReviews $eventStore;Save-EvidenceStore $eventStore;$changeRows=@($eventStore.state.reviews.Values|Where-Object state -eq 'ready-for-review'|Sort-Object created_at|Select-Object -First $N);$selected=@($changeRows|ForEach-Object{[pscustomobject]@{id=$_.repo;stars=0}}|Sort-Object id -Unique)}finally{$eventStore.guard.Dispose()}
 }
 elseif($SampleFile){
  $samplePath=[IO.Path]::GetFullPath((Join-Path $Root $SampleFile))
  if(-not $samplePath.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Sample must be in workspace'}
  $seal=Get-Content ($samplePath+'.manifest.json') -Raw|ConvertFrom-Json
  if((Hash-File $samplePath) -ne $seal.frame_sha256){throw 'Blind sample changed'}
  $ids=@(Read-JsonlSafe $samplePath|ForEach-Object id);$all=@(Read-JsonlSafe (Join-Path $Root 'data/candidates.jsonl'));$selected=@($all|Where-Object{$_.id -in $ids})
  if($selected.Count -ne $ids.Count){throw 'Sample identity missing from ledger'}
 }
 elseif(-not $Backlog -and (Test-Path $scope)){$ids=@((Get-Content $scope -Raw|ConvertFrom-Json).ids);$all=@(Read-JsonlSafe (Join-Path $Root 'data/candidates.jsonl'));$selected=@($all|Where-Object{$_.id -in $ids})}
 else{$selected=@(Select-ReviewWork -Rows $rows -N $N -Date $Date)}
 # Idempotent preparation preserves existing review forms and validated packets.
 $mode=if($Changes){'changes'}elseif($SampleFile){'blind-'+(Hash-File $samplePath)}elseif($Backlog){'backlog'}else{'daily'}
 foreach($existing in @(Get-ChildItem (Join-Path $Root 'data/audit/reviews') -Recurse -File -Filter manifest.json -ErrorAction SilentlyContinue|Sort-Object FullName)){
  $m=Get-Content $existing.FullName -Raw|ConvertFrom-Json
  if($m.date -eq $Date -and $m.mode -eq $mode -and ((@($m.items|ForEach-Object id|Sort-Object) -join '|') -eq (@($selected|ForEach-Object id|Sort-Object) -join '|'))){
   & $PSCommandPath verify -Root $Root -Batch $existing.DirectoryName
   if($LASTEXITCODE -ne 0){throw 'Existing review batch failed verification; preserve it for investigation'}
   Write-Output $existing.DirectoryName;exit 0
  }
 }
 $out=Join-Path $Root ('data/audit/reviews/'+$Date+'-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Force $out|Out-Null
 $wanted=@{};foreach($r in $selected){$wanted[$r.id]=$r};$facts=@{}
 foreach($file in @(Get-ChildItem (Join-Path $Root 'data/raw') -Recurse -File -Filter meta.json -ErrorAction SilentlyContinue|Sort-Object FullName)){
  $meta=Get-Content $file.FullName -Raw|ConvertFrom-Json
  foreach($import in @($meta.imports|Where-Object ok)){
   $rawPath=[IO.Path]::GetFullPath((Join-Path $file.DirectoryName $import.file))
   if(-not $rawPath.StartsWith($file.DirectoryName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid raw path'}
   if($import.sha256 -and (Hash-File $rawPath) -ne $import.sha256){throw 'Changed source raw'}
   $json=Get-Content $rawPath -Raw|ConvertFrom-Json
   foreach($item in $json.items){if($wanted.ContainsKey([string]$item.full_name) -and -not $item.private){$facts[$item.full_name]=@{item=$item;source=($rawPath.Substring($Root.Length+1) -replace '\\','/');source_sha256=Hash-File $rawPath;captured_at=$import.at}}}
  }
 }
 $manifest=@();$forms=@()
 $readmeCache=@{}
 $evidence=Open-EvidenceStore $Root
 try{
  foreach($r in $selected){
   $metadata=Get-EvidenceCache $evidence $r.id metadata
   if($metadata -and $metadata.outcome -eq 'present' -and ($Changes -or -not $facts[$r.id])){
    $facts[$r.id]=@{item=(Get-Content (Get-EvidencePath $Root $metadata.path) -Raw|ConvertFrom-Json);source=$metadata.path;source_sha256=$metadata.sha256;captured_at=$metadata.checked_at}
   }
   $version=Get-EvidenceVersion $facts[$r.id].item.pushed_at
   foreach($kind in @('metadata','readme','license','releases','issues')){$null=Add-EvidenceTask $evidence $r.id $kind $version 'declared review scope'}
   $cached=Get-EvidenceCache $evidence $r.id readme
   if($cached -and $cached.outcome -eq 'present' -and $cached.version -eq $version -and (ConvertTo-EvidenceInstant $cached.expires_at) -gt [datetimeoffset]::UtcNow){
    $body=Get-Content (Get-EvidencePath $Root $cached.path) -Raw|ConvertFrom-Json
    $target=Join-Path $out (($r.id -replace '/','--')+'.README.md')
    [IO.File]::WriteAllText($target,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body.content)),[Text.UTF8Encoding]::new($false))
    $readmeCache[$r.id]=@{path=$target;record=[pscustomobject]@{id=$r.id;path=[IO.Path]::GetFileName($target);fetched_at=$cached.fetched_at;checked_at=$cached.checked_at;sha256=(Get-FileHash $target).Hash;source=$cached.path}}
   }
  }
  Save-EvidenceStore $evidence
 }finally{$evidence.guard.Dispose()}
 foreach($file in @(Get-ChildItem (Join-Path $Root 'data/audit/reviews') -Recurse -File -Filter readme-evidence.jsonl)){
  foreach($entry in Read-JsonlSafe $file.FullName){
   if($entry.fetched_at -and ([datetimeoffset]::Parse($entry.fetched_at).ToUniversalTime().AddHours(8).ToString('yyyy-MM-dd')) -eq $Date){
    $p=[IO.Path]::GetFullPath((Join-Path $file.DirectoryName $entry.path))
    if(-not $readmeCache.ContainsKey($entry.id) -and $p.StartsWith($file.DirectoryName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path $p) -and (Hash-File $p) -eq $entry.sha256){$readmeCache[$entry.id]=@{record=$entry;path=$p}}
   }
  }
 }
 foreach($r in $selected){
  $key=($r.id -replace '/','--');$path=Join-Path $out ($key+'.json')
  $fact=$facts[$r.id]
  if(-not $fact){throw 'Selected candidate lacks registered public evidence'}
  $packet=@{id=$r.id;observed=$fact;untrusted_content=$true;readme=$null;release=$null;license_verified=$false;missing=@('README evidence','release evidence','license verification','independent reviews');rules=@{rubric_sha256=Hash-File (Join-Path $Root 'RUBRIC.md');criteria_sha256=Hash-File (Join-Path $Root 'data/criteria.json')}}
  if($readmeCache.ContainsKey($r.id)){
   $cached=$readmeCache[$r.id];$target=Join-Path $out ($key+'.README.md');if([IO.Path]::GetFullPath($cached.path) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $cached.path -Destination $target}
   $packet.readme=$cached.record;$packet.missing=@('release evidence','license verification','independent reviews')
   $entry=$cached.record;$entry.path=[IO.Path]::GetFileName($target);$entry|ConvertTo-Json -Compress|Add-Content (Join-Path $out 'readme-evidence.jsonl') -Encoding UTF8
  }
  [IO.File]::WriteAllText($path,($packet|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
  $manifest+=@{id=$r.id;file=[IO.Path]::GetFileName($path);sha256=Hash-File $path}
  # Do not expose previous grades or invent quality from metadata.
  $forms+=@{id=$r.id;reviewer1=$null;score1=$null;tier1=$null;evidence1=$null;reviewer2=$null;score2=$null;tier2=$null;evidence2=$null;decision=$null;reason=$null}
 }
 @{version=2;date=$Date;mode=$mode;change_reviews=$(if($Changes){$changeRows}else{@()});selection='due deferrals first, then oldest-first round-robin star bands; not probability sample';items=$manifest;ledger_sha256=$(if(Test-Path (Join-Path $Root 'data/candidates.jsonl')){Hash-File (Join-Path $Root 'data/candidates.jsonl')}else{$null})}|ConvertTo-Json -Depth 15|Set-Content (Join-Path $out 'manifest.json') -Encoding UTF8
 $forms|ForEach-Object{ConvertTo-Json $_ -Compress}|Set-Content (Join-Path $out 'reviews.jsonl') -Encoding UTF8
 Write-Host "已准备 $($manifest.Count) 份可追溯证据包；缺失证据明确标记，未填评分。"
 Write-Output $out
}else{
 $dir=[IO.Path]::GetFullPath($Batch)
 if(-not $dir.StartsWith([IO.Path]::GetFullPath((Join-Path $Root 'data/audit/reviews'))+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Review batch must remain in workspace review directory'}
 $manifest=Get-Content (Join-Path $dir 'manifest.json') -Raw|ConvertFrom-Json
 foreach($item in $manifest.items){
  $p=[IO.Path]::GetFullPath((Join-Path $dir $item.file))
  if(-not $p.StartsWith($dir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Hash-File $p) -ne $item.sha256){throw 'Evidence packet missing or changed'}
  $packet=Get-Content $p -Raw|ConvertFrom-Json
  if((Hash-File (Join-Path $Root $packet.observed.source)) -ne $packet.observed.source_sha256){throw 'Original source changed'}
  if((Hash-File (Join-Path $Root 'RUBRIC.md')) -ne $packet.rules.rubric_sha256 -or (Hash-File (Join-Path $Root 'data/criteria.json')) -ne $packet.rules.criteria_sha256){throw 'Review criteria changed'}
 }
 $readmeManifest=Join-Path $dir 'readme-evidence.jsonl'
 if(Test-Path $readmeManifest){foreach($entry in Read-JsonlSafe $readmeManifest){
  $readmePath=[IO.Path]::GetFullPath((Join-Path $dir $entry.path))
  if(-not $readmePath.StartsWith($dir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Hash-File $readmePath) -ne $entry.sha256){throw 'README evidence missing or changed'}
 }}
 Write-Host "证据包校验通过；这不代表质量评审已通过。"
}
exit 0
