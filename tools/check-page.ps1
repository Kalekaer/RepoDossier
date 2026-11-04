# check-page.ps1 — 真跑一遍 legacy\overview-v5.html（旧版工具库）的内嵌 JS
#
# 为什么需要：单文件页面 JS 出错时**页面照常渲染**，只有点击才暴露。
# 2026-10-13「卡片点不了」就是这类问题（数据里混进 [null] → detail() 抛 TypeError）。
# 语法检查、数据检查都抓不到，只有真执行才行。
#
# 两层证据：
#   ① 桩 DOM 层（**默认**）：极简 DOM 桩 + 真跑页面 JS，断言 ①–⑰ —— 快、沙箱内可跑 ✓
#   ② 真机层（**加 `-Real` 才跑**，E-3 于 2026-10-17 合入；2026-10-18 加新站点）：真 Edge + CDP **三个探针**
#      · `tools\history-probe-cdp.js` —— 旧版路由/历史 14 项（真鼠标点导航、**真浏览器前进/后退**、筛选进 URL）
#      · `tools\page-smoke-cdp.js`    —— 旧版页面功能 22 项（首屏/KPI/搜索空态/分类/徽章/排序/详情+适合谁/方案/工作区/图例/键盘/对比/图表/外部请求/溢出/控制台）
#      · `tools\site-smoke-cdp.js`    —— **新站点** 30 项（shell 5 路由 + 首页 4 点击 + 5 页直载 + 控制台/溢出/性能）
#      ⚠️ 沙箱内 Chromium 起不来（mojo 命名管道被拒 → debug.log 报 crashpad 拒绝访问）⇒ 只能给 SKIP，
#         要真跑得**一次性放开权限**，或在普通桌面会话里执行（见交接文档 §6）。三个探针合计约 40～60s。
#
# 用法：
#   & ".\tools\check-page.ps1"                  # 只跑桩 DOM 层
#   & ".\tools\check-page.ps1" -Real            # 跑完桩层，再追加真机层（路由 + 页面功能）
#   & ".\tools\check-page.ps1" -Real -RealPort 9411
# 退出码：0 = PASS ｜ 1 = FAIL（页面/探针真有问题）｜ 2 = 环境不可用（-Real 但浏览器起不来，**不是页面缺陷**）
#
# ⚠️ 判据是**输出文件**，不是退出码：实测 `Start-Process -PassThru -Wait` 调 DSH Desktop.exe 时
#    `$p.ExitCode` 为 `$null`（GUI 子系统程序）⇒ 与踩坑 #24 同族：以输出里的成功标志为主判据 ✓
#
# JS 运行时优先级：PATH 里的 node → DSH 自带的 Electron（ELECTRON_RUN_AS_NODE=1 当 Node 用）
# 注意：本机 shell 连不通网络与此无关；这里只做本地文件求值。

param(
  [switch]$Real,
  [int]$RealPort = 9411
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }

# Electron 每次启动都会在 CWD 写 crashpad 日志（debug.log）—— 运行期垃圾。
# **每个出口都要清** ✓（原来那句写在 `exit` 之后 = 死代码、从未执行过 ✗ 2026-10-17 修）
function Clear-CrashpadLog { Remove-Item (P 'debug.log') -Force -ErrorAction SilentlyContinue }
Clear-CrashpadLog

$ovPath = P 'legacy\overview-v5.html'
if (-not (Test-Path $ovPath)) { Write-Host "❌ 找不到 legacy\overview-v5.html，先跑 build-overview.ps1" -ForegroundColor Red; exit 1 }

# 抽出内嵌 JS
$html = Get-Content $ovPath -Raw -Encoding UTF8
$m = [regex]::Match($html, '(?s)<script>(.*)</script>')
if (-not $m.Success) { Write-Host "❌ 页面里找不到 <script> 块" -ForegroundColor Red; exit 1 }

$tmp = P 'data\_tmp'
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
$pageJs = Join-Path $tmp 'page.js'
$resFile = Join-Path $tmp 'check-page-result.txt'
$harness = P 'tools\check-page.js'
[System.IO.File]::WriteAllText($pageJs, $m.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
Remove-Item $resFile -ErrorAction SilentlyContinue

# 找 JS 运行时
$node = Get-Command node -ErrorAction SilentlyContinue
$exe = $null; $useElectron = $false
if ($node) { $exe = $node.Source }
else {
  foreach ($cand in @("$env:ProgramFiles\DSH Desktop\DSH Desktop.exe", 'E:\DSH Desktop\DSH Desktop.exe', "${env:LOCALAPPDATA}\Programs\DSH Desktop\DSH Desktop.exe")) {
    if ($cand -and (Test-Path $cand)) { $exe = $cand; $useElectron = $true; break }
  }
}
if (-not $exe) { Write-Host "❌ 没有可用的 JS 运行时（既没有 node，也没找到 DSH Desktop.exe）" -ForegroundColor Red; exit 1 }

if ($useElectron) {
  # Electron 是 GUI 子系统程序：用 `&` 调用时，只要外层再套一层管道/重定向，
  # PowerShell 就会报「StandardOutputEncoding is only supported when standard output is redirected」。
  # 用 Start-Process 起独立进程，彻底避开标准流接管问题（子进程自己写结果文件）。
  $env:ELECTRON_RUN_AS_NODE = '1'
  try {
    Start-Process -FilePath $exe -ArgumentList @($harness, $pageJs, $resFile) -NoNewWindow -Wait
  } finally {
    Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  }
} else {
  & $exe $harness $pageJs $resFile
}
Start-Sleep -Seconds 2

if (-not (Test-Path $resFile)) {
  Write-Host "❌ 检查未产出结果（运行时启动失败？）" -ForegroundColor Red
  Clear-CrashpadLog; exit 1
}

# ---------- ① 桩 DOM 层 ----------
$lines = Get-Content $resFile -Encoding UTF8
$lines | ForEach-Object { Write-Host "  $_" }
$verdict = ($lines | Where-Object { $_ -match '^RESULT:' } | Select-Object -Last 1)
$stubPass = ($verdict -match 'PASS')
Write-Host ""
if (-not $stubPass) {
  Write-Host "PAGE CHECK: FAIL —— 见上面 ❌ 行" -ForegroundColor Red
  Clear-CrashpadLog; exit 1
}
Write-Host "PAGE CHECK: PASS（桩 DOM 层 ①–⑰）—— 卡片可点、筛选可用、数据无 null 元素" -ForegroundColor Green

if (-not $Real) { Clear-CrashpadLog; exit 0 }

# ---------- ② 真机层（E-3）：两个探针 ----------
# 注意：两个探针的 argv 约定**不一样**（history 是「输出在前」、page-smoke 是「页面在前」✗ 曾因传错顺序覆盖过页面）
$probes = @(
  @{ n = '路由/历史'; js = 'tools\history-probe-cdp.js'; out = 'data\_tmp\check-page-real-route.json'; port = $RealPort
     build = { param($js, $out, $page, $port) @($js, $out, $page, "$port") } }
  @{ n = '页面功能'; js = 'tools\page-smoke-cdp.js';     out = 'data\_tmp\check-page-real-page.json';  port = 9501
     build = { param($js, $out, $page, $port) @($js, $page, $out) } }
  @{ n = '新站点'; js = 'tools\site-smoke-cdp.js';       out = 'data\_tmp\site-smoke-cdp.json';        port = 9502
     build = { param($js, $out, $page, $port) @($js) } }
)

Write-Host ""
Write-Host "=== 真机层（真 Edge + CDP）===" -ForegroundColor Cyan
$realPass = 0; $realFail = 0; $realSkip = @()

foreach ($pr in $probes) {
  $jsPath = P $pr.js
  $outPath = P $pr.out
  Write-Host ("--- {0}：{1} ---" -f $pr.n, $pr.js) -ForegroundColor DarkCyan
  if (-not (Test-Path $jsPath)) {
    Write-Host ("    ✗ 找不到探针 {0}" -f $pr.js) -ForegroundColor Red
    $realFail++; continue
  }
  Remove-Item $outPath -Force -ErrorAction SilentlyContinue
  $probeArgs = @(& $pr.build $jsPath $outPath $ovPath $pr.port)
  try {
    if ($useElectron) {
      $env:ELECTRON_RUN_AS_NODE = '1'
      try { Start-Process -FilePath $exe -ArgumentList $probeArgs -NoNewWindow -Wait | Out-Null }
      finally { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
    } else {
      & $exe @probeArgs | Out-Null
    }
  } catch {
    Write-Host ("    ⚠ 启动失败：{0}" -f $_.Exception.Message.Split([char]10)[0]) -ForegroundColor Yellow
  }
  # 探针连不上浏览器时会轮询到超时（history 最长 30s / page-smoke 最长 20s）再落盘 ⇒ 多等一会儿
  for ($i = 0; $i -lt 20 -and -not (Test-Path $outPath); $i++) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Path $outPath)) {
    Write-Host "    SKIP —— 探针未落盘（真浏览器没起来？）" -ForegroundColor Yellow
    $realSkip += $pr.n; continue
  }
  try { $rj = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch {
    Write-Host "    FAIL —— 探针输出不可解析（工具缺陷）" -ForegroundColor Red
    $realFail++; continue
  }
  $results = @($rj.results)
  foreach ($r in $results) {
    Write-Host ("    {0} {1}  （{2}）" -f $(if ($r.ok) { '✓' } else { '✗' }), $r.name, $r.detail)
  }
  # 只有"连上了真浏览器"才算真机证据；连不上 = 环境问题（SKIP），不是页面缺陷 ✓
  $cdpUp = @($results | Where-Object { $_.ok -and $_.name -like '*CDP*' }).Count -gt 0
  if ($rj.error -and -not $cdpUp) {
    Write-Host ("    SKIP —— {0}" -f ([string]$rj.error -split "`n")[0]) -ForegroundColor Yellow
    $realSkip += $pr.n; continue
  }
  if ($rj.error -or [int]$rj.failed -gt 0) {
    Write-Host ("    FAIL —— {0} 项失败 / {1} 项通过" -f $rj.failed, $rj.passed) -ForegroundColor Red
    $realFail += [int]$rj.failed; continue
  }
  $realPass += [int]$rj.passed
  Write-Host ("    ✓ {0} 项全过" -f $rj.passed) -ForegroundColor Green
}

Write-Host ""
if ($realFail -gt 0) {
  Write-Host ("PAGE CHECK: FAIL（真机层 {0} 项失败）—— 见上面 ✗ 行" -f $realFail) -ForegroundColor Red
  Clear-CrashpadLog; exit 1
}
if ($realSkip.Count -gt 0) {
  Write-Host ("REAL: SKIP —— 真浏览器起不来/证据不完整（{0}）" -f ($realSkip -join '、')) -ForegroundColor Yellow
  Write-Host "  环境限制，**不是页面缺陷**。沙箱内 Chromium 起不来（debug.log 报 crashpad 拒绝访问）→ 需一次性放开权限或在普通桌面会话跑。" -ForegroundColor Yellow
  Clear-CrashpadLog; exit 2
}
Write-Host ("PAGE CHECK: PASS（桩 DOM 层 ①–⑰ + 真机层 {0} 项全过）" -f $realPass) -ForegroundColor Green
Clear-CrashpadLog
exit 0
