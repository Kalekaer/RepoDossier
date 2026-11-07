param([string]$Root=(Split-Path -Parent $PSScriptRoot),[switch]$Pristine)
$ErrorActionPreference='Stop'
try {
 $manifest=Get-Content (Join-Path $Root 'distribution.json') -Raw|ConvertFrom-Json
 if($manifest.schema_version -ne 1 -or $manifest.profile -ne 'demo' -or $manifest.version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid distribution manifest'}
 $required=@('GLOSSARY.md','日报结构.md','AGENTS.md','README.md','PROMPT-daily.md','RUBRIC.md','SOURCES.md','tools/check-all.ps1','tools/release-readiness.ps1','tests/distribution-tests.ps1','tools/glossary-lock.json','.agents/skills/github-daily-picks/SKILL.md','.dsh/skills/github-daily-picks/SKILL.md','index.html','tools/serve-site.py','tools/start-site.ps1')
 if([version]$manifest.version -ge [version]'1.3.0'){$required+=@('tools/query-contract.ps1','tools/check-daily-network.ps1','tools/daily-network.ps1','tools/fetch-daily.ps1','tools/collect-daily.ps1','tools/check-site-assets.ps1','tools/check-site-assets.py','tests/test_site_assets.py','docs/network-and-query-reliability.md')}
 $names=@{};$prefix=[IO.Path]::GetFullPath($Root)+[IO.Path]::DirectorySeparatorChar
 foreach($entry in $manifest.files){
  $rel=[string]$entry.path
  if($rel -match '(^|/)(\.\.?|_backup|_tmp)(/|$)' -or $rel -match '(^|/)relink-session\.js$' -or [IO.Path]::IsPathRooted($rel)){throw 'Disallowed manifest path'}
  $path=[IO.Path]::GetFullPath((Join-Path $Root $rel))
  if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $names.ContainsKey($rel)){throw 'Invalid or duplicate manifest path'}
  $names[$rel]=$true
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing distribution file: $rel"}
  # Runtime data/pages are meant to change. Code and locked rules must stay verified.
  $mutable=$rel -match '^(reports/|legacy/|examples/|data/(meta/|picks/|snapshots/|human/|site/|evidence/))' -or $rel -in @('index.html','overview.html','config.json','data/seen.jsonl','data/projects.jsonl','data/events.jsonl','data/.projects-signature','data/recommend-log.csv','data/user-notes.jsonl','data/workspaces.jsonl','data/status-log.jsonl')
  if($Pristine -or -not $mutable){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256){throw "Distribution content changed: $rel"}}
 }
 foreach($rel in $required){if(-not $names.ContainsKey($rel)){throw "Required distribution file not declared: $rel"}}
 Write-Host "DISTRIBUTION CHECK: PASS ($($names.Count) files; pristine=$Pristine)"
 exit 0
} catch {Write-Host ('DISTRIBUTION CHECK: FAIL '+$_.Exception.Message);exit 1}
