# check-drift.ps1 — 库 ↔ 发布包 漂移检查（只读，不写任何文件）
#
# 为什么需要它：同一套脚本曾一度有 4 份拷贝、其中 3 份是旧版，导致
#   · 手工同步 22 个文件；· BOM 被回退；· 第三方会话误报"版本漂移"。
# 规矩：**唯一真源是 `tools\`**；`release\github-daily-picks\` 是"发版产物"，允许比库旧，
#      但**不允许出现"只存在于发布包"的脚本**（那说明有人在发布包里直接改代码）。
#
# 用法：pwsh -File .\tools\check-drift.ps1 [-Json]
# 退出码：0 = 只有"库较新"（正常，等下次发版同步）；1 = 发现异常漂移

param([switch]$Json)

$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$libDir = Join-Path $root 'tools'
$pkg    = Join-Path $root 'release\github-daily-picks'
$pkgDir = Join-Path $pkg 'tools'

# 开发期工具：有意**不进发布包**（发布包要"单文件 HTML + 零依赖 PowerShell"）
# 2026-10-19：用户流程会用到的写入器/重建器/对账器已改为随包，
#   所以 rebuild-page / add-rows / run-manifest / reconcile / mark-status /
#   build-samples / score / validate-lib 都从这里移出（必须真的在包里）。
$devOnly = @(
  'start-site.ps1'  # Local browser launcher; paired with serve-site.py, not a release tool
  'import-local-library.ps1'  # Codex local migration helper; not a release artifact
  'classify-semantic.ps1', 'setup-fastembed.ps1',   # dev-only: P2-5 semantic review (needs Python + fastembed; never ships)
  'code-health.ps1', 'check-drift.ps1', 'make-testcopy.ps1', 'fetch-series.ps1', 'classify-probe.ps1', 'metrics.ps1', 'enrich-ecosyste.ms.ps1',
  '安装开发工具.ps1', 'devtools-init.ps1', 'ui-check.ps1',
  'check-page.ps1'   # 2026-10-19：旧单页检查器，站点版改由 audit 第 22 节承担，不随包
    'backfill-meta.ps1'   # 批次 B：补齐无快照仓库的元数据（联网）；库内专用
    'smoke-test.ps1'      # 功能巡检（工具链层：只读/演练模式跑 31 项）；库内专用
    'verify-handoff.ps1'   # 交接验收（文档声明 vs 实物）；库内专用
    'dupes-probe.ps1'      # P2-4 相似度去重侦察（**只产候选、不改数据**）；库内专用
    'pick-daily-layout.ps1', 'build-sim-daily.ps1'   # 模拟/版式实验生成器；库内专用
    'append-guard.ps1'   # P1：picks/CSV 写前唯一键检查（只读，可选）；库内专用
    'migrate-snapshots-round.ps1'   # P1：快照 round 迁移；库内专用
    'normalize-dates.ps1'   # 2026-10-24：美式日期 → ISO 8601 一次性修复；库内专用
    'term-check.ps1'      # 运行层术语检查；库内专用
    'responsive-probe-cdp.js'  # 2026-10-20：620/打印/reduced-motion 真机验收；库内专用
    'publish-archive.ps1'  # 2026-10-20：本地上线入口（周报/周一页/空白页/首页浮窗）；不随包
    'build-weekly.ps1'  # 2026-10-20：周报页生成器（依赖设计样张模板）；库内专用
    'build-monday.ps1'  # 2026-10-20：周一入口注入；库内专用
    'weekly-check.ps1'  # 2026-10-20：周报巡检（只读）；库内专用
    'fetch-evidence.ps1'  # 2026-10-21：抓 deps.dev/Scorecard 证据；库内专用
    'calibrate.ps1'  # 2026-10-21：黄金集校准；库内专用
    'taxonomy-guard.ps1'  # 2026-10-21：分类四道闸；库内专用
    'discovery-lib.ps1', 'discovery-pool.ps1', 'recall-audit.ps1', 'queue.ps1'  # 2026-10-25：发现层/召回审计；不随包
    'metadata-raw-fill.ps1', 'stageb-sample.ps1', 'discovery-report.ps1', 'frame-sample.ps1', 'frame-estimate.ps1', 'npr-precheck.ps1', 'npr-sample.ps1', 'channel-report.ps1', 'discovery-refresh.ps1', 'check-all.ps1'  # 2026-10-25：元数据/StageB/健康报告/frame/NPR/渠道/刷新；不随包
    'candidate-ledger.ps1', 'collect-daily.ps1', 'daily-maintenance.ps1', 'daily-network.ps1', 'date-utils.ps1', 'editorial-batch.ps1', 'evidence-queue.ps1', 'evidence-store.ps1', 'export-review-bundle.ps1', 'fetch-review-readmes.ps1', 'github-transport.ps1', 'query-partitions.ps1', 'release-readiness.ps1', 'review-compare.ps1', 'review-health.ps1', 'review-metrics.ps1', 'review-workbench.ps1', 'search-scheduler.ps1', 'weekly-utils.ps1', 'workspace-diff.ps1'  # Codex 双宿主新增开发工具；不随包
)

if (-not (Test-Path $pkgDir)) {
  Write-Host "找不到发布包：$pkgDir" -ForegroundColor Red
  exit 1
}

function Get-Lines([string]$p) { (( [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) ) -split "`r?`n").Count }

$lib = @{}
Get-ChildItem $libDir -Filter *.ps1 -File | ForEach-Object { $lib[$_.Name] = $_.FullName }
$pkgFiles = @{}
Get-ChildItem $pkgDir -Filter *.ps1 -File | ForEach-Object { $pkgFiles[$_.Name] = $_.FullName }

$same = @(); $behind = @(); $pkgOnly = @(); $libNotShipped = @()
foreach ($n in ($pkgFiles.Keys | Sort-Object)) {
  if (-not $lib.ContainsKey($n)) { $pkgOnly += $n; continue }
  if ((Get-FileHash $lib[$n]).Hash -eq (Get-FileHash $pkgFiles[$n]).Hash) { $same += $n; continue }
  $ll = Get-Lines $lib[$n]; $pl = Get-Lines $pkgFiles[$n]
  $behind += [pscustomobject]@{ 文件 = $n; 库行 = $ll; 包行 = $pl; 库改时间 = (Get-Item $lib[$n]).LastWriteTime.ToString('MM-dd HH:mm') }
}
foreach ($n in ($lib.Keys | Sort-Object)) {
  if (-not $pkgFiles.ContainsKey($n) -and ($devOnly -notcontains $n)) { $libNotShipped += $n }
}

# 页面模板 / 浮层（2026-10-19 补）：这些也是随包产物，之前只比 .ps1，模板落后不会被发现。
$tplNames = @('daily-layout-c-finsara.html','library-notebook.html','plans-shelf.html','site-shell.html','home-brutal-token.html','_detail.js','_detail.css','templates\sources-queries.md.tpl')
foreach ($n in $tplNames) {
  $lp = Join-Path $libDir $n; $pp = Join-Path $pkgDir $n
  if (-not (Test-Path $lp)) { continue }
  if (-not (Test-Path $pp)) { $libNotShipped += $n; continue }
  if ((Get-FileHash $lp).Hash -eq (Get-FileHash $pp).Hash) { $same += $n; continue }
  $behind += [pscustomobject]@{ 文件 = $n; 库行 = (Get-Lines $lp); 包行 = (Get-Lines $pp); 库改时间 = (Get-Item $lp).LastWriteTime.ToString('MM-dd HH:mm') }
}

$skillLib = Join-Path $root '.dsh\skills\github-daily-picks\audit.ps1'
$skillPkg = Join-Path $pkg '.dsh\skills\github-daily-picks\audit.ps1'
$auditNote = ''
if ((Test-Path $skillLib) -and (Test-Path $skillPkg)) {
  $ln = ([regex]::Match([System.IO.File]::ReadAllText($skillLib, [System.Text.Encoding]::UTF8), 'TOTAL_CHECKS\s*=\s*(\d+)')).Groups[1].Value
  $pn = ([regex]::Match([System.IO.File]::ReadAllText($skillPkg, [System.Text.Encoding]::UTF8), 'TOTAL_CHECKS\s*=\s*(\d+)')).Groups[1].Value
  $auditNote = "库 $ln 项 / 包 $pn 项"
}

# ---------- 依赖检查（2026-10-19）：包内「可执行调用」的目标必须存在 ----------
# 为什么加：发布包曾出现「文档/脚本要求 tools\add-rows.ps1 / rebuild-page.ps1，
#   但这两个文件没随包」的静默缺口；只查"文件是否存在"永远发现不了。
# 口径：只看真正的调用（& (P 'tools\…') / & ".\tools\…" / & (Join-Path … 'tools\…')），
#   跳过注释行；注释里提到 dev-only 工具不算缺失。
$missingRefs = @()
$refPatterns = @(
  '&\s*\(\s*P\s+''([^'']+)''',
  '&\s*"\.\\([^"]+)"',
  '&\s*\(\s*Join-Path[^)]*''([^'']+)'''
)
$scanFiles = @(Get-ChildItem $pkg -Recurse -File -Include *.ps1, *.md -ErrorAction SilentlyContinue)
foreach ($sf in $scanFiles) {
  foreach ($ln in [System.IO.File]::ReadAllLines($sf.FullName, [System.Text.Encoding]::UTF8)) {
    $trim = $ln.Trim()
    if (-not $trim -or $trim.StartsWith('#')) { continue }
    foreach ($pat in $refPatterns) {
      foreach ($m in [regex]::Matches($ln, $pat)) {
        $rel = ($m.Groups[1].Value -replace '/', '\')
        if ($rel -notmatch '^tools\\') { continue }
        if ($rel -match '[$%…<>*]') { continue }
        if (-not (Test-Path (Join-Path $pkg $rel))) {
          $missingRefs += (($sf.FullName.Substring($pkg.Length).TrimStart('\')) + ' -> ' + $rel)
        }
      }
    }
  }
}
$missingRefs = @($missingRefs | Sort-Object -Unique)

if ($Json) {
  [pscustomobject]@{
    一致 = $same.Count
    库较新 = @($behind)
    只在发布包 = @($pkgOnly)
    未随包发布 = @($libNotShipped)
    引用缺失 = @($missingRefs)
    audit口径 = $auditNote
  } | ConvertTo-Json -Depth 5
} else {
  Write-Host ''
  Write-Host '=== 库 ↔ 发布包 漂移检查 ===' -ForegroundColor Cyan
  Write-Host ("  一致: {0} 个 ｜ 库较新: {1} 个 ｜ 只在发布包: {2} 个 ｜ 未随包发布: {3} 个" -f `
    $same.Count, @($behind).Count, @($pkgOnly).Count, @($libNotShipped).Count)
  Write-Host ("  audit 口径: {0}（既有设计：发布包自带一份）" -f $auditNote)

  Write-Host ''
  Write-Host '  ── 库较新（正常：等下次发版同步）──' -ForegroundColor Yellow
  if (@($behind).Count) {
    $behind | ForEach-Object { Write-Host ("    {0,-24} 库 {1,5} 行 ｜ 包 {2,5} 行 ｜ 库改于 {3}" -f $_.文件, $_.库行, $_.包行, $_.库改时间) }
  } else { Write-Host '    （无）' }

  Write-Host ''
  Write-Host '  ── 只在发布包（❗异常：有人在发布包里直接改代码）──' -ForegroundColor Red
  if (@($pkgOnly).Count) { $pkgOnly | ForEach-Object { Write-Host ('    ' + $_) } } else { Write-Host '    （无 ✓）' }

  Write-Host ''
  Write-Host '  ── 未随包发布（如果是有意的，加进本脚本顶部的 $devOnly）──' -ForegroundColor Yellow
  if (@($libNotShipped).Count) { $libNotShipped | ForEach-Object { Write-Host ('    ' + $_) } } else { Write-Host '    （无）' }

  Write-Host ''
  Write-Host '  ── 包内引用缺失（❗脚本/文档要用的 tools 文件不在包里）──' -ForegroundColor Red
  if (@($missingRefs).Count) { $missingRefs | ForEach-Object { Write-Host ('    ' + $_) } } else { Write-Host '    （无 ✓）' }
  Write-Host ''
}

if (@($pkgOnly).Count -gt 0 -or @($libNotShipped).Count -gt 0 -or @($missingRefs).Count -gt 0) { exit 1 } else { exit 0 }
