# 安装开发工具.ps1 — 把开发期辅助工具装进**本工作区**（2026-10-16 改版）
#
# 设计原则：**只动本工作区**（不动系统、不装全局、不用 winget）
#   .devtools\bin\      三个单文件工具（gitleaks / lychee / git-cliff）
#   .devtools\modules\  PowerShell 模块（PSScriptAnalyzer / Pester 5）→ 用 Save-Module 下到这里
#   .devtools\cache\    下载的压缩包（留档，便于复核）
#   .devtools\manifest.json  本次装了什么的清单（名称 / 版本 / URL / SHA256 / 目标路径）
#
# "别装错"的四道闸：
#   ① 二进制**版本与 SHA256 写死**在本脚本里（取自官方 release 的 digest），下载后**先校验再解压**，不符就丢弃；
#   ② 只从官方域名下载（github.com / www.powershellgallery.com）；
#   ③ 每个工具装完立刻跑 --version，与期望版本比对；
#   ④ 全程清单留档 + 可 -Uninstall 一键整目录删除回滚。
#
# 用法：
#   pwsh -File ".\tools\安装开发工具.ps1"            # 安装 + 核对
#   pwsh -File ".\tools\安装开发工具.ps1" -DryRun     # 只看计划，不做任何修改
#   pwsh -File ".\tools\安装开发工具.ps1" -Only bin   # 只装二进制（或 modules）
#   pwsh -File ".\tools\安装开发工具.ps1" -Uninstall  # 删除整个 .devtools\（回滚）

param(
  [switch]$DryRun,
  [switch]$Uninstall,
  [ValidateSet('all', 'bin', 'modules')][string]$Only = 'all'
)

$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dev   = Join-Path $root '.devtools'
$binD  = Join-Path $dev 'bin'
$modD  = Join-Path $dev 'modules'
$cache = Join-Path $dev 'cache'
function P([string]$rel) { Join-Path $root $rel }
$script:log = @()
function Say([string]$s, [string]$c = 'Gray') { Write-Host $s -ForegroundColor $c; $script:log += $s }
$script:rows = @()

# 固定的安装清单（版本 + SHA256 来自官方 release 资产）
$BINS = @(
  @{ Name = 'gitleaks'; Ver = '8.30.1'; Exe = 'gitleaks.exe'
     Url = 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip'
     Sha = 'd29144deff3a68aa93ced33dddf84b7fdc26070add4aa0f4513094c8332afc4e'; Size = 8438883 }
  @{ Name = 'lychee'; Ver = '0.24.2'; Exe = 'lychee.exe'
     Url = 'https://github.com/lycheeverse/lychee/releases/download/lychee-v0.24.2/lychee-x86_64-pc-windows-msvc.zip'
     Sha = '32975d1493ee1a975d6bb41e4fb56fe419cb442ded628bb772ba2e614acfacad'; Size = 6868524 }
  @{ Name = 'git-cliff'; Ver = '2.14.2'; Exe = 'git-cliff.exe'
     Url = 'https://github.com/orhun/git-cliff/releases/download/v2.14.2/git-cliff-2.14.2-x86_64-pc-windows-msvc.zip'
     Sha = '6ece2112b3f4af462190ecbea4aeb1315fff6af415629b597f84319073c31131'; Size = 7428304 }
)
$MODS = @(
  @{ Name = 'PSScriptAnalyzer'; Min = '1.20.0'; Author = 'Microsoft'; Why = '给 .ps1 做静态检查' }
  @{ Name = 'Pester';           Min = '5.0.0';  Author = 'Pester';    Why = 'PS7 下的测试框架' }
)

Say "`n=== 安装开发工具（只装进本工作区）===" 'Cyan'
Say ("  工作区 : {0}" -f $root)
Say ("  目标   : {0}" -f $dev)
Say ("  模式   : {0}" -f $(if ($Uninstall) { 'Uninstall（删除 .devtools）' } elseif ($DryRun) { 'DryRun（不改动）' } else { '安装' }))

if ($Uninstall) {
  if (-not (Test-Path $dev)) { Say "  .devtools\ 不存在，无需卸载" 'DarkGray'; return }
  if ($DryRun) { Say "  [DryRun] 将删除 $dev" 'Yellow'; return }
  $sz = [math]::Round(((Get-ChildItem $dev -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
  Remove-Item $dev -Recurse -Force
  Say ("  ✅ 已删除 .devtools\（释放约 {0} MB）；pre-commit 钩子在 git 里，未受影响" -f $sz) 'Green'
  return
}

# ---------- 0. 预检 ----------
Say "`n=== 0. 预检 ===" 'Cyan'
Say ("  PowerShell : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
$net = $null; $netOk = $false
if (-not $DryRun) {
  foreach ($u in @('https://github.com', 'https://www.powershellgallery.com/api/v2/')) {
    try {
      $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20
      $net = ("HTTP {0} @ {1}" -f $r.StatusCode, $u); $netOk = $true; break
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match '\b[45]\d\d\b') { $net = ("可达（{0}）@ {1}" -f $msg, $u); $netOk = $true; break }
      $net = "失败：" + $msg
    }
  }
  Say ("  联网探测   : {0}" -f $net) $(if ($netOk) { 'Green' } else { 'Red' })
  if (-not $netOk) { Say "  ⚠️ 没有网络 → 无法下载。先解决网络，再重跑本脚本。" 'Red'; return }
}

# ---------- 1. 单文件工具 ----------
if ($Only -in @('all', 'bin')) {
  Say "`n=== 1. 单文件工具 → .devtools\bin\ ===" 'Cyan'
  if (-not $DryRun) { foreach ($d in @($dev, $binD, $cache)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } }
  foreach ($b in $BINS) {
    $existing = Join-Path $binD $b.Exe
    if (Test-Path $existing) {
      $haveV = (& $existing --version 2>&1 | Select-Object -First 1)
      if ("$haveV" -match [regex]::Escape($b.Ver)) { Say ("  ✅ {0,-10} 已装且版本匹配：{1}" -f $b.Name, $haveV) 'Green'; $script:rows += [pscustomobject]@{ 工具 = $b.Name; 期望 = $b.Ver; 实际 = "$haveV"; 结果 = '✅ 已装' }; continue }
      Say ("  ⚠️ {0,-10} 已存在但版本不符（{1}），将覆盖为 {2}" -f $b.Name, $haveV, $b.Ver) 'Yellow'
    }
    if ($DryRun) { Say ("  [DryRun] 下载 {0} → 校验 SHA256 → 解压 {1}" -f $b.Url, $b.Exe) 'Yellow'; continue }
    $zip = Join-Path $cache (Split-Path $b.Url -Leaf)
    Say ("  … 下载 {0} {1}" -f $b.Name, $b.Ver) 'Yellow'
    try { Invoke-WebRequest -Uri $b.Url -OutFile $zip -UseBasicParsing -TimeoutSec 300 } catch { Say ("  ❌ 下载失败：{0}" -f $_.Exception.Message) 'Red'; $script:rows += [pscustomobject]@{ 工具 = $b.Name; 期望 = $b.Ver; 实际 = '下载失败'; 结果 = '❌' }; continue }
    $h = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $b.Sha) {
      Say ("  ❌ SHA256 不符 → **丢弃不装**`n     期望 {0}`n     实际 {1}" -f $b.Sha, $h) 'Red'
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
      $script:rows += [pscustomobject]@{ 工具 = $b.Name; 期望 = $b.Ver; 实际 = 'SHA256 不符'; 结果 = '❌ 已丢弃' }
      continue
    }
    Say ("  ✅ SHA256 通过（{0}…）" -f $h.Substring(0, 16)) 'Green'
    $tmp = Join-Path $cache ('x_' + $b.Name)
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem $tmp -Recurse -Filter $b.Exe | Select-Object -First 1
    if (-not $exe) { Say ("  ❌ 压缩包里没找到 {0}" -f $b.Exe) 'Red'; $script:rows += [pscustomobject]@{ 工具 = $b.Name; 期望 = $b.Ver; 实际 = '包内无 exe'; 结果 = '❌' }; continue }
    Copy-Item $exe.FullName $existing -Force
    Remove-Item $tmp -Recurse -Force
    $vv = (& $existing --version 2>&1 | Select-Object -First 1)
    $ok = ("$vv" -match [regex]::Escape($b.Ver))
    Say ("  {0} {1,-10} → {2} ｜ {3}" -f $(if ($ok) { '✅' } else { '⚠️' }), $b.Name, $existing, $vv) $(if ($ok) { 'Green' } else { 'Yellow' })
    $script:rows += [pscustomobject]@{ 工具 = $b.Name; 期望 = $b.Ver; 实际 = "$vv"; 结果 = $(if ($ok) { '✅' } else { '⚠️ 版本不符' }) }
  }
}

# ---------- 2. PowerShell 模块（Save-Module 到工作区） ----------
if ($Only -in @('all', 'modules')) {
  Say "`n=== 2. PowerShell 模块 → .devtools\modules\（Save-Module，不装系统）===" 'Cyan'
  if (-not $DryRun) { if (-not (Test-Path $modD)) { New-Item -ItemType Directory -Path $modD -Force | Out-Null } }
  $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
  if (-not $repo -and -not $DryRun) {
    Say "  … 注册 PSGallery" 'Yellow'
    try { Register-PSRepository -Default -ErrorAction Stop; $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue } catch { Say ("  ⚠️ 注册失败：{0}" -f $_.Exception.Message) 'Yellow' }
  }
  foreach ($m in $MODS) {
    $found = @(Get-ChildItem $modD -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $m.Name })
    if ($found) {
      $psd1 = Get-ChildItem $found[0].FullName -Recurse -Filter "$($m.Name).psd1" | Select-Object -First 1
      $v = if ($psd1) { (Get-Content $psd1.FullName -Raw | Select-String -Pattern "ModuleVersion\s*=\s*'([^']+)'" ).Matches.Groups[1].Value } else { '?' }
      Say ("  ✅ {0,-16} 已在工作区：v{1}" -f $m.Name, $v) 'Green'
      $script:rows += [pscustomobject]@{ 工具 = $m.Name; 期望 = ">=$($m.Min)"; 实际 = "v$v"; 结果 = '✅ 已装' }
      continue
    }
    if ($DryRun) { Say ("  [DryRun] Save-Module {0} -Path .devtools\modules" -f $m.Name) 'Yellow'; continue }
    if (-not $repo) { Say ("  ❌ {0}：PSGallery 不可用 → 手工：Save-Module {0} -Path .devtools\modules" -f $m.Name) 'Red'; $script:rows += [pscustomobject]@{ 工具 = $m.Name; 期望 = ">=$($m.Min)"; 实际 = 'PSGallery 不可用'; 结果 = '❌' }; continue }
    Say ("  … Save-Module {0}（用途：{1}）" -f $m.Name, $m.Why) 'Yellow'
    try { Save-Module -Name $m.Name -Path $modD -Repository PSGallery -ErrorAction Stop }
    catch { Say ("  ❌ {0} 下载失败：{1}" -f $m.Name, $_.Exception.Message) 'Red'; $script:rows += [pscustomobject]@{ 工具 = $m.Name; 期望 = ">=$($m.Min)"; 实际 = '下载失败'; 结果 = '❌' }; continue }
    $v2 = (Get-ChildItem $modD -Recurse -Filter "$($m.Name).psd1" | Select-Object -First 1)
    Say ("  ✅ {0,-16} → {1}" -f $m.Name, $v2.DirectoryName) 'Green'
    $script:rows += [pscustomobject]@{ 工具 = $m.Name; 期望 = ">=$($m.Min)"; 实际 = (Split-Path (Split-Path $v2.DirectoryName -Parent) -Leaf); 结果 = '✅' }
  }
}

# ---------- 3. 清单 + 核对表 ----------
if (-not $DryRun) {
  $manifest = @{ installed_at = (Get-Date -Format 's'); workspace = $root; binaries = $BINS; modules = $MODS; note = '本目录由 tools\安装开发工具.ps1 生成；删除整个 .devtools\ 即回滚' }
  [System.IO.File]::WriteAllText((Join-Path $dev 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}
Say "`n=== 3. 核对表 ===" 'Cyan'
$script:rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
$logPath = P ('data\_tmp\install-devtools-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd-HHmm'))
if (-not (Test-Path (Split-Path $logPath -Parent))) { New-Item -ItemType Directory -Path (Split-Path $logPath -Parent) -Force | Out-Null }
[System.IO.File]::WriteAllText($logPath, ($script:log -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Say ("日志：{0}" -f $logPath) 'DarkGray'
Say "`n用法（每个新终端里先跑一次）：" 'Cyan'
Say "  . .\tools\devtools-init.ps1        # 把 .devtools\bin 与 .devtools\modules 加进本会话的 PATH / PSModulePath"
Say "  Invoke-ScriptAnalyzer -Path .\tools -Recurse    # 静态检查"
Say "  gitleaks detect --source . --no-banner          # 密钥扫描"
Say "  lychee --offline README.md QUICKSTART.md        # 链接检查"
if ($DryRun) { Say "（这是 DryRun，什么都没改。）" 'Yellow' }