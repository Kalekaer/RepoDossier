# publish-archive.ps1 — 上线「历史档案入口 + W01 周报 + 周一入口」
# 规矩：唯一真源是 tools/；data/site/ 是上线产物；不自动 git commit / push。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function P([string]$rel) { Join-Path $root $rel }
$enc = New-Object System.Text.UTF8Encoding($false)
function ReadUtf8([string]$path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
function WriteUtf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $enc) }

$homeSrc = P 'tools\home-brutal-token.html'
$homeBak = P 'data\_tmp\home-brutal-token.before-archive.html'
$siteDir = P 'data\site'
New-Item -ItemType Directory -Force -Path $siteDir | Out-Null
Copy-Item -LiteralPath $homeSrc -Destination $homeBak -Force

try {
  # ---------- 1. 周报 W01（2026-10-20 起由 build-weekly 生成，不再直接拷样张） ----------
  $weeklyOut = & (P 'tools\build-weekly.ps1') -WeekStart '2026-10-12' *>&1
  $weeklyCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
  if ($weeklyCode -ne 0 -or -not (Test-Path (P 'data\site\weekly-2026-10-18.generated.html'))) {
    throw ("build-weekly 失败：`n" + ($weeklyOut -join "`n"))
  }

  # ---------- 2. 周一日报（带 W01 周报入口） ----------
  $monday = ReadUtf8 (P 'archive\2026-10\样张-05-周一入口.html')
  $monday = $monday.Replace('../../assets/', '../assets/').Replace('../assets/', '../../assets/')
  $monday = $monday.Replace('周报样张.html', 'weekly-2026-10-18.generated.html')
  $monday = $monday.Replace('首页-报刊亭.html', 'home-brutal-token.generated.html')
  WriteUtf8 (P 'data\site\daily-2026-10-19.generated.html') $monday

  # ---------- 3. 空白占位 ----------
  $blank = ReadUtf8 (P '设计样张\空白报.html')
  $blank = $blank.Replace('../../assets/', '../assets/').Replace('../assets/', '../../assets/')
  $blank = $blank.Replace('首页-报刊亭.html', 'home-brutal-token.generated.html')
  $blank = $blank.Replace('历史档案.html', 'home-brutal-token.generated.html')
  WriteUtf8 (P 'data\site\blank-issue.html') $blank

  # ---------- 4. 共享返回脚本 ----------
  Copy-Item -LiteralPath (P '设计样张\kiosk-return.js') -Destination (P 'data\site\kiosk-return.js') -Force

  # ---------- 4b. 冻结当天日报为历史归档（防止明天覆盖今天） ----------
  $dailyCurrent = P 'data\site\daily-layout-c-finsara.generated.html'
  if (Test-Path $dailyCurrent) {
    $dailyHtml = ReadUtf8 $dailyCurrent
    $m = [regex]::Match($dailyHtml, '"date"\s*:\s*"(\d{4}-\d{2}-\d{2})"')
    if ($m.Success) {
      $archiveDaily = P ("data\site\daily-{0}.generated.html" -f $m.Groups[1].Value)
      if (-not (Test-Path $archiveDaily)) { Copy-Item -LiteralPath $dailyCurrent -Destination $archiveDaily -Force }
    }
  }

  # ---------- 5. 首页源注入历史档案（触发器进 hero 右下角，浮窗留在 body 末尾） ----------
  $html = ReadUtf8 $homeSrc
  $html = [regex]::Replace($html, '(?s)\r?\n?<!-- ARCHIVE_TRIGGER:START -->.*?<!-- ARCHIVE_TRIGGER:END -->', '')
  $html = [regex]::Replace($html, '(?s)\r?\n?<!-- ARCHIVE_HOME:CSS START -->.*?<!-- ARCHIVE_HOME:CSS END -->', '')
  $html = [regex]::Replace($html, '(?s)\r?\n?<!-- ARCHIVE_HOME:HTML START -->.*?<!-- ARCHIVE_HOME:HTML END -->', '')
  $html = [regex]::Replace($html, '(?s)\r?\n?<!-- ARCHIVE_HOME:JS START -->.*?<!-- ARCHIVE_HOME:JS END -->', '')

  $css = ReadUtf8 (P '设计样张\_kiosk.css').Replace('../../assets/', '../assets/').Replace('../assets/', '../../assets/')
  $frag = ReadUtf8 (P '设计样张\_kiosk.html')
  $js = ReadUtf8 (P '设计样张\_kiosk.js')

  # 把片段拆成「触发器」和「浮窗」：触发器放到 hero 里，才能贴在 hero 的右下角
  $btnEnd = $frag.IndexOf('</button>')
  if ($btnEnd -lt 0) { throw '_kiosk.html 找不到触发器的 </button>' }
  $btnEnd += '</button>'.Length
  $trigger = $frag.Substring(0, $btnEnd).Trim()
  $modal = $frag.Substring($btnEnd).Trim()

  $heroAt = $html.IndexOf('<section class="hero">')
  if ($heroAt -lt 0) { throw '首页源找不到 hero 段' }
  $heroClose = $html.IndexOf('</section>', $heroAt)
  if ($heroClose -lt 0) { throw 'hero 段找不到 </section>' }
  $html = $html.Insert($heroClose, "`n  <!-- ARCHIVE_TRIGGER:START -->`n  $trigger`n  <!-- ARCHIVE_TRIGGER:END -->`n")

  $styleAt = $html.LastIndexOf('</style>')
  if ($styleAt -lt 0) { throw '首页源找不到 </style>' }
  $html = $html.Insert($styleAt, "`n<!-- ARCHIVE_HOME:CSS START -->`n<style>`n$css`n</style>`n<!-- ARCHIVE_HOME:CSS END -->`n")

  $bodyAt = $html.LastIndexOf('</body>')
  if ($bodyAt -lt 0) { throw '首页源找不到 </body>' }
  $html = $html.Insert($bodyAt, "`n<!-- ARCHIVE_HOME:HTML START -->`n$modal`n<!-- ARCHIVE_HOME:HTML END -->`n")
  $bodyAt = $html.LastIndexOf('</body>')
  $html = $html.Insert($bodyAt, "`n<!-- ARCHIVE_HOME:JS START -->`n<script>`n$js`n</script>`n<!-- ARCHIVE_HOME:JS END -->`n")
  WriteUtf8 $homeSrc $html

  # ---------- 6. 用正式生成器重建首页 ----------
  $out = & (P 'tools\build-samples.ps1') -Layout home *>&1
  $code = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
  if ($code -ne 0) { throw ("build-samples 失败：`n" + ($out -join "`n")) }

  # ---------- 7. 报告 ----------
  $files = @(
    'data\site\home-brutal-token.generated.html',
    'data\site\weekly-2026-10-18.generated.html',
    'data\site\daily-2026-10-19.generated.html',
    'data\site\blank-issue.html',
    'data\site\kiosk-return.js'
  )
  foreach ($f in $files) {
    $p = P $f
    if (-not (Test-Path $p)) { throw "缺少上线文件：$f" }
    Write-Host ("OK  {0,-58} {1,7} KB" -f $f, [math]::Round((Get-Item $p).Length / 1KB, 1))
  }
  Write-Host 'PUBLISH archive: data/site ready（未 commit / 未 push）'
}
catch {
  Copy-Item -LiteralPath $homeBak -Destination $homeSrc -Force
  Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
