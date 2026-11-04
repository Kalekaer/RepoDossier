# discovery-lib.ps1 — 发现层公共函数（纯函数，不联网、不写盘）
# 供 discovery-pool / recall-audit / queue / tests 使用。

function Read-JsonlSafe {
  param([string]$Path)
  $out = New-Object System.Collections.ArrayList
  if (-not (Test-Path $Path)) { return @() }
  foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $o = $line | ConvertFrom-Json
      if ($o) { [void]$out.Add($o) }
    } catch { }
  }
  return @($out)
}

function ConvertTo-RepoRecord {
  param($Item, [string]$Channel, [string]$Date)
  $lic = $null
  if ($Item.license) {
    if ($Item.license.spdx_id) { $lic = [string]$Item.license.spdx_id }
    elseif ($Item.license.name) { $lic = [string]$Item.license.name }
  }
  return [ordered]@{
    id           = [string]$Item.full_name
    channel      = $Channel
    query_id     = $Channel
    discovered_at= $Date
    stars        = [int]$Item.stargazers_count
    created_at   = if ($Item.created_at) { ([datetime]$Item.created_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
    pushed_at    = if ($Item.pushed_at) { ([datetime]$Item.pushed_at).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
    license      = $lic
    language     = [string]$Item.language
    topics       = @($Item.topics)
    description  = [string]$Item.description
    archived     = [bool]$Item.archived
    fork         = [bool]$Item.fork
    eligible     = $true
    exclude_reason = $null
    layer        = 'other'
    in_library   = $false
    in_seen      = $false
  }
}

function Get-EligibilityReason {
  param($Record)
  if ($Record.archived) { return 'archived' }
  if ($Record.fork) { return 'fork' }
  # Missing descriptions require README review. They are not proof of no content.
  if ($Record.pushed_at) {
    try {
      if (([datetime]::UtcNow - ([datetime]$Record.pushed_at).ToUniversalTime()).TotalDays -gt 180) { return 'stale_180d' }
    } catch { }
  }
  $text = ([string]$Record.id + ' ' + [string]$Record.description).ToLowerInvariant()
  $repo=([string]$Record.id -split '/')[-1]
  if ($repo -match '^awesome-|^interview-questions$|^roadmap$|^books$' -or $text -match '\bcurated (list|collection) of\b|\bawesome (list|collection)\b') {
    return 'resource_list'
  }
  return $null
}

function Get-DshLayer {
  param($Record)
  $text = (([string]$Record.id) + ' ' + ([string]$Record.description) + ' ' + (@($Record.topics) -join ' ')).ToLowerInvariant()
  if ($text -match 'desktop|client|\bapp\b|客户端') { return 'desktop' }
  if ($text -match 'plugin|extension|插件') { return 'plugin' }
  if ($text -match 'harness|router|toolchain|runtime') { return 'harness' }
  return 'other'
}

function Get-WilsonCI {
  param([double]$P, [int]$N)
  if ($N -le 0) { return @{ low = 0.0; high = 1.0 } }
  $z = 1.96
  $den = 1 + $z * $z / $N
  $center = ($P + $z * $z / (2 * $N)) / $den
  $half = $z * [math]::Sqrt($P * (1 - $P) / $N + $z * $z / (4 * $N * $N)) / $den
  return @{ low = [math]::Max(0.0, $center - $half); high = [math]::Min(1.0, $center + $half) }
}

function Get-KnownShare {
  param([object[]]$Rows)
  $rows = @($Rows)
  $n = $rows.Count
  if ($n -eq 0) { return @{ eligible = 0; known = 0; share = 0.0 } }
  $known = @($rows | Where-Object { $_.in_library }).Count
  return @{ eligible = $n; known = $known; share = [math]::Round($known / [double]$n, 4) }
}

function Test-QueueTransition {
  param([string]$From, [string]$To)
  $allowed = @{
    new      = @('screened', 'rejected', 'deferred', 'known')
    screened = @('scored', 'rejected', 'deferred', 'known')
    scored   = @('accepted', 'rejected', 'deferred')
    accepted = @()
    rejected = @()
    deferred = @('screened')
    known    = @()
  }
  if (-not $allowed.ContainsKey($From)) { return $false }
  return ($allowed[$From] -contains $To)
}

function Get-PageSampleProbability {
  param([int]$Population,[int]$Page,[int]$SampleN,[double]$CellProbability=1.0)
  if($Population -le 0 -or $Page -lt 1 -or $SampleN -le 0 -or $CellProbability -le 0 -or $CellProbability -gt 1){return 0.0}
  $pages=[int][math]::Ceiling($Population/100.0)
  if($Page -gt $pages){return 0.0}
  $pageSize=if($Page -eq $pages){$Population-100*($pages-1)}else{100}
  return $CellProbability*(1.0/$pages)*([math]::Min($SampleN,$pageSize)/[double]$pageSize)
}

function Select-ReviewWork {
 param([object[]]$Rows,[int]$N=24,[string]$Date='')
 if(-not $Date){$Date=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')}
 # Due deferrals are promises, including projects outside today's search window.
 $due=@($Rows|Where-Object{$_.state -eq 'deferred' -and $_.review_after -and $_.review_after -le $Date}|Sort-Object review_after,discovered_at,id|Select-Object -First $N)
 if($due.Count -ge $N){return $due}
 $Rows=@($Rows|Where-Object{$_.state -ne 'deferred' -and $_.id -notin @($due|ForEach-Object id)})
 $bands=@('low','mid','high');$queues=@{}
 foreach($b in $bands){$queues[$b]=[Collections.Generic.Queue[object]]::new()}
 foreach($r in @($Rows|Sort-Object discovered_at,id)){
  $b=if($r.stars -lt 200){'low'}elseif($r.stars -le 800){'mid'}else{'high'};$queues[$b].Enqueue($r)
 }
 $selected=@($due);while($selected.Count -lt $N){$added=0;foreach($b in $bands){if($queues[$b].Count -and $selected.Count -lt $N){$selected+=$queues[$b].Dequeue();$added++}};if(-not $added){break}}
 return $selected
}
