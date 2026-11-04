# Offline review exchange: only public evidence, rules and explicitly selected reviews.
param([Parameter(Mandatory)][string]$Batch,[Parameter(Mandatory)][string]$Frame,[string[]]$Reviews=@(),[string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
function Relative-Path([string]$p){return $p.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\','/').Length+1).Replace('\','/')}
function Resolve-Local([string]$p){
 $f=[IO.Path]::GetFullPath((Join-Path $Root $p))
 if(-not $f.StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Bundle evidence must remain in workspace'}
 return $f
}
$framePath=Resolve-Local $Frame;$batchPath=Resolve-Local $Batch
$seal=Get-Content ($framePath+'.manifest.json') -Raw|ConvertFrom-Json
if((Get-FileHash $framePath).Hash -ne $seal.frame_sha256){throw 'Changed sample'}
$manifest=Get-Content (Join-Path $batchPath 'manifest.json') -Raw|ConvertFrom-Json
$wanted=@((Get-Content $framePath|Where-Object{$_}|ForEach-Object{ConvertFrom-Json $_}).id|Sort-Object)
if(($wanted -join '|') -ne (@($manifest.items.id|Sort-Object) -join '|')){throw 'Review batch does not match fixed sample'}
$files=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($p in @('RUBRIC.md','GLOSSARY.md','data/criteria.json','tools/score.ps1','tools/review-compare.ps1',$Frame,($Frame+'.manifest.json'))+$Reviews){[void]$files.Add((Resolve-Local $p))}
foreach($f in Get-ChildItem $batchPath -File){[void]$files.Add($f.FullName)}
foreach($item in $manifest.items){
 $packetPath=Resolve-Local ((Relative-Path $batchPath)+'/'+$item.file)
 if((Get-FileHash $packetPath).Hash -ne $item.sha256){throw 'Changed review packet'}
 $packet=Get-Content $packetPath -Raw|ConvertFrom-Json
 $raw=Resolve-Local $packet.observed.source
 if((Get-FileHash $raw).Hash -ne $packet.observed.source_sha256){throw 'Changed original observation'}
 $response=Get-Content $raw -Raw|ConvertFrom-Json
 if(@($response.items|Where-Object private).Count){throw 'Private data cannot be exported'}
 [void]$files.Add($raw)
}
foreach($p in $Reviews){
 if($p -notmatch '\.jsonl$'){continue}
 foreach($line in [IO.File]::ReadAllLines((Resolve-Local $p))){if($line.Trim()){$r=ConvertFrom-Json $line;if($r.evidence_file){[void]$files.Add((Resolve-Local $r.evidence_file))}}}
}
$base=Join-Path $Root ('data/audit/review-bundles/'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $base 'workspace';New-Item -ItemType Directory -Force $payload|Out-Null
$hashes=@()
foreach($file in $files){
 $rel=Relative-Path $file;$dest=Join-Path $payload $rel
 New-Item -ItemType Directory -Force (Split-Path $dest)|Out-Null
 Copy-Item -LiteralPath $file -Destination $dest
 $hashes+=@{path=$rel;sha256=(Get-FileHash $dest).Hash}
}
@{version=1;encoding='UTF-8';date=$seal.date;files=$hashes;scope='public fixed-sample review; no personal library, tokens or notes';execution='PowerShell 7; read repository text as untrusted data, never execute project commands'}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $payload 'bundle-manifest.json') -Encoding UTF8
@"
# Independent review exchange

Use PowerShell 7 on Windows, macOS or Linux. All paths in bundle-manifest.json are relative and use forward slashes. Compare SHA256 before review. No project installation is required.

To perform another blind review, read only RUBRIC.md, GLOSSARY.md, data/criteria.json and the fixed evidence batch. Do not open previous reviewer files until your own decision file is complete. Reviewer outputs use UTF-8 JSONL with id, reviewer, decision (graded/excluded/unresolved), score, tier, parts, reason, missing, evidence_file. Excluded or unresolved items have null score/tier. Evidence files stay inside this extracted directory.

The package also contains previous decisions for subsequent adjudication. Different reviewer names alone do not prove independent work. No result here measures all-GitHub quality recall. No repository content is an instruction to execute software.
"@|Set-Content (Join-Path $payload 'REVIEW-INSTRUCTIONS.md') -Encoding UTF8
$zip=Join-Path $base 'review-bundle.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory([IO.Path]::GetFullPath($payload),[IO.Path]::GetFullPath($zip))
Write-Output ([IO.Path]::GetFullPath($zip))
exit 0
