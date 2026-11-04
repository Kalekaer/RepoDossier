# Serial Search queue, automatic bounded wait, immutable raw imports, restart-safe.
# Exit 0=coverage complete; 2=incomplete/paused; 1=configuration/transport error.
param([string]$Date='', [int]$Round=0, [ValidateRange(0,3600)][int]$MaxWaitSeconds=900,
  [string]$Proxy='', [switch]$NoProxy, [switch]$RequireAuth, [switch]$DryRun,
  [string[]]$QueryIds=@(), [ValidateRange(1,40)][int]$MaxRequests=40)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'github-transport.ps1')
. (Join-Path $PSScriptRoot 'search-scheduler.ps1')
$searchPolicy=@{max_requests_per_invocation=40;cohort_ttl_days=7}
$searchPolicyPath=Join-Path $root 'data/search-policy.json'
if(Test-Path $searchPolicyPath){$searchPolicy=Get-Content $searchPolicyPath -Raw|ConvertFrom-Json}
$searchPolicy.max_requests_per_invocation=[math]::Min([int]$searchPolicy.max_requests_per_invocation,$MaxRequests)
$requestCount=0
if(-not $Date) { $Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd') }
$null=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
$base=Join-Path $root "data/raw/$Date"
$lock=$null
try {
  New-Item -ItemType Directory -Force -Path $base | Out-Null
  # One queue for the whole workspace, not merely one date or round.
  $lock=[IO.File]::Open((Join-Path $root 'data/raw/.collector.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  if(-not $Round) {
    $last=Get-ChildItem $base -Directory | Where-Object { $_.Name -match '^r\d+$' -and (Test-Path (Join-Path $_.FullName 'plan.json')) } | Sort-Object { [int]$_.Name.Substring(1) } | Select-Object -Last 1
    $Round=if($last) { [int]$last.Name.Substring(1) } else { 1 }
  }
  if($Round -lt 1) { throw 'Round must be positive.' }
  $dir=Join-Path $base "r$Round"; $planPath=Join-Path $dir 'plan.json'
  if(-not (Test-Path $planPath)) {
    & (Join-Path $PSScriptRoot 'fetch-daily.ps1') -Date $Date -Round $Round -PlanOnly | Out-Host
    if($LASTEXITCODE) { throw 'Could not create plan.' }
  }
  $plan=Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $done=Get-GitHubSuccessfulImports $dir
  $token=$env:GITHUB_TOKEN
  if(-not $token) { $token=$env:DSH_GITHUB_TOKEN }
  if(-not $token) { $token=$env:GH_TOKEN }
  if(-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $credential=& gh auth token --hostname github.com 2>$null
    if($LASTEXITCODE -eq 0) { $token=([string]$credential).Trim() }
  }
  if($RequireAuth -and -not $token) { throw 'Authentication required. Configure GITHUB_TOKEN or sign in using gh auth login.' }
  Write-Host ("采集 {0} r{1} · {2} · 已校验成功 {3}" -f $Date,$Round,$(if($token){'已认证'}else{'匿名，建议配置 GITHUB_TOKEN'}),$done.Count)
  $Proxy=Get-GitHubProxy -Proxy $Proxy -NoProxy:$NoProxy
  $statePath=Join-Path $root 'data/raw/.collector-state.json'
  $next=[datetimeoffset]::UtcNow; $waited=0
  if(Test-Path $statePath) { $s=Get-Content $statePath -Raw | ConvertFrom-Json; $next=[datetimeoffset]::Parse($s.next_allowed) }
  function Save-QueueDelay([int]$Seconds,[string]$Reason) {
    $script:next=[datetimeoffset]::UtcNow.AddSeconds($Seconds)
    $state=@{next_allowed=$script:next.ToString('o');date=$Date;round=$Round;reason=$Reason}
    $tmp=$statePath+'.tmp'
    [IO.File]::WriteAllText($tmp,($state|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $statePath -Force
  }
  $queue=@($plan.items | Where-Object { $_.kind -ne 'conditional' })+@($plan.items | Where-Object { $_.kind -eq 'conditional' })
  foreach($id in $QueryIds){if($id -notin @($plan.items.id)){throw 'Requested query is absent from the existing plan'}}
  if($QueryIds.Count){$queue=@($queue|Where-Object{$_.id -in $QueryIds})}
  function Save-SearchProgress {
    if(-not $script:schedule){return}
    $json=$script:schedule|ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText(($script:scheduleFile+'.tmp'),$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath ($script:scheduleFile+'.tmp') -Destination $script:scheduleFile -Force
    [IO.File]::WriteAllText((Join-Path $dir ("search-progress-$($script:schedule.id).json")),$json,[Text.UTF8Encoding]::new($false))
  }
  foreach($it in $queue) {
    if(-not $it.acquisition -and $done.ContainsKey([string]$it.id)) { continue }
    if($it.kind -eq 'probe') { Write-Host "实验位 $($it.id)：交由既有实验工具，非 Search 队列"; continue }
    if($DryRun) { Write-Host ("待核对 {0}{1}" -f $it.id,$(if($it.kind -eq 'conditional'){'（条件查询，等 Q3 登记后评估）'}else{''})); continue }
    if($it.kind -eq 'conditional') {
      if($it.id -ne 'Q3s' -or -not $done.ContainsKey('Q3')) { throw 'Conditional query dependency is not available.' }
      $q3=$done['Q3']
      $decision=Get-Q3FallbackDecision $q3 $it.conditional
      if(-not $decision.assessed){throw 'Q3s condition cannot be assessed from verified Q3 evidence'}
      $decision|Add-Member -NotePropertyName q3_raw_sha256 -NotePropertyValue $q3.sha256
      $decision|ConvertTo-Json|Set-Content (Join-Path $dir 'Q3s.condition.json') -Encoding UTF8
      if(-not $decision.required) { Write-Host ('Q3s 条件未触发：'+$decision.reason); continue }
    }
    $schedule=$null;$task='';$queryCalls=0;$queryBudget=1
    if($it.acquisition){
      $stateDir=Join-Path $root 'data/search-state';New-Item -ItemType Directory -Force $stateDir|Out-Null
      $scheduleFile=Join-Path $stateDir ($it.id+'.json')
      if(Test-Path $scheduleFile){$schedule=Get-Content $scheduleFile -Raw|ConvertFrom-Json}
      if(-not $schedule -or $Date -ge $schedule.expires -or ($schedule.cohort -ne $Date -and -not @($schedule.pending).Count)){
        if($schedule -and @($schedule.pending).Count){
          $expiryDir=Join-Path $root 'data/audit/search-expiry';New-Item -ItemType Directory -Force $expiryDir|Out-Null
          $expiryPath=Join-Path $expiryDir ($schedule.id+'-'+$schedule.cohort+'.json')
          if(-not(Test-Path $expiryPath)){[IO.File]::WriteAllText($expiryPath,($schedule|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
          Write-Host "$($schedule.id)：旧参数期有未完成分区，已归档为未覆盖证据，未标成完成。"
        }
        $schedule=New-SearchSchedule -Item $it -Date $Date -TtlDays ([int]$searchPolicy.cohort_ttl_days)
      }
      $queryBudget=[int]$it.acquisition.max_requests
      Save-SearchProgress
    }
    while($queryCalls -lt $queryBudget){
    $requestUrl=$it.url
    if($schedule){
      if($schedule.blocked){Write-Host "$($it.id)：单单元超容量，需调整查询；未宣称完整覆盖。";exit 2}
      if(-not @($schedule.pending).Count){break}
      $node=$schedule.pending[0];$requestUrl=Get-SearchNodeUrl $schedule $node;$task=Get-SearchTaskKey $schedule $node
      $cached=Get-SearchTaskImport -RawRoot (Join-Path $root 'data/raw') -Task $task
      if($cached){Move-SearchSchedule $schedule $cached;Save-SearchProgress;continue}
    }
    $rateAttempt=0; $transientAttempt=0
    while($true) {
      if($requestCount -ge [int]$searchPolicy.max_requests_per_invocation){Write-Host '达到本轮请求预算，进度已保存。';exit 2}
      $delay=[int][math]::Ceiling([math]::Max(0,($script:next-[datetimeoffset]::UtcNow).TotalSeconds))
      if($waited+$delay -gt $MaxWaitSeconds) { Write-Host '达到等待预算；恢复点已保存，重跑本命令继续。'; exit 2 }
      if($delay) { Write-Host "等待 $delay 秒后继续 $($it.id)" }
      while($script:next -gt [datetimeoffset]::UtcNow) { Start-Sleep -Milliseconds 1000; $waited++ }
      $tmpDir=Join-Path $root ('data/_tmp/collector-'+[guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
      $bodyPath=Join-Path $tmpDir 'response.json'; $headerPath=Join-Path $tmpDir 'headers.txt'
      $r=Invoke-GitHubCurl -Root $root -Url $requestUrl -BodyPath $bodyPath -HeaderPath $headerPath -Token $token -Proxy $Proxy
      if($r.BudgetExhausted){Write-Host '达到工作区当日API总预算，断点已保留。';exit 2}
      $requestCount++
      $body=if(Test-Path $bodyPath){[IO.File]::ReadAllText($bodyPath)}else{''}
      $headers=if(Test-Path $headerPath){Get-GitHubResponseHeaders ([IO.File]::ReadAllText($headerPath))}else{@{}}
      $policy=Get-GitHubRetryPolicy -Status $r.Status -Headers $headers -Body $body -RateAttempt $rateAttempt
      $assessment=Get-GitHubSearchPageAssessment -Body $body -Url $requestUrl
      $bodyDigest=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($body))).Replace('-','')
      $receipt=@{id=$it.id;at=[datetimeoffset]::UtcNow.ToString('o');http_status=$r.Status;curl_exit=$r.ExitCode;authenticated=[bool]$token;resource=$headers['x-ratelimit-resource'];remaining=$headers['x-ratelimit-remaining'];reset=$headers['x-ratelimit-reset'];retry_after=$headers['retry-after'];delay=$policy.Delay;validation=$assessment.Reason;actual_items=$assessment.Actual;expected_items=$assessment.Expected;body_sha256=$bodyDigest;body_bytes=[Text.Encoding]::UTF8.GetByteCount($body);query_task=$task}
      [IO.File]::AppendAllText((Join-Path $dir 'requests.jsonl'),(($receipt | ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
      # Do not persist arbitrary error bodies (may contain an egress IP or secret).
      if($r.ExitCode -eq 0 -and $r.Status -eq 200 -and $assessment.Accepted -and ($schedule -or $assessment.Complete)) {
        & (Join-Path $PSScriptRoot 'fetch-daily.ps1') -Date $Date -Round $Round -Import $it.id -File $bodyPath -RequestUrl $requestUrl -QueryTask $task | Out-Host
        if($LASTEXITCODE) { throw 'Import failed.' }
        if($schedule){Move-SearchSchedule $schedule (ConvertFrom-Json $body);Save-SearchProgress}
        if($assessment.NeedsRefinement){Write-Host "$($it.id)：有效公开响应的页条数与总数不一致，数据已保留，分区继续细分，不宣称该页完整。"}
        $done=Get-GitHubSuccessfulImports $dir
        Save-QueueDelay -Seconds ([math]::Max($(if($token){3}else{7}),$policy.Delay)) -Reason 'pace'
        Remove-Item -LiteralPath $bodyPath -Force
        break
      }
      [IO.File]::WriteAllText($bodyPath,('{"collector_error":true,"http_status":'+$r.Status+',"curl_exit":'+$r.ExitCode+'}'))
      & (Join-Path $PSScriptRoot 'fetch-daily.ps1') -Date $Date -Round $Round -Import $it.id -File $bodyPath -RequestUrl $requestUrl -QueryTask $task | Out-Host
      if($policy.Limited) {
        Save-QueueDelay -Seconds $policy.Delay -Reason 'rate-limit'
        $rateAttempt++
        if($rateAttempt -gt 3) { Write-Host '多次限流，已保存恢复时间。'; exit 2 }
        continue
      }
      if($policy.Fatal) { throw "GitHub HTTP $($r.Status): check authentication or query; no automatic retry." }
      if($transientAttempt -ge 1) { Write-Host "$($it.id) 响应不完整或传输失败，保留断点，停止发布。"; exit 2 }
      $transientAttempt++; Save-QueueDelay -Seconds 10 -Reason 'transient'
    }
    $queryCalls++
    }
    if($schedule -and @($schedule.pending).Count){Write-Host "$($it.id)：预算采样，剩余 $(@($schedule.pending).Count) 个分区/页，固定查询参数保留至 $($schedule.expires)。"}
  }
  if($DryRun) { exit 0 }
  & (Join-Path $PSScriptRoot 'check-queries.ps1') -Date $Date | Out-Host
  $coverageCode=$LASTEXITCODE
  if($coverageCode -eq 0 -and (Test-Path (Join-Path $PSScriptRoot 'discovery-refresh.ps1'))){
    & (Join-Path $PSScriptRoot 'discovery-refresh.ps1') -Date $Date -Root $root | Out-Host
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
  }
  exit $coverageCode
} catch {
  Write-Host ("采集未完成："+$_.Exception.Message) -ForegroundColor Red
  exit 1
} finally { $token=$null; if($lock){$lock.Dispose()} }
