# Fixed-query cohorts and budgeted two-dimensional shards. Pure policy helpers.
function New-SearchSchedule($Item,[string]$Date,[int]$TtlDays=7) {
 $q=[uri]::UnescapeDataString(([regex]::Match($Item.url,'[?&]q=([^&]+)').Groups[1].Value -replace '\+',' '))
 $policy=$Item.acquisition
 $low=if($null -ne $policy.star_min){[int]$policy.star_min}else{0}
 $high=if($policy.star_max){[int]$policy.star_max}else{1000000000}
 if($null -eq $policy.star_min){
  if($q -match '(?<!\S)stars:>(\d+)'){$low=[int]$Matches[1]+1}
  elseif($q -match '(?<!\S)stars:(\d+)\.\.(\d+)'){$low=[int]$Matches[1];$high=[int]$Matches[2]}
 }
 $dt=[datetime]::ParseExact($Date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
 $start=[datetimeoffset]::Parse('1970-01-01T00:00:00Z');$end=[datetimeoffset]::Parse($Date+'T23:59:59Z')
 if($policy.created_days_max){$start=[datetimeoffset]::Parse($dt.AddDays(-[int]$policy.created_days_max).ToString('yyyy-MM-dd')+'T00:00:00Z')}
 if($policy.created_days_min){$end=[datetimeoffset]::Parse($dt.AddDays(-[int]$policy.created_days_min).ToString('yyyy-MM-dd')+'T23:59:59Z')}
 if($q -match '(?<!\S)created:(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})'){$start=[datetimeoffset]::Parse($Matches[1]+'T00:00:00Z');$end=[datetimeoffset]::Parse($Matches[2]+'T23:59:59Z')}
 elseif($q -match '(?<!\S)created:>(\d{4}-\d{2}-\d{2})'){$start=[datetimeoffset]::Parse($Matches[1]+'T00:00:00Z')}
 elseif($q -match '(?<!\S)created:<(\d{4}-\d{2}-\d{2})'){$end=[datetimeoffset]::Parse($Matches[1]+'T00:00:00Z').AddSeconds(-1)}
 $node=@{low=$low;high=$high;start=$start.ToUnixTimeSeconds();end=$end.ToUnixTimeSeconds();page=1}
 if($policy.mode -eq 'pages'){$page=[regex]::Match($Item.url,'[?&]page=(\d+)');if($page.Success){$node.page=[int]$page.Groups[1].Value}}
 return [pscustomobject]@{version=1;id=$Item.id;cohort=$Date;expires=$dt.AddDays($TtlDays).ToString('yyyy-MM-dd');query=$q;url=$Item.url;mode=$policy.mode;per_page=$Item.per_page;reverse=($Item.url -match 'sort=updated');pending=@($node);completed=0;blocked=$false;requests=0;last_status='pending'}
}
function Get-SearchNodeUrl($Schedule,$Node) {
 $url=[string]$Schedule.url
 if($Schedule.mode -eq 'bounded'){
  $q=([string]$Schedule.query -replace '(?<!\S)(stars|created):\S+','').Trim()
  $s=[datetimeoffset]::FromUnixTimeSeconds([long]$Node.start).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $e=[datetimeoffset]::FromUnixTimeSeconds([long]$Node.end).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $q+=" stars:$($Node.low)..$($Node.high) created:$s..$e"
  $encoded=[uri]::EscapeDataString($q)
  $url=[regex]::Replace($url,'([?&]q=)[^&]+',('$1'+$encoded))
 }
 if($url -match '[?&]page='){$url=[regex]::Replace($url,'([?&]page=)\d+',('${1}'+$Node.page))}else{$url+='&page='+$Node.page}
 return $url
}
function Get-SearchTaskKey($Schedule,$Node) {
 $url=Get-SearchNodeUrl $Schedule $Node
 $bytes=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Schedule.cohort+'|'+$url))
 return ($Schedule.id+'-'+[BitConverter]::ToString($bytes).Replace('-','').Substring(0,24))
}
function Move-SearchSchedule($Schedule,$Response) {
 $nodes=@($Schedule.pending);if(-not $nodes.Count){return}
 $n=$nodes[0];$rest=@($nodes|Select-Object -Skip 1);$total=[long]$Response.total_count
 $refine=$false
 if($Response.PSObject.Properties['incomplete_results']){
  $assessment=Get-GitHubSearchPageAssessment -Response $Response -Url (Get-SearchNodeUrl $Schedule $n)
  $refine=$assessment.NeedsRefinement
 }
 if(($total -gt 1000 -or $refine) -and $Schedule.mode -eq 'pages'){$Schedule.mode='bounded'}
 $Schedule.requests++;$Schedule.last_status='sampling'
 if(($total -gt 1000 -or $refine) -and $Schedule.mode -eq 'bounded'){
  # First stars-sorted response provides a tighter safe maximum for this observation.
  if(-not $refine -and $n.page -eq 1 -and -not $Schedule.reverse -and @($Response.items).Count -and [int]$Response.items[0].stargazers_count -lt [int]$n.high -and [int]$Response.items[0].stargazers_count -ge [int]$n.low){$n.high=[int]$Response.items[0].stargazers_count}
  $a=@{};$b=@{};foreach($k in @('low','high','start','end')){$a[$k]=$n.$k;$b[$k]=$n.$k};$a.page=1;$b.page=1
  if([int]$n.high -gt [int]$n.low){$mid=[int][math]::Floor(([long]$n.low+[long]$n.high)/2);$a.high=$mid;$b.low=$mid+1}
  elseif([long]$n.end -gt [long]$n.start){$mid=[long][math]::Floor(([long]$n.start+[long]$n.end)/2);$a.end=$mid;$b.start=$mid+1}
  else{$Schedule.blocked=$true;$Schedule.last_status='single-second-overflow';return}
  $children=@($a,$b);if($Schedule.reverse){[array]::Reverse($children)}
  # Breadth first: avoid spending the whole cohort on the first dense leaf.
  $Schedule.pending=@($rest)+$children
  if($refine){$Schedule.last_status='page-count-drift-refining'}
 } elseif([int]$n.page -lt [math]::Max(1,[math]::Ceiling($total/[double]$Schedule.per_page))){
  $n.page=[int]$n.page+1;$Schedule.pending=@($rest)+@($n)
 } else{$Schedule.completed++;$Schedule.pending=$rest}
 if(-not @($Schedule.pending).Count){$Schedule.last_status='observed-cycle-complete'}
}
function Get-SearchTaskImport([string]$RawRoot,[string]$Task) {
 foreach($f in @(Get-ChildItem $RawRoot -Recurse -File -Filter meta.json)){
  $m=Get-Content $f.FullName -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($r in @($m.imports|Where-Object{$_.ok -and $_.query_task -eq $Task})){
   $p=[IO.Path]::GetFullPath((Join-Path $f.DirectoryName $r.file))
   if(-not $p.StartsWith($f.DirectoryName+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid task raw path'}
   if($r.sha256 -and (Get-FileHash -LiteralPath $p).Hash -ne $r.sha256){throw 'Task raw changed'}
   $body=[IO.File]::ReadAllText($p)
   if(Test-GitHubSearchResponse $body){return (ConvertFrom-Json $body)}
  }
 }
 return $null
}
