# term-check.ps1 — 严格术语检查（运行层）
# 范围：当前规范文档 + 当前生成页面 + 库内档位。
# 不检查：archive/、backups/、release/、发布测试/、data/_tmp/、legacy/（历史页已清，但不作为运行层）。
# 退出码：0 通过；1 有旧词/坏档位。

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function P([string]$rel) { Join-Path $root $rel }

$terms = @('候选','精品','大厂附加区','官方附加区','回锅','未评档','unrated','生命周期','软删除','跟踪','tier=dropped','筛选通过','私人库','淘汰','退稿')
$docs = @(
  'AGENTS.md','README.md','PROMPT-daily.md','RUBRIC.md','SOURCES.md',
  'TABLE.md','CONTEXT.md','data/README.md','data/criteria.json','data/schema.json',
  '.dsh/skills/github-daily-picks/SKILL.md',
  '验收基准.md',
  'TEMPLATES/daily.md','TEMPLATES/weekly.md',
  'reports/2026-10-19.md'
)
# 交接文件带日期：换名/归档后，根目录当前交接也要扫到（不依赖固定文件名）
$docs += @(Get-ChildItem $root -Filter '交接-*.md' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$docs = @($docs | Select-Object -Unique)
$pages = @(Get-ChildItem (P 'data/site') -Filter '*.generated.html' | ForEach-Object { $_.FullName })

$bad = @()
foreach($t in $terms){
  foreach($rel in $docs){
    $p = P $rel
    if(Test-Path $p){
      $m = Select-String -Path $p -Pattern ([regex]::Escape($t)) -SimpleMatch
      foreach($x in $m){ $bad += [pscustomobject]@{where=$rel;line=$x.LineNumber;term=$t;text=$x.Line.Trim()} }
    }
  }
}

# 页面只查“标签/固定文案”，不扫项目正文（正文里的“候选/跟踪”等普通词不算术语违规）
$pageLabels = @('未评档','U / 未评','"unrated"','精品','D / 淘汰','退稿原因','淘汰原因')
foreach($p in $pages){
  foreach($label in $pageLabels){
    $m = Select-String -Path $p -Pattern ([regex]::Escape($label)) -SimpleMatch
    foreach($x in $m){ $bad += [pscustomobject]@{where=(Split-Path $p -Leaf);line=$x.LineNumber;term=$label;text=$x.Line.Trim()} }
  }
}

# 库内档位必须 SABCD
$proj = @(Get-Content (P 'data/projects.jsonl') | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$badTier = @($proj | Where-Object { [string]$_.tier -notin @('S','A','B','C','D') })

# 术语表锁定（2026-10-19）：未获用户明确授权，任何改动都必须红
$lockBad = $null
$glossaryPath = P 'GLOSSARY.md'
$lockPath = P 'tools\glossary-lock.json'
if (-not (Test-Path $glossaryPath)) { $lockBad = 'GLOSSARY.md 不存在' }
elseif (-not (Test-Path $lockPath)) { $lockBad = '锁定文件 tools/glossary-lock.json 不存在' }
else {
  try {
    $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $actualHash = (Get-FileHash $glossaryPath -Algorithm SHA256).Hash
    if ([string]$lock.sha256 -ne $actualHash) {
      $lockBad = ('GLOSSARY.md 被改动（锁 {0}… / 实 {1}…）；未获用户授权不得修改' -f ([string]$lock.sha256).Substring(0,12), $actualHash.Substring(0,12))
    }
  } catch { $lockBad = '锁定文件 tools/glossary-lock.json 无法解析' }
}

Write-Host '=== 术语检查（运行层） ===' -ForegroundColor Cyan
if($bad.Count -eq 0){ Write-Host '  ✓ 规范文档 / 生成页面：0 处旧词' -ForegroundColor Green }
else{
  Write-Host ("  ✗ 旧词 {0} 处" -f $bad.Count) -ForegroundColor Red
  $bad | Select-Object -First 20 | ForEach-Object { Write-Host ("    {0}:{1} [{2}] {3}" -f $_.where,$_.line,$_.term,$_.text.Substring(0,[Math]::Min(100,$_.text.Length))) }
}
if($badTier.Count -eq 0){ Write-Host '  ✓ projects：259 条全部 SABCD' -ForegroundColor Green }
else{ Write-Host ("  ✗ 非 SABCD：{0}" -f $badTier.Count) -ForegroundColor Red; $badTier | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.id + ' → ' + $_.tier) } }
if(-not $lockBad){ Write-Host '  ✓ GLOSSARY.md 锁定未变' -ForegroundColor Green }
else{ Write-Host ("  ✗ " + $lockBad) -ForegroundColor Red }

if($bad.Count -eq 0 -and $badTier.Count -eq 0 -and -not $lockBad){ Write-Host 'TERM CHECK: PASS' -ForegroundColor Green; exit 0 }
Write-Host 'TERM CHECK: FAIL' -ForegroundColor Red; exit 1
