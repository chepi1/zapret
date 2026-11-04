# Actual local curl queue cancellation when its required fake engine exits. No bypass process.
param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
if(-not(Get-Command Assert-ProbeContext -ErrorAction SilentlyContinue)){throw 'FAIL required-engine probe guard missing'}
$ready=Join-Path $Script:Runtime ('engine-fixture-'+[guid]::NewGuid().ToString('N'));$script:engineAccepted=$ready+'.accepted'
$job=Start-Job -ArgumentList $ready -ScriptBlock {
    param($Ready)
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$client=$null
    try{
        $listener.Start();[IO.File]::WriteAllText(($Ready+'.tmp'),[string]$listener.LocalEndpoint.Port);[IO.File]::Move(($Ready+'.tmp'),$Ready)
        $pending=$listener.AcceptTcpClientAsync();if(-not $pending.Wait(10000)){throw 'No local request'}
        $client=$pending.Result;[IO.File]::WriteAllText(($Ready+'.accepted'),'accepted');Start-Sleep -Seconds 5
    }finally{if($client){$client.Dispose()};$listener.Stop()}
}
$fails=0
try{
    for($i=0;$i -lt 100 -and -not(Test-Path $ready) -and $job.State -notin @('Completed','Failed','Stopped');$i++){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path $ready)){Receive-Job $job;throw 'Fixture did not start'}
    $target=[pscustomobject]@{Group='Clean';Name='fixture';Url=('http://127.0.0.1:'+([IO.File]::ReadAllText($ready))+'/');Post=$false}
    $engine=[pscustomobject]@{Id=-1};$engine|Add-Member ScriptProperty HasExited {[IO.File]::Exists($script:engineAccepted)}
    $Parallel=1;$TimeoutSec=20;$failure=$null;$clock=[Diagnostics.Stopwatch]::StartNew()
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long]([Diagnostics.Stopwatch]::Frequency*4)
    try{Invoke-CurlBatch @($target,$target,$target) '' 1 -DeadlineTicks $deadline -RequiredProcess $engine | Out-Null}catch{$failure=$_}
    if($failure -and $failure.Exception.Data['Kind'] -eq 'EngineUnavailable' -and $clock.Elapsed.TotalSeconds -lt 4){Write-Host 'ok fake engine death interrupts an actual active curl batch'}else{Write-Host 'FAIL engine death did not interrupt curl';$fails++}
    $owned=@(if($failure){$failure.Exception.Data['ProbeProcessIds']})
    $alive=@($owned|ForEach-Object{Get-Process -Id $_ -ErrorAction SilentlyContinue})
    if($owned.Count -eq 1 -and $alive.Count -eq 0){Write-Host 'ok dead engine prevents queued requests and releases its one owned curl'}else{Write-Host 'FAIL queue or owned curl cleanup';$fails++}
    $rows=@(if($failure){$failure.Exception.Data['Rows']})
    if($rows.Count -eq 1 -and $rows[0].State -eq 'CANCELLED'){Write-Host 'ok interrupted request remains cancelled evidence without a score'}else{Write-Host 'FAIL aborted evidence missing';$fails++}
}finally{Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force -ErrorAction SilentlyContinue}
if($fails){exit 1}
