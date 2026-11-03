# Native Windows process counters on our own TEMP PowerShell child. No network/driver.
param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if (-not (Get-Command Get-ProcessResourceSample -ErrorAction SilentlyContinue)) { throw 'FAIL process sampler is missing' }
$fixture=Join-Path $Script:Runtime ('resource-child-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$childFile=Join-Path $fixture 'child.ps1';$signal=Join-Path $fixture 'signal';$out=Join-Path $fixture 'observed.json'
$source=@'
param($Signal)
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText(($Signal+'.ready'),'ready')
$life=[Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath ($Signal+'.go')) -and $life.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 10 }
$payload=New-Object byte[] (32*1024*1024)
for ($i=0;$i -lt $payload.Length;$i+=4096) { $payload[$i]=1 }
$cpu=[Diagnostics.Stopwatch]::StartNew()
while ($cpu.Elapsed.TotalMilliseconds -lt 400) { for ($i=0;$i -lt 1000;$i++) { [void][math]::Sqrt($i) } }
[IO.File]::WriteAllText(($Signal+'.done'),'done')
while ($life.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 20 }
'@
[IO.File]::WriteAllText($childFile,$source,(New-Object Text.UTF8Encoding($true)))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$ps;$start.Arguments='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-WinArg $childFile)+' -Signal '+(ConvertTo-WinArg $signal)
$start.UseShellExecute=$false;$start.CreateNoWindow=$true
$child=$null;$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
try {
    $child=[Diagnostics.Process]::Start($start)
    for ($i=0;$i -lt 150 -and -not (Test-Path ($signal+'.ready')) -and -not $child.HasExited;$i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path ($signal+'.ready'))) { throw 'Child fixture did not become ready' }
    $before=Get-ProcessResourceSample $child
    [IO.File]::WriteAllText(($signal+'.go'),'go')
    for ($i=0;$i -lt 150 -and -not (Test-Path ($signal+'.done')) -and -not $child.HasExited;$i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path ($signal+'.done'))) { throw 'Child fixture did not finish controlled work' }
    $after=Get-ProcessResourceSample $child
    $window=Get-ProcessResourceWindow @($before,$after)
    Check 'native sample identifies our child rather than the sampler host' ($before.ResourceStatus -eq 'Ready' -and $before.ProcessId -eq $child.Id -and $before.ProcessId -ne $PID -and $before.ProcessStartKey -match '^\d{18}$')
    Check 'native CPU work produces a positive accounted CPU delta' ($window.Status -eq 'Ready' -and $window.CpuTimeMs -gt 0 -and $window.ElapsedMs -gt 0)
    Check 'Refresh observes the child allocation after its initial sample' ($window.PrivateBytesEnd -ge $window.PrivateBytesStart+16*1024*1024 -and $window.WorkingSetBytesEnd -gt 0)
    & (Join-Path $Pkg 'dev/perfprobe.ps1') -ProcessId $child.Id -DurationSec 1 -IntervalMs 100 -OutFile $out | Out-Null
    $saved=[IO.File]::ReadAllText($out) | ConvertFrom-Json
    Check 'read-only CLI preserves raw native samples and their window' ($saved.Schema -eq 1 -and @($saved.Samples).Count -ge 3 -and $saved.Window.Status -eq 'Ready' -and $saved.Window.ProcessId -eq $child.Id)
    Check 'read-only sampler leaves its observed process running' (-not $child.HasExited)
    $original=[IO.File]::ReadAllText($out);$blocked=$false
    try { & (Join-Path $Pkg 'dev/perfprobe.ps1') -ProcessId $child.Id -DurationSec 1 -IntervalMs 100 -OutFile $out | Out-Null } catch { $blocked=$true }
    Check 'sampler refuses to overwrite an earlier artifact' ($blocked -and [IO.File]::ReadAllText($out) -ceq $original)
    $child.Kill();[void]$child.WaitForExit(2000)
    $gone=Get-ProcessResourceSample $child
    Check 'native early exit remains unknown rather than returning cached zero metrics' ($gone.ResourceStatus -eq 'Exited' -and $null -eq $gone.CpuTotalMs -and $null -eq $gone.PrivateBytes)
} finally { if ($child) { try { if (-not $child.HasExited) { $child.Kill();[void]$child.WaitForExit(2000) } } finally { $child.Dispose() } } }
if ($fails) { exit 1 }
