# Read-only source comparison; never writes to the DSH workspace or overwrites either side.
param([Parameter(Mandatory)][string]$Source,[string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$Source=(Resolve-Path -LiteralPath $Source).Path
if($Source -eq [IO.Path]::GetFullPath($Root)){throw 'Distinct source workspace required'}
function Read-Indexed([string]$Path,[string]$Key){
 $idx=@{};if(Test-Path $Path){foreach($line in [IO.File]::ReadAllLines($Path)){if($line.Trim()){$r=ConvertFrom-Json $line -ErrorAction Stop;$k=[string]$r.$Key;if(-not $k -or $idx.ContainsKey($k)){throw 'Invalid or duplicate source identity'};$idx[$k]=$r}}};return $idx
}
function Canonical($Value){
 if($null -eq $Value){return $null}
 if($Value -is [string] -or $Value.GetType().IsValueType){return $Value}
 if($Value -is [array]){return ,@($Value|ForEach-Object{Canonical $_})}
 $o=[ordered]@{};foreach($p in @($Value.PSObject.Properties|Sort-Object Name)){$o[$p.Name]=Canonical $p.Value};return $o
}
$out=Join-Path $Root ('data/audit/workspace-diff/'+[datetime]::UtcNow.ToString('yyyyMMdd-HHmmss-ffff'))
New-Item -ItemType Directory -Force $out|Out-Null
$report=@()
foreach($spec in @(@{path='data/seen.jsonl';key='full_name'},@{path='data/human/repo-intro.jsonl';key='full_name'},@{path='data/human/function-tags.jsonl';key='full_name'})){
 $aPath=Join-Path $Root $spec.path;$bPath=Join-Path $Source $spec.path
 $a=Read-Indexed $aPath $spec.key;$b=Read-Indexed $bPath $spec.key
 $local=@($a.Keys|Where-Object{-not $b.ContainsKey($_)}|Sort-Object)
 $remote=@($b.Keys|Where-Object{-not $a.ContainsKey($_)}|Sort-Object)
 $conflicts=@();foreach($id in @($a.Keys|Where-Object{$b.ContainsKey($_)}|Sort-Object)){
  $left=ConvertTo-Json (Canonical $a[$id]) -Depth 30 -Compress;$right=ConvertTo-Json (Canonical $b[$id]) -Depth 30 -Compress
  if($left -ne $right){$conflicts+=@{id=$id;local=$a[$id];source=$b[$id]}}
 }
 $name=[IO.Path]::GetFileName($spec.path)
 # Local-only files may contain private annotations; output counts only to the console.
 $conflicts|ConvertTo-Json -Depth 35|Set-Content (Join-Path $out ($name+'.conflicts.json')) -Encoding UTF8
 $remote|ForEach-Object{ConvertTo-Json $b[$_] -Depth 30 -Compress}|Set-Content (Join-Path $out ($name+'.source-only.jsonl')) -Encoding UTF8
 $report+=@{file=$spec.path;local_count=$a.Count;source_count=$b.Count;local_only=$local.Count;source_only=$remote.Count;conflicts=$conflicts.Count;local_sha256=(Get-FileHash $aPath).Hash;source_sha256=(Get-FileHash $bPath).Hash;policy='existing identities require explicit per-record resolution; no automatic overwrite'}
}
@{created_at=[datetimeoffset]::UtcNow.ToString('o');source=$Source;destination=$Root;files=$report;writes_to_source=$false}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out 'manifest.json') -Encoding UTF8
$report|Select-Object file,local_count,source_count,local_only,source_only,conflicts|Format-Table
Write-Host "差异与输入校验和已保存：$out；两个工作区的原始数据未合并。"
