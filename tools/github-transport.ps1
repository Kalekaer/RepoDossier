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
function Reserve-GitHubRequest([string]$Root,[string]$Kind,[switch]$Peek){
 $day=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd');$dir=Join-Path $Root 'data/api-usage'
 New-Item -ItemType Directory -Force $dir|Out-Null
 $guard=[IO.File]::Open((Join-Path $dir ($day+'.lock')),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  $path=Join-Path $dir ($day+'.jsonl');$limit=45
  $config=Join-Path $Root 'config.json';if(Test-Path $config){$v=(Get-Content $config -Raw|ConvertFrom-Json).sources.daily_api_ceiling;if($v){$limit=[int]$v}}
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
  if($Peek){return @{limit=$limit;used=$used;remaining=[math]::Max(0,$limit-$used)}}
  if($used -ge $limit){return $null}
  $id=[guid]::NewGuid().ToString('N')
  @{type='request';requests=1;id=$id;kind=$Kind;at=[datetimeoffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Add-Content $path -Encoding UTF8
  return $id
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
  if($Token -match '[\r\n"\\]') { throw 'Invalid credential format.' }
  if(-not(Reserve-GitHubRequest $Root 'search')){return [pscustomobject]@{Status=0;ExitCode=0;BudgetExhausted=$true}}
  $config=(Get-GitHubProxyConfig $Proxy)+'header = "Accept: application/vnd.github+json"'+"`n"+'header = "User-Agent: github-daily-picks"'+"`n"
  if($Token) { $config+='header = "Authorization: Bearer '+$Token+'"'+"`n" }
  $a=@('--silent','--show-error','--config','-','--connect-timeout','15','--max-time','90','--compressed','--dump-header',$HeaderPath,'--output',$BodyPath,'--write-out','%{http_code}')
  $status=$config | & curl.exe @a $Url 2>$null
  [pscustomobject]@{Status=([string]$status -as [int]); ExitCode=$LASTEXITCODE}
}
function Get-GitHubReadCredential {
 $credential=$env:GITHUB_TOKEN
 if(-not $credential){$credential=$env:DSH_GITHUB_TOKEN};if(-not $credential){$credential=$env:GH_TOKEN}
 return [string]$credential
}
function Invoke-GitHubPublicGet([string]$Url,[string]$BodyPath,[string]$HeaderPath,[string]$Token='',[string]$Proxy='',[string]$ETag='',[string]$Root=(Split-Path -Parent $PSScriptRoot)) {
 if($Url -notmatch '^https://api\.github\.com/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/(?:readme|license|releases/latest|issues/comments)(?:\?per_page=100&sort=created&direction=desc)?)?$'){throw 'Unsupported public evidence endpoint'}
 if($Token -match '[\r\n"\\]' -or $ETag -match '[\r\n]'){throw 'Invalid HTTP header'}
 if(-not(Reserve-GitHubRequest $Root 'evidence')){return [pscustomobject]@{Status=0;ExitCode=0;BudgetExhausted=$true}}
 $config=(Get-GitHubProxyConfig $Proxy)+'header = "Accept: application/vnd.github+json"'+"`n"+'header = "User-Agent: github-daily-picks-evidence"'+"`n"
 if($Token){$config+='header = "Authorization: Bearer '+$Token+'"'+"`n"}
 if($ETag){$config+='header = "If-None-Match: '+($ETag -replace '"','\"')+'"'+"`n"}
 $args=@('--silent','--show-error','--config','-','--connect-timeout','15','--max-time','45','--compressed','--dump-header',$HeaderPath,'--output',$BodyPath,'--write-out','%{http_code}')
 $status=$config|& curl.exe @args $Url 2>$null
 return [pscustomobject]@{Status=([string]$status -as [int]);ExitCode=$LASTEXITCODE}
}
