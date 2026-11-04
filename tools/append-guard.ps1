# append-guard.ps1 — append 型文件的「写前唯一键」检查（只读，不写任何文件）
#
# 为什么需要它：picks / recommend-log.csv 都是**追加写**，没有数据库唯一约束。
#   同日重跑、失败重试、agent 多轮时，最容易把同一仓库写第二行；
#   等 reconcile 才发现就晚了。⇒ 写之前先问一句，撞键就停下。
#
# 唯一键（与 data/schema.json 一致）：
#   picks ：date + full_name（data/picks/<date>.jsonl，date 取文件名）
#   csv   ：仓库（data/recommend-log.csv）
#
# 用法：
#   .\tools\append-guard.ps1 -Target picks -Date 2026-10-19 -Repo owner/repo
#   .\tools\append-guard.ps1 -Target csv -Repo owner/repo
#   .\tools\append-guard.ps1 -Target picks -Repo owner/repo -Json
# 退出码：0 = 可追加 ｜ 1 = 已存在（刷新旧行，不要再追加）｜ 2 = 参数/文件错误

param(
  [Parameter(Mandatory)][ValidateSet('picks', 'csv')][string]$Target,
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [Parameter(Mandatory)][string]$Repo,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P($r) { Join-Path $root $r }

$result = [ordered]@{ target = $Target; date = $Date; repo = $Repo; exists = $false; detail = ''; exit = 0 }
$code = 0
$msg = ''

try {
  if ($Target -eq 'picks') {
    $path = P ("data\picks\$Date.jsonl")
    $rows = @()
    if (Test-Path $path) {
      foreach ($line in (Get-Content $path -Encoding UTF8 | Where-Object { $_.Trim() })) {
        try { $rows += ($line | ConvertFrom-Json) } catch { $null = $_ }
      }
    }
    $hit = @($rows | Where-Object { [string]$_.full_name -eq $Repo }) | Select-Object -First 1
    if ($hit) {
      $code = 1
      $msg = "已存在：picks/$Date 里已有 $Repo（tier=$($hit.tier)，score=$($hit.score)）→ 同日重跑请改写旧行，不要再追加一行"
    } else {
      $msg = "可追加：picks/$Date 里还没有 $Repo（现有 $($rows.Count) 行）"
    }
    $result.exists = [bool]$hit
  } else {
    $path = P 'data\recommend-log.csv'
    if (-not (Test-Path $path)) { throw "找不到 $path" }
    $rows = @(Import-Csv $path)
    $hit = @($rows | Where-Object { [string]$_.仓库 -eq $Repo }) | Select-Object -First 1
    if ($hit) {
      $code = 1
      $msg = "已存在：recommend-log.csv 里已有 $Repo（首次推荐日=$($hit.首次推荐日)，状态=$($hit.状态)）→ 请刷新该行，不要追加新行"
    } else {
      $msg = "可追加：recommend-log.csv 里还没有 $Repo（现有 $($rows.Count) 行）"
    }
    $result.exists = [bool]$hit
  }
} catch {
  $code = 2
  $msg = "检查失败：$($_.Exception.Message)"
}

$result.detail = $msg
$result.exit = $code

if ($Json) {
  [pscustomobject]$result | ConvertTo-Json -Depth 4
  exit $code
}
if ($code -eq 0) { Write-Host "✅ $msg" -ForegroundColor Green }
elseif ($code -eq 1) { Write-Host "⛔ $msg" -ForegroundColor Yellow }
else { Write-Host "❌ $msg" -ForegroundColor Red }
exit $code
