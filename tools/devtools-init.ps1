# devtools-init.ps1 — 把工作区内的 .devtools 接进当前会话（不改系统）
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bin  = Join-Path $root '.devtools\bin'
$mod  = Join-Path $root '.devtools\modules'
if (Test-Path $bin) { $env:PATH = "$bin;$env:PATH" }
if (Test-Path $mod) { $env:PSModulePath = "$mod;$env:PSModulePath" }
Write-Host "已接入：" -NoNewline
Write-Host " bin=$(if (Test-Path $bin) { '✓' } else { '×' })  modules=$(if (Test-Path $mod) { '✓' } else { '×' })" -ForegroundColor Cyan
foreach ($m in 'PSScriptAnalyzer', 'Pester') { $f = @(Get-Module -ListAvailable -Name $m); if ($f) { Write-Host ("  {0,-16} v{1}" -f $m, $f[0].Version) } }