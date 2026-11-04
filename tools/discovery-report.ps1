# discovery-report.ps1 — 周报「发现健康」一页（只读，写 data/audit/health-<date>.md）
param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
function P([string]$rel) { Join-Path $Root $rel }
. (Join-Path $PSScriptRoot 'discovery-lib.ps1')
$recallPath = P ("data\audit\recall\{0}.json" -f $Date)
if (-not (Test-Path $recallPath)) { Write-Host "✗ 先跑 recall-audit -Date $Date" -ForegroundColor Red; exit 1 }
$r = Get-Content $recallPath -Raw -Encoding UTF8 | ConvertFrom-Json
$q = @(Read-JsonlSafe (P 'data\candidates.jsonl'))
$counts = @{}
foreach ($x in $q) { $counts[$x.state] = 1 + [int]$counts[$x.state] }
$projs = @(Read-JsonlSafe (P 'data\projects.jsonl'))
$missCreated = @($projs | Where-Object { -not $_.stars.created_at }).Count
$missPushed = @($projs | Where-Object { -not $_.pushed_at }).Count
$missLicense = @($projs | Where-Object { -not $_.license }).Count

$md = @()
$md += "# 发现健康 · $Date"
$md += ""
$md += ("- 池：{0} ｜ 合格：{1} ｜ 在库：{2} ｜ **known_share {3:P1}** ｜ 新产出 {4:P1}" -f $r.pool, $r.eligible, $r.in_library, $r.known_share, $r.yield_new)
$md += ""
$md += "| 层 | 合格 | 在库 | known_share |"
$md += "|---|---:|---:|---:|"
foreach ($k in $r.layers.PSObject.Properties.Name) {
  $l = $r.layers.$k
  $md += ("| {0} | {1} | {2} | {3:P1} |" -f $k, $l.eligible, $l.known, $l.known_share)
}
$md += ""
$md += ("- 队列：" + (($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
$sbPath = P ("data\audit\stageb\{0}.jsonl" -f $Date)
if (Test-Path $sbPath) {
  $sb = @(Read-JsonlSafe $sbPath)
  $sa = @($sb | Where-Object { $_.tier -in @('S', 'A') }).Count
  $md += ("- Stage B：样本 {0} ｜ 未见 S/A {1}（{2:P1}，池内样本，不是总体）" -f $sb.Count, $sa, ($sa / [double]$sb.Count))
}
$md += ("- 元数据缺失：created {0}/{1}（{2:P0}）｜ pushed {3}/{1} ｜ license {4}/{1}" -f $missCreated, $projs.Count, ($missCreated / [double]$projs.Count), $missPushed, $missLicense)
$md += ""
$md += "> known_share 是「渠道产出里已有比例」，不是总体召回；R_pop 需 frame 抽样（P2）。"
$out = P ("data\audit\health-{0}.md" -f $Date)
[IO.File]::WriteAllText($out, ($md -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("✓ {0}" -f $out) -ForegroundColor Green
exit 0
