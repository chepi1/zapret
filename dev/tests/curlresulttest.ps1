param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
foreach ($relative in @('tools/test.ps1','dev/strategylab.ps1')) {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg $relative),[ref]$null,[ref]$null)
    foreach ($fn in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
function Parse($Code,$Exit,$Up=0,$Down=0,[bool]$Post=$false) {
    $item=[pscustomobject]@{T=[pscustomobject]@{Group='Clean';Name='fixture';Url='https://example.test/';Post=$Post};P=[pscustomobject]@{ExitCode=$Exit};Out=[pscustomobject]@{Result=($Code+' '+$Up+' '+$Down+' 0.05 0.1')}}
    Convert-CurlResult $item
}
$timeout=Parse '200' 28 0 15114
Check 'actual reported HTTP200 timeout is a freeze rather than a successful strategy' ($timeout.State -eq 'FREEZE' -and $timeout.Code -eq '200' -and $timeout.Exit -eq 28)
Check 'partial HTTP200 response with exit18 is not successful' ((Parse '200' 18 0 16384).State -eq 'FAIL')
Check 'HTTP206 headers without received body do not hide a timeout' ((Parse '206' 28).State -eq 'FAIL')
Check 'POST response-body freeze is detected even after all upload bytes were sent' ((Parse '404' 28 65536 7813 $true).State -eq 'FREEZE')
Check 'upload timeout remains a freeze' ((Parse '000' 28 16384 0 $true).State -eq 'FREEZE')
Check 'completed403 response remains valid reachability' ((Parse '403' 0 65536 100 $true).State -eq 'OK')
Check 'completed HEAD-style response with no body remains valid' ((Parse '200' 0).State -eq 'OK')
Check 'DNS failure remains unknown' ((Parse '000' 6).State -eq 'NA')
Check 'missing exit is not assumed to be successful zero' ((Parse '200' $null).State -eq 'FAIL')
foreach ($exitCode in @(23,35,56,63,-1)) { Check ('nonzero curl exit '+$exitCode+' cannot become OK just because headers arrived') ((Parse '200' $exitCode 0 100).State -eq 'FAIL') }
Check 'empty or corrupt HTTP status with exit0 is not success' ((Parse '000' 0).State -eq 'FAIL' -and (Parse 'oops' 0).State -eq 'FAIL')
$Parallel=16;$RetryMax=16;$HarmSlowMs=500;$GroupNames=[ordered]@{Clean='Clean';DPI='DPI';YouTube='YouTube'}
$target=[pscustomobject]@{Group='Clean';Name='fixture';Url='https://example.test/';Post=$false}
Check 'HTTP timeout enters the real retry path' (@(Get-RetryTargets @($target) @($timeout) @{fixture=100}).Count -eq 1)
$twice=Parse '200' 28 0 15114
$failedTwice=@(Merge-Retry @($twice) @((Parse '200' 28 0 15114)))
$summary=Get-RunSummary '12' 'fixture' $failedTwice @{fixture=100}
Check 'reproduced timeout harms the actual score instead of being counted clean' ($summary.Harm -eq 1 -and $summary.Score -eq -1)
$expected=[pscustomobject]@{Group='Clean';Name='fixture';State='OK';TlsMs=100}
Check 'HTTP timeout cannot confirm a working final combination' (-not (Test-FinalCandidateRows @($expected) @($timeout)).Ok)
$retry=Parse '200' 0 0 100
$merged=@(Merge-Retry @($timeout) @($retry))
Check 'successful retry keeps the first attempt marked flaky' ($merged[0].State -eq 'OK' -and $merged[0].Flaky -and $merged[0].Tries -eq 2)
if (-not (Get-Command Get-LabCurlState -ErrorAction SilentlyContinue)) { throw 'FAIL lab classification is not shared' }
Check 'laboratory rejects the same partial and stalled transfers' ((Get-LabCurlState '200' 28 0 15114 $false) -eq 'F' -and (Get-LabCurlState '200' 18 0 16384 $false) -eq 'c18')
Check 'laboratory preserves completed response and no-progress timeout labels' ((Get-LabCurlState '404' 0 65536 100 $true) -eq '+' -and (Get-LabCurlState '000' 28 0 0 $false) -eq 'H')
if ($fails) { exit 1 }
