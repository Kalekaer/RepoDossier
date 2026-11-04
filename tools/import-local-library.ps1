param([Parameter(Mandatory)][string]$Source)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Source = (Resolve-Path -LiteralPath $Source).Path
if ($Source -eq $root) { throw 'Source must differ from destination' }
$backup = Join-Path $root ('data/_backup/import-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$summary = [Collections.Generic.List[object]]::new()
function Backup([string]$rel) {
  $dst = Join-Path $root $rel
  if (Test-Path -LiteralPath $dst) {
    $bak = Join-Path $backup $rel
    New-Item -ItemType Directory -Path (Split-Path $bak) -Force | Out-Null
    Copy-Item -LiteralPath $dst -Destination $bak
  }
}
function Rows([string]$path) {
  if (Test-Path -LiteralPath $path) {
    Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json -InputObject $_ }
  }
}
function Key($row, [string[]]$fields) {
  if ($fields.Count) { return (($fields | ForEach-Object { [string]$row.$_ }) -join '|') }
  return ($row | ConvertTo-Json -Depth 50 -Compress)
}
function Merge-Lines([string]$rel, [string[]]$fields, [string]$writer = '') {
  $src = Join-Path $Source $rel
  if (-not (Test-Path -LiteralPath $src)) { return }
  $dst = Join-Path $root $rel
  $keys = @{}
  foreach ($row in @(Rows $dst)) { $keys[(Key $row $fields)] = $true }
  $add = @(
    foreach ($row in @(Rows $src)) {
      $k = Key $row $fields
      if (-not $keys.ContainsKey($k)) { $row; $keys[$k] = $true }
    }
  )
  if (-not $add.Count) { return }
  Backup $rel
  New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
  $lines = @($add | ForEach-Object { $_ | ConvertTo-Json -Depth 50 -Compress })
  if ($writer) {
    $inputFile = Join-Path $backup 'writer-input.jsonl'
    [IO.File]::WriteAllLines($inputFile, [string[]]$lines, $utf8)
    if ($writer -eq 'picks') {
      & (Join-Path $PSScriptRoot 'add-rows.ps1') -Target picks -Date ([IO.Path]::GetFileNameWithoutExtension($rel)) -From $inputFile
    } else {
      $date = [IO.Path]::GetFileNameWithoutExtension($rel)
      $result = & (Join-Path $PSScriptRoot 'append-snapshot.ps1') -Date $date -CapturedAt "${date}T00:00:00+08:00" -From $inputFile -Apply -Json
      $status = $result | ConvertFrom-Json
      Write-Output "Snapshots $date : $($status.count) imported"
    }
    if ($LASTEXITCODE -ne 0) { throw "Writer failed: $rel" }
  } else {
    $prefix = if ((Test-Path $dst) -and (Get-Item $dst).Length -gt 0 -and -not [IO.File]::ReadAllText($dst).EndsWith("`n")) { "`n" } else { '' }
    [IO.File]::AppendAllText($dst, $prefix + ($lines -join "`n") + "`n", $utf8)
  }
  $summary.Add([pscustomobject]@{file=$rel; added=$add.Count})
}
Merge-Lines 'data/seen.jsonl' @('full_name')
foreach ($name in @('repo-intro','function-tags')) { Merge-Lines "data/human/$name.jsonl" @('full_name') }
Merge-Lines 'data/human/search-synonyms.jsonl' @()
Merge-Lines 'data/user-notes.jsonl' @()
Merge-Lines 'data/workspaces.jsonl' @('id')
Merge-Lines 'data/status-log.jsonl' @()
foreach ($dir in @('meta','picks','snapshots')) {
  foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Source "data/$dir") -Filter '*.jsonl' -File) {
    $fields = if ($dir -eq 'snapshots') { @('full_name','round') } else { @('full_name') }
    $writer = if ($dir -in @('picks','snapshots')) { $dir } else { '' }
    Merge-Lines "data/$dir/$($file.Name)" $fields $writer
  }
}
$rel = 'data/recommend-log.csv'
$dst = Join-Path $root $rel
$keys = @{}
Import-Csv -LiteralPath $dst | ForEach-Object { $keys[$_.仓库] = $true }
$new = @(Import-Csv -LiteralPath (Join-Path $Source $rel) | Where-Object { -not $keys.ContainsKey($_.仓库) })
if ($new.Count) {
  Backup $rel
  $inputFile = Join-Path $backup 'csv-input.jsonl'
  [IO.File]::WriteAllLines($inputFile, [string[]]@($new | ForEach-Object { $_ | ConvertTo-Json -Compress }), $utf8)
  & (Join-Path $PSScriptRoot 'add-rows.ps1') -Target csv -From $inputFile
  if ($LASTEXITCODE -ne 0) { throw 'CSV import failed' }
  $summary.Add([pscustomobject]@{file=$rel;added=$new.Count})
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Source 'reports') -File -Filter '*.md' | Where-Object { $_.Name -match '^(weekly-)?\d{4}-\d{2}-\d{2}.*\.md$' }) {
  $dst = Join-Path $root "reports/$($file.Name)"
  if (-not (Test-Path $dst)) { Copy-Item -LiteralPath $file.FullName -Destination $dst }
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'summary.json') -Encoding UTF8
$summary | Format-Table -AutoSize
Write-Output "Backup: $backup"
