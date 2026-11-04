# backfill-meta.ps1 — 补齐"没有任何元数据快照"的仓库（2026-10-17 批次 B）
#
# 背景（实测 2026-10-17）：`data/meta/*.jsonl` 的并集只覆盖 **194/229**，正好缺 **39** 条 ⇒
# 这 39 条在投影里 `stars.created_at` 为空（页面看不到建仓时间），而其余 190 条的 `created_at` 都有 ✓
#
# 做法：对这 39 个仓库各调一次 `GET /repos/{owner}/{repo}`，把返回写成**与现有快照同 schema** 的新行，
# 追加进 `data/meta/<当天>.jsonl`（按 full_name 去重 ✓），然后由 `sync-projects.ps1` 重投影。
#
# 额度：39 次调用。匿名 GitHub API 限 **60 次/小时**（本机脚本必须走代理 `http://127.0.0.1:2080`）；
#      若设置了 `$env:DSH_GITHUB_TOKEN` 则带 Authorization（额度 5000/小时 ✓）。
#
# 用法：
#   .\tools\backfill-meta.ps1 -List            # 只列出缺哪些（不联网）
#   .\tools\backfill-meta.ps1                 # 真抓（追加快照 + 重投影）
#   .\tools\backfill-meta.ps1 -DryRun         # 打印将要抓的清单与请求 URL，不联网
#   .\tools\backfill-meta.ps1 -Limit 5        # 只抓前 5 个（先验管道）

param(
  [switch]$List,
  [switch]$DryRun,
  [int]$Limit = 0,
  [string]$Proxy = 'http://127.0.0.1:2080',
  [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }
. (P 'tools\date-utils.ps1')
$today = (Get-Date).ToString('yyyy-MM-dd')

# ---------- 1) 找出"完全没有快照"的仓库 ----------
$meta = @{}
Get-ChildItem (P 'data\meta') -Filter '*.jsonl' | ForEach-Object {
  Get-Content $_.FullName -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
    $x = $_ | ConvertFrom-Json
    if ($x.full_name) { $meta[$x.full_name] = $true }
  }
}
$rows = @(Get-Content (P 'data\seen.jsonl') -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$missing = @($rows | Where-Object { -not $meta.ContainsKey($_.full_name) } | ForEach-Object { $_.full_name })
if ($Limit -gt 0) { $missing = @($missing | Select-Object -First $Limit) }

Write-Host ("有快照的仓库 {0} 个 ｜ 台账 {1} 条 ｜ **缺快照 {2} 个**" -f $meta.Count, $rows.Count, $missing.Count) -ForegroundColor Cyan
if ($List -or $DryRun -or -not $missing.Count) {
  $missing | ForEach-Object { Write-Host ("  {0}  →  {1}/repos/{0}" -f $_, 'https://api.github.com') }
  if ($DryRun) { Write-Host "  -DryRun：未联网 ✓" -ForegroundColor Yellow }
  if (-not $missing.Count) { Write-Host "  ✅ 没有缺口，无需补齐" -ForegroundColor Green }
  exit 0
}

# ---------- 2) 逐个抓（写成与现有快照同 schema 的行）----------
$outPath = P ("data\meta\{0}.jsonl" -f $today)
$headers = @{ 'User-Agent' = 'github-daily-picks/backfill'; 'Accept' = 'application/vnd.github+json' }
if ($env:DSH_GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:DSH_GITHUB_TOKEN)" }
$ok = 0; $fail = @()
foreach ($full in $missing) {
  $uri = "https://api.github.com/repos/$full"
  try {
    $r = Invoke-RestMethod -Uri $uri -Headers $headers -Proxy $Proxy -TimeoutSec 25
    $row = [pscustomobject][ordered]@{
      # ⚠️ 用**台账里的名字**当键：仓库被改名时 API 会返回新名（实测 jiwoochris/artex-ko → artex-global）,
      #    若用响应名当键就与台账 join 不上 ✗ → 真名记在 `_api_name` 里（数据发现：台账名已过期，只记不改 ✓）
      full_name   = $full
      _api_name   = if ([string]$r.full_name -ne $full) { [string]$r.full_name } else { $null }
      description = [string]$r.description
      license     = if ($r.license) { [string]$r.license.spdx_id } else { $null }
      topics      = @($r.topics)
      archived    = [bool]$r.archived
      pushed_at   = ConvertTo-GitHubTimestamp $r.pushed_at 'pushed_at'
      stars       = [int]$r.stargazers_count
      forks       = [int]$r.forks_count
      open_issues = [int]$r.open_issues_count
      created_at  = ConvertTo-GitHubTimestamp $r.created_at 'created_at'
      fetched_at  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      _source     = 'backfill-meta.ps1（2026-10-17 批次 B：补齐无快照的仓库）'
    }
    ($row | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $outPath -Encoding UTF8
    $ok++
    Write-Host ("  ✓ {0}（★{1}，建仓 {2}）" -f $row.full_name, $row.stars, $row.created_at) -ForegroundColor DarkGray
  } catch {
    $msg = $_.Exception.Message.Split([char]10)[0]
    $fail += "$full （$msg）"
    Write-Host ("  ✗ {0}：{1}" -f $full, $msg) -ForegroundColor Yellow
    # 匿名额度用尽（403 rate limit）→ **立刻停止**，别再白撞额度 ✗（额度按小时重置，下次跑本脚本即可续上 ✓）
    if ($msg -match '403|rate limit') {
      Write-Host "  ⛔ 触发 GitHub 额度限制 → 停在这里（已完成 $ok 个，剩 $($missing.Count - $ok) 个待下次续跑）" -ForegroundColor Yellow
      break
    }
  }
}
Write-Host ("✅ 补齐 {0} 个，失败 {1} 个 → {2}" -f $ok, $fail.Count, $outPath) -ForegroundColor Green
if ($fail.Count) { Write-Host "  失败清单："; $fail | ForEach-Object { Write-Host "    $_" } }

# ---------- 3) 重投影 + 重建页面 ----------
if (-not $NoSync -and $ok -gt 0) { & (P 'tools\rebuild-page.ps1') }
exit 0
