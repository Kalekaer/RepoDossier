# metrics.ps1 — P1-5 四个质量指标（读 data/，只读；黄金集未标注时给出"代理口径"并明确标注）
#
# 用法：pwsh -File .\tools\metrics.ps1 [-Json]
# 退出码：恒为 0（这是度量工具，不是门禁）；门禁在 audit。

param([switch]$Json)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$proj = @(Get-Content (Join-Path $root 'data\projects.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$gsPath = Join-Path $root 'data\golden-set.jsonl'
$gs = @()
if (Test-Path $gsPath) { $gs = @(Get-Content $gsPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) }
$labeled = @($gs | Where-Object { $_.human -and ([string]$_.human).Trim() })
$agentL  = @($gs | Where-Object { -not ($_.human -and ([string]$_.human).Trim()) -and $_.agent })
$useField = if ($labeled.Count -gt 0) { 'human' } elseif ($agentL.Count -gt 0) { 'agent' } else { '' }
$口径 = switch ($useField) { 'human' { '人工标注（独立）' } 'agent' { '自标（**非独立**，仅自洽性检查）' } default { '未标注' } }
$byId = @{}; foreach ($g in $gs) { $byId[$g.id] = $g }

# ① precision@8：每天前 8（按档位+分数）里，被标为 🔥/👍 的比例
$ranked = @($proj | Where-Object { $_.tier -in @('S','A','B') } | Sort-Object @{e={switch([string]$_.tier){'S'{0}'A'{1}default{2}}}}, @{e={-[int]$_.score}} | Select-Object -First 8)
$p8hit = @($ranked | Where-Object { $byId.ContainsKey($_.id) -and ([string]$byId[$_.id].$useField) -match '🔥|👍|必须|值得' }).Count
$p8 = if ($useField) { [math]::Round(100.0 * $p8hit / [Math]::Max(1,$ranked.Count), 1) } else { $null }

# ② 新星命中率（代理口径）：Δ7d ≥100 的项目里，first_seen 早于其"爆发"（用 first_stars 远低于当前判断）
$hot = @($proj | Where-Object { $_.stars -and $null -ne $_.stars.delta_7d -and [int]$_.stars.delta_7d -ge 100 })
$early = @($hot | Where-Object { $_.stars.first -and [int]$_.stars.first -lt [int]$_.stars.current -and ([int]$_.stars.delta_7d -ge [int]$_.stars.first) })
$newstar = if ($hot.Count -gt 0) { [math]::Round(100.0 * $early.Count / $hot.Count, 1) } else { $null }

# ③ 误杀率：被 dropped 后仍大涨（当前星数 ≥ 5×首次）
$dropped = @($proj | Where-Object { $_.status -eq 'dropped' })
$killed = @($dropped | Where-Object { $_.stars.first -and [int]$_.stars.first -gt 0 -and [int]$_.stars.current -ge 5 * [int]$_.stars.first })
$killRate = if ($dropped.Count -gt 0) { [math]::Round(100.0 * $killed.Count / $dropped.Count, 1) } else { $null }

# ④ 垃圾率：入库后被用户判定踢出（origin=user 且 dropped，或 note 含"用户…判定"）
$userIn = @($proj | Where-Object { $_.origin -eq 'user' })
$userDropped = @($userIn | Where-Object { $_.status -eq 'dropped' -or ([string]$_.drop_reason) -match '用户.*(判定|踢出)' })
$junkRate = if ($userIn.Count -gt 0) { [math]::Round(100.0 * $userDropped.Count / $userIn.Count, 1) } else { $null }

$rep = [ordered]@{
  生成时间 = (Get-Date -Format 's')
  黄金集 = @{ 总数 = $gs.Count; 已人工标注 = $labeled.Count; 口径 = $口径 }
  'precision@8' = @{ 值 = $p8; 说明 = '前 8 条里被标为 🔥/👍 的比例（黄金集未标注时为 null）'; 命中 = $p8hit; 样本 = $ranked.Count }
  新星命中率 = @{ 值 = $newstar; 说明 = '代理口径：Δ7d≥100 且首见星数远低于当前（快照窗口不足，属代理）'; 样本 = $hot.Count }
  误杀率 = @{ 值 = $killRate; 说明 = '被淘汰后仍涨 ≥5 倍'; 误杀 = $killed.Count; 样本 = $dropped.Count }
  垃圾率 = @{ 值 = $junkRate; 说明 = '用户入库后被判定踢出的比例'; 踢出 = $userDropped.Count; 样本 = $userIn.Count }
}
if ($Json) { $rep | ConvertTo-Json -Depth 5; exit 0 }
Write-Host ''
Write-Host '=== 质量指标（P1-5）===' -ForegroundColor Cyan
Write-Host ('  黄金集：{0} 条 ｜ 已标注 {1} 条 ｜ 口径：{2}' -f $gs.Count, $labeled.Count, $rep.黄金集.口径)
foreach ($k in 'precision@8','新星命中率','误杀率','垃圾率') {
  $v = $rep.$k.值
  $txt = if ($null -eq $v) { '—（黄金集未标注）' } else { ($v.ToString() + ' %') }
  Write-Host ('  {0,-14} {1,-16} {2}' -f $k, $txt, $rep.$k.说明) -ForegroundColor Gray
}
Write-Host ''
Write-Host '  怎么标注：编辑 data\golden-set.jsonl，把每行的 "human" 填成 🔥必须推 / 👍值得入库 / 😐留观 / 🗑应淘汰' -ForegroundColor DarkGray
exit 0