# Actual curl against one temporary loopback HTTP fixture. No external requests or WinDivert.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach ($definition in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
$ready=Join-Path $Script:Runtime ('curl-ready-'+[guid]::NewGuid().ToString('N')+'.txt')
$request=$ready+'.request'
$job=Start-Job -ArgumentList $ready,$request -ScriptBlock {
    param($Ready,$Request)
    $ErrorActionPreference='Stop'
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $client=$null
    try {
        $listener.Start()
        [IO.File]::WriteAllText(($Ready+'.tmp'),[string]$listener.LocalEndpoint.Port)
        [IO.File]::Move(($Ready+'.tmp'),$Ready)
        $pending=$listener.AcceptTcpClientAsync()
        if (-not $pending.Wait(10000)) { throw 'Loopback fixture timed out' }
        $client=$pending.Result;$stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=5000
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,1024,$true)
        $first=$reader.ReadLine();[IO.File]::WriteAllText($Request,$first)
        for ($i=0; $i -lt 64; $i++) { $line=$reader.ReadLine();if (-not $line) { break } }
        $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 8192`r`nConnection: close`r`n`r`n")
        $stream.Write($header,0,$header.Length)
        if (-not $first.StartsWith('HEAD ')) { $body=New-Object byte[] 8192;$stream.Write($body,0,$body.Length) }
        $stream.Flush();$reader.Dispose()
    } finally { if ($client) { $client.Dispose() };$listener.Stop() }
}
$fails=0
try {
    for ($i=0; $i -lt 100 -and -not (Test-Path $ready) -and $job.State -notin @('Completed','Failed','Stopped'); $i++) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path $ready)) { Receive-Job $job;throw 'Fixture did not start' }
    $port=[int][IO.File]::ReadAllText($ready)
    $Parallel=1;$TimeoutSec=3
    $post=Join-Path $Script:Runtime 'head-must-not-post.bin';[IO.File]::WriteAllBytes($post,(New-Object byte[] 1024))
    $target=[pscustomobject]@{Group='Clean';Name='loopback';Url=('http://127.0.0.1:'+$port+'/fixture');Post=$true}
    $rows=@(Invoke-CurlBatch @($target) $post 1 -Control)
    $finished=Wait-Job $job -Timeout 5
    if (-not $finished -or $job.State -ne 'Completed') { Receive-Job $job;throw 'Fixture did not complete' }
    if (([IO.File]::ReadAllText($request)).StartsWith('HEAD /fixture ') -and $rows.Count -eq 1 -and $rows[0].State -eq 'OK' -and $rows[0].Down -eq 0) { Write-Host 'ok control uses HEAD without a POST or response body' } else { Write-Host 'FAIL control must use HEAD without a POST or response body';$fails++ }
    if ($null -ne $rows[0].DnsMs -and $null -ne $rows[0].TotalMs) { Write-Host 'ok actual curl emits optional measurement phases' } else { Write-Host 'FAIL actual curl measurement phases missing';$fails++ }
} finally {
    Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ready,$request -Force -ErrorAction SilentlyContinue
}
if ($fails) { exit 1 }
