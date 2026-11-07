param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
& python (Join-Path (Split-Path -Parent $PSScriptRoot) 'tests/test_site_assets.py')
if($LASTEXITCODE){exit $LASTEXITCODE}
& python (Join-Path $PSScriptRoot 'check-site-assets.py') --root $Root
exit $LASTEXITCODE
