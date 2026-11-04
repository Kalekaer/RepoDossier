function Get-BeijingDate { [datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd') }
function Get-WeeklyPeriod {
  param([Parameter(Mandatory)][string]$DailyDate)
  $daily = [datetime]::ParseExact($DailyDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
  $monday = $daily.AddDays(-(([int]$daily.DayOfWeek + 6) % 7))
  $start = $monday.AddDays(-7); $end = $monday.AddDays(-1)
  $number = [int][math]::Floor(($start - [datetime]'2026-10-12').Days / 7) + 1
  [pscustomobject]@{Start=$start.ToString('yyyy-MM-dd');End=$end.ToString('yyyy-MM-dd');
    Monday=$monday.ToString('yyyy-MM-dd');IsMonday=($daily.DayOfWeek -eq [DayOfWeek]::Monday);
    Issue=('W{0:D2}' -f $number);Number=$number;File=('weekly-'+$end.ToString('yyyy-MM-dd')+'.generated.html')}
}
function Ensure-WeeklyForDaily {
  param([string]$Root,[string]$DailyDate,[string]$GeneratedOn='')
  $period = Get-WeeklyPeriod $DailyDate
  if ($period.Number -lt 1) { return }
  if (-not (Test-Path (Join-Path $Root "reports/$DailyDate.md")) -or
      -not (Test-Path (Join-Path $Root "data/picks/$DailyDate.jsonl"))) { return }
  $path = Join-Path $Root ('data/site/'+$period.File)
  if (-not (Test-Path $path)) {
    $global:LASTEXITCODE = 0
    if (-not $GeneratedOn) { $GeneratedOn = Get-BeijingDate }
    $generatedOn = $GeneratedOn
    & (Join-Path $Root 'tools/build-weekly.ps1') -WeekStart $period.Start -GeneratedOn $generatedOn -Backfill:($generatedOn -gt $period.Monday)
    if ($global:LASTEXITCODE -ne 0 -or -not (Test-Path $path)) { throw 'Weekly report generation failed' }
  }
  return $period
}
function Set-DailyWeeklyEntry {
  param([string]$Html,[string]$DailyDate,[string]$Root)
  $Html = [regex]::Replace($Html,'(?s)<style id="weekly-entry-css">.*?</style>\r?\n?','')
  $Html = [regex]::Replace($Html,'(?s)\s*<!-- WEEKLY_ENTRY:START -->.*?<!-- WEEKLY_ENTRY:END -->','')
  $p = Get-WeeklyPeriod $DailyDate
  if (-not $p.IsMonday -or $p.Number -lt 1 -or -not (Test-Path (Join-Path $Root ('data/site/'+$p.File)))) { return $Html }
  $entry = [IO.File]::ReadAllText((Join-Path $Root 'tools/templates/weekly-entry.html'))
  $entry = $entry.Replace('{{FILE}}',$p.File).Replace('{{ISSUE}}',$p.Issue).Replace('{{RANGE}}',($p.Start+' — '+$p.End))
  return $Html.Replace('</body>',($entry+"`n</body>"))
}
function Get-WeeklyArchive {
  param([string]$Root)
  foreach ($file in @(Get-ChildItem (Join-Path $Root 'data/site') -File -Filter 'weekly-*.generated.html' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    $html = [IO.File]::ReadAllText($file.FullName)
    $match = [regex]::Match($html,'(?s)var D = (\{.*?\});\s*\r?\n')
    if (-not $match.Success) { throw "Missing weekly data: $($file.Name)" }
    $data = $match.Groups[1].Value | ConvertFrom-Json
    $start = [string]$data.dates[0]; $end = [string]$data.dates[-1]
    $period = Get-WeeklyPeriod ([datetime]::ParseExact($end,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture).AddDays(1).ToString('yyyy-MM-dd'))
    if ($period.Start -ne $start -or $file.Name -ne $period.File) { throw "Weekly period mismatch: $($file.Name)" }
    [ordered]@{issue=$period.Issue;start=$start;end=$end;found=$data.found;scored=$data.scored;main=$data.main;has_page=$true;page_note='完整周报';path=$file.Name}
  }
}
