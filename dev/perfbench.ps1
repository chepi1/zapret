# Offline replay only. No lib.ps1, process control, DNS or external requests.
param([Parameter(Mandatory=$true)][string]$PlanFile,[Parameter(Mandatory=$true)][string]$JournalFile,[Parameter(Mandatory=$true)][string]$OutFile)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/selection.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/comparison.ps1')
foreach ($file in @($PlanFile,$JournalFile)) {
    $item=Get-Item -LiteralPath $file -ErrorAction Stop
    if ($item.Length -gt 67108864 -or $item.PSIsContainer) { throw 'Evidence file is too large or is not a file.' }
    if ([IO.Path]::GetFullPath($file) -eq [IO.Path]::GetFullPath($OutFile)) { throw 'Output must not overwrite evidence.' }
}
$plan=[IO.File]::ReadAllText($PlanFile) | ConvertFrom-Json
$rows=@(foreach ($line in [IO.File]::ReadLines($JournalFile)) { if ($line.Trim()) { $line | ConvertFrom-Json } })
$assessment=Get-FinalistAssessment $plan $rows
[IO.File]::WriteAllText($OutFile,($assessment | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Write-Output $assessment.Status
