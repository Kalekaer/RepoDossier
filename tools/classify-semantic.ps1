# classify-semantic.ps1 — P2-5 语义分类复核的**统一入口**（包装 tools\classify-semantic.py）
#
# 分工：**.py 干分析**（fastembed 嵌入 + 余弦判定），**.ps1 干环境与调用**（venv 定位 / 工作区内缓存 /
#   沙箱友好的 Start-Process + 重定向）✓ —— 与 page-smoke-cdp.js 一样：重活给合适的人干。
#
# 用法：
#   & ".\tools\classify-semantic.ps1"                          # 完整复核 + 报告
#   & ".\tools\classify-semantic.ps1" -SelfTest                # 只验打分/判定逻辑（不加载模型，秒级）
#   & ".\tools\classify-semantic.ps1" -Json                    # 机器可读
#   & ".\tools\classify-semantic.ps1" -Suggest 0.03 -Top 15    # 收紧阈值
# 退出码：0 正常 ｜ 1 输入/分析有问题 ｜ 2 环境未就绪（先跑 setup-fastembed.ps1）
#
# ⚠️ 判据是**输出文件 / 报告内容**，退出码只作辅助（与 check-page 同族：踩坑 #24）
# ⚠️ 模型与 venv 都在工作区内（data\_models / data\_pyenv）⇒ 工作区自包含、可整体搬走 ✓

param(
  [switch]$Json,
  [switch]$SelfTest,
  [switch]$Fixture,
  [double]$MinSim = 0.62,
  [int]$Kw = 6,
  [double]$Suggest = 0.02,
  [double]$Watch = 0.01,
  [int]$Top = 25
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }

$vpy = P 'data\_pyenv\Scripts\python.exe'
$pyScript = P 'tools\classify-semantic.py'
if (-not (Test-Path $pyScript)) { Write-Host ('❌ 找不到 {0}' -f $pyScript) -ForegroundColor Red; exit 1 }
if (-not (Test-Path $vpy)) {
  Write-Host '❌ 语义环境未安装（data\_pyenv 不存在）' -ForegroundColor Red
  Write-Host '   ⇒ 先跑：& ".\tools\setup-fastembed.ps1"（一次性，需联网 + 放开权限）' -ForegroundColor Yellow
  exit 2
}

# 缓存必须在工作区内 ✓（默认会写用户目录 ✗）
$env:FASTEMBED_CACHE_PATH = P 'data\_models'
$env:HF_ENDPOINT = 'https://hf-mirror.com'   # model download goes through the CN mirror by default (official HF is blocked/slow here)
$env:HF_HOME = P 'data\_models\hf'
$env:PYTHONIOENCODING = 'utf-8'   # 关键：Start-Process 重定向时没有 tty ⇒ Python 按 locale(GBK) 编码 stdout ⇒ 中文/✓ 全崩 ✗（2026-10-17 实测）

$tmp = P 'data\_tmp'
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
$outFile = Join-Path $tmp 'classify-semantic.out.txt'
$errFile = Join-Path $tmp 'classify-semantic.err.txt'

$pyArgs = @($pyScript)
if ($SelfTest) { $pyArgs += '--selftest' }
if ($Fixture) { $pyArgs += '--fixture' }
if ($Json) { $pyArgs += '--json' }
if (-not $SelfTest -and -not $Fixture) { $pyArgs += @('--suggest', "$Suggest", '--watch', "$Watch", '--min-sim', "$MinSim", '--kw', "$Kw", '--top', "$Top") }

# 沙箱内直接 `& python` 会被拒（实测"拒绝访问"）⇒ Start-Process + 重定向 ✓（踩坑 #11 / #27）
$proc = Start-Process -FilePath $vpy -ArgumentList $pyArgs -NoNewWindow -Wait -PassThru `
  -RedirectStandardOutput $outFile -RedirectStandardError $errFile

if (Test-Path $outFile) { Get-Content $outFile -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
if (Test-Path $errFile) {
  $err = @(Get-Content $errFile -Encoding UTF8 | Where-Object { $_.Trim() })
  if ($err) {
    Write-Host '--- stderr（最多 15 行）---' -ForegroundColor DarkGray
    $err | Select-Object -Last 15 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
  }
}
$code = if ($null -eq $proc.ExitCode) { 1 } else { [int]$proc.ExitCode }
if ($code -eq 2) { Write-Host '（退出码 2 = 环境未就绪：**不是**分类结论有问题 ✓）' -ForegroundColor Yellow }
exit $code
