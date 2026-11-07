# Read-only diagnosis by default. Live mode performs one bounded public GET.
param([switch]$Live,[switch]$Mirrors,[switch]$NoProxy)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'github-transport.ps1')
$token=Get-GitHubReadCredential -Root $root
$proxy=Get-GitHubProxy -NoProxy:$NoProxy
$sources=(Get-Content (Join-Path $root 'config.json') -Raw|ConvertFrom-Json).sources
$day=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')
$usage=Join-Path $root ('data/api-usage/'+$day+'.jsonl');$used=0;$attempts=0;$released=0
if(Test-Path $usage){foreach($line in [IO.File]::ReadAllLines($usage)){if($line.Trim()){$row=ConvertFrom-Json $line;$used+=[int]$row.requests;if($row.type -eq 'request'){$attempts++};if($row.type -eq 'settlement' -and $row.requests -lt 0){$released++}}}}
$limit=if($token -and $sources.authenticated_daily_api_ceiling){[int]$sources.authenticated_daily_api_ceiling}else{[int]$sources.daily_api_ceiling}
$report=[ordered]@{date=$day;credential_available=[bool]$token;credential_validated=$false;authentication_required=[bool]$sources.require_auth_for_daily;proxy_configured=[bool]$proxy;budget=@{limit=$limit;used=$used;remaining=[math]::Max(0,$limit-$used);recorded_attempts=$attempts;released_not_connected=$released};core=(Get-GitHubTransportGate $root core $proxy $token);search=(Get-GitHubTransportGate $root search $proxy $token);live_requested=[bool]$Live}
if($Live){
 $dir=Join-Path $root 'data/_tmp/network-diagnosis';New-Item -ItemType Directory -Force $dir|Out-Null
 $base=Join-Path $dir ([guid]::NewGuid().ToString('N'))
 $r=Invoke-GitHubPublicGet -Root $root -Url 'https://api.github.com/repos/Kalekaer/RepoDossier' -Token $token -Proxy $proxy -BodyPath ($base+'.json') -HeaderPath ($base+'.headers')
 $headers=if(Test-Path ($base+'.headers')){Get-GitHubResponseHeaders ([IO.File]::ReadAllText($base+'.headers'))}else{@{}}
 $report.official=@{status=$r.Status;curl_exit=$r.ExitCode;paused=[bool]$r.Paused;reason=$r.Reason;budget_exhausted=[bool]$r.BudgetExhausted;limit=$headers['x-ratelimit-limit'];remaining=$headers['x-ratelimit-remaining']}
 $report.credential_validated=[bool]($token -and $r.Status -eq 200 -and [int]$headers['x-ratelimit-limit'] -gt 60)
 if($Mirrors){
  $results=@()
  foreach($url in @('https://mirrors.ustc.edu.cn/help/github-release.html','https://mirror.nju.edu.cn/github-release/','https://cdn.jsdelivr.net/gh/jsdelivr/jsdelivr@master/README.md','https://help.gitee.com/repository/settings/sync-between-gitee-github')){
   $config=Get-GitHubProxyConfig $proxy
   $status=$config|& curl.exe --silent --show-error --head --config - --connect-timeout 10 --max-time 20 --output NUL --write-out '%{http_code}' $url 2>$null
   $results+=@{url=$url;status=([string]$status -as [int]);curl_exit=$LASTEXITCODE;redirect_followed=$false;purpose='documentation-or-file-reachability-only'}
  }
  $report.mirrors=$results
 }
 $report.budget_before=$report.budget
 $report.budget=Reserve-GitHubRequest $root diagnosis -Peek -Authenticated:([bool]$token)
 $name=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+$(if($NoProxy){'direct'}else{'configured'})+'.json'
 $report|ConvertTo-Json -Depth 7|Set-Content (Join-Path $dir $name) -Encoding UTF8
 $report|ConvertTo-Json -Depth 7|Set-Content (Join-Path $dir 'latest.json') -Encoding UTF8
}
$token=$null
$report|ConvertTo-Json -Depth 7
if($Live -and ($report.official.status -ne 200 -or $report.official.paused -or $report.official.budget_exhausted)){exit 2}
exit 0
