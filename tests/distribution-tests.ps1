# Portable offline behavioral tests; no Pester or personal history required.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$passed=0
function Assert($condition,[string]$name){if(-not $condition){throw "FAIL: $name"};$script:passed++;Write-Host "PASS: $name"}
try {
 . (Join-Path $root 'tools/score.ps1')
 foreach($case in @(@(80,'S'),@(65,'A'),@(55,'B'),@(45,'C'),@(44,'D'))){Assert ((Get-Tier $case[0]) -eq $case[1]) ('score boundary '+$case[0])}
 . (Join-Path $root 'tools/github-transport.ps1')
 Assert (Test-GitHubSearchResponse '{"total_count":0,"incomplete_results":false,"items":[]}') 'complete empty search is valid'
 Assert (-not(Test-GitHubSearchResponse '{"total_count":1,"incomplete_results":true,"items":[]}')) 'incomplete search is rejected'
 Assert (-not(Test-GitHubSearchResponse '{"items":[')) 'truncated search is rejected'
 Assert (-not(Get-Q3FallbackDecision $null).assessed) 'unknown Q3 cannot silently skip fallback'
 Assert (Get-Q3FallbackDecision @{ok=$true;newFaces=1;total_count=40}).required 'Q3 low new faces triggers fallback'
 Assert (-not(Get-Q3FallbackDecision @{ok=$true;newFaces=32;total_count=40}).required) 'Q3 with sufficient evidence needs no fallback'
 $retry=Get-GitHubRetryPolicy 429 @{'retry-after'='120'}
 Assert ($retry.Limited -and $retry.Delay -ge 120) 'Retry-After is respected'
 Assert (Get-GitHubRetryPolicy 401 @{}).Fatal 'authentication errors are fatal'
 $glossary=(Get-FileHash (Join-Path $root 'GLOSSARY.md')).Hash
 $lock=Get-Content (Join-Path $root 'tools/glossary-lock.json') -Raw|ConvertFrom-Json
 Assert ($glossary -eq $lock.sha256) 'locked glossary matches'
 . (Join-Path $root 'tools/evidence-store.ps1')
 $fixture=Join-Path $root ('data/_tmp/distribution-test-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Force $fixture|Out-Null
 '{"publication_mode":"declared-editorial-batch"}' | Set-Content (Join-Path $fixture 'policy.tmp')
 New-Item -ItemType Directory -Force (Join-Path $fixture 'data')|Out-Null
 Move-Item -LiteralPath (Join-Path $fixture 'policy.tmp') -Destination (Join-Path $fixture 'data/search-policy.json')
 $s=Open-EvidenceStore $fixture
 try {
  $task=Add-EvidenceTask $s 'fixture/tool' readme 'v1'
  $body='{"type":"file","sha":"git1","encoding":"base64","content":"SGVsbG8="}'
  $cache=Save-EvidenceResult $s $task $body @{} present 200
  $cache.fetched_at=[datetimeoffset]::UtcNow.AddDays(-1).ToString('o')
  Assert (Add-EvidenceTask $s 'fixture/tool' readme 'v1').reused 'fresh unchanged evidence is reused across dates'
  Assert ((Add-EvidenceTask $s 'fixture/tool' readme 'v2').state -eq 'pending') 'changed resource version requires fresh evidence'
  $path=Get-EvidencePath $fixture $cache.path
  [IO.File]::WriteAllText($path,'corrupt')
  $rejected=$false;try{$null=Get-EvidenceCache $s 'fixture/tool' readme}catch{$rejected=$true}
  Assert $rejected 'modified cached bytes are rejected'
 } finally {$s.guard.Dispose()}
 $out=& pwsh -NoProfile -NonInteractive -File (Join-Path $root 'tools/release-readiness.ps1') -Root $fixture -Date 2026-10-19 2>&1
 Assert ($LASTEXITCODE -ne 0 -and ($out -join ' ') -match 'BLOCKED') 'missing review scope blocks publication'
 Write-Host "PORTABLE TESTS: $passed passed / 0 failed"
 exit 0
} catch {Write-Host $_.Exception.Message;exit 1}
