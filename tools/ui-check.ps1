# ui-check.ps1 — 界面审美自检（impeccable 引擎，确定性"反 AI 味"规则）
#
# 三条踩坑（2026-10-16，全部已修）：
#   ① 人类可读结果走 **stderr** ✗ → 只捕 stdout 会得到空输出，而空输出曾被当成"通过" ✗
#   ② 改用 `detect --json`（JSON 走 stdout ✓）；**0 违规时 stdout 也是空的** ✗ → 单看输出无法区分"干净"与"没扫到"
#   ③ 拿进程退出码也不稳（Start-Process -PassThru 在重定向时 ExitCode 可能为空 ✗）
#   ⇒ 最终判据：**真页面 0 输出时，自动往副本注入一条违规做阳性对照**；
#      对照能抓到 → "真页面 0 违规"可信 ✓；对照也抓不到 → 引擎对该文件无效，**不判定为通过** ✗
#
# 用法：
#   & ".\tools\ui-check.ps1"                      # 默认：扫 overview.html（必要时自动做阳性对照）
#   & ".\tools\ui-check.ps1" -Json                # 原始 JSON
#   & ".\tools\ui-check.ps1" -NoControl           # 跳过阳性对照（不推荐）
# 退出码：0 = 0 违规且可信 ｜ 2 = 有违规 ｜ 1 = 无法判定（引擎无效/目标不存在）

param(
  [string]$Target = 'legacy\overview-v5.html',
  [switch]$Json,
  [switch]$NoControl
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe  = Join-Path $root '.devtools\bin\impeccable.exe'
if (-not (Test-Path $exe)) { Write-Host "缺少引擎：.devtools\bin\impeccable.exe" -ForegroundColor Red; exit 1 }
$t = if ([System.IO.Path]::IsPathRooted($Target)) { $Target } else { Join-Path $root $Target }
if (-not (Test-Path $t)) { Write-Host "目标不存在：$t" -ForegroundColor Red; exit 1 }
$tmpDir = Join-Path $root 'data\_tmp'
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$env:DO_NOT_TRACK = '1'

function Get-Findings([string]$file, [string]$tag) {
  $o = Join-Path $tmpDir ("imp-$tag.json")
  Remove-Item $o, ($o + '.err') -Force -ErrorAction SilentlyContinue
  Start-Process -FilePath $exe -ArgumentList @('detect', '--json', $file) -NoNewWindow -Wait -RedirectStandardOutput $o -RedirectStandardError ($o + '.err') | Out-Null
  if (-not (Test-Path $o)) { return @() }
  $raw = Get-Content $o -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  try { return @($raw | ConvertFrom-Json) } catch { return @() }
}

Write-Host ("界面自检：" + $t.Substring($root.Length + 1)) -ForegroundColor Cyan
$found = Get-Findings $t 'real'

if ($Json) { if ($found.Count) { $found | ConvertTo-Json -Depth 5 } else { '[]' }; exit 0 }

if ($found.Count -gt 0) {
  Write-Host ("⚠️ " + $found.Count + " 条违规：") -ForegroundColor Yellow
  $found | Group-Object severity | ForEach-Object { Write-Host ("   " + $_.Name + "：" + $_.Count) }
  $found | Group-Object antipattern | ForEach-Object { Write-Host ("   " + $_.Name + "：" + $_.Count) }
  $found | Select-Object -First 15 | ForEach-Object {
    $sn = if ($_.snippet) { $_.snippet.Substring(0, [Math]::Min(96, $_.snippet.Length)) } else { '' }
    Write-Host ("   [" + $_.antipattern + "] " + $sn) -ForegroundColor DarkYellow
  }
  exit 2
}

# 0 条 → 必须做阳性对照才能认定
if ($NoControl) { Write-Host "✅ 0 条违规（未做阳性对照，结论仅供参考）" -ForegroundColor Green
Remove-Item (Join-Path $root 'debug.log') -Force -ErrorAction SilentlyContinue; exit 0 }
$copy = Join-Path $tmpDir 'ui-control.html'
$html = [System.IO.File]::ReadAllText($t, [System.Text.Encoding]::UTF8)
$inject = '<style id="ui-control">body{color:#bbbbbb !important;background:#ffffff !important}</style>'
[System.IO.File]::WriteAllText($copy, ($html -replace '</head>', ($inject + '</head>')), (New-Object System.Text.UTF8Encoding($false)))
$script:ControlCopy = $copy
$ctl = Get-Findings $copy 'control'
if ($ctl.Count -eq 0) {
  Write-Host "❌ 阳性对照也 0 条 → 引擎对该文件无效，**不判定为通过**" -ForegroundColor Red
  exit 1
}
Write-Host ("✅ 0 条违规（阳性对照通过：" + $ctl.Count + " 条注入违规被抓到 → 结论可信）") -ForegroundColor Green
Remove-Item $copy -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root 'debug.log') -Force -ErrorAction SilentlyContinue
exit 0