# Declared review scope for a daily brief. Discovery retention is not publication.
param([ValidateSet('prepare','check')][string]$Action='check',[string]$Date='',
 [string]$Root=(Split-Path -Parent $PSScriptRoot),[ValidateRange(1,500)][int]$N=24)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
. (Join-Path $PSScriptRoot 'score.ps1')
if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
function Read-EditorialRows([string]$File){
 $out=@();if(Test-Path $File){foreach($line in [IO.File]::ReadAllLines($File)){if($line.Trim()){$out+=ConvertFrom-Json $line -ErrorAction Stop}}};return $out
}
$poolPath=Join-Path $Root "data/audit/pool/$Date-all.jsonl"
$path=Join-Path $Root "data/audit/editorial/$Date.json"
if(-not(Test-Path $poolPath)){throw 'Daily search results missing'}
$pool=@(Read-EditorialRows $poolPath)
$rows=@(Read-JsonlSafe (Join-Path $Root 'data/candidates.jsonl'));$idx=@{};foreach($r in $rows){$idx[$r.id]=$r}
foreach($p in $pool){if(-not $p.id -or -not $idx.ContainsKey([string]$p.id)){throw 'Every retained search result must have a ledger record before editorial preparation or publication'}}
$picksPath=Join-Path $Root "data/picks/$Date.jsonl"
if($Action -eq 'prepare'){
 if(Test-Path $path){Write-Host '当期审阅范围已固定，不覆盖。';exit 0}
 if(Test-Path $picksPath){throw 'Freeze review scope before scoring; do not choose a scope after seeing grades'}
 $today=@{};foreach($p in $pool){$today[$p.id]=$true}
 $eligible=@($rows|Where-Object{($_.state -in @('new','screened') -or ($_.state -eq 'deferred' -and $_.review_after -le $Date)) -and $today.ContainsKey($_.id)})
 $selected=@(Select-ReviewWork -Rows $eligible -N $N -Date $Date)
 New-Item -ItemType Directory -Force (Split-Path $path)|Out-Null
 $snapshot=Join-Path (Split-Path $path) "$Date.search.jsonl"
 Copy-Item -LiteralPath $poolPath -Destination $snapshot
 $manifest=@{version=1;date=$Date;created_at=[datetimeoffset]::UtcNow.ToString('o');selection='oldest first within star bands; round robin; no score-based selection';ids=@($selected|ForEach-Object id);search_count=$pool.Count;search_snapshot=[IO.Path]::GetFileName($snapshot);search_sha256=(Get-FileHash $snapshot).Hash;rubric_sha256=(Get-FileHash (Join-Path $Root 'RUBRIC.md')).Hash;glossary_sha256=(Get-FileHash (Join-Path $Root 'GLOSSARY.md')).Hash}
 $manifest|ConvertTo-Json -Depth 8|Set-Content $path -Encoding UTF8
 Write-Host "已固定当期审阅 $($selected.Count) 项；检索留存 $($pool.Count) 项，不自动入库或评分。"
 exit 0
}
if(-not(Test-Path $path)){Write-Host '缺少评分前固定的当期审阅范围';exit 1}
$batch=Get-Content $path -Raw|ConvertFrom-Json
$snapshotPath=[IO.Path]::GetFullPath((Join-Path (Split-Path $path) $batch.search_snapshot))
if(-not $snapshotPath.StartsWith((Split-Path $path)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash $snapshotPath).Hash -ne $batch.search_sha256){throw 'Declared search snapshot changed'}
if((Get-FileHash (Join-Path $Root 'RUBRIC.md')).Hash -ne $batch.rubric_sha256 -or (Get-FileHash (Join-Path $Root 'GLOSSARY.md')).Hash -ne $batch.glossary_sha256){throw 'Scoring rules or glossary changed after scope was frozen'}
$ids=@($batch.ids);if(@($ids|Sort-Object -Unique).Count -ne $ids.Count){throw 'Invalid review identities'}
$frozen=@{};foreach($p in Read-JsonlSafe $snapshotPath){$frozen[$p.id]=$true}
foreach($id in $ids){if(-not $frozen.ContainsKey($id) -or -not $idx.ContainsKey($id)){throw 'Review identity lacks a search source or disposition record'}}
if($ids.Count){
 & (Join-Path $PSScriptRoot 'candidate-ledger.ps1') check -Root $Root -Date $Date -ScopeIds $ids -Publish
 if($LASTEXITCODE -ne 0){exit 1}
}
$picks=@(Read-EditorialRows $picksPath)
if(-not(Test-Path $picksPath)){Write-Host '缺少当天规则分文件；无评分时也应明确写空文件';exit 1}
$main=@();$bad=@();$special=@()
$seen=@{};foreach($s in Read-JsonlSafe (Join-Path $Root 'data/seen.jsonl')){$seen[$s.full_name]=$s}
$orgs=@{};$orgPath=Join-Path $Root 'data/owner-whitelist.json'
if(Test-Path $orgPath){$orgData=Get-Content $orgPath -Raw|ConvertFrom-Json;foreach($p in $orgData.orgs.PSObject.Properties){$orgs[$p.Name]=$true}}
foreach($p in $picks){
 if($p.date -ne $Date -or $null -eq $p.score -or (Get-Tier $p.score) -ne $p.tier){$bad+='invalid daily rule score';continue}
 $sa=$p.tier -in @('S','A')
 if($sa){
  if($p.risk -eq '高'){$bad+='high-risk publication'}
  $readmePath=[string]$p.evidence.readme_file;$readmeHash=[string]$p.evidence.readme_sha256
  if(-not $readmePath -or -not $readmeHash){$bad+='missing README evidence'}else{
   $ep=[IO.Path]::GetFullPath((Join-Path $Root $readmePath))
   if(-not $ep.StartsWith([IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path $ep) -or (Get-FileHash $ep).Hash -ne $readmeHash){$bad+='changed README evidence'}
  }
 }
 $blocked=$p.daily_status -eq 'over_quota' -or [bool]$p.quota_block
 $isSpecial=$p.section -eq 'special'
 if($isSpecial){$special+=$p;if(-not $orgs.ContainsKey(([string]$p.full_name -split '/')[0])){$bad+='special display is not a verified official organization'}}
 $isUser=$seen[[string]$p.full_name].origin -eq 'user'
 if($sa -and -not $p.repeat -and -not $blocked -and -not $isSpecial -and -not $isUser){
  $main+=$p
  if($p.full_name -notin $ids -or -not $frozen.ContainsKey($p.full_name)){$bad+='main recommendation outside declared daily search/review scope'}
 }
}
if($main.Count -gt 8 -or @($main|Where-Object tier -eq 'S').Count -gt 3){$bad+='recommendation quota exceeded'}
if($special.Count -gt 3){$bad+='special display quota exceeded'}
$report=Join-Path $Root "reports/$Date.md"
$disclosure="检索留存：$($pool.Count)；当期审阅：$($ids.Count)；其余留存：$($pool.Count-$ids.Count)"
if(-not(Test-Path $report) -or -not ([IO.File]::ReadAllText($report)).Contains($disclosure)){$bad+='missing exact search/review disclosure'}
if(-not $main.Count -and (Test-Path $report) -and -not ([IO.File]::ReadAllText($report)).Contains('今日无主推荐')){$bad+='missing explicit no-main-recommendation state'}
@{date=$Date;reviewed_scope=$ids.Count;search_retained=$pool.Count;main=$main.Count;errors=$bad;ready=($bad.Count -eq 0)}|ConvertTo-Json -Depth 5|Set-Content (Join-Path (Split-Path $path) "$Date.check.json") -Encoding UTF8
if($bad.Count){Write-Host ('当期审阅验收失败：'+($bad -join '; '));exit 1}
Write-Host '当期审阅与主推荐证据检查通过；其余检索记录保留，不代表已经评分。';exit 0
