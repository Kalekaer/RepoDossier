# smoke-test.ps1 — 功能巡检（工具链层）：把每个工具用它**安全的模式**真跑一遍，并断言输出里的预期标志
#
# 为什么需要它：`audit.ps1` 查"文档/数据/页面是否自相矛盾"，**不查"工具还能不能跑"** ✗ → 本脚本补这一层
#
# 三条硬约束（都是实测踩出来的）：
#   1. **同进程调用**：沙箱下起不了子进程（`pwsh` 子进程一律"拒绝访问" ✗）→ 用 `& 脚本` 而不是 `pwsh -File`
#   2. **参数用 scriptblock 绑定**：`& $path @arr` 的 splat 在本机反复把 `-List` 当位置参数 ✗
#      → 每个用例写 `sb = { param($p) & $p -List }`，**解析期就绑好**，不进字符串解析 ✓
#   3. **每项前清 `$LASTEXITCODE`**：它是有粘性的（上一个脚本的码会串到下一项 ✗）
#
# 用法： pwsh -File .\tools\smoke-test.ps1              # 全部
#        pwsh -File .\tools\smoke-test.ps1 -Only chain   # 只跑某一组（tools/func/chain/audit）
# 不在此脚本内的（都需真机浏览器 + 放开权限，沙箱内跑不起来 ⇒ 不进巡检，避免把环境限制当成失败）：
#   · tools\history-probe-cdp.js（真机路由探针，14/14 ✓）—— 已由 check-page.ps1 -Real 包装（E-3，2026-10-17）✓
#   · tools\page-smoke-cdp.js（页面功能巡检 21～22 项）—— **已修好并接进 `check-page -Real`** ✓（2026-10-17；原「前 5 项后静默退出」是探针缺异常兜底 + 断言写死项目，见 CHANGELOG [4.10.25]）
# 退出码：0 全过；1 有失败

param(
  [string]$Only = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }

$cases = @(
  @{ n = 'mark-status -List';      g = 'tools'; s = 'tools\mark-status.ps1';   sb = { param($p) & $p -List };  e = '台账状态现状' }
  @{ n = 'workspace -List';        g = 'tools'; s = 'tools\workspace.ps1';     sb = { param($p) & $p -List };  e = '.' }
  @{ n = 'backfill-meta -List';    g = 'tools'; s = 'tools\backfill-meta.ps1'; sb = { param($p) & $p -List };  e = '快照' }
  @{ n = 'enrich -DryRun';         g = 'tools'; s = 'tools\enrich-ecosyste.ms.ps1'; sb = { param($p) & $p -DryRun }; e = '富化|目标' }
  @{ n = 'fetch-series -DryRun';   g = 'tools'; s = 'tools\fetch-series.ps1';  sb = { param($p) & $p -DryRun }; e = '.' }
  @{ n = 'verify-handoff（交接验收）'; g = 'tools'; s = 'tools\verify-handoff.ps1'; sb = { param($p) & $p }; e = '交接验收' }
  @{ n = 'check-config';           g = 'tools'; s = 'tools\check-config.ps1';  sb = { param($p) & $p };         e = '.' }
  @{ n = 'validate-lib';           g = 'tools'; s = 'tools\validate-lib.ps1';  sb = { param($p) & $p };         e = '违规' }
  @{ n = 'check-drift';            g = 'tools'; s = 'tools\check-drift.ps1';   sb = { param($p) & $p };         e = '一致' }
  @{ n = 'ui-check';               g = 'tools'; s = 'tools\ui-check.ps1';      sb = { param($p) & $p };         e = '违规' }
  @{ n = 'check-page';             g = 'tools'; s = 'tools\check-page.ps1';    sb = { param($p) & $p };         e = 'PAGE CHECK' }
  @{ n = 'check-page -Real（真机层）'; g = 'tools'; s = 'tools\check-page.ps1'; sb = { param($p) & $p -Real }; e = '真机层 \d+ 项全过|REAL: SKIP' }
  @{ n = 'dupes-probe（相似度侦察）'; g = 'tools'; s = 'tools\dupes-probe.ps1'; sb = { param($p) & $p }; e = '相似度去重侦察' }
  @{ n = 'code-health';            g = 'tools'; s = 'tools\code-health.ps1';   sb = { param($p) & $p };         e = '.' }
  @{ n = 'metrics';                g = 'tools'; s = 'tools\metrics.ps1';       sb = { param($p) & $p };         e = '.' }
  @{ n = 'intake-check（只读）';   g = 'tools'; s = 'tools\intake-check.ps1';  sb = { param($p) & $p };         e = '.' }
  @{ n = 'auto-tag（只读）';       g = 'tools'; s = 'tools\auto-tag.ps1';      sb = { param($p) & $p };         e = '.' }
  @{ n = 'suggest-terms（只读）';  g = 'tools'; s = 'tools\suggest-terms.ps1'; sb = { param($p) & $p };         e = '.' }
  @{ n = 'suggest-plans（只读）';  g = 'tools'; s = 'tools\suggest-plans.ps1'; sb = { param($p) & $p };         e = '.' }
  @{ n = 'gaps';                   g = 'tools'; s = 'tools\gaps.ps1';          sb = { param($p) & $p };         e = '.' }
  @{ n = 'humanize-next';          g = 'tools'; s = 'tools\humanize-next.ps1'; sb = { param($p) & $p };         e = '.' }
  @{ n = 'daily-questions';        g = 'tools'; s = 'tools\daily-questions.ps1'; sb = { param($p) & $p };       e = '.' }
  @{ n = 'classify-probe';         g = 'tools'; s = 'tools\classify-probe.ps1'; sb = { param($p) & $p };        e = '.' }
  # 需要参数的工具：**给真参数**，断言真有结果（只打印用法不算过 ✓）
  @{ n = 'query -Text AI';         g = 'func';  s = 'tools\query.ps1';    sb = { param($p) & $p -Text 'AI' };                     e = 'AI|/|命中' }
  @{ n = 'compose -Need 做视频';   g = 'func';  s = 'tools\compose.ps1';  sb = { param($p) & $p -Need '做视频' };                  e = '.' }
  @{ n = 'compare 两个真实项目';   g = 'func';  s = 'tools\compare.ps1';  sb = { param($p) & $p 'pre-commit/pre-commit' 'orhun/git-cliff' }; e = 'pre-commit|git-cliff' }
  @{ n = 'score 库（dot-source）'; g = 'func';  s = 'tools\score.ps1';    sb = { param($p) . $p; $c = Get-Criteria; 'criteria 键: ' + (($c.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') }; e = 'criteria 键' }
  # 重建链（写盘但幂等：投影 + 页面；页面本来就要跟数据一致 ✓）
  @{ n = 'sync-projects';          g = 'chain'; s = 'tools\sync-projects.ps1';  sb = { param($p) & $p }; e = 'projects.jsonl|输入未变化' }
  @{ n = 'build-overview';         g = 'chain'; s = 'tools\build-overview.ps1'; sb = { param($p) & $p }; e = '已生成' }
  @{ n = 'rebuild-page（统一入口）'; g = 'chain'; s = 'tools\rebuild-page.ps1'; sb = { param($p) & $p }; e = '页面已重建|输入未变化|无需重建' }
  @{ n = 'audit（166 项）';        g = 'audit'; s = '.dsh\skills\github-daily-picks\audit.ps1'; sb = { param($p) & $p }; e = '结果：\d+ 通过' }
)

$pass = 0; $fail = @(); $warn = @()
$selected = @($cases | Where-Object { -not $Only -or $_.g -eq $Only -or $_.n -match $Only })
Write-Host ("=== 功能巡检（工具链）· 共 {0} 项 ===" -f $selected.Count) -ForegroundColor Cyan
Write-Host ''

foreach ($c in $selected) {
  $out = ''; $exit = 0
  $global:LASTEXITCODE = 0                       # 清粘性退出码 ✗（否则上一项的码会串味）
  $path = P $c.s
  if (-not (Test-Path $path)) { $fail += "$($c.n)：脚本不存在"; Write-Host ("  ✗ {0}：脚本不存在" -f $c.n) -ForegroundColor Red; continue }
  try {
    $out = (& $c.sb $path *>&1 | Out-String)     # scriptblock 在解析期绑定参数 ✓ 不走 splat ✗
    $exit = $LASTEXITCODE
  } catch {
    $fail += "$($c.n)：执行异常 $($_.Exception.Message.Split([char]10)[0])"
    Write-Host ("  ✗ {0}：执行异常" -f $c.n) -ForegroundColor Red
    continue
  }
  $hit = if ($c.e -eq '.') { $out.Trim().Length -gt 0 } else { $out -match $c.e }
  # chain/func 组要求 exit=0；tools 组里"发现问题"的检查器本来就该非 0（audit / validate-lib / check-* ）
  $exitOk = if ($c.g -in @('chain', 'func')) { $exit -eq 0 } else { $true }
  if ($hit -and $exitOk) {
    $pass++; Write-Host ("  ✓ {0,-26} exit={1}  标志命中" -f $c.n, $exit) -ForegroundColor Green
  } elseif ($hit) {
    $warn += "$($c.n)：输出正常但 exit=$exit"; Write-Host ("  ⚠ {0,-26} exit={1}（非 0，需人工看）" -f $c.n, $exit) -ForegroundColor Yellow
  } else {
    $tail = (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' / ')
    $fail += "$($c.n)：未见预期标志「$($c.e)」（exit=$exit；尾部：$tail）"
    Write-Host ("  ✗ {0,-26} exit={1}  未命中「{2}」" -f $c.n, $exit, $c.e) -ForegroundColor Red
  }
}

Write-Host ''
Write-Host ("================ 工具链巡检：{0} 通过 / {1} 失败 / {2} 需人工 ================" -f $pass, $fail.Count, $warn.Count) `
  -ForegroundColor $(if ($fail.Count) { 'Red' } elseif ($warn.Count) { 'Yellow' } else { 'Green' })
$fail | ForEach-Object { Write-Host ('  ✗ ' + $_) -ForegroundColor Red }
$warn | ForEach-Object { Write-Host ('  ⚠ ' + $_) -ForegroundColor Yellow }
if ($fail.Count) { exit 1 }
exit 0
