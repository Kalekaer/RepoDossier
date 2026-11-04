# setup-fastembed.ps1 — 一次性把**语义复核环境**装进工作区内（P2-5 用；不碰系统 Python ✓）
#
# 为什么单独一个脚本：fastembed 是 Python 生态、要联网下包与下模型（几百 MB）✗ 与工作区
#   "零依赖 PowerShell / 单文件 HTML"的发布纪律相冲 ⇒ 明确划成**开发期一次性工具**：
#   · venv 装在工作区内 `data\_pyenv` ✓（绝不 `pip install` 到系统 Python）
#   · 模型缓存也锁在工作区内 `data\_models` ✓（默认会写用户目录 ✗）
#   · 它**不进发布包**（已登记 check-drift 的 $devOnly）✓
#
# 用法：
#   & ".\tools\setup-fastembed.ps1"                 # venv + 装 fastembed + 预热模型（顺带跑一次复核）
#   & ".\tools\setup-fastembed.ps1" -SkipModel      # 只装包，不下载模型
#   & ".\tools\setup-fastembed.ps1" -Proxy ''       # 不走代理（直连）
# 退出码：0 成功；1 失败（看 data\_tmp\setup-fastembed-*.err）
#
# ⚠️ 沙箱内**起不了外部程序 / TLS 不可用**（实测：`& py` 报"拒绝访问"、schannel 报 SEC_E_NO_CREDENTIALS）
#    ⇒ 本脚本要在**一次性放开权限**的会话里跑 ✓（与真机浏览器探针同一限制）

param(
  [switch]$SkipModel,
  [string]$Proxy = '',                                      # default: no proxy -- domestic mirror is faster here
  [string]$IndexUrl = 'https://pypi.tuna.tsinghua.edu.cn/simple',
  [string]$HfEndpoint = 'https://hf-mirror.com'             # model comes from HF: mirror is mandatory in CN, else it hangs
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
$tmp = P 'data\_tmp'
if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
$venv = P 'data\_pyenv'
$models = P 'data\_models'

# 系统 python 的候选（本机实测：py 启动器 + Python312 ✓）
$sysPy = $null
foreach ($c in @(
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    'C:\Python312\python.exe', 'C:\Python311\python.exe')) {
  if ($c -and (Test-Path $c)) { $sysPy = $c; break }
}
if (-not $sysPy) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd) { $sysPy = $cmd.Source }
}
if (-not $sysPy) {
  Write-Host '❌ 找不到系统 python（装 Python 3.11+ 后重试；本机实测路径：%LOCALAPPDATA%\Programs\Python\Python312\python.exe）' -ForegroundColor Red
  exit 1
}
Write-Host ("系统 python：{0}" -f $sysPy)

if ($Proxy) { $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy; Write-Host ("代理：{0}" -f $Proxy) }
if ($HfEndpoint) { $env:HF_ENDPOINT = $HfEndpoint; Write-Host ("HF 镜像：{0}" -f $HfEndpoint) }
Write-Host ("PyPI 源：{0}" -f $(if ($IndexUrl) { $IndexUrl } else { 'pip default (official)' }))
$env:FASTEMBED_CACHE_PATH = $models
$env:HF_HOME = Join-Path $models 'hf'
$env:PYTHONIOENCODING = 'utf-8'
$env:PIP_CACHE_DIR = P 'data\_pip-cache'    # pip 缓存也锁进工作区 ✓（上次漏了 ⇒ 317 MB 落到 %LOCALAPPDATA% ✗）
$env:TMP = $tmp                      # pip 的临时文件也别撒到工作区外/根目录 ✓（上次留过 tmp_xxxx 残留 ✗）
$env:TEMP = $tmp
if (-not (Test-Path $models)) { New-Item -ItemType Directory -Path $models -Force | Out-Null }

function Run([string]$exe, [string[]]$argv, [string]$tag) {
  $o = Join-Path $tmp "setup-fastembed-$tag.out"
  $e = Join-Path $tmp "setup-fastembed-$tag.err"
  Write-Host ("  [{0}] 启动 …（日志 data\_tmp\setup-fastembed-{0}.{{out,err}}）" -f $tag) -ForegroundColor DarkCyan
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $exe -ArgumentList $argv -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $sw.Stop()
  $code = if ($null -eq $p.ExitCode) { -1 } else { [int]$p.ExitCode }   # null = unknown -- NEVER treat as success (pitfall #24 family)
  Write-Host ("  [{0}] exit={1} 耗时={2:N0}s" -f $tag, $code, $sw.Elapsed.TotalSeconds)
  if (Test-Path $e) { $er = @(Get-Content $e -Encoding UTF8 | Where-Object { $_.Trim() }); if ($er) { $er | Select-Object -Last 6 | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor DarkGray } } }
  if (Test-Path $o) { $ou = @(Get-Content $o -Encoding UTF8 | Where-Object { $_.Trim() }); if ($ou) { $ou | Select-Object -Last 3 | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor DarkGray } } }
  return $code
}

# ① venv（已存在就跳过 ⇒ 幂等 ✓）
$vpy = Join-Path $venv 'Scripts\python.exe'
if (Test-Path $vpy) {
  Write-Host '① venv 已存在，跳过 ✓'
} else {
  Write-Host '① 建 venv（data\_pyenv）'
  if ((Run $sysPy @('-m', 'venv', $venv) 'venv') -ne 0) { Write-Host '❌ venv 创建失败' -ForegroundColor Red; exit 1 }
}
if (-not (Test-Path $vpy)) { Write-Host '❌ venv 里没有 python.exe' -ForegroundColor Red; exit 1 }

# ② 装包（fastembed 会带 onnxruntime / numpy / tokenizers 等，约 200 MB 级）
$pip = Join-Path $venv 'Scripts\pip.exe'
Write-Host '② pip install fastembed'
$pipArgs = @('install', '--disable-pip-version-check', '--no-input', '--upgrade', '--timeout', '30', '--retries', '1')
if ($IndexUrl) { $pipArgs += @('-i', $IndexUrl) }
$pipArgs += 'fastembed'
$pipCode = Run $pip $pipArgs 'pip'   # timeout 30s x1 retry => fails in ~1 min instead of hanging 10 min
$pipOut = Join-Path $tmp 'setup-fastembed-pip.out'
$pipOk = (Test-Path $pipOut) -and (Select-String -Path $pipOut -Pattern 'Successfully installed|Requirement already satisfied' -Quiet)
if (-not $pipOk) { Write-Host 'pip did NOT report success -- read data\_tmp\setup-fastembed-pip.{out,err}' -ForegroundColor Red; exit 1 }
if ($pipCode -ne 0) { Write-Host '❌ pip install 失败（多半是网络/代理）⇒ 看 data\_tmp\setup-fastembed-pip.err' -ForegroundColor Red; exit 1 }

# ③ 验包
Write-Host '③ 验包'
$chk = Run $vpy @('-m', 'pip', 'show', 'fastembed') 'check'
$chkOut = Join-Path $tmp 'setup-fastembed-check.out'
if (-not ((Test-Path $chkOut) -and (Select-String -Path $chkOut -Pattern 'Name: fastembed' -Quiet))) { Write-Host 'fastembed is not installed correctly' -ForegroundColor Red; exit 1 }
if ($chk -ne 0) { Write-Host '❌ 包导入失败' -ForegroundColor Red; exit 1 }

if ($SkipModel) { Write-Host '（-SkipModel：不下载模型）✓' -ForegroundColor Green; exit 0 }

# ④ 预热模型 + 顺带跑第一次复核（模型首次使用会下载到 data\_models ✓）
Write-Host '④ 预热模型并跑第一次语义复核（首次会下载模型，几百 MB）'
$LASTEXITCODE = 0
& (P 'tools\classify-semantic.ps1')
$code = $LASTEXITCODE
if (-not (Test-Path (P 'data\classify-semantic.jsonl'))) { Write-Host 'classify-semantic.jsonl missing -- analysis did not finish' -ForegroundColor Red; exit 1 }
if ($code -ne 0) { Write-Host ("❌ 复核返回 {0}（2 = 环境未就绪；1 = 输入问题）" -f $code) -ForegroundColor Red; exit 1 }
Write-Host '语义环境就绪 ✓' -ForegroundColor Green
exit 0
