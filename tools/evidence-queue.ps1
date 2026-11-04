param([ValidateSet('enqueue','run','sync-events','check','resolve-review')][string]$Action='check',
 [string]$Root=(Split-Path -Parent $PSScriptRoot),[string[]]$Ids=@(),
 [string[]]$Kinds=@('metadata','readme','license','releases','issues'),[string]$Batch='',
  [ValidateRange(1,200)][int]$MaxRequests=20,[string]$Proxy='',[switch]$NoProxy,[ValidateRange(0,900)][int]$MaxWaitSeconds=0,[switch]$Force,[string]$ReviewId='',[string]$Evidence='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
$store=Open-EvidenceStore $Root
try{
 if($Batch){$dir=Get-EvidencePath $Root $Batch;$m=Get-Content (Join-Path $dir 'manifest.json') -Raw|ConvertFrom-Json;$Ids=@($m.items.id)}
 if($Action -eq 'enqueue'){
  foreach($id in $Ids){foreach($kind in $Kinds){$null=Add-EvidenceTask $store $id $kind -Force:$Force}}
  Save-EvidenceStore $store;Write-Host "证据任务已登记：$($Ids.Count) 个项目；不自动评分。"
 }elseif($Action -eq 'run'){
  $Proxy=Get-GitHubProxy -Proxy $Proxy -NoProxy:$NoProxy
  $result=Invoke-EvidenceTasks $store -Repos $Ids -Kinds $Kinds -MaxRequests $MaxRequests -Proxy $Proxy -MaxWaitSeconds $MaxWaitSeconds
  Update-EvidenceReviews $store;Save-EvidenceStore $store
  Write-Host "证据队列：请求 $($result.requests)；待补 $($result.pending)；停止原因 $($result.stop)"
  if($result.pending){exit 2}
 }elseif($Action -eq 'sync-events'){
  $n=Sync-EvidenceEvents $store (Join-Path $Root 'data/events.jsonl');Update-EvidenceReviews $store;Save-EvidenceStore $store
  Write-Host "变化复核新增 $n 项；事件重放不会重复入队。"
 }elseif($Action -eq 'resolve-review'){
  $r=$store.state.reviews[$ReviewId]
  if(-not $r){throw 'Unknown change review'}
  Update-EvidenceReviews $store
  if($r.state -ne 'ready-for-review'){throw 'Change evidence must be ready before review can resolve'}
  $file=Get-EvidencePath $Root $Evidence
  $receipt=@(Read-EvidenceRows $file|Where-Object{$_.review_id -eq $ReviewId -and $_.id -ieq $r.repo}|Select-Object -Last 1)
  if(-not $receipt.Count -or $receipt[0].decision -notin @('graded','excluded') -or -not $receipt[0].reviewer -or -not $receipt[0].reason){throw 'A complete matching reviewer decision is required; unresolved work cannot close'}
  $decision=$receipt[0]
  if($decision.decision -eq 'graded'){
   . (Join-Path $PSScriptRoot 'score.ps1')
   if($null -eq $decision.score -or $decision.score -lt 0 -or $decision.score -gt 100 -or (Get-Tier $decision.score) -ne $decision.tier){throw 'Reviewer score/tier mismatch'}
  }
  $tasks=if($r.task_ids){@($store.state.tasks.Values|Where-Object{$_.id -in $r.task_ids})}else{@($store.state.tasks.Values|Where-Object{$_.repo -ieq $r.repo -and $_.version -eq $r.task_version})}
  if(-not $tasks.Count){throw 'Change review has no evidence tasks'}
  foreach($t in $tasks){if($decision.evidence_sha256.($t.kind) -ne $t.result.sha256){throw 'Reviewed evidence does not match the current change facts'}}
  $r.state='resolved';$r.resolution=@{file=$Evidence;sha256=(Get-FileHash $file).Hash;reviewer=$decision.reviewer;decision=$decision.decision;at=[datetimeoffset]::UtcNow.ToString('o')}
  Save-EvidenceStore $store;Write-Host '变化复核已凭匹配证据和真实决定关单；未写入评分库或主推荐。'
 }else{
  foreach($c in $store.state.cache.Values){$null=Get-EvidenceCache $store $c.repo $c.kind}
  foreach($t in $store.state.tasks.Values){
   if($t.state -notin @('pending','running','retry','blocked','succeeded','superseded')){throw 'Invalid durable evidence task state'}
   if($t.state -eq 'succeeded' -and -not $t.result){throw 'Successful task lacks evidence'}
   if($t.result){$p=Get-EvidencePath $Root $t.result.path;if((Get-FileHash -LiteralPath $p).Hash -ne $t.result.sha256){throw 'Task result evidence changed'}}
  }
  foreach($r in $store.state.reviews.Values){if($r.state -eq 'resolved'){$p=Get-EvidencePath $Root $r.resolution.file;if((Get-FileHash $p).Hash -ne $r.resolution.sha256){throw 'Change review decision evidence changed'}}}
  $pending=@($store.state.tasks.Values|Where-Object state -in @('pending','running','retry','blocked')).Count
  Write-Host "证据存储校验通过：缓存 $($store.state.cache.Count)，待执行 $pending，变化复核 $($store.state.reviews.Count)；不是全部任务完成。"
 }
}finally{$store.guard.Dispose()}
exit 0
