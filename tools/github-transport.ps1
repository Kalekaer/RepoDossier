# Shared policy for the daily Search queue. No network or writes on dot-source.
function Get-Q3FallbackDecision($Q3,$Condition=$null){
 $minNew=3;$minTotal=10
 if($Condition){if($null -ne $Condition.newFacesLt){$minNew=[int]$Condition.newFacesLt};if($null -ne $Condition.totalCountLt){$minTotal=[int]$Condition.totalCountLt}}
 $total=if($null -ne $Q3.query_total_count){$Q3.query_total_count}else{$Q3.total_count}
 $assessed=$null -ne $Q3 -and [bool]$Q3.ok -and $null -ne $Q3.newFaces -and $null -ne $total
 [pscustomobject]@{assessed=$assessed;required=($assessed -and ($Q3.newFaces -lt $minNew -or $total -lt $minTotal));new_faces=$Q3.newFaces;total_count=$total;new_faces_lt=$minNew;total_count_lt=$minTotal;reason=$(if(-not $assessed){'Q3 dependency or condition evidence missing'}else{"Q3 newFaces=$($Q3.newFaces) total=$total; thresholds <$minNew or <$minTotal"})}
}
function Get-GitHubResponseHeaders([string]$Text) {
  $h=@{}
  # Proxies and redirects can produce several header blocks; only use the last.
  foreach($line in ($Text -split "`r?`n")) {
    if($line -match '^HTTP/\S+\s+\d+') { $h=@{} }
    elseif($line -match '^([^: ]+):\s*(.*)$') { $h[$Matches[1].ToLowerInvariant()]=$Matches[2].Trim() }
  }
  return $h
}
function Get-GitHubRetryPolicy([int]$Status, [hashtable]$Headers, [string]$Body='', [int]$RateAttempt=0, [datetimeoffset]$Now=[datetimeoffset]::UtcNow) {
  $seconds=0.0
  $limited=($Status -eq 429 -or ($Status -eq 403 -and ($Body -match 'rate limit|secondary rate|abuse' -or $Headers['x-ratelimit-remaining'] -eq '0' -or $Headers['retry-after'])))
  if($limited) { $seconds=60*[math]::Pow(2,[math]::Min(4,$RateAttempt)) }
  if($limited -and $Headers['retry-after']) {
    $n=0.0; $date=[datetimeoffset]::MinValue
    if([double]::TryParse($Headers['retry-after'],[ref]$n)) { $seconds=[math]::Max($seconds,$n) }
    elseif([datetimeoffset]::TryParse($Headers['retry-after'],[ref]$date)) { $seconds=[math]::Max($seconds,($date-$Now).TotalSeconds) }
  }
  if($Headers['x-ratelimit-remaining'] -eq '0' -and $Headers['x-ratelimit-reset']) {
    $epoch=0L
    if([long]::TryParse($Headers['x-ratelimit-reset'],[ref]$epoch)) {
      $seconds=[math]::Max($seconds,([datetimeoffset]::FromUnixTimeSeconds($epoch)-$Now).TotalSeconds+5)
    }
  }
  [pscustomobject]@{Limited=[bool]$limited; Delay=[int][math]::Ceiling([math]::Max(0,$seconds)); Fatal=($Status -in @(401,403,404,422) -and -not $limited)}
}
function Test-GitHubSearchResponse([string]$Body) {
  try {
    $o=ConvertFrom-Json -InputObject $Body -ErrorAction Stop
    return [bool]($o.PSObject.Properties['items'] -and $o.items -is [array] -and $o.PSObject.Properties['total_count'] -and $o.total_count -ge 0 -and $o.incomplete_results -eq $false -and @($o.items | Where-Object { $_.private -eq $true -or -not $_.full_name }).Count -eq 0)
  } catch { return $false }
}
function Get-GitHubSuccessfulImports([string]$RoundDir) {
  $done=@{}; $meta=Join-Path $RoundDir 'meta.json'
  if(Test-Path $meta) {
    foreach($m in @((Get-Content $meta -Raw -Encoding UTF8 | ConvertFrom-Json).imports)) {
      if(-not $m.ok) { continue }
      try {
        $p=[IO.Path]::GetFullPath((Join-Path $RoundDir $m.file))
        if(-not $p.StartsWith([IO.Path]::GetFullPath($RoundDir)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { continue }
        if($m.sha256 -and (Get-FileHash -LiteralPath $p).Hash -ne $m.sha256) { continue }
        $body=[IO.File]::ReadAllText($p)
        if((Test-GitHubSearchResponse $body) -and @((ConvertFrom-Json $body).items).Count -eq $m.items) { $done[[string]$m.id]=$m }
      } catch { continue }
    }
  }
  return $done
}
function Get-GitHubSearchPageAssessment([string]$Body,[string]$Url,$Response=$null){
 if(-not $Response){
  if(-not(Test-GitHubSearchResponse $Body)){return [pscustomobject]@{Accepted=$false;Complete=$false;NeedsRefinement=$false;Reason='invalid-json-schema-private-or-incomplete';Actual=$null;Expected=$null}}
  $Response=ConvertFrom-Json $Body
 }
 $r=$Response
 $page=1;$size=30
 if($Url -match '[?&]page=(\d+)'){$page=[int]$Matches[1]}
 if($Url -match '[?&]per_page=(\d+)'){$size=[int]$Matches[1]}
 $expected=[math]::Max(0,[math]::Min($size,[long]$r.total_count-($page-1)*$size))
 $actual=@($r.items).Count
 $valid=$actual -le $size
 $complete=$valid -and $actual -eq $expected
 return [pscustomobject]@{Accepted=$valid;Complete=$complete;NeedsRefinement=($valid -and -not $complete);Reason=$(if(-not $valid){'over-page-capacity'}elseif($complete){'expected-count'}else{'page-count-drift-refine'});Actual=$actual;Expected=$expected}
}
function Test-GitHubSearchPage([string]$Body,[string]$Url){
 return (Get-GitHubSearchPageAssessment -Body $Body -Url $Url).Complete
}
function Reserve-GitHubRequest([string]$Root,[string]$Kind,[switch]$Peek,[switch]$Authenticated){
 $day=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd');$dir=Join-Path $Root 'data/api-usage'
 New-Item -ItemType Directory -Force $dir|Out-Null
 $guard=[IO.File]::Open((Join-Path $dir ($day+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $path=Join-Path $dir ($day+'.jsonl');$limit=45
  $config=Join-Path $Root 'config.json';if(Test-Path $config){$sources=(Get-Content $config -Raw|ConvertFrom-Json).sources;$v=$sources.daily_api_ceiling;if($v){$limit=[int]$v};if($Authenticated -and $sources.authenticated_daily_api_ceiling){$limit=[int]$sources.authenticated_daily_api_ceiling}}
  if(-not(Test-Path $path)){
   $legacy=0;$receipts=@()
   foreach($f in @(Get-ChildItem (Join-Path $Root 'data/raw') -Recurse -File -Filter requests.jsonl -ErrorAction SilentlyContinue)){foreach($l in [IO.File]::ReadAllLines($f.FullName)){if($l.Trim()){$receipts+=ConvertFrom-Json $l}}}
   $state=Join-Path $Root 'data/evidence/state.json'
   if(Test-Path $state){$s=Get-Content $state -Raw|ConvertFrom-Json;foreach($t in $s.tasks.PSObject.Properties.Value){$receipts+=@($t.history)}}
   foreach($r in $receipts){
    if(-not $r.at){continue};$instant=if($r.at -is [datetime]){[datetimeoffset]::new($r.at.ToUniversalTime())}else{[datetimeoffset]::Parse([string]$r.at)}
    if($instant.ToUniversalTime().AddHours(8).ToString('yyyy-MM-dd') -eq $day){$legacy++}
   }
   @{type='baseline';requests=$legacy;date=$day}|ConvertTo-Json -Compress|Set-Content $path -Encoding UTF8
  }
  $used=0;foreach($l in [IO.File]::ReadAllLines($path)){if($l.Trim()){$r=ConvertFrom-Json $l;$used+=[int]$r.requests}}
  if($Peek){return @{limit=$limit;used=$used;remaining=[math]::Max(0,$limit-$used);authenticated=[bool]$Authenticated}}
  if($used -ge $limit){return $null}
  $id=$day+':'+[guid]::NewGuid().ToString('N')
  @{type='request';requests=1;id=$id;kind=$Kind;at=[datetimeoffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Add-Content $path -Encoding UTF8
  return $id
 }finally{$guard.Dispose()}
}
function Complete-GitHubRequest([string]$Root,[string]$Id,[int]$Status,[int]$ExitCode,[hashtable]$Headers=@{}){
 # Only DNS/connect failures before an origin response can release a reservation.
 # HTTP errors, 304, TLS/timeouts and crashed/unsettled requests remain charged.
 if($Id -notmatch '^(\d{4}-\d{2}-\d{2}):[a-f0-9]{32}$'){throw 'Invalid request receipt'}
 $day=$Matches[1];$dir=Join-Path $Root 'data/api-usage';$path=Join-Path $dir ($day+'.jsonl')
 $guard=[IO.File]::Open((Join-Path $dir ($day+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $rows=@([IO.File]::ReadAllLines($path)|Where-Object{$_}|ForEach-Object{ConvertFrom-Json $_})
  if(-not @($rows|Where-Object{$_.type -eq 'request' -and $_.id -eq $Id}).Count){throw 'Reservation not found'}
  if(@($rows|Where-Object{$_.type -eq 'settlement' -and $_.id -eq $Id}).Count){return}
  $release=$Status -eq 0 -and $ExitCode -in @(5,6,7) -and -not $Headers['x-github-request-id'] -and -not $Headers['x-ratelimit-resource']
  @{type='settlement';id=$Id;requests=$(if($release){-1}else{0});http_status=$Status;curl_exit=$ExitCode;reason=$(if($release){'not-connected'}else{'conservative-charge'});at=[datetimeoffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Add-Content $path -Encoding UTF8
 }finally{$guard.Dispose()}
}
function Get-GitHubTransportKey([string]$Value){
 $hash=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','')}finally{$hash.Dispose()}
}
function ConvertTo-GitHubInstant($Value){
 if($Value -is [datetimeoffset]){return $Value.ToUniversalTime()}
 if($Value -is [datetime]){return [datetimeoffset]::new($Value.ToUniversalTime())}
 return [datetimeoffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Get-GitHubTransportGate([string]$Root,[string]$Resource,[string]$Proxy='',[string]$Token=''){
 $file=Join-Path $Root 'data/api-usage/transport-state.json';$until=[datetimeoffset]::MinValue;$reason='';$now=[datetimeoffset]::UtcNow
 if(Test-Path $file){
  $state=Get-Content $file -Raw|ConvertFrom-Json -AsHashtable
  $identity=Get-GitHubTransportKey $(if($Token){'auth:'+ $Token}else{'anonymous:'+ $Proxy})
  foreach($key in @(('network:'+(Get-GitHubTransportKey $Proxy)),($identity+':global'),($identity+':'+$Resource))){
   $entry=$state[$key]
   if($entry){$at=ConvertTo-GitHubInstant $entry.next_allowed;if($at -gt $until){$until=$at;$reason=$entry.reason}}
  }
 }
 return @{paused=($until -gt $now);next_allowed=$until.ToString('o');reason=$reason}
}
function Set-GitHubTransportGate([string]$Root,[string]$Resource,[string]$Proxy,[string]$Token,[int]$Status,[int]$ExitCode,[hashtable]$Headers,[string]$Body,[int]$RateAttempt=0){
 $policy=Get-GitHubRetryPolicy $Status $Headers $Body $RateAttempt
 $network=$Status -eq 0 -and $ExitCode -ne 0
 $authFailure=$Status -in @(401,403) -and -not $policy.Limited
 if(-not $network -and -not $authFailure -and -not $policy.Limited -and $Headers['x-ratelimit-remaining'] -ne '0'){return}
 $identity=Get-GitHubTransportKey $(if($Token){'auth:'+ $Token}else{'anonymous:'+ $Proxy})
 $scope=if($network){'network:'+(Get-GitHubTransportKey $Proxy)}elseif($authFailure -or ($policy.Limited -and ($Headers['x-ratelimit-remaining'] -ne '0' -or $Body -match 'secondary rate|abuse'))){$identity+':global'}else{$identity+':'+$Resource}
 $dir=Join-Path $Root 'data/api-usage';New-Item -ItemType Directory -Force $dir|Out-Null
 $guard=[IO.File]::Open((Join-Path $dir 'transport-state.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $file=Join-Path $dir 'transport-state.json';$state=if(Test-Path $file){Get-Content $file -Raw|ConvertFrom-Json -AsHashtable}else{@{}}
  $seconds=if($network){60}else{[math]::Max(60,$policy.Delay)}
  $next=[datetimeoffset]::UtcNow.AddSeconds($seconds)
  if($state[$scope] -and (ConvertTo-GitHubInstant $state[$scope].next_allowed) -gt $next){$next=ConvertTo-GitHubInstant $state[$scope].next_allowed}
  $state[$scope]=@{next_allowed=$next.ToString('o');reason=$(if($network){'network-unavailable'}elseif($authFailure){'authentication-failed'}else{'rate-limit'});http_status=$Status;curl_exit=$ExitCode}
  $temp=$file+'.tmp';[IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false));[IO.File]::Move($temp,$file,$true)
 }finally{$guard.Dispose()}
}
function Get-GitHubProxy([string]$Proxy='', [switch]$NoProxy) {
  if($NoProxy){return ''}
  if(-not $Proxy){
    foreach($name in @('DSH_HTTP_PROXY','HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')){
      $value=[Environment]::GetEnvironmentVariable($name)
      if(-not [string]::IsNullOrWhiteSpace($value)){$Proxy=$value;break}
    }
  }
  if($Proxy -match '[\x00-\x1f\x7f]'){throw 'Proxy contains invalid control characters'}
  return $Proxy.Trim()
}
function Get-GitHubProxyConfig([string]$Proxy='') {
  if($Proxy -match '[\x00-\x1f\x7f]'){throw 'Proxy contains invalid control characters'}
  # stdin config preserves an empty proxy even with legacy native argv handling.
  # An empty value explicitly disables curl's inherited environment proxy.
  return 'proxy = "'+$Proxy.Replace('\','\\').Replace('"','\"')+'"'+"`n"
}
function Invoke-GitHubCurl([string]$Url,[string]$BodyPath,[string]$HeaderPath,[string]$Token,[string]$Proxy='',[string]$Root=(Split-Path -Parent $PSScriptRoot)) {
  if($Url -notmatch '^https://api\.github\.com/search/repositories\?') { throw 'Only GitHub repository Search URLs are allowed.' }
  return Invoke-GitHubRequest -Root $Root -Resource search -Url $Url -BodyPath $BodyPath -HeaderPath $HeaderPath -Token $Token -Proxy $Proxy -Timeout 90
}
function Get-GitHubReadCredential([string]$Root='') {
 $credential=$env:GITHUB_TOKEN
 if(-not $credential){$credential=$env:DSH_GITHUB_TOKEN};if(-not $credential){$credential=$env:GH_TOKEN}
 if(-not $credential -and (Get-Command gh -ErrorAction SilentlyContinue)){
  $value=& gh auth token --hostname github.com 2>$null
  if($LASTEXITCODE -eq 0){$credential=([string]$value).Trim()}
 }
 # Opt-in reuse of an existing Git login. Never opens a login UI or stores a token.
 $useGit=$false;$config=if($Root){Join-Path $Root 'config.json'}else{''}
 if($Root -and (Test-Path $config)){$useGit=[bool](Get-Content $config -Raw|ConvertFrom-Json).sources.reuse_git_login}
 if(-not $credential -and $useGit){$credential=Get-GitHubGitCredential}
 return [string]$credential
}
function Get-GitHubGitCredential {
 if(-not(Get-Command git -ErrorAction SilentlyContinue)){return ''}
 $start=[Diagnostics.ProcessStartInfo]::new('git');$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 foreach($arg in @('-c','credential.interactive=false','credential','fill')){$start.ArgumentList.Add($arg)}
 $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['GIT_TERMINAL_PROMPT']='0';$start.Environment['GCM_INTERACTIVE']='Never';$start.Environment['GCM_GUI_PROMPT']='0'
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start
 try{
  $null=$process.Start();$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
  $process.StandardInput.Write("protocol=https`nhost=github.com`n`n");$process.StandardInput.Close()
  if(-not $process.WaitForExit(10000)){$process.Kill($true);return ''}
  $value=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()
  if($process.ExitCode -eq 0 -and $value -match '(?m)^password=([^\r\n]+)'){return $Matches[1]}
 }catch{return ''}finally{$process.Dispose()}
 return ''
}
function Invoke-GitHubPublicGet([string]$Url,[string]$BodyPath,[string]$HeaderPath,[string]$Token='',[string]$Proxy='',[string]$ETag='',[string]$Root=(Split-Path -Parent $PSScriptRoot)) {
 if($Url -notmatch '^https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/(?:readme|license|releases/latest|issues/comments)(?:\?per_page=100&sort=created&direction=desc)?)?$'){throw 'Unsupported public evidence endpoint'}
 return Invoke-GitHubRequest -Root $Root -Resource core -Url $Url -BodyPath $BodyPath -HeaderPath $HeaderPath -Token $Token -Proxy $Proxy -ETag $ETag
}
function Invoke-GitHubRequest([string]$Root,[ValidateSet('core','search')][string]$Resource,[string]$Url,[string]$BodyPath,[string]$HeaderPath,[string]$Token='',[string]$Proxy='',[string]$ETag='',[int]$Timeout=45){
 # This shared entry is also bounded when invoked directly.
 if($Url -notmatch '^https://api\.github\.com/(search/repositories\?|repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:$|/(?:readme|license|releases/latest|issues/comments)(?:$|\?per_page=100&sort=created&direction=desc$)))'){throw 'Unsupported GitHub endpoint'}
 if($Token -match '[\r\n"\\]' -or $ETag -match '[\r\n]'){throw 'Invalid HTTP header'}
 $settings=Join-Path $Root 'config.json'
 if(-not $Token -and (Test-Path $settings) -and (Get-Content $settings -Raw|ConvertFrom-Json).sources.require_auth_for_daily){return [pscustomobject]@{Status=0;ExitCode=0;Paused=$true;Reason='authentication-required';NextAllowed=$null}}
 $dir=Join-Path $Root 'data/api-usage';New-Item -ItemType Directory -Force $dir|Out-Null
 try{$guard=[IO.File]::Open((Join-Path $dir 'http.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{return [pscustomobject]@{Status=0;ExitCode=0;Paused=$true;Reason='network-busy';NextAllowed=[datetimeoffset]::UtcNow.AddSeconds(5).ToString('o')}}
 try{
 $gate=Get-GitHubTransportGate $Root $Resource $Proxy $Token
 if($gate.paused){return [pscustomobject]@{Status=0;ExitCode=0;Paused=$true;Reason=$gate.reason;NextAllowed=$gate.next_allowed}}
 $id=Reserve-GitHubRequest $Root $(if($Resource -eq 'search'){'search'}else{'evidence'}) -Authenticated:([bool]$Token)
 if(-not $id){return [pscustomobject]@{Status=0;ExitCode=0;BudgetExhausted=$true}}
 $config=(Get-GitHubProxyConfig $Proxy)+'header = "Accept: application/vnd.github+json"'+"`n"+'header = "User-Agent: github-daily-picks-evidence"'+"`n"
 if($Token){$config+='header = "Authorization: Bearer '+$Token+'"'+"`n"}
 if($ETag){$config+='header = "If-None-Match: '+($ETag -replace '"','\"')+'"'+"`n"}
 $args=@('--silent','--show-error','--config','-','--connect-timeout','15','--max-time',[string]$Timeout,'--compressed','--dump-header',$HeaderPath,'--output',$BodyPath,'--write-out','%{http_code}')
 $status=$config|& curl.exe @args $Url 2>$null
 $code=$LASTEXITCODE;$http=([string]$status -as [int]);$headers=if(Test-Path $HeaderPath){Get-GitHubResponseHeaders ([IO.File]::ReadAllText($HeaderPath))}else{@{}}
 $body=if(Test-Path $BodyPath){[IO.File]::ReadAllText($BodyPath)}else{''}
 Complete-GitHubRequest $Root $id $http $code $headers
 Set-GitHubTransportGate $Root $Resource $Proxy $Token $http $code $headers $body
 return [pscustomobject]@{Status=$http;ExitCode=$code;RequestId=$id;NetworkFailure=($http -eq 0 -and $code -ne 0)}
 }finally{$guard.Dispose()}
}
