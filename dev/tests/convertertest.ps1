param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
& python -I (Join-Path $PSScriptRoot 'convertertest.py') $Pkg
exit $LASTEXITCODE
