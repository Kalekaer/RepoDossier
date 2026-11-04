# pick-daily-layout.ps1 -- 按日期挑一套日报版面（换骨）
# 确定性：同一天 → 同一个版面（重渲染不会改历史）；换天自动换。
# 2026-10-18：回滚到改动前行为：C/D 按日轮换（今天 10-18 = C）。
# 用法：.\pick-daily-layout.ps1 [-Date 2026-10-16] [-Pool c]
param(
  [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
  [string[]]$Pool = @('c')
)
$d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$dayIndex = [int][Math]::Floor(($d - [datetime]'2026-01-01').TotalDays)
$idx = (($dayIndex % $Pool.Count) + $Pool.Count) % $Pool.Count
$pick = $Pool[$idx]
Write-Output ('date=' + $Date + '  layout=' + $pick + '  (pool: ' + ($Pool -join ',') + ')')
