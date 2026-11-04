# frame-estimate.ps1 — 从 frame 样本估 R_pop（加权 + 两阶段 bootstrap CI，只读）
#
# 用法：.\tools\frame-estimate.ps1 -Date 2026-10-25
# 输入：data/audit/frame/sample-<date>.jsonl（frame-sample.ps1 -Sample 产出）
# 输出：data/audit/frame/estimate-<date>.json + .md
#
# 口径：
#   w_i = pop_n / (P_c * sample_n)
#   R_pop = Σw·I(in_library)/Σw
#   e     = Σw·I(eligible)/Σw
#   R_pop_eligible = R_pop / e
#   CI：band 内按 cell 重抽（细胞选择）+ cell 内按行重抽（个体抽样）；仅覆盖已抽中的 15 格，
#       不能修复未抽中单元/未覆盖 total 的偏差（报告必须写边界）。

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$SampleFile = '',
  [int]$Bootstraps = 2000,
  [int]$Seed = 20261025,
  [string]$Root = (Split-Path -Parent $PSScriptRoot),
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
if (-not $OutDir) { $OutDir = P 'data\audit\frame' }
if (-not $SampleFile) { $SampleFile = Join-Path $OutDir ("sample-{0}.jsonl" -f $Date) }
if (-not (Test-Path $SampleFile)) { Write-Host "✗ 找不到样本：$SampleFile" -ForegroundColor Red; exit 1 }
$rows = @(Read-JsonlSafe $SampleFile)
if (-not $rows.Count) { Write-Host "✗ 样本为空" -ForegroundColor Red; exit 1 }

function Get-W($r) {
  $pop = [double]$r.pop_n; $n = [double]$r.sample_n; $p = [double]$r.P_c
  if ($pop -le 0 -or $n -le 0 -or $p -le 0) { return 0 }
  $inc = Get-PageSampleProbability -Population $pop -Page ([int]$r.page) -SampleN $n -CellProbability $p
  if ($inc -le 0) { return 0 }
  return 1.0 / $inc
}
$rows = @($rows | Where-Object { (Get-W $_) -gt 0 })
if (-not $rows.Count) { Write-Host "✗ 权重全为 0" -ForegroundColor Red; exit 1 }

function Get-Estimate($Rows) {
  $sw = 0.0; $swk = 0.0; $swe = 0.0
  foreach ($r in $Rows) {
    $w = Get-W $r
    $sw += $w
    if ($r.in_library) { $swk += $w }
    if ($r.eligible) { $swe += $w }
  }
  if ($sw -le 0) { return $null }
  return [pscustomobject]@{
    R = $swk / $sw
    eligible = $swe / $sw
    R_eligible = if ($swe -gt 0) { ($swk / $sw) / ($swe / $sw) } else { $null }
  }
}
$point = Get-Estimate $rows

# 设计口径：每个 cell 是一个 PSU；先按 cell 汇总权重，再做 cell 级有效样本量。
# 行级 n_eff 会把同一 cell 内的 20 条当成独立样本，系统性高估精度。
$cellW = @{}
foreach ($r in $rows) {
  $w = Get-W $r
  $key = [string]$r.cell
  if (-not $cellW.ContainsKey($key)) { $cellW[$key] = 0.0 }
  $cellW[$key] += $w
}
$sw = 0.0; $sw2 = 0.0
foreach ($w in $cellW.Values) { $sw += $w; $sw2 += $w * $w }
$nEffCells = if ($sw2 -gt 0) { ($sw * $sw) / $sw2 } else { 0 }
$rowSW = 0.0; $rowSW2 = 0.0
foreach ($r in $rows) { $w = Get-W $r; $rowSW += $w; $rowSW2 += $w * $w }
$nEffRows = if ($rowSW2 -gt 0) { ($rowSW * $rowSW) / $rowSW2 } else { 0 }
$nForCI = [int][Math]::Max(1, [Math]::Round($nEffCells))
$wR = Get-WilsonCI ([double]$point.R) $nForCI
$wE = Get-WilsonCI ([double]$point.eligible) $nForCI
$wRE = if ($null -ne $point.R_eligible) { Get-WilsonCI ([double]$point.R_eligible) $nForCI } else { $null }
$ci = [ordered]@{
  method = 'Wilson on cell-level effective n (PSU=cell)'
  n_eff_cells = [math]::Round($nEffCells, 1)
  n_eff_rows = [math]::Round($nEffRows, 1)
  R_low = $wR.low; R_high = $wR.high
  eligible_low = $wE.low; eligible_high = $wE.high
  R_eligible_low = if ($wRE) { $wRE.low } else { $null }
  R_eligible_high = if ($wRE) { $wRE.high } else { $null }
}

$byBand = @()
foreach ($band in @($rows | Group-Object band | Sort-Object Name | ForEach-Object { $_.Name })) {
  $br = @($rows | Where-Object { $_.band -eq $band })
  $e = Get-Estimate $br
  $byBand += [ordered]@{
    band = $band; n = $br.Count
    R_pop = [math]::Round($e.R, 4); eligible = [math]::Round($e.eligible, 4)
    R_eligible = if ($null -ne $e.R_eligible) { [math]::Round($e.R_eligible, 4) } else { $null }
  }
}
$out = [ordered]@{
  date = $Date; sample = $rows.Count; cells = @($rows | Group-Object cell).Count
  R_pop = [math]::Round($point.R, 4)
  eligible = [math]::Round($point.eligible, 4)
  R_pop_eligible = if ($null -ne $point.R_eligible) { [math]::Round($point.R_eligible, 4) } else { $null }
  ci95 = $ci
  by_band = $byBand
  boundary = '仅覆盖抽中的 15 格；stars<200、2015 前不在 frame；PSU=cell，CI 不含未抽中单元的偏差'
  generated_at = (Get-Date).ToString('o')
}
$jsonPath = Join-Path $OutDir ("estimate-{0}.json" -f $Date)
[IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

$md = @()
$md += "# frame 估计 · $Date"
$md += ""
$md += ("- 样本：{0} 条 / {1} 格 ｜ n_eff(cell) {2} ｜ n_eff(row) {3}" -f $rows.Count, $out.cells, $ci.n_eff_cells, $ci.n_eff_rows)
$md += ("- **R_pop：{0:P1}**（95% CI {1:P1}–{2:P1}，{3}）" -f $point.R, $ci.R_low, $ci.R_high, $ci.method)
$md += ("- 资格率：{0:P1}（{1:P1}–{2:P1}）" -f $point.eligible, $ci.eligible_low, $ci.eligible_high)
if ($null -ne $point.R_eligible) { $md += ("- 合格总体 R_pop：{0:P1}" -f $point.R_eligible) }
$md += ""
$md += "| 星段 | 样本 | R_pop | 资格率 |"
$md += "|---|---:|---:|---:|"
foreach ($x in $byBand) { $md += ("| {0} | {1} | {2:P1} | {3:P1} |" -f $x.band, $x.n, $x.R_pop, $x.eligible) }
$md += ""
$md += "> 边界：仅覆盖抽中的格；stars<200、2015 前不在 frame；PSU=cell，CI 不含未抽中单元的偏差。R_pop 此处是历史字段名，统计的是在库占比，不是优质项目召回率。"
$mdPath = Join-Path $OutDir ("estimate-{0}.md" -f $Date)
[IO.File]::WriteAllText($mdPath, ($md -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host ("✓ R_pop {0:P1} ｜ 95% CI {1:P1}–{2:P1} ｜ {3}" -f $point.R, $ci.R_low, $ci.R_high, $jsonPath) -ForegroundColor Green
exit 0
