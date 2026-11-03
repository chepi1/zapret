# Read-only sampling of an explicitly selected process. Never starts/stops it or loads lib.ps1.
param([Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$ProcessId,[ValidateRange(1,30)][int]$DurationSec=10,[ValidateRange(100,5000)][int]$IntervalMs=250,[Parameter(Mandatory=$true)][string]$OutFile)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $OutFile) { throw 'Output already exists; select a new artifact path.' }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/selection.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/processmetrics.ps1')
$observed=$null;$samples=New-Object 'System.Collections.Generic.List[object]'
try {
    try { $observed=[Diagnostics.Process]::GetProcessById($ProcessId) } catch { }
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $sample=Get-ProcessResourceSample $observed;$samples.Add($sample)
        if ($sample.ResourceStatus -ne 'Ready') { break }
        $remaining=$DurationSec*1000-$clock.Elapsed.TotalMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][math]::Max(1,[math]::Min($IntervalMs,$remaining)))
    } while ($true)
} finally { if ($observed) { $observed.Dispose() } }
$result=[pscustomobject]@{Schema=1;Scope='ProcessOnly';RequestedProcessId=$ProcessId;Samples=@($samples.ToArray());Window=(Get-ProcessResourceWindow @($samples.ToArray()))}
$stream=[IO.File]::Open($OutFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try { $bytes=[Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 8));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
Write-Output $result.Window.Status
