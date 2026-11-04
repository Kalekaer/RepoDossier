# Persist measured review effort and explicit adjudications. No estimated costs.
param([Parameter(Mandatory)][string]$From,[string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'evidence-store.ps1')
$source=Get-EvidencePath $Root $From;$rows=@(Read-EvidenceRows $source)
$out=Get-EvidencePath $Root 'data/audit/review-metrics.jsonl';New-Item -ItemType Directory -Force (Split-Path $out)|Out-Null
$guard=[IO.File]::Open(($out+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $seen=@{};foreach($r in Read-EvidenceRows $out){$seen[$r.record_id]=$true}
 $prepared=@()
 foreach($r in $rows){
  if(-not $r.id -or -not $r.reviewer -or -not $r.reviewed_at -or $r.phase -notin @('primary','secondary','adjudication')){throw 'Measured review identity, date and phase are required'}
  $at=(ConvertTo-EvidenceInstant $r.reviewed_at).ToString('o')
  if($null -ne $r.elapsed_seconds -and ($r.elapsed_seconds -isnot [valuetype] -or $r.elapsed_seconds -lt 0)){throw 'Elapsed seconds must be actually measured, nonnegative or null'}
  if($null -ne $r.error_confirmed -and ($r.phase -ne 'adjudication' -or $r.error_confirmed -isnot [bool])){throw 'Error findings require explicit adjudication'}
  $e=Get-EvidencePath $Root $r.evidence_file
  if(-not(Test-Path -LiteralPath $e -PathType Leaf)){throw 'Review evidence missing'}
  $record=[ordered]@{id=$r.id;reviewer=$r.reviewer;reviewed_at=$at;phase=$r.phase;elapsed_seconds=$r.elapsed_seconds;error_confirmed=$r.error_confirmed;evidence_file=$r.evidence_file;evidence_sha256=(Get-FileHash $e).Hash;source=$From}
  $key=Get-EvidenceHash ($r.id+'|'+$r.reviewer+'|'+$at+'|'+$r.phase);$record.record_id=$key
  if(-not $seen.ContainsKey($key)){$prepared+=$record;$seen[$key]=$true}
 }
 foreach($r in $prepared){$r|ConvertTo-Json -Compress|Add-Content $out -Encoding UTF8}
 Write-Host "实测审阅记录写入 $($prepared.Count) 条；无实测时间的记录不估算成本。"
}finally{$guard.Dispose()}
exit 0
