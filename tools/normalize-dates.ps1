# normalize-dates.ps1 — 把快照/元数据里的美式日期时间统一成 ISO 8601（UTC）
#
# 背景：2026-10-24 两批采集里，16:10 那批的 created_at / pushed_at 被写成
#   "10/14/2026 23:21:44"（Excel / 本地化格式），schema 只校验 string 所以不报错，
#   但按字符串排序、页面解析都会出问题。本脚本只改这两个字段，幂等。
#
# 用法：
#   .\tools\normalize-dates.ps1            # dry-run：只报告会改多少行
#   .\tools\normalize-dates.ps1 -Apply     # 实际写入（保持原行尾 / 无 BOM）
param([switch]$Apply)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$files = @()
$files += Get-ChildItem (Join-Path $root 'data\snapshots') -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
$files += Get-ChildItem (Join-Path $root 'data\meta')      -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
$total = 0
foreach ($f in $files) {
  $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
  $n = 0
  $new = [regex]::Replace($text, '"(created_at|pushed_at)":"(\d{1,2})/(\d{1,2})/(\d{4}) (\d{2}):(\d{2})(?::(\d{2}))?"', {
    param($m)
    $mon = [int]$m.Groups[2].Value
    $day = [int]$m.Groups[3].Value
    $sec = if ($m.Groups[7].Success) { $m.Groups[7].Value } else { '00' }
    $script:n++
    return ('"{0}":"{1}-{2:D2}-{3:D2}T{4}:{5}:{6}Z"' -f $m.Groups[1].Value, $m.Groups[4].Value, $mon, $day, $m.Groups[5].Value, $m.Groups[6].Value, $sec)
  })
  if ($n -gt 0) {
    $total += $n
    Write-Host ("{0}: {1} 个字段{2}" -f $f.Name, $n, $(if ($Apply) { '（已写）' } else { '（dry-run）' }))
    if ($Apply) { [IO.File]::WriteAllText($f.FullName, $new, $utf8) }
  }
}
Write-Host ("合计 {0} 个字段{1}" -f $total, $(if ($Apply) { '' } else { '；加 -Apply 才写入' }))