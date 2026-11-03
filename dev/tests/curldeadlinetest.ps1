# Actual curl cancellation against a delayed loopback fixture. No external traffic/driver.
param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach ($definition in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
$ready=Join-Path $Script:Runtime ('deadline-fixture-'+[guid]::NewGuid().ToString('N'))
$job=Start-Job -ArgumentList $ready -ScriptBlock {
    param($Ready)
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $client=$null
    try {
        $listener.Start();[IO.File]::WriteAllText(($Ready+'.tmp'),[string]$listener.LocalEndpoint.Port);[IO.File]::Move(($Ready+'.tmp'),$Ready)
        $pending=$listener.AcceptTcpClientAsync()
        if (-not $pending.Wait(10000)) { throw 'No fixture request' }
        $client=$pending.Result
        [IO.File]::WriteAllText(($Ready+'.accepted'),'accepted')
        $stream=$client.GetStream();$stream.ReadTimeout=5000
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,1024,$true)
        for ($i=0; $i -lt 64; $i++) { $line=$reader.ReadLine();if (-not $line) { break } }
        Start-Sleep -Seconds 5
        $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length:0`r`nConnection:close`r`n`r`n")
        $stream.Write($bytes,0,$bytes.Length)
    } finally { if ($client) { $client.Dispose() };$listener.Stop() }
}
$fails=0
try {
    for ($i=0; $i -lt 100 -and -not (Test-Path $ready) -and $job.State -notin @('Completed','Failed','Stopped'); $i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path $ready)) { Receive-Job $job;throw 'Fixture did not start' }
    $port=[int][IO.File]::ReadAllText($ready)
    $target=[pscustomobject]@{Group='Clean';Name='delayed';Url=('http://127.0.0.1:'+$port+'/fixture');Post=$false}
    $Parallel=1;$TimeoutSec=20;$errorRecord=$null
    $clock=[Diagnostics.Stopwatch]::StartNew();$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long][Diagnostics.Stopwatch]::Frequency
    try { Invoke-CurlBatch @($target,$target,$target) '' 1 -DeadlineTicks $deadline | Out-Null } catch { $errorRecord=$_ }
    $clock.Stop()
    if ($errorRecord -and $errorRecord.Exception.Data['Kind'] -eq 'RunDeadline' -and $clock.Elapsed.TotalSeconds -lt 4 -and (Test-Path ($ready+'.accepted'))) { Write-Host 'ok total deadline interrupts an active batch before its queue completes' } else { Write-Host 'FAIL active batch ignored deadline';$fails++ }
    $owned=@(if ($errorRecord) { $errorRecord.Exception.Data['ProbeProcessIds'] })
    $alive=@($owned | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($owned.Count -eq 1 -and $alive.Count -eq 0) { Write-Host 'ok interrupted curl process is gone before the caller resumes' } else { Write-Host 'FAIL interrupted curl process cleanup';$fails++ }
    $cancelled=@(if ($errorRecord) { $errorRecord.Exception.Data['Rows'] })
    if ($cancelled.Count -eq 1 -and $cancelled[0].State -eq 'CANCELLED' -and $null -ne $cancelled[0].StartedMs) { Write-Host 'ok cancelled real request remains evidence without invented success' } else { Write-Host 'FAIL cancelled request evidence missing';$fails++ }
} finally {
    Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ready,($ready+'.accepted') -Force -ErrorAction SilentlyContinue
}
if ($fails) { exit 1 }
