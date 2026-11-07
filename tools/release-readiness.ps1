# One explicit release verdict. Engineering checks alone are never a publish verdict.
param([string]$Date='', [string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
$scope=Join-Path $Root "data/audit/editorial/$Date.json"
$policyPath=Join-Path $Root 'data/search-policy.json'
if(Test-Path $policyPath){
 $policy=Get-Content $policyPath -Raw|ConvertFrom-Json
 if($policy.publication_mode -eq 'declared-editorial-batch' -and -not(Test-Path $scope)){
  Write-Host '发布就绪：BLOCKED（缺少当期审阅范围，不能跳过发布门禁）'
  exit 1
 }
}
$results=@{}
$reviewGate=@{name='dispositions';script='candidate-ledger.ps1';args=@{Date=$Date;Root=$Root;Action='check';Publish=$true}}
$policyPath=Join-Path $Root 'data/search-policy.json'
if((Test-Path $policyPath) -and (Get-Content $policyPath -Raw|ConvertFrom-Json).publication_mode -eq 'declared-editorial-batch'){
 $reviewGate=@{name='dispositions';script='editorial-batch.ps1';args=@{Date=$Date;Root=$Root;Action='check'}}
}
foreach($gate in @(@{name='queries';script='check-queries.ps1';args=@{Date=$Date;Root=$Root}},$reviewGate)){
 $global:LASTEXITCODE=0;$gateArgs=$gate.args
 try{& (Join-Path $Root ('tools/'+$gate.script)) @gateArgs|Out-Host;$code=$LASTEXITCODE}catch{$code=1}
 $results[$gate.name]=@{code=$code;ok=($code -eq 0)}
}
$manifest=Join-Path $Root "data/runs/$Date.manifest.json"
$complete=$false
if(Test-Path $manifest){$m=Get-Content $manifest -Raw|ConvertFrom-Json;$required=@('report','snapshot','seen','index','csv','picks','build','validation','verification','candidates','queries');$complete=@($required|Where-Object{$m.steps.$_.status -ne 'ok'}).Count -eq 0}
$results.production_artifacts=@{ok=$complete}
$ready=$complete -and $results.queries.ok -and $results.dispositions.ok
$out=Join-Path $Root 'data/audit/releases';New-Item -ItemType Directory -Force $out|Out-Null
@{date=$Date;publish_ready=$ready;checks=$results;at=[datetimeoffset]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $out "$Date.json") -Encoding UTF8
Write-Host $(if($ready){'发布就绪：PASS'}else{'发布就绪：BLOCKED（不得以工程测试通过替代）'})
if(-not $ready){exit 1};exit 0
