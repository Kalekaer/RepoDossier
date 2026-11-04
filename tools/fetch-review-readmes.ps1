# Compatibility entry point; all network/cache/retry state belongs to evidence-store.
param([string]$Batch='',[string]$Proxy='', [switch]$NoProxy,
  [ValidateRange(1,200)][int]$MaxRequests=24,[ValidateRange(0,900)][int]$MaxWaitSeconds=60)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Batch)){throw 'Batch is required; pass -Batch with a workspace review directory'}
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
$Proxy=Get-GitHubProxy -Proxy $Proxy -NoProxy:$NoProxy
$dir=Get-EvidencePath $root $Batch
if(-not $dir.StartsWith([IO.Path]::GetFullPath((Join-Path $root 'data/audit/reviews'))+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Batch must be a workspace review directory'}
$manifest=Get-Content (Join-Path $dir 'manifest.json') -Raw|ConvertFrom-Json
$index=Join-Path $dir 'readme-evidence.jsonl';$known=@{}
foreach($r in Read-EvidenceRows $index){$known[$r.id]=$r}
$store=Open-EvidenceStore $root
try{
 $missing=@();$wanted=@{}
 foreach($item in $manifest.items){
  if($known.ContainsKey($item.id)){
   $path=Get-EvidencePath $dir $known[$item.id].path
   if((Get-FileHash $path).Hash -ne $known[$item.id].sha256){throw 'Frozen README changed'}
   continue
  }
  $packetPath=Get-EvidencePath $dir $item.file
  if((Get-FileHash $packetPath).Hash -ne $item.sha256){throw 'Review packet changed'}
  $packet=Get-Content $packetPath -Raw|ConvertFrom-Json
  $version=Get-EvidenceVersion $packet.observed.item.pushed_at
  $t=Add-EvidenceTask $store $item.id readme $version 'README for frozen evidence packet';$wanted[$item.id]=$t.id;$missing+=$item.id
 }
 Save-EvidenceStore $store
 $result=if($missing.Count){Invoke-EvidenceTasks $store -Repos $missing -Kinds readme -MaxRequests $MaxRequests -Proxy $Proxy -MaxWaitSeconds $MaxWaitSeconds}else{@{pending=0;requests=0}}
 foreach($id in $missing){
  $c=Get-EvidenceCache $store $id readme
  $t=$store.state.tasks[$wanted[$id]]
  if(-not $c -or $t.state -ne 'succeeded' -or $c.version -ne $t.version -or $c.outcome -ne 'present' -or (ConvertTo-EvidenceInstant $c.expires_at) -le [datetimeoffset]::UtcNow){continue}
  $body=Get-Content (Get-EvidencePath $root $c.path) -Raw|ConvertFrom-Json
  $name=($id -replace '/','--')+'.README.md';$target=Join-Path $dir $name
  if(Test-Path $target){throw 'Unregistered README already exists; do not overwrite audit evidence'}
  [IO.File]::WriteAllText($target,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body.content)),[Text.UTF8Encoding]::new($false))
  @{id=$id;path=$name;sha256=(Get-FileHash $target).Hash;fetched_at=$c.fetched_at;checked_at=$c.checked_at;source=$c.path;api_sha=$body.sha}|ConvertTo-Json -Compress|Add-Content $index -Encoding UTF8
 }
 Update-EvidenceReviews $store;Save-EvidenceStore $store
 Write-Host "README补证：本次请求 $($result.requests)，待补 $($result.pending)。"
 if($result.pending){exit 2}
}finally{$store.guard.Dispose()}
exit 0
