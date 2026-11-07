# Portable regression cases for the network and query contracts. No real HTTP.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$passed=0
function Assert-Release($condition,[string]$name){if(-not $condition){throw ('FAIL: '+$name)};$script:passed++}
function New-ReleaseFixture {
 $dir=Join-Path $root ('data/_tmp/release-reliability-'+[guid]::NewGuid().ToString('N'))
 foreach($p in @('tools','data/_tmp','data/picks','reports')){New-Item -ItemType Directory -Force (Join-Path $dir $p)|Out-Null}
 foreach($file in @('github-transport.ps1','query-contract.ps1','query-partitions.ps1','search-scheduler.ps1','fetch-daily.ps1','check-queries.ps1','collect-daily.ps1','weekly-utils.ps1','build-samples.ps1')){Copy-Item (Join-Path $root ('tools/'+$file)) (Join-Path $dir ('tools/'+$file))}
 Copy-Item (Join-Path $root 'data/queries.json') (Join-Path $dir 'data/queries.json')
 '{"sources":{"daily_api_ceiling":45,"authenticated_daily_api_ceiling":180}}'|Set-Content (Join-Path $dir 'config.json')
 & (Join-Path $dir 'tools/fetch-daily.ps1') -Date 2026-11-07 -Round 1 -PlanOnly *> $null
 if($LASTEXITCODE){throw 'Canonical plan setup failed'}
 return $dir
}
function Get-ReleaseCoverage($dir){return (& (Join-Path $dir 'tools/check-queries.ps1') -Date 2026-11-07 -Root $dir -Json|ConvertFrom-Json)}
function Next-ReleaseRequest($dir){
 '{"next_allowed":"2000-01-01T00:00:00Z"}'|Set-Content (Join-Path $dir 'data/raw/.collector-state.json')
 & (Join-Path $dir 'tools/collect-daily.ps1') -Date 2026-11-07 -NextRequest -MaxWaitSeconds 0 *> $null
 return Get-Content (Join-Path $dir 'data/raw/2026-11-07/r1/next-request.json') -Raw|ConvertFrom-Json
}
function Import-ReleaseResponse($dir,$job,[string]$body='{"total_count":0,"incomplete_results":false,"items":[]}'){
 $file=Join-Path $dir $job.response_file;[IO.File]::WriteAllText($file,$body)
 & (Join-Path $dir 'tools/fetch-daily.ps1') -Date 2026-11-07 -Round 1 -Import $job.query -File $file -RequestUrl $job.url -QueryTask $job.query_task *> $null
 if($LASTEXITCODE){throw 'Valid fixture response import failed'}
}
try {
 . (Join-Path $root 'tools/evidence-store.ps1')
 . (Join-Path $root 'tools/query-contract.ps1')
 $dir=New-ReleaseFixture;$planPath=Join-Path $dir 'data/raw/2026-11-07/r1/plan.json';$plan=Get-Content $planPath -Raw|ConvertFrom-Json
 Assert-Release (@($plan.items|Where-Object{$_.kind -eq 'search' -and -not $_.required}).Count -eq 0) 'scheduled Search queries are mandatory'
 Assert-Release ('Q4' -notin @($plan.items.id) -and 'Q2d' -notin @($plan.items.id)) 'manual and disabled channels are not invented'
 $altered=$plan|ConvertTo-Json -Depth 15|ConvertFrom-Json;$altered.items=@($altered.items|Where-Object id -ne Q9)
 Assert-Release (@(Get-QueryPlanIssues $dir 2026-11-07 $altered 1).Count -gt 0) 'deleted query rejected'
 $altered=$plan|ConvertTo-Json -Depth 15|ConvertFrom-Json;$altered.items[0].required=$false
 Assert-Release (@(Get-QueryPlanIssues $dir 2026-11-07 $altered 1).Count -gt 0) 'weakened query rejected'
 $altered=$plan|ConvertTo-Json -Depth 15|ConvertFrom-Json;$altered.items[0].per_page=10
 Assert-Release (@(Get-QueryPlanIssues $dir 2026-11-07 $altered 1).Count -gt 0) 'reduced page size rejected'
 $altered=$plan|ConvertTo-Json -Depth 15|ConvertFrom-Json;$altered.items+=@($altered.items[0])
 Assert-Release (@(Get-QueryPlanIssues $dir 2026-11-07 $altered 1).Count -gt 0) 'duplicate query rejected'
 $body='{"total_count":1,"incomplete_results":false,"items":[{"full_name":"f/tool","private":false}]}'
 $rejected=$false;try{Assert-QueryImport $dir 2026-11-07 1 Q2 $plan.items[0].url '' $body}catch{$rejected=$true}
 Assert-Release $rejected 'ambiguous Q2 identity rejected'
 $rejected=$false;try{Assert-QueryImport $dir 2026-11-07 1 Q1 $plan.items[0].url.Replace('per_page=100','per_page=10') '' $body}catch{$rejected=$true}
 Assert-Release $rejected 'changed request URL rejected'
 $cov=Get-ReleaseCoverage $dir
 Assert-Release ($cov.status -eq 'fail' -and ($cov.queries|Where-Object id -eq Q3s).status -eq 'blocked') 'unknown Q3 cannot skip Q3s'
 $job=Next-ReleaseRequest $dir;$again=Next-ReleaseRequest $dir
 Assert-Release ($job.kind -eq 'request' -and $job.query -eq 'Q1' -and $job.reservation -eq $again.reservation) 'host task reservation is idempotent'
 $body=@{total_count=250;incomplete_results=$false;items=@(1..100|ForEach-Object{@{full_name="f/tool$_";private=$false;stargazers_count=200}})}|ConvertTo-Json -Depth 6
 Import-ReleaseResponse $dir $job $body
 Assert-Release ((Next-ReleaseRequest $dir).query -eq 'Q1b') 'missing directions precede extra pages'
 $fresh=New-ReleaseFixture;$done=@()
 foreach($iteration in 1..20){
  $job=Next-ReleaseRequest $fresh
  if($job.kind -eq 'complete'){break}
  if($job.kind -ne 'request'){throw 'Unexpected file-mode stop'}
  $done+=$job.query;Import-ReleaseResponse $fresh $job
 }
 $cov=Get-ReleaseCoverage $fresh
 Assert-Release ($job.kind -eq 'complete' -and $cov.status -eq 'pass' -and $cov.successful -eq $cov.planned -and 'Q3s' -in $done -and 'Q8' -in $done) 'all scheduled queries complete with actual evidence'
 $partial=New-ReleaseFixture;$job=Next-ReleaseRequest $partial
 $body='{"total_count":200,"incomplete_results":false,"items":[{"full_name":"f/partial","private":false}]}'
 Import-ReleaseResponse $partial $job $body;$cov=Get-ReleaseCoverage $partial
 Assert-Release ($cov.status -eq 'fail' -and ($cov.queries|Where-Object id -eq Q1).status -eq 'partial') 'partial raw is retained without full coverage'
 '{"id":"f/tool"}'|Set-Content (Join-Path $partial 'data/projects.jsonl')
 ''|Set-Content (Join-Path $partial 'data/picks/2026-11-07.jsonl')
 'partial report'|Set-Content (Join-Path $partial 'reports/2026-11-07.md')
 '{"status":"pass"}'|Set-Content (Join-Path $partial 'data/raw/2026-11-07/coverage.json')
 & (Join-Path $partial 'tools/build-samples.ps1') -Date 2026-11-07 -Root $partial -Layout c *> $null
 Assert-Release ($LASTEXITCODE -ne 0 -and -not(Test-Path (Join-Path $partial 'data/site/daily-layout-c-finsara.generated.html'))) 'formal page refuses a forged green coverage file'
 $budget=New-ReleaseFixture
 '{"sources":{"daily_api_ceiling":1,"authenticated_daily_api_ceiling":3}}'|Set-Content (Join-Path $budget 'config.json')
 $null=Reserve-GitHubRequest $budget test
 Assert-Release ((Reserve-GitHubRequest $budget test -Peek).remaining -eq 0 -and (Reserve-GitHubRequest $budget test -Peek -Authenticated).remaining -eq 2) 'anonymous and authenticated budgets share the same ledger'
 $global:releaseNetworkCalls=0;$global:releaseCurlExit=7
 function global:curl.exe {
  $null=@($input);$global:releaseNetworkCalls++;$a=@($args)
  [IO.File]::WriteAllText($a[[array]::IndexOf($a,'--output')+1],'')
  [IO.File]::WriteAllText($a[[array]::IndexOf($a,'--dump-header')+1],'')
  $global:LASTEXITCODE=$global:releaseCurlExit;return '0'
 }
 $network=New-ReleaseFixture;$s=Open-EvidenceStore $network
 try{
  foreach($n in 1..10){$null=Add-EvidenceTask $s "f/tool$n" readme}
  $result=Invoke-EvidenceTasks $s -MaxRequests 10 -DelaySeconds 0
  Assert-Release ($global:releaseNetworkCalls -eq 1 -and $result.stop -eq 'network-unavailable' -and $result.pending -eq 10) 'connect failure stops the whole queue'
  Assert-Release ((Reserve-GitHubRequest $network test -Peek).used -eq 0) 'proven connect failure releases the reservation'
  Assert-Release (@($s.state.tasks.Values|Where-Object{$_.failures -gt 0 -or $_.state -eq 'blocked'}).Count -eq 0) 'network failure does not penalize projects'
  $paused=Invoke-GitHubPublicGet -Root $network -Url 'https://api.github.com/repos/f/tool' -BodyPath (Join-Path $network 'body') -HeaderPath (Join-Path $network 'headers')
  Assert-Release ($paused.Paused -and $global:releaseNetworkCalls -eq 1) 'network circuit survives later phase calls'
 }finally{$s.guard.Dispose()}
 $timeout=New-ReleaseFixture;$global:releaseCurlExit=28
 $null=Invoke-GitHubPublicGet -Root $timeout -Url 'https://api.github.com/repos/f/tool' -BodyPath (Join-Path $timeout 'body') -HeaderPath (Join-Path $timeout 'headers')
 Assert-Release ((Reserve-GitHubRequest $timeout test -Peek).used -eq 1) 'ambiguous timeout remains charged'
 $rejected=$false;try{Invoke-GitHubPublicGet -Root $timeout -Url 'https://api.github.com.evil.invalid/repos/f/tool' -Token fixture -BodyPath (Join-Path $timeout 'body') -HeaderPath (Join-Path $timeout 'headers')}catch{$rejected=$true}
 Assert-Release $rejected 'credentials cannot be sent to a lookalike endpoint'
 @{passed=$passed;failed=0}|ConvertTo-Json -Compress
 exit 0
}catch{Write-Host $_.Exception.Message;exit 1}finally{Remove-Item Function:/curl.exe -ErrorAction SilentlyContinue}
