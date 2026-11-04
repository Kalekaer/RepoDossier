# enrich-ecosyste.ms.ps1 — 慢变信号富化（第二数据源，**只读第三方**，开发期工具）
#
# 为什么存在（2026-10-16 实测定策，见 优化汇总 §9.14）：
#   * ecosyste.ms 的**标准文件清单 100% 覆盖** ✓（readme/license/security/contributing/citation/code_of_conduct…）
#   * 改名史 previous_names 53% ✓、license ✓、open_issues ✓
#   * OpenSSF Scorecard **只有 47%** ✗ → 标为"有则用"
#   * **stars 有滞后** ✗✗（实测 storytold/photocraft 差 −33298）→ **本工具绝不写 stars** ✓
#
# 用法：
#   pwsh -File .\tools\enrich-ecosyste.ms.ps1 -DryRun            # 只看计划
#   pwsh -File .\tools\enrich-ecosyste.ms.ps1 -MaxRequests 25    # 本轮最多 25 个（礼貌限速）
#   （可选）$env:DSH_HTTP_PROXY / HTTP_PROXY 指定代理；默认 http://127.0.0.1:2080
#
# 输出：data/enrich/ecosyste.ms.jsonl（**append-only，不覆盖**；同一 id 已存在则跳过 → 可断点续采）
# 退出码：0 正常；1 目标缺失

param(
  [int]$MaxRequests = 25,
  [double]$DelaySeconds = 1.0,
  [string]$Proxy = '',
  [switch]$NoProxy,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$projPath = Join-Path $root 'data\projects.jsonl'
$outDir = Join-Path $root 'data\enrich'
$outPath = Join-Path $outDir 'ecosyste.ms.jsonl'
if (-not (Test-Path $projPath)) { Write-Host "找不到 $projPath" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# 代理（可选）
if ($NoProxy) { $Proxy = '' }
elseif (-not $Proxy) {
  if ($env:DSH_HTTP_PROXY) { $Proxy = $env:DSH_HTTP_PROXY }
  elseif ($env:HTTPS_PROXY) { $Proxy = $env:HTTPS_PROXY }
  elseif ($env:HTTP_PROXY) { $Proxy = $env:HTTP_PROXY }
  else { $Proxy = 'http://127.0.0.1:2080' }
}

# 目标清单（只读投影）
$ids = @()
Get-Content $projPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
  try { $o = $_ | ConvertFrom-Json; if ($o.id) { $ids += [string]$o.id } } catch { $null = $_ }
}
$ids = @($ids | Sort-Object -Unique)

# 断点：已富化的 id
$done = @{}
if (Test-Path $outPath) {
  Get-Content $outPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object {
    try { $r = $_ | ConvertFrom-Json; if ($r.id) { $done[[string]$r.id] = $true } } catch { $null = $_ }
  }
}
$todo = @($ids | Where-Object { -not $done.ContainsKey($_) })

Write-Host ''
Write-Host '=== 慢变信号富化（ecosyste.ms；绝不写 stars）===' -ForegroundColor Cyan
Write-Host ("  目标 {0} 条 ｜ 已富化 {1} ｜ 待富化 {2}" -f $ids.Count, $done.Count, $todo.Count)
Write-Host ("  代理 {0} ｜ 本轮上限 {1} ｜ 间隔 {2}s" -f $(if ($Proxy) { $Proxy } else { '（不用）' }), $MaxRequests, $DelaySeconds)
Write-Host ("  写入 {0}（append-only，跳过已存在 → 可断点续采）" -f $outPath.Substring($root.Length + 1))
if ($todo.Count -eq 0) { Write-Host "`n已全部富化，无需再跑。" -ForegroundColor Green; exit 0 }
if ($DryRun) {
  Write-Host "`n[DryRun] 将要富化的前 10 个：" -ForegroundColor Yellow
  $todo | Select-Object -First 10 | ForEach-Object { Write-Host ('    ' + $_) }
  exit 0
}

$n = 0; $ok = 0; $fail = 0; $errs = @{}
$cov = @{ files = 0; license = 0; prev = 0; issues = 0; scorecard = 0 }
$utf8 = New-Object System.Text.UTF8Encoding($false)

foreach ($id in $todo) {
  if ($n -ge $MaxRequests) { break }
  $url = 'https://repos.ecosyste.ms/api/v1/hosts/GitHub/repositories/' + [uri]::EscapeDataString($id)
  $rec = [ordered]@{ id = $id; fetched_at = (Get-Date -Format 's'); source = 'ecosyste.ms'; ok = $false }
  try {
    $wa = @{ Uri = $url; TimeoutSec = 25; UseBasicParsing = $true; Headers = @{ 'User-Agent' = 'github-daily-picks-enrich/1.0' } }
    if ($Proxy) { $wa['Proxy'] = $Proxy }
    $r = Invoke-WebRequest @wa
    $j = $r.Content | ConvertFrom-Json
    $files = @()
    if ($j.metadata -and $j.metadata.files) {
      foreach ($fp in $j.metadata.files.PSObject.Properties) { if ($fp.Value) { $files += [string]$fp.Name } }
    }
    $prev = @(); if ($j.previous_names) { $prev = @($j.previous_names) }
    $sc = $null
    if ($j.scorecard -and $j.scorecard.data -and $j.scorecard.data.scorecard) { $sc = $j.scorecard.data.scorecard.score }
    $rec['ok'] = $true
    $rec['license'] = $j.license
    $rec['open_issues'] = $j.open_issues_count
    $rec['files'] = $files
    $rec['previous_names'] = $prev
    $rec['scorecard'] = $sc
    $rec['homepage'] = $j.homepage
    $rec['pushed_at'] = $j.pushed_at
    $ok++
    if ($files.Count -gt 0) { $cov.files++ }
    if ($j.license) { $cov.license++ }
    if ($prev.Count -gt 0) { $cov.prev++ }
    if ($null -ne $j.open_issues_count) { $cov.issues++ }
    if ($null -ne $sc) { $cov.scorecard++ }
  } catch {
    $rec['error'] = $_.Exception.Message
    $fail++
    $key = if ($_.Exception.Response) { 'HTTP ' + [int]$_.Exception.Response.StatusCode } else { 'network' }
    if (-not $errs.ContainsKey($key)) { $errs[$key] = 0 }
    $errs[$key]++
  }
  [System.IO.File]::AppendAllText($outPath, (($rec | ConvertTo-Json -Compress -Depth 6) + "`n"), $utf8)
  Write-Host ("  [{0,3}] {1,-42} {2}" -f ($n + 1), $id, $(if ($rec['ok']) { '文件 ' + @($rec['files']).Count + ' ｜ license ' + $(if ($rec['license']) { $rec['license'] } else { '—' }) + ' ｜ 改名史 ' + @($rec['previous_names']).Count + ' ｜ issues ' + $rec['open_issues'] } else { '失败: ' + $rec['error'] })) -ForegroundColor $(if ($rec['ok']) { 'Gray' } else { 'Yellow' })
  $n++
  if ($DelaySeconds -gt 0 -and $n -lt $MaxRequests) { Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000)) }
}

Write-Host ''
Write-Host '=== 本轮富化汇总 ===' -ForegroundColor Cyan
Write-Host ("  尝试 {0} ｜ 成功 {1} ｜ 失败 {2}" -f $n, $ok, $fail)
if ($ok -gt 0) {
  Write-Host ("  覆盖率：标准文件 {0}/{1} ｜ license {2}/{1} ｜ 改名史 {3}/{1} ｜ open_issues {4}/{1} ｜ Scorecard {5}/{1}" -f $cov.files, $ok, $cov.license, $cov.prev, $cov.issues, $cov.scorecard)
}
if ($errs.Count) { Write-Host ("  错误类型：" + (($errs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')) -ForegroundColor Yellow }
Write-Host '  续采：直接再跑一次本脚本（自动跳过已富化）✓'
