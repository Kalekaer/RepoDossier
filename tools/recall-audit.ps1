# recall-audit.ps1 — 召回审计（只读）：池内 known_share / yield_new / 分层 / 漏检
#
# 用法：
#   .\tools\recall-audit.ps1 -Date 2026-10-25
#   .\tools\recall-audit.ps1 -Date 2026-10-25 -StageB data\audit\stageb\2026-10-25.jsonl
#
# 说明：
#   - known_share 是「池内已有比例」，不是总体召回；总体 R_pop 需 frame 抽样（P2）。
#   - StageB 只报「池内样本里未被发现的 S/A」，不冒充总体 S/A 召回。
# 退出码：0；1 池缺失；2 数据不合法

param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$PoolFile = '',
  [string]$StageB = '',
  [string]$OutDir = '',
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
if (-not $OutDir) { $OutDir = P 'data\audit\recall' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not $PoolFile) { $PoolFile = P ("data\audit\pool\{0}.jsonl" -f $Date) }
if (-not (Test-Path $PoolFile)) { Write-Host "✗ 找不到池：$PoolFile" -ForegroundColor Red; exit 1 }

$rows = Read-JsonlSafe $PoolFile
if (-not $rows.Count) { Write-Host "✗ 池为空" -ForegroundColor Red; exit 2 }
$eligible = @($rows | Where-Object { $_.eligible })
$known = @($eligible | Where-Object { $_.in_library })
$missing = @($eligible | Where-Object { -not $_.in_library })
$share = if ($eligible.Count) { [math]::Round($known.Count / [double]$eligible.Count, 4) } else { 0 }

$layers = [ordered]@{}
foreach ($g in @($eligible | Group-Object layer)) {
  $k = @($g.Group | Where-Object { $_.in_library }).Count
  $layers[$g.Name] = [ordered]@{ eligible = $g.Count; known = $k; known_share = [math]::Round($k / [double]$g.Count, 4) }
}

$stage = $null
if ($StageB -and (Test-Path $StageB)) {
  $s = @(Read-JsonlSafe $StageB)
  $sMiss = @($s | Where-Object { $_.tier -in @('S', 'A') })
  $stage = [ordered]@{
    sample = $s.Count
    missed_SA = $sMiss.Count
    missed_SA_share = if ($s.Count) { [math]::Round($sMiss.Count / [double]$s.Count, 4) } else { 0 }
    note = '池内样本，不是总体 S/A 召回'
  }
}

$out = [ordered]@{
  date = $Date
  pool = $rows.Count
  eligible = $eligible.Count
  in_library = $known.Count
  known_share = $share
  yield_new = [math]::Round(1 - $share, 4)
  layers = $layers
  missing_top = @($missing | Sort-Object stars -Descending | Select-Object -First 20 | ForEach-Object { $_.id })
  stageb = $stage
  generated_at = (Get-Date).ToString('o')
}
$jsonPath = Join-Path $OutDir ("{0}.json" -f $Date)
[IO.File]::WriteAllText($jsonPath, ($out | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

$md = @()
$md += "# 召回审计 · $Date"
$md += ""
$md += ("- 池：{0} ｜ 合格：{1} ｜ 在库：{2}" -f $rows.Count, $eligible.Count, $known.Count)
$md += ("- known_share：{0:P1} ｜ yield_new：{1:P1}" -f $share, (1 - $share))
$md += ""
$md += "| 层 | 合格 | 在库 | known_share |"
$md += "|---|---:|---:|---:|"
foreach ($k in $layers.Keys) { $md += ("| {0} | {1} | {2} | {3:P1} |" -f $k, $layers[$k].eligible, $layers[$k].known, $layers[$k].known_share) }
if ($stage) { $md += ""; $md += ("Stage B：样本 {0} ｜ 未见 S/A {1}（{2:P1}，池内样本）" -f $stage.sample, $stage.missed_SA, $stage.missed_SA_share) }
$md += ""
$md += "> known_share 是渠道产出里的在库比例；frame 的在库占比也不是优质项目召回。总体质量召回需要独立抽样框和质量标签。"
$mdPath = Join-Path $OutDir ("{0}.md" -f $Date)
[IO.File]::WriteAllText($mdPath, ($md -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("✓ {0} 条 ｜ 合格 {1} ｜ known_share {2:P1} ｜ 漏检 {3}" -f $rows.Count, $eligible.Count, $share, $missing.Count) -ForegroundColor Green
Write-Host ("  -> {0}" -f $jsonPath)
exit 0
