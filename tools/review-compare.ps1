# Portable exchange contract: independent files, fixed sample, no invented consensus.
param([Parameter(Mandatory)][string]$Frame,[Parameter(Mandatory)][string]$ReviewA,
 [Parameter(Mandatory)][string]$ReviewB,[string]$Root=(Split-Path -Parent $PSScriptRoot),[string]$Out='data/audit/reviews/comparison-20261029.json')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'score.ps1')
function Local-File([string]$rel){
 $path=[IO.Path]::GetFullPath((Join-Path $Root $rel))
 if(-not $path.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Evidence must remain in review workspace'}
 return $path
}
function Read-Rows([string]$path){$rows=@();foreach($line in [IO.File]::ReadAllLines($path)){if($line.Trim()){$rows+=ConvertFrom-Json $line -ErrorAction Stop}};return $rows}
$fp=Local-File $Frame;$seal=Get-Content ($fp+'.manifest.json') -Raw|ConvertFrom-Json
if((Get-FileHash $fp).Hash -ne $seal.frame_sha256){throw 'Sampling frame changed'}
$sample=@(Read-Rows $fp);$ids=@($sample|ForEach-Object id)
if(-not $ids.Count -or @($ids|Sort-Object -Unique).Count -ne $ids.Count){throw 'Invalid sample identities'}
$reviewers=@();$indexes=@();$hashes=@{}
foreach($file in @($ReviewA,$ReviewB)){
 $path=Local-File $file;$rows=@(Read-Rows $path);$idx=@{}
 if($rows.Count -ne $ids.Count){throw 'Incomplete review sample'}
 $names=@($rows|ForEach-Object{([string]$_.reviewer).Trim().ToLowerInvariant()}|Sort-Object -Unique)
 if($names.Count -ne 1 -or -not $names[0]){throw 'A stable reviewer identity is required'}
 $reviewers+=$names[0]
 foreach($r in $rows){
  if($r.id -notin $ids -or $idx.ContainsKey([string]$r.id)){throw 'Unexpected or duplicate review identity'}
  if($r.decision -notin @('graded','excluded','unresolved') -or -not ([string]$r.reason).Trim()){throw 'Invalid review decision'}
  if($r.decision -eq 'graded'){
   if($null -eq $r.score -or $r.score -lt 0 -or $r.score -gt 100 -or (Get-Tier $r.score) -ne $r.tier){throw 'Invalid review score/tier'}
   $sum=0;foreach($d in (Get-Content (Join-Path $Root 'data/criteria.json') -Raw|ConvertFrom-Json).打分维度){$v=$r.parts.($d.名称);if($null -eq $v -or $v -lt 0 -or $v -gt $d.权重){throw 'Invalid score dimensions'};$sum+=$v}
   if($sum -ne $r.score){throw 'Score dimensions do not sum to the declared score'}
  }elseif($null -ne $r.score -or $null -ne $r.tier){throw 'Exclusion or missing evidence is not a quality tier'}
  $ep=Local-File $r.evidence_file
  if(-not(Test-Path -LiteralPath $ep -PathType Leaf)){throw 'Reviewer evidence missing'}
  $hashes[$r.evidence_file]=(Get-FileHash -LiteralPath $ep).Hash;$idx[$r.id]=$r
 }
 $indexes+=,$idx;$hashes[$file]=(Get-FileHash $path).Hash
}
if($reviewers[0] -eq $reviewers[1]){throw 'Two distinct reviewers are required'}
$comparison=@();foreach($id in $ids){
 $a=$indexes[0][$id];$b=$indexes[1][$id]
 $same=$a.decision -eq $b.decision -and ($a.decision -ne 'graded' -or $a.tier -eq $b.tier)
 $comparison+=@{id=$id;decision_a=$a.decision;decision_b=$b.decision;score_a=$a.score;score_b=$b.score;tier_a=$a.tier;tier_b=$b.tier;needs_adjudication=(-not $same);unresolved=($a.decision -eq 'unresolved' -or $b.decision -eq 'unresolved')}
}
$output=Local-File $Out;New-Item -ItemType Directory -Force (Split-Path $output)|Out-Null
@{version=1;sample_sha256=$seal.frame_sha256;reviewers=$reviewers;sample_count=$ids.Count;review_files_complete=$true;disagreements=@($comparison|Where-Object needs_adjudication).Count;pending_evidence=@($comparison|Where-Object unresolved).Count;quality_recall=$null;identity_note='Reviewer labels identify separate review files; this does not authenticate identity or prove model independence';evidence_sha256=$hashes;items=$comparison}|ConvertTo-Json -Depth 10|Set-Content $output -Encoding UTF8
Write-Host "双评文件完整：$($ids.Count) 项；需裁定 $(@($comparison|Where-Object needs_adjudication).Count) 项；不代表GitHub总体召回。"
exit 0
