# Real curl with local HTTP partial/stalled bodies and a temporary curlrc. No external traffic.
param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
foreach ($relative in @('tools/test.ps1','dev/strategylab.ps1')) {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg $relative),[ref]$null,[ref]$null)
    foreach ($fn in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
$fails=0;$Parallel=1;$TimeoutSec=1
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
function Start-Fixture($Mode) {
    $ready=Join-Path $Script:Runtime ('curl-body-'+[guid]::NewGuid().ToString('N'))
    $job=Start-Job -ArgumentList $ready,$Mode -ScriptBlock {
        param($Ready,$Mode)
        $ErrorActionPreference='Stop';$client=$null
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        try {
            $listener.Start();[IO.File]::WriteAllText(($Ready+'.tmp'),[string]$listener.LocalEndpoint.Port);[IO.File]::Move(($Ready+'.tmp'),$Ready)
            $pending=$listener.AcceptTcpClientAsync();if (-not $pending.Wait(10000)) { throw 'No loopback request' }
            $client=$pending.Result;$stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=5000
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,1024,$true)
            $headers=New-Object 'System.Collections.Generic.List[string]'
            for ($i=0;$i -lt 100;$i++) { $line=$reader.ReadLine();if (-not $line) { break };$headers.Add($line) }
            [IO.File]::WriteAllLines(($Ready+'.headers'),[string[]]$headers.ToArray())
            $complete=$Mode -eq 'complete';$code=if ($complete) {'404 Not Found'} else {'200 OK'};$length=if ($complete) {4} else {65536}
            $header=[Text.Encoding]::ASCII.GetBytes(('HTTP/1.1 '+$code+"`r`nContent-Length: "+$length+"`r`nConnection: close`r`n`r`n"))
            $stream.Write($header,0,$header.Length);$body=New-Object byte[] $(if ($complete) {4} else {16384});$stream.Write($body,0,$body.Length);$stream.Flush()
            if ($Mode -eq 'stall') { Start-Sleep -Milliseconds 2200 }
        } finally { if ($client) { $client.Dispose() };$listener.Stop() }
    }
    for ($i=0;$i -lt 100 -and -not (Test-Path $ready) -and $job.State -notin @('Completed','Failed','Stopped');$i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path $ready)) { Receive-Job $job;Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force;throw 'Loopback fixture did not start' }
    return [pscustomobject]@{Job=$job;Ready=$ready;Url=('http://127.0.0.1:'+([IO.File]::ReadAllText($ready))+'/fixture')}
}
function Stop-Fixture($Fixture) {
    try { $done=Wait-Job $Fixture.Job -Timeout 4;if (-not $done -or $Fixture.Job.State -ne 'Completed') { Receive-Job $Fixture.Job;throw 'Loopback fixture did not complete' } }
    finally { Stop-Job $Fixture.Job -ErrorAction SilentlyContinue;Remove-Job $Fixture.Job -Force -ErrorAction SilentlyContinue }
}
$curlHomeBefore=[Environment]::GetEnvironmentVariable('CURL_HOME','Process')
$config=Join-Path $Script:Runtime ('curl-config-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($config)
$contents='header = "X-Zapret-Test: ambient"'+[Environment]::NewLine
foreach ($name in @('.curlrc','_curlrc')) { [IO.File]::WriteAllText((Join-Path $config $name),$contents) }
try {
    $env:CURL_HOME=$config
    $fixture=Start-Fixture complete
    try { $native=Invoke-Native (Join-Path $env:SystemRoot 'System32/curl.exe') ('-s --noproxy "*" --max-time 2 -o NUL "'+$fixture.Url+'"') $Script:Runtime 4 } finally { Stop-Fixture $fixture }
    Check 'temporary curlrc is genuinely active in the unisolated baseline' ($native.ExitCode -eq 0 -and [IO.File]::ReadAllText(($fixture.Ready+'.headers')).Contains('X-Zapret-Test: ambient'))
    foreach ($mode in @('truncate','stall','complete')) {
        $fixture=Start-Fixture $mode
        try { $target=[pscustomobject]@{Group='Clean';Name=$mode;Url=$fixture.Url;Post=$false};$rows=@(Invoke-CurlBatch @($target) '' 1) } finally { Stop-Fixture $fixture }
        $row=$rows[0]
        if ($mode -eq 'truncate') { Check 'real HTTP200 with a short body is curl18 and not OK' ($row.Code -eq '200' -and $row.Exit -eq 18 -and $row.Down -eq 16384 -and $row.State -eq 'FAIL') }
        elseif ($mode -eq 'stall') { Check 'real HTTP200 followed by body timeout is FREEZE' ($row.Code -eq '200' -and $row.Exit -eq 28 -and $row.Down -eq 16384 -and $row.State -eq 'FREEZE') }
        else { Check 'real completed404 remains a successful reachability probe' ($row.Code -eq '404' -and $row.Exit -eq 0 -and $row.State -eq 'OK') }
        Check ($mode+' direct probe ignores ambient curlrc headers') (-not [IO.File]::ReadAllText(($fixture.Ready+'.headers')).Contains('X-Zapret-Test: ambient'))
    }
    $fixture=Start-Fixture truncate
    try { $target=[pscustomobject]@{Key='Clean|lab';Host='127.0.0.1';Ip='127.0.0.1';Url=$fixture.Url;Post=$false};$rows=@(Invoke-LabBatch @($target) '') } finally { Stop-Fixture $fixture }
    Check 'actual lab curl uses the shared incomplete-transfer policy' ($rows[0].Code -eq '200' -and $rows[0].Exit -eq 18 -and $rows[0].St -eq 'c18')
    Check 'laboratory also ignores ambient curlrc headers' (-not [IO.File]::ReadAllText(($fixture.Ready+'.headers')).Contains('X-Zapret-Test: ambient'))
    $fixture=Start-Fixture complete
    try { $Script:ServiceProbes=[ordered]@{fixture=$fixture.Url};$jobs=Start-ServiceProbes -TimeoutSec 2;$service=@(Get-ServiceProbeResults $jobs) } finally { Stop-Fixture $fixture }
    Check 'service health keeps completed404 valid with isolated curl' ($service.Count -eq 1 -and $service[0].Ok -and -not [IO.File]::ReadAllText(($fixture.Ready+'.headers')).Contains('X-Zapret-Test: ambient'))
} finally { [Environment]::SetEnvironmentVariable('CURL_HOME',$curlHomeBefore,'Process') }
if ($fails) { exit 1 }
