# Deterministic bounded search scheduling. Only reads existing acquisition evidence.
function Get-NextSearchPartition {
  param([int]$Minimum=200, [int]$Maximum=800, [int]$PageSize=100,
        [object[]]$Observations=@(), [switch]$Reverse)
  $queue = [Collections.Generic.List[object]]::new()
  $queue.Add(@{low=$Minimum;high=$Maximum;page=1})
  foreach ($observation in $Observations) {
    $head = $queue[0]
    if ($observation.low -ne $head.low -or $observation.high -ne $head.high -or $observation.page -ne $head.page) { continue }
    $total = [int]$observation.total
    if ($total -gt 1000) {
      if ($head.low -eq $head.high) { return @{low=$head.low;high=$head.high;page=1;blocked=$true} }
      $mid = [int][math]::Floor(($head.low + $head.high)/2)
      $children = @(@{low=$head.low;high=$mid;page=1}, @{low=$mid+1;high=$head.high;page=1})
      if ($Reverse) { [array]::Reverse($children) }
      $queue.RemoveAt(0)
      $queue.Insert(0,$children[1]); $queue.Insert(0,$children[0])
    } elseif ($head.page -lt [math]::Max(1,[math]::Ceiling($total/[double]$PageSize))) {
      $head.page++
    } else {
      $queue.RemoveAt(0)
      if (-not $queue.Count) { $queue.Add(@{low=$Minimum;high=$Maximum;page=1}) }
    }
  }
  return $queue[0]
}

function Get-SearchPartitionEvidence {
  param([string]$RawRoot, [string]$QueryId, [string]$Date)
  $observations = @()
  foreach ($file in @(Get-ChildItem $RawRoot -Recurse -File -Filter meta.json -ErrorAction SilentlyContinue)) {
    $planPath = Join-Path $file.DirectoryName 'plan.json'
    if (-not (Test-Path $planPath)) { continue }
    $plan = Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$plan.date -gt $Date) { continue }
    $item = @($plan.items | Where-Object id -eq $QueryId | Select-Object -First 1)
    if (-not $item.Count) { continue }
    $meta = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $import = @($meta.imports | Where-Object { $_.id -eq $QueryId -and $_.ok } | Sort-Object attempt -Descending | Select-Object -First 1)
    if (-not $import.Count) { continue }
    $import = $import[0]
    $path = Join-Path $file.DirectoryName $import.file
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if ($import.sha256 -and (Get-FileHash -LiteralPath $path).Hash -ne $import.sha256) { continue }
    $response = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($response.incomplete_results -or $null -eq $response.total_count -or $response.items -isnot [array]) { continue }
    $shard = $item[0].partition
    if (-not $shard) {
      # Legacy wide queries can seed the first split, but never claim a leaf complete.
      if ($item[0].url -notmatch 'stars:200\.\.800') { continue }
      $shard = @{low=200;high=800;page=1}
    }
    $observations += [pscustomobject]@{date=[string]$plan.date;round=[int]$plan.round;low=[int]$shard.low;high=[int]$shard.high;page=[int]$shard.page;total=[int]$response.total_count}
  }
  return @($observations | Sort-Object date,round)
}
