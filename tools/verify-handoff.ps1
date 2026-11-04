# verify-handoff.ps1 — 交接验收：基准声明 vs 实物，逐条机器核对
#
# 为什么需要它：文档会过期，靠人记对不上。
# 2026-10-19：基准从「带日期的交接文档」迁到根目录稳定文件 `验收基准.md`，
#   交接文档可以按日期换名 / 归档，门禁不受影响；同时删掉只对旧交接文档结构有意义的 3 条检查。
#   ⇒ 把"对账"变成可复跑的一条命令 ✓
#
# 用法： pwsh -File .\tools\verify-handoff.ps1
# 退出码：0 全过；1 有不符

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
$docPath = P '验收基准.md'
if (-not (Test-Path $docPath)) { Write-Host '❌ 找不到验收基准：验收基准.md' -ForegroundColor Red; exit 1 }
$doc = [System.IO.File]::ReadAllText($docPath)

$ok = 0; $bad = @()
function Check([string]$label, [bool]$cond, [string]$detail) {
  if ($cond) { $script:ok++; Write-Host ("  ✓ {0}{1}" -f $label, $(if ($detail) { "  （$detail）" } else { '' })) -ForegroundColor Green }
  else { $script:bad += $label; Write-Host ("  ✗ {0}  ← {1}" -f $label, $detail) -ForegroundColor Red }
}

# ---------- A. 数字声明 vs 实测 ----------
$audit = [int][regex]::Match([System.IO.File]::ReadAllText((P '.dsh\skills\github-daily-picks\audit.ps1')), 'TOTAL_CHECKS\s*=\s*(\d+)').Groups[1].Value
$pageKB = [math]::Round((Get-Item (P 'legacy\overview-v5.html')).Length / 1KB, 1)
$genKB = [math]::Round((Get-Item (P 'tools\build-overview.ps1')).Length / 1KB)
$tplKB = [math]::Round(((Get-Item (P 'tools\templates\overview.css')).Length + (Get-Item (P 'tools\templates\overview.js')).Length) / 1KB)
$nProj = (Get-Content (P 'data\projects.jsonl') | Where-Object { $_.Trim() }).Count
$nEv = (Get-Content (P 'data\events.jsonl') | Where-Object { $_.Trim() }).Count
$nRec = @(Get-Content (P 'data\projects.jsonl') | Where-Object { $_ -match '"recommended":true' }).Count
$nIntro = (Get-Content (P 'data\human\repo-intro.jsonl') | Where-Object { $_.Trim() }).Count
$nEnr = (Get-Content (P 'data\enrich\ecosyste.ms.jsonl') | Where-Object { $_.Trim() }).Count
$nMeta = ((Get-ChildItem (P 'data\meta') -Filter '*.jsonl' | ForEach-Object { (Get-Content $_.FullName | Where-Object { $_.Trim() }).Count }) | Measure-Object -Sum).Sum

Write-Host '=== A. 数字声明 vs 实测 ===' -ForegroundColor Cyan
Check ("audit 声明 {0}" -f $audit) ($doc -match ("audit \*\*{0}" -f $audit)) $audit
Check ("页面声明 {0} KB" -f $pageKB) ($doc -match ([regex]::Escape("$pageKB KB"))) $pageKB
Check ("生成器声明 {0} KB" -f $genKB) ($doc -match ("生成器 \*\*{0} KB" -f $genKB)) $genKB
Check ("模板声明 {0} KB" -f $tplKB) ($doc -match ("模板 {0} KB" -f $tplKB)) $tplKB
Check "项目/事件/推荐/人话层/富化/元数据 六项数字" (($doc -match ("项目 \*\*{0}\*\*" -f $nProj)) -and ($doc -match ("事件 \*\*{0}\*\*" -f $nEv)) -and ($doc -match ("推荐 \*\*{0}\*\*" -f $nRec)) -and ($doc -match ("人话层 \*\*{0}\*\*" -f $nIntro)) -and ($doc -match ("富化 \*\*{0}\*\*" -f $nEnr)) -and ($doc -match ("元数据 \*\*{0}" -f $nMeta))) "$nProj/$nEv/$nRec/$nIntro/$nEnr/$nMeta"

# ---------- B. check-page 断言数 ----------
$cp = [System.IO.File]::ReadAllText((P 'tools\check-page.js'))
$uniq = @([regex]::Matches($cp, "log\('([\u2460-\u2473])") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Write-Host '=== B. check-page 断言 ===' -ForegroundColor Cyan
Check ("声明 ①–⑰（实测去重 {0} 个）" -f $uniq.Count) (($doc -match '①–⑰') -and ($uniq.Count -eq 17)) ($uniq.Count)

# ---------- C. 引用路径存在性 ----------
Write-Host '=== C. 引用路径存在性 ===' -ForegroundColor Cyan
$paths = @(
  'tools\rebuild-page.ps1', 'tools\mark-status.ps1', 'tools\backfill-meta.ps1', 'tools\smoke-test.ps1',
  'tools\templates\overview.css', 'tools\templates\overview.js', '刷新页面.cmd', 'THIRD-PARTY.md',
  'assets\anton-latin.woff2', 'data\owner-whitelist.json', 'data\tags-vocabulary.json',
  'tools\check-page.ps1', 'tools\validate-lib.ps1', 'tools\ui-check.ps1', 'tools\check-drift.ps1',
  'tools\history-probe-cdp.js', 'tools\page-smoke-cdp.js',
  'tests\run-tests.ps1', '.dsh\skills\github-daily-picks\audit.ps1', '.dsh\skills\github-daily-picks\CHANGELOG.md',
  'GLOSSARY.md', '日报结构.md', 'tools\term-check.ps1', 'tools\verify-handoff.ps1', 'README.md'
)
$miss = @($paths | Where-Object { -not (Test-Path (P $_)) })
Check "被引用的关键文件都在（$($paths.Count) 个）" ($miss.Count -eq 0) ($miss -join ', ')

# ---------- D. 过期内容扫描 ----------
Write-Host '=== D. 过期内容扫描 ===' -ForegroundColor Cyan
$stale = @(
  @{ p = 'audit \*\*163'; d = 'audit 163' }
  @{ p = 'PASS（14 项）'; d = 'check-page 14 项' }
  @{ p = '566\.8 KB'; d = '页面 566.8 KB' }
  @{ p = '生成器 \*\*25 KB'; d = '生成器 25 KB' }
  @{ p = '余 \*\*204 条\*\*待续采'; d = 'enrich 204 待采' }
  @{ p = 'created_at` 有 \*\*39/229 缺\*\*'; d = 'created_at 39 缺' }
  @{ p = 'mark-researching\.ps1`（把项目一键转'; d = 'mark-researching 未写' }
  @{ p = '模板拆分\*\*（把那段'; d = '模板拆分未做' }
)
$hit = @($stale | Where-Object { $doc -match $_.p })
Check '无过期数字/说法残留' ($hit.Count -eq 0) (($hit | ForEach-Object { $_.d }) -join '; ')

# ---------- E. （已移除）旧交接文档的 §5/§10/§0 结构检查 ----------
# 2026-10-19：这三条只对已归档的旧交接文档有意义；基准迁到根目录 验收基准.md 后删除。
# 删除后验收项数 15 → 12，交接/README 同步。

# ---------- F. 三处口径一致（audit 自己也会查，这里再兜一层）----------
Write-Host '=== F. 计数口径三处一致 ===' -ForegroundColor Cyan
$readme = [System.IO.File]::ReadAllText((P 'README.md'))
$chg = [System.IO.File]::ReadAllText((P '.dsh\skills\github-daily-picks\CHANGELOG.md'))
Check ("README 写 {0} 项" -f $audit) ($readme -match ("{0} 项" -f $audit)) ''
Check ("CHANGELOG 指纹写 {0} 项" -f $audit) ($chg -match ("\| 校验 \| {0} 项全通过" -f $audit)) ''

# ---------- G. 仍属库内专用的工具都登记进 $devOnly（否则 check-drift 会红 ✗）----------
# 2026-10-19：rebuild-page / mark-status 已随发布包（用户写入流程要用），从名单里移出。
Write-Host '=== G. 库内专用工具已登记 $devOnly ===' -ForegroundColor Cyan
$drift = [System.IO.File]::ReadAllText((P 'tools\check-drift.ps1'))
$need = @('backfill-meta.ps1', 'smoke-test.ps1', 'verify-handoff.ps1', 'dupes-probe.ps1')
$notReg = @($need | Where-Object { $drift -notmatch [regex]::Escape("'$_'") })
Check ("$($need.Count) 个库内工具都已登记") ($notReg.Count -eq 0) ($notReg -join ', ')

# ---------- H. 运行层术语检查（2026-10-19：把 term-check 接进门禁）----------
Write-Host '=== H. 运行层术语检查 ===' -ForegroundColor Cyan
$termOut = @()
try {
  $termOut = @(& (P 'tools\term-check.ps1') *>&1)
  $termExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
} catch {
  $termOut = @($_.Exception.Message); $termExit = 1
}
$termLine = @($termOut | Where-Object { $_ -match 'TERM CHECK|旧词|非 SABCD' }) -join ' / '
Check "term-check 通过（运行层 0 旧词）" ($termExit -eq 0) $termLine
# ---------- I. 检索覆盖（2026-10-23 新增：Q 表单一真源 + 覆盖门禁）----------
Write-Host '=== I. 检索覆盖 ===' -ForegroundColor Cyan
$qs = Get-Content (P 'data\queries.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runs = @(Get-ChildItem (P 'data\runs') -Filter '2026-*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
$runDates = @($runs | ForEach-Object { $_.BaseName })
$lastDate = ''
foreach ($d in @($runDates | Sort-Object -Descending)) {
  if (Test-Path (P ("data\raw\{0}" -f $d))) { $lastDate = $d; break }
}
if (-not $lastDate -or $lastDate -lt [string]$qs.enforce_from) {
  Check '检索覆盖（未到 enforce_from，跳过）' $true $(if ($lastDate) { "$lastDate < $($qs.enforce_from)" } else { '' })
} else {
  $covOut = @(& (P 'tools\check-queries.ps1') -Date $lastDate *>&1)
  $covExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
  $covLabel = switch ($covExit) { 0 { 'pass' } 2 { 'warn' } default { 'fail' } }
  $warnOk = $true
  if ($covExit -eq 2) {
    $rp = P "reports\$lastDate.md"
    $warnOk = (Test-Path $rp) -and ([IO.File]::ReadAllText($rp) -match '不完整')
  }
  Check ("检索覆盖 {0}：{1}" -f $lastDate, $covLabel) (($covExit -eq 0) -or ($covExit -eq 2 -and $warnOk)) (($covOut | Select-Object -Last 1))
}


Write-Host ''
$color = if ($bad.Count) { 'Red' } else { 'Green' }
Write-Host ("================ 交接验收：{0} 通过 / {1} 不符 ================" -f $ok, $bad.Count) -ForegroundColor $color
$bad | ForEach-Object { Write-Host ('  ✗ ' + $_) -ForegroundColor Red }
if ($bad.Count) { exit 1 }
exit 0
