# make-testcopy.ps1 — 一键生成"测试副本"（解决"4 份拷贝、3 份是旧的"）
#
# 思路：**以发布包为骨架**（它就是交付形态）→ 覆盖当前库里的脚本 → 按模式配齐"数据 + 文档 + 技能"→ 重建页面。
# 两种模式，各自**自洽**（跑完 audit 就该通过；不通过说明代码真有问题）：
#   默认（demo）      ：数据/文档/技能都用发布包自带的（15 条 demo，audit 139 项口径）
#   -WithLibraryData  ：数据/文档/技能都用库里的（全量数据，audit 141 项口径）→ 等于"库的镜像"
#
# 用法：
#   pwsh -File .\tools\make-testcopy.ps1                                  # → 发布测试\测试副本-YYYY-MM-DD\
#   pwsh -File .\tools\make-testcopy.ps1 -Path 发布测试\我的副本
#   pwsh -File .\tools\make-testcopy.ps1 -WithLibraryData                 # 库镜像（全量数据）
#   pwsh -File .\tools\make-testcopy.ps1 -Force                           # 覆盖已存在的目录

param(
  [string]$Path = '',
  [switch]$WithLibraryData,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pkg  = Join-Path $root 'release\github-daily-picks'

if (-not (Test-Path $pkg)) { Write-Host "找不到发布包：$pkg" -ForegroundColor Red; exit 1 }
if (-not $Path) { $Path = Join-Path '发布测试' ('测试副本-' + (Get-Date -Format 'yyyy-MM-dd')) }
$target = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $root $Path }

# 开发期工具不进副本（副本要模拟"用户拿到的东西"）
$devOnly = @('code-health.ps1', 'check-drift.ps1', 'make-testcopy.ps1', '安装开发工具.ps1', 'devtools-init.ps1', 'ui-check.ps1')

# 复制目录时**先删目标**：否则 Copy-Item 目录 → 已存在的同名目录会嵌套成 data\human\human\（已踩过）
function Copy-DirClean([string]$src, [string]$dst) {
  if (-not (Test-Path $src)) { return }
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
  Copy-Item $src $dst -Recurse -Force
}

if (Test-Path $target) {
  if (-not $Force) { Write-Host "目标已存在：$target（要覆盖请加 -Force）" -ForegroundColor Red; exit 1 }
  Remove-Item $target -Recurse -Force
}
Write-Host ("生成测试副本 → " + $target) -ForegroundColor Cyan
Write-Host ("  模式：" + $(if ($WithLibraryData) { '库镜像（全量数据 + 库文档 + 库技能）' } else { 'demo（15 条示例数据 + 发布包文档/技能）' }))

# 1) 以发布包为骨架（排除 .git）
New-Item -ItemType Directory -Path $target -Force | Out-Null
Get-ChildItem $pkg -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
  Copy-Item $_.FullName -Destination $target -Recurse -Force
}
Write-Host '  [1/5] 发布包骨架 ✓'

# 2) 覆盖当前库的脚本（跳过开发期工具）—— 两种模式都要，副本要跑"当前代码"
$n = 0
Get-ChildItem (Join-Path $root 'tools') -Filter *.ps1 -File | Where-Object { $devOnly -notcontains $_.Name } | ForEach-Object {
  Copy-Item $_.FullName (Join-Path $target 'tools') -Force; $n++
}
Write-Host ("  [2/5] 覆盖库脚本 {0} 个 ✓" -f $n)

if ($WithLibraryData) {
  # 3) 库技能（含 141 项 audit.ps1）
  Copy-DirClean (Join-Path $root '.dsh\skills\github-daily-picks') (Join-Path $target '.dsh\skills\github-daily-picks')
  # 4) 库数据 + 会声明口径的库文档（README / data\README 必须与 audit 同源，否则项数自检会挂）
  foreach ($sub in @('human', 'meta', 'picks', 'snapshots', 'runs', 'batch', 'push')) {
    $srcSub = Join-Path $root ('data\' + $sub)
    if (Test-Path $srcSub) { Copy-DirClean $srcSub (Join-Path $target ('data\' + $sub)) }
  }
  Get-ChildItem (Join-Path $root 'data') -File | Where-Object { $_.Name -ne '.projects-signature' } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $target 'data') -Force
  }
  # 根目录所有 .md/.json：README 里的相对链接指向它们，少一个 audit 就会报「死链」
  Get-ChildItem $root -File | Where-Object { $_.Extension -in @('.md', '.json') } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $target $_.Name) -Force
  }
  # README 还会链接到这些目录
  foreach ($dir in @('reports', 'TEMPLATES', 'examples')) {
    $srcDir = Join-Path $root $dir
    if (Test-Path $srcDir) { Copy-DirClean $srcDir (Join-Path $target $dir) }
  }
  Write-Host '  [3/5] 覆盖库技能 ✓  [4/5] 覆盖库数据 + 库文档 ✓'
} else {
  Write-Host '  [3/5] 保留发布包技能（audit 139 项口径）✓  [4/5] 保留 demo 数据与文档 ✓'
}

# 5) 重建页面（用副本自己的脚本 + 数据）
Push-Location $target
$out = & (Join-Path $target 'tools\build-overview.ps1') 2>&1
Pop-Location
$built = ($out | Where-Object { "$_" -match '已生成' }) -join ' '
Write-Host ("  [5/5] 重建页面 ✓ {0}" -f $built)

$projPath = Join-Path $target 'data\projects.jsonl'
$projN = if (Test-Path $projPath) { @(Get-Content $projPath -Encoding UTF8 | Where-Object { $_.Trim() }).Count } else { 0 }
Write-Host ''
Write-Host ("完成：{0} 条项目 ｜ 双击入口 {1}" -f $projN, (Join-Path $target 'overview.html')) -ForegroundColor Green
Write-Host '自检建议：cd 到副本，然后跑 .\.dsh\skills\github-daily-picks\audit.ps1 与 .\tools\check-page.ps1'
Write-Host '提醒：副本是**只读快照**，改代码请在 tools\ 改，然后重新生成副本。'
