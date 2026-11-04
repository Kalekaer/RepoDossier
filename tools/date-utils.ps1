# Shared write-boundary conversion. No file I/O and no dependency on host timezone.
function ConvertTo-GitHubTimestamp {
  param([object]$Value, [string]$Field = 'timestamp', [string]$Default = '')
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    if (-not $Default) { return $null }
    $Value = $Default
  }
  if ($Value -is [datetime]) {
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
      $Value = [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
  $parsed = [datetimeoffset]::MinValue
  if (-not [datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
    throw "Invalid $Field timestamp; row was not written."
  }
  return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
}
