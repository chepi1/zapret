# Лаборатория: чтение JSON-набора и пустой пакет запросов, без сети/перехвата.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'dev\strategylab.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Resolve-DnsName { New-Object PSObject -Property @{ Type = 'A'; IPAddress = '192.0.2.1' } }
$fails = 0
$targets = @(Read-LabTargets)
$dpi = @($targets | Where-Object { $_.Key -like 'DPI|*' })
if ($dpi.Count -eq 36) { Write-Host 'ok   all 36 DPI targets read from JSON' } else { Write-Host ('FAIL DPI target count: ' + $dpi.Count); $fails++ }
try {
    $rows = @(Invoke-LabBatch @() '')
    if ($rows.Count -ne 0) { throw 'Unexpected rows' }
    Write-Host 'ok   empty batch returns an empty array'
} catch { Write-Host ('FAIL empty batch: ' + $_.Exception.Message); $fails++ }
if ($fails) { exit 1 }
Write-Host 'all ok'
