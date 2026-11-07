# Shared, deterministic query plan. No network or writes on dot-source.
. (Join-Path $PSScriptRoot 'query-partitions.ps1')
function Test-QueryContractRequired($Spec,[string]$Date){
 return [bool]($Spec.execution_contract_from -and $Date -ge [string]$Spec.execution_contract_from)
}
function Get-DailyQueryPlanItems([string]$Root,[string]$Date,$Spec=$null){
 if(-not $Spec){$Spec=Get-Content (Join-Path $Root 'data/queries.json') -Raw|ConvertFrom-Json}
 $dt=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
 $wd=[string]$(if([int]$dt.DayOfWeek -eq 0){7}else{[int]$dt.DayOfWeek})
 $dayCfg=$Spec.weekdays.$wd;if(-not $dayCfg){throw 'Missing weekday query configuration'}
 function Resolve-QueryText([string]$q){
  foreach($days in @(7,8,14,30,180)){$q=$q.Replace('{D'+$days+'}',$dt.AddDays(-$days).ToString('yyyy-MM-dd'))}
  return $q.Replace('{TODAY_TOPIC}',[string]$dayCfg.topic).Replace('{TODAY_TOPIC2}',[string]$dayCfg.topic2)
 }
 $items=@()
 foreach($q in $Spec.queries){
  if($q.enabled -eq $false){continue}
  $freq=[string]$q.frequency
  $take=$freq -in @('daily','conditional') -or ($freq -match '^weekly:(.+)$' -and @($Matches[1].Split(',')) -contains $wd)
  if(-not $take){continue}
  $partition=$null
  if($q.adaptive_star_partition -and -not $q.acquisition){
   $observations=@(Get-SearchPartitionEvidence -RawRoot (Join-Path $Root 'data/raw') -QueryId $q.id -Date $Date)
   $partition=Get-NextSearchPartition -Observations $observations -PageSize $q.per_page -Reverse:($q.sort -eq 'updated')
   if($partition.blocked){throw 'Query partition exceeds search capacity'}
  }
  $url=''
  if($q.mode -eq 'search'){
   $text=Resolve-QueryText $q.q
   if($partition){$text=$text.Replace('stars:200..800',('stars:{0}..{1}' -f $partition.low,$partition.high))}
   $url='https://api.github.com/search/repositories?q='+$text.Replace(' ','+').Replace('>','%3E')
   if($q.sort){$url+="&sort=$($q.sort)&order=$($q.order)"}
   if($q.per_page){$url+="&per_page=$($q.per_page)"}
   if($partition){$url+="&page=$($partition.page)"}elseif($q.page){$url+="&page=$($q.page)"}elseif($q.page_rotate){$url+='&page='+(($dt.DayOfYear % [int]$q.page_rotate)+1)}
  }
  $items+=[pscustomobject][ordered]@{id=[string]$q.id;name=[string]$q.name;kind=$(if($freq -eq 'conditional'){'conditional'}elseif($q.mode -eq 'probe'){'probe'}else{'search'});url=$url;per_page=[int]$q.per_page;required=[bool]$q.required;conditional=$(if($freq -eq 'conditional'){$q.when}else{$null});partition=$partition;acquisition=$q.acquisition}
 }
 return $items
}
function ConvertTo-QueryCanonicalJson($Value){
 if($null -eq $Value){return 'null'}
 if($Value -is [System.Collections.IDictionary]){
  $parts=@(foreach($key in @($Value.Keys|Sort-Object)){(ConvertTo-Json ([string]$key) -Compress)+':'+(ConvertTo-QueryCanonicalJson $Value[$key])})
  return '{'+($parts -join ',')+'}'
 }
 if($Value -is [pscustomobject]){
  $map=@{};foreach($p in $Value.PSObject.Properties){$map[$p.Name]=$p.Value};return ConvertTo-QueryCanonicalJson $map
 }
 if($Value -is [array]){return '['+(@($Value|ForEach-Object{ConvertTo-QueryCanonicalJson $_})-join ',')+']'}
 return ConvertTo-Json $Value -Compress
}
function Get-QueryPlanIssues([string]$Root,[string]$Date,$Plan,[int]$Round=0){
 $spec=Get-Content (Join-Path $Root 'data/queries.json') -Raw|ConvertFrom-Json
 if(-not(Test-QueryContractRequired $spec $Date)){return @()}
 $issues=@();$expected=@(Get-DailyQueryPlanItems $Root $Date $spec)
 if([string]$Plan.date -ne $Date){$issues+='plan-date-mismatch'}
 if($Round -and [int]$Plan.round -ne $Round){$issues+='plan-round-mismatch'}
 if($Plan.spec_sha256 -ne (Get-FileHash (Join-Path $Root 'data/queries.json')).Hash){$issues+='query-spec-fingerprint-mismatch'}
 $byId=@{}
 foreach($it in @($Plan.items)){
  if($byId.ContainsKey([string]$it.id)){$issues+='duplicate-query:'+ $it.id}
  $byId[[string]$it.id]=$it
  if($it.id -notin @($expected.id)){$issues+='unexpected-query:'+ $it.id}
 }
 foreach($e in $expected){
  $it=$byId[$e.id]
  if(-not $it){$issues+='missing-planned-query:'+ $e.id;continue}
  foreach($key in @('kind','required','url','per_page','conditional','acquisition')){
   if((ConvertTo-QueryCanonicalJson $it.$key) -cne (ConvertTo-QueryCanonicalJson $e.$key)){$issues+='query-contract-mismatch:'+ $e.id+':'+$key}
  }
 }
 return $issues
}
function Assert-QueryImport([string]$Root,[string]$Date,[int]$Round,[string]$Id,[string]$RequestUrl,[string]$QueryTask,[string]$Body){
 $spec=Get-Content (Join-Path $Root 'data/queries.json') -Raw|ConvertFrom-Json
 if(-not(Test-QueryContractRequired $spec $Date)){return}
 $dir=Join-Path $Root "data/raw/$Date/r$Round";$planPath=Join-Path $dir 'plan.json'
 if(-not(Test-Path $planPath)){throw 'Import requires an existing canonical plan'}
 $plan=Get-Content $planPath -Raw|ConvertFrom-Json
 $issues=@(Get-QueryPlanIssues $Root $Date $plan $Round)
 if($issues.Count){throw ('Query plan rejected: '+($issues -join ', '))}
 $it=@($plan.items|Where-Object id -eq $Id)
 if($it.Count -ne 1 -or $it[0].kind -eq 'probe'){throw 'Unknown or non-search query ID'}
 if(-not $RequestUrl){throw 'Original request URL is required'}
 if($QueryTask -or $RequestUrl -ne $it[0].url){
  $progress=Join-Path $Root ('data/search-state/'+$Id+'.json')
  if(-not $QueryTask -or -not(Test-Path $progress)){throw 'Unplanned query parameters or reduced page size'}
  . (Join-Path $PSScriptRoot 'search-scheduler.ps1')
  $schedule=Get-Content $progress -Raw|ConvertFrom-Json
  if($schedule.id -ne $Id -or [int]$schedule.per_page -ne [int]$it[0].per_page -or -not @($schedule.pending).Count -or $RequestUrl -ne (Get-SearchNodeUrl $schedule $schedule.pending[0]) -or $QueryTask -ne (Get-SearchTaskKey $schedule $schedule.pending[0])){throw 'Request does not match the pending search task'}
 }
 if(-not(Test-GitHubSearchResponse $Body)){throw 'Invalid, incomplete or private search response'}
 $assessment=Get-GitHubSearchPageAssessment -Body $Body -Url $RequestUrl
 if(-not $assessment.Complete -and -not($assessment.Accepted -and $QueryTask -and $it[0].acquisition)){throw 'Truncated or undersized page is not completed coverage'}
}
