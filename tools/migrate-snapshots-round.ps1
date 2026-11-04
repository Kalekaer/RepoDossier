# migrate-snapshots-round.ps1 — 给快照补 `round`（同日多轮的唯一区分）
#
# 背景：`data/snapshots/<date>.jsonl` 里同一天同一仓库可能有多行（多轮采集）。
#   没有 round 时，无法区分「合法多轮」与「失败重试重复追加」。
#   本脚本按文件内出现顺序给每个 date+full_name 编号（1 起），可重复执行（幂等）。
#
# 用法：
#   .\tools\migrate-snapshots-round.ps1            # dry-run：只报告会改多少行
#   .\tools\migrate-snapshots-round.ps1 -Apply     # 实际写入（保持每行原行尾 / 无 BOM）
#   .\tools\migrate-snapshots-round.ps1 -Apply -Json
#
# 退出码：0 = OK ｜ 1 = 有行不合法（未写任何文件）｜ 2 = 目录不存在

param([switch]$Apply, [switch]$Json)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dir = Join-Path $root 'data\snapshots'
if (-not (Test-Path $dir)) { Write-Host '❌ 找不到 data\snapshots' -ForegroundColor Red; exit 2 }

function Split-Lines([string]$text) {
  $out = New-Object System.Collections.ArrayList
  $pos = 0
  while ($pos -lt $text.Length) {
    $nl = $text.IndexOf("`n", $pos)
    if ($nl -lt 0) {
      [void]$out.Add([pscustomobject]@{ Text = $text.Substring($pos); Eol = '' })
      $pos = $text.Length
    } else {
      $content = $text.Substring($pos, $nl - $pos)
      if ($content.EndsWith("`r")) { $content = $content.Substring(0, $content.Length - 1); $eol = "`r`n" } else { $eol = "`n" }
      [void]$out.Add([pscustomobject]@{ Text = $content; Eol = $eol })
      $pos = $nl + 1
    }
  }
  return $out
}

$files = @(Get-ChildItem $dir -Filter '*.jsonl' -File | Sort-Object Name)
$report = @()
$bad = @()
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $lines = @(Split-Lines $text)
  $counts = @{}
  $changed = 0
  $total = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if (-not $l.Text.Trim()) { continue }
    $obj = $null
    try { $obj = $l.Text | ConvertFrom-Json } catch { $bad += "$($f.Name):$($i + 1) JSON 非法"; continue }
    $total++
    $repo = [string]$obj.full_name
    $n = if ($counts.ContainsKey($repo)) { $counts[$repo] + 1 } else { 1 }
    $counts[$repo] = $n
    if ($obj.PSObject.Properties['round']) { continue }
    $brace = $l.Text.LastIndexOf('}')
    if ($brace -lt 0) { $bad += "$($f.Name):$(($i + 1)) 找不到 JSON 结尾"; continue }
    $lines[$i].Text = $l.Text.Substring(0, $brace) + ',"round":' + $n + $l.Text.Substring($brace)
    $changed++
  }
  $report += [pscustomobject]@{ file = $f.Name; lines = $total; changed = $changed; rows = @($counts.Keys | ForEach-Object { $counts[$_] }) }
  if ($Apply -and $changed -gt 0) {
    $out = ($lines | ForEach-Object { $_.Text + $_.Eol }) -join ''
    [IO.File]::WriteAllText($f.FullName, $out, (New-Object System.Text.UTF8Encoding($false)))
  }
}

if ($bad.Count) {
  if ($Json) { [pscustomobject]@{ ok = $false; applied = [bool]$Apply; bad = $bad } | ConvertTo-Json -Depth 4 }
  else { Write-Host "⛔ 有 $($bad.Count) 行不合法，未写任何文件：" -ForegroundColor Red; $bad | ForEach-Object { Write-Host "  ✗ $_" } }
  exit 1
}

$totalRows = ($report | ForEach-Object { $_.lines } | Measure-Object -Sum).Sum
$totalChanged = ($report | ForEach-Object { $_.changed } | Measure-Object -Sum).Sum
if ($Json) {
  [pscustomobject]@{ ok = $true; applied = [bool]$Apply; files = $report.Count; rows = $totalRows; changed = $totalChanged; detail = $report } | ConvertTo-Json -Depth 5
} else {
  Write-Host ''
  Write-Host ('=== snapshots round 迁移（{0}）===' -f $(if ($Apply) { 'APPLY' } else { 'dry-run' })) -ForegroundColor Cyan
  foreach ($r in $report) { Write-Host ('  {0,-22} {1,4} 行 ｜ 补 round {2,4} 行' -f $r.file, $r.lines, $r.changed) }
  Write-Host ('  合计：{0} 文件 ｜ {1} 行 ｜ {2} 行需要补 round' -f $report.Count, $totalRows, $totalChanged) -ForegroundColor $(if ($totalChanged) { 'Yellow' } else { 'Green' })
  if (-not $Apply -and $totalChanged) { Write-Host '  （dry-run，未写盘；确认后加 -Apply）' -ForegroundColor DarkGray }
}
exit 0
