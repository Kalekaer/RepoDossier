# Local browser entry. Does not rebuild data or change host permissions.
param([ValidateRange(1024,65535)][int]$Port=8788,[switch]$NoOpen,[switch]$Stop)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\','/')
$normalized=$root.Replace('\','/').ToLowerInvariant()
$rootHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
$url="http://127.0.0.1:$Port/"
$state=Join-Path $root "data/_tmp/site-server-$Port.json"
$handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false
$client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[timespan]::FromSeconds(2)
function Get-SiteHealth {
 try {return ($client.GetStringAsync($url+'__daily_site_health').GetAwaiter().GetResult()|ConvertFrom-Json)} catch {return $null}
}
function Test-OwnSite($health){return ($health -and $health.service -eq 'github-daily-picks-local-site-v1' -and $health.root_sha256 -eq $rootHash)}
try {
 $health=Get-SiteHealth
 if($Stop){
  if(-not (Test-OwnSite $health)){throw 'No matching workspace site is running; no process was stopped'}
  if(-not(Test-Path -LiteralPath $state)){throw 'No launcher process record; no process was stopped'}
  $saved=Get-Content -LiteralPath $state -Raw|ConvertFrom-Json
  $process=Get-Process -Id $saved.pid -ErrorAction Stop
  if($saved.root_sha256 -ne $rootHash -or $process.StartTime.ToUniversalTime().Ticks.ToString() -ne $saved.started_ticks){throw 'Process identity changed; no process was stopped'}
  Stop-Process -Id $process.Id
  Remove-Item -LiteralPath $state
  Write-Output 'Local site stopped.'
  exit 0
 }
 if($health -and -not(Test-OwnSite $health)){throw 'Port belongs to another site. Use -Port with a different port'}
 if(-not(Test-OwnSite $health)){
  $python=Get-Command python -CommandType Application -ErrorAction Stop|Select-Object -First 1
  $server=Join-Path $PSScriptRoot 'serve-site.py'
  $tmp=Join-Path $root 'data/_tmp';New-Item -ItemType Directory -Force $tmp|Out-Null
  $stamp=[guid]::NewGuid().ToString('N')
  $process=Start-Process -FilePath $python.Source -ArgumentList @('-B',('"'+$server+'"'),'--port',"$Port") -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $tmp "site-server-$stamp.out.log") -RedirectStandardError (Join-Path $tmp "site-server-$stamp.err.log")
  for($i=0;$i -lt 30;$i++){
   Start-Sleep -Milliseconds 200
   $process.Refresh()
   if($process.HasExited){throw 'Local server could not start (port occupied or environment restriction); see data/_tmp/site-server-*.err.log'}
   $health=Get-SiteHealth
   if(Test-OwnSite $health){break}
  }
  if(-not(Test-OwnSite $health)){
   if(-not $process.HasExited){Stop-Process -Id $process.Id}
   throw 'Local server did not become ready; no browser was opened'
  }
  @{pid=$process.Id;started_ticks=$process.StartTime.ToUniversalTime().Ticks.ToString();root_sha256=$rootHash;port=$Port}|ConvertTo-Json|Set-Content -LiteralPath $state -Encoding UTF8
 }
 Write-Output ($url+'#/daily')
 if(-not $NoOpen){Start-Process ($url+'#/daily')}
} finally {$client.Dispose();$handler.Dispose()}
