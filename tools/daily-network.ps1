# Stable, bounded entry for the daily workflow's existing network scripts.
# This is an invocation convenience, NOT a sandbox or permission grant.
param(
 [ValidateSet('Plan','Collect','Maintain','Readmes','Evidence')][string]$Action='Plan',
 [string]$Date='',
 [ValidateRange(0,999)][int]$Round=0,
 [string]$Batch='',
 [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
try {
 if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
 $parsed=[datetime]::MinValue
 if(-not [datetime]::TryParseExact($Date,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)){throw 'Date must be a real date in YYYY-MM-DD format'}
 if($Round -and $Action -ne 'Collect'){throw 'Round is only valid for Collect'}
 if($Batch -and $Action -ne 'Readmes'){throw 'Batch is only valid for Readmes'}
 $parameters=@{}
 $scriptName=switch($Action){
  'Plan' {''}
  'Collect' {$parameters=@{Date=$Date};if($Round){$parameters.Round=$Round};'collect-daily.ps1'}
  'Maintain' {$parameters=@{Date=$Date};'daily-maintenance.ps1'}
  'Evidence' {$parameters=@{Action='run';MaxRequests=20;MaxWaitSeconds=60};'evidence-queue.ps1'}
  'Readmes' {
   if(-not $Batch){throw 'Readmes requires -Batch; no interactive prompt is used'}
   $batchPath=if([IO.Path]::IsPathRooted($Batch)){[IO.Path]::GetFullPath($Batch)}else{[IO.Path]::GetFullPath((Join-Path $root $Batch))}
   $reviewRoot=[IO.Path]::GetFullPath((Join-Path $root 'data/audit/reviews'))+[IO.Path]::DirectorySeparatorChar
   if(-not $batchPath.StartsWith($reviewRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Batch must be inside this workspace data/audit/reviews'}
   if(-not (Test-Path -LiteralPath (Join-Path $batchPath 'manifest.json') -PathType Leaf)){throw 'Batch manifest does not exist'}
   $part=Get-Item -LiteralPath $batchPath -Force
   while($part -and $part.FullName.Length -ge $root.Length){
    if($part.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Batch must not traverse a junction or symbolic link'}
    $part=$part.Parent
   }
   $parameters=@{Batch=$batchPath};'fetch-review-readmes.ps1'
  }
 }
 if($Action -eq 'Plan' -or $PlanOnly){
  [ordered]@{action=$Action;date=$Date;script=$scriptName;parameters=$parameters;network_executed=$false;permissions_changed=$false;available_actions=@('Collect','Maintain','Readmes','Evidence')}|ConvertTo-Json -Depth 4
  exit 0
 }
 Push-Location $root
 try {
  $global:LASTEXITCODE=0
  & (Join-Path $PSScriptRoot $scriptName) @parameters
  $result=$LASTEXITCODE
 } finally {Pop-Location}
 if($result -eq 2){Write-Host '本阶段未完成，已有断点保留；不得将它记为日报发布成功。'}
 exit $result
} catch {
 [Console]::Error.WriteLine(('daily-network: '+$_.Exception.Message))
 exit 1
}
