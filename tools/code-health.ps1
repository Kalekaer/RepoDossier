# code-health.ps1 — 代码结构体检（不是 lint，是"屎山体检"）
#
# 与 PSScriptAnalyzer 分工：
#   PSScriptAnalyzer 管「单条语句对不对」（未用变量、空 catch、BOM…）→ 目前 0 告警
#   本脚本管「结构健不健康」：文件规模、函数长度、顶层语句、嵌套深度、
#                            跨文件重复定义、超长行、内嵌 HTML/CSS/JS、待办标记、重复拷贝
# 用法：pwsh -File .\tools\code-health.ps1 [-Top 12]

param([int]$Top = 12)

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dirs = @('tools', 'tests', '发布测试', '.dsh\skills\github-daily-picks')

$files = @()
foreach ($d in $dirs) {
  $p = Join-Path $root $d
  if (Test-Path $p) { $files += Get-ChildItem $p -Filter *.ps1 -File -Recurse -ErrorAction SilentlyContinue }
}
# 只统计真实源码：排除「测试副本目录 / 备份 / 发布包」里的拷贝，
# 否则同一个脚本会被统计 4~5 次，把所有指标都污染掉。
$files = @($files | Where-Object { $_.FullName -notmatch 'v5\.1\.0-测试副本|\\_backup\\|\\release\\|\\发布测试\\[^\\]+\\' })

function Get-ScriptStats([string]$path) {
  $text  = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  $lines = $text -split "`r?`n"
  $code  = @($lines | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
  $cmt   = @($lines | Where-Object { $_.Trim().StartsWith('#') })

  $fns = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*function\s+([A-Za-z0-9_\-]+)') {
      $fns += [pscustomobject]@{ name = $Matches[1]; start = $i }
    }
  }
  $fnInfo = @()
  for ($k = 0; $k -lt $fns.Count; $k++) {
    $end = if ($k + 1 -lt $fns.Count) { $fns[$k + 1].start } else { $lines.Count }
    $fnInfo += [pscustomobject]@{ name = $fns[$k].name; lines = ($end - $fns[$k].start) }
  }

  $depth = 0; $maxDepth = 0
  foreach ($l in $code) {
    $depth += ([regex]::Matches($l, '\{')).Count - ([regex]::Matches($l, '\}')).Count
    if ($depth -gt $maxDepth) { $maxDepth = $depth }
  }

  [pscustomobject]@{
    file         = (Split-Path $path -Leaf)
    full         = $path
    lines        = $lines.Count
    codeLines    = $code.Count
    commentLines = $cmt.Count
    functions    = $fnInfo
    fnCount      = $fnInfo.Count
    longestFn    = if ($fnInfo.Count) { ($fnInfo | Sort-Object lines -Descending | Select-Object -First 1).lines } else { 0 }
    topStmt      = @($code | Where-Object { $_ -notmatch '^\s' -and $_ -notmatch '^\s*[}\]]' }).Count
    maxNest      = $maxDepth
    longLines    = @($lines | Where-Object { $_.Length -gt 200 }).Count
    hereDocs     = @($lines | Where-Object { $_ -match '^\s*@[''"]' }).Count
    markers      = @($lines | Where-Object { $_ -match 'TODO|FIXME|HACK|XXX|临时|变通|workaround' }).Count
    bytes        = (Get-Item $path).Length
  }
}

$stats = @()
foreach ($f in $files) { $stats += Get-ScriptStats $f.FullName }

$funcHome = @{}
foreach ($s in $stats) {
  foreach ($fn in $s.functions) {
    if (-not $funcHome.ContainsKey($fn.name)) { $funcHome[$fn.name] = @() }
    if ($funcHome[$fn.name] -notcontains $s.file) { $funcHome[$fn.name] += $s.file }
  }
}

$totalLines = ($stats | Measure-Object lines -Sum).Sum
$totalCode  = ($stats | Measure-Object codeLines -Sum).Sum
$totalCmt   = ($stats | Measure-Object commentLines -Sum).Sum

Write-Host ''
Write-Host '=== A. 规模总览 ===' -ForegroundColor Cyan
Write-Host ("  脚本 {0} 个 ｜ 总行 {1} ｜ 代码行 {2} ｜ 注释行 {3} ｜ 注释/代码 = {4}" -f `
  $stats.Count, $totalLines, $totalCode, $totalCmt, [math]::Round($totalCmt / [math]::Max(1, $totalCode), 2))
$stats | Sort-Object codeLines -Descending | Select-Object -First $Top | ForEach-Object {
  Write-Host ("  {0,-22} 行{1,5} 代码{2,5} 注释{3,4} 函数{4,3} 最长函数{5,4} 顶层句{6,4} 嵌套{7,2} 长行{8,3} here{9,2} 标记{10}" -f `
    $_.file, $_.lines, $_.codeLines, $_.commentLines, $_.fnCount, $_.longestFn, $_.topStmt, $_.maxNest, $_.longLines, $_.hereDocs, $_.markers)
}

Write-Host ''
Write-Host '=== B. 跨文件重复定义的函数（复制粘贴信号） ===' -ForegroundColor Cyan
$dups = $funcHome.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | Sort-Object { $_.Value.Count } -Descending
Write-Host ("  重复函数名: {0} 个" -f @($dups).Count)
@($dups) | Select-Object -First 15 | ForEach-Object {
  Write-Host ("    {0,-16} ×{1,-3} {2}" -f $_.Key, $_.Value.Count, (($_.Value | Sort-Object) -join ', '))
}

Write-Host ''
Write-Host '=== C. 最长的 10 个函数 ===' -ForegroundColor Cyan
$allFn = @()
foreach ($s in $stats) { foreach ($fn in $s.functions) { $allFn += [pscustomobject]@{ name = $fn.name; file = $s.file; lines = $fn.lines } } }
$allFn | Sort-Object lines -Descending | Select-Object -First 10 | ForEach-Object {
  Write-Host ("    {0,-28} {1,4} 行  ({2})" -f $_.name, $_.lines, $_.file)
}

Write-Host ''
Write-Host '=== D. 结构性问题 ===' -ForegroundColor Cyan
Write-Host '  顶层语句 > 100（脚本式，不是函数式）:'
@($stats | Where-Object { $_.topStmt -gt 100 } | Sort-Object topStmt -Descending) | ForEach-Object {
  Write-Host ("    {0,-22} {1} 句" -f $_.file, $_.topStmt)
}
Write-Host '  最大嵌套 >= 5:'
@($stats | Where-Object { $_.maxNest -ge 5 }) | ForEach-Object { Write-Host ("    {0,-22} 嵌套 {1}" -f $_.file, $_.maxNest) }
Write-Host '  内嵌 here-string（HTML/CSS/JS 混进 .ps1）:'
@($stats | Where-Object { $_.hereDocs -gt 0 }) | ForEach-Object { Write-Host ("    {0,-22} {1} 处" -f $_.file, $_.hereDocs) }
Write-Host '  超长行 > 200 字符:'
@($stats | Where-Object { $_.longLines -gt 0 }) | ForEach-Object { Write-Host ("    {0,-22} {1} 行" -f $_.file, $_.longLines) }
Write-Host '  待办/临时标记:'
@($stats | Where-Object { $_.markers -gt 0 }) | ForEach-Object { Write-Host ("    {0,-22} {1} 处" -f $_.file, $_.markers) }

Write-Host ''
Write-Host '=== E. 与发布包的重复（同一套脚本两份拷贝） ===' -ForegroundColor Cyan
$pkg = Join-Path $root 'release\github-daily-picks'
if (Test-Path $pkg) {
  $pkgFiles = Get-ChildItem $pkg -Filter *.ps1 -File -Recurse | Where-Object { $_.FullName -notmatch '\\\.git\\' }
  $sameCount = 0; $diffCount = 0; $onlyPkg = 0
  foreach ($pf in $pkgFiles) {
    $lib = Join-Path $root ('tools\' + $pf.Name)
    if (-not (Test-Path $lib)) { $onlyPkg++; continue }
    if ((Get-Item $lib).Length -eq $pf.Length) { $sameCount++ } else { $diffCount++ }
  }
  Write-Host ("  发布包 .ps1 {0} 个 ｜ 与库字节相同 {1} ｜ 不同（需人工同步） {2} ｜ 只在发布包 {3}" -f `
    $pkgFiles.Count, $sameCount, $diffCount, $onlyPkg)
} else {
  Write-Host '  （没有发布包）'
}

Write-Host ''
Write-Host '=== F. 重复拷贝（同一内容多份，容易改一份漏一份） ===' -ForegroundColor Cyan
$byHash = @{}
foreach ($f in $files) {
  $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
  if (-not $byHash.ContainsKey($h)) { $byHash[$h] = @() }
  $byHash[$h] += $f.FullName
}
$copies = @($byHash.Values | Where-Object { $_.Count -gt 1 })
Write-Host ("  内容完全相同的拷贝组: {0} 组" -f $copies.Count)
foreach ($g in $copies) {
  $rel = @($g | ForEach-Object { $_.Substring($root.Length + 1) })
  Write-Host ("    ×{0}  {1}" -f $g.Count, ($rel -join '  |  '))
}
Write-Host ''

# 明确退出码（与 sync-projects / build-overview 同理：原来没有 exit → 调用方会读到上一次的 0 ✗）
exit 0
