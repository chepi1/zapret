param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
. (Join-Path $Pkg 'tools/latency.ps1')
$module=Join-Path $Pkg 'tools/latencyprobe.ps1'
if(-not(Test-Path $module)){throw 'FAIL bounded asynchronous TCP operation missing'}
. $module
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
Check 'import alone does not compile or launch managed probes' ($null -eq ('Zapret.Diagnostics.ConnectOperation' -as [type]))
Initialize-LatencyProbeType
Add-Type -TypeDefinition 'public sealed class LatencyFixtureOwner : System.IDisposable { public int Disposals; public void Dispose(){ System.Threading.Interlocked.Increment(ref Disposals); } }'
function Wait-Operation($Operation){$clock=[Diagnostics.Stopwatch]::StartNew();while(-not $Operation.IsCompleted -and $clock.ElapsedMilliseconds -lt 2000){Start-Sleep -Milliseconds 5};if(-not $Operation.IsCompleted){throw 'Managed operation did not finish'}}
function Pending-Operation([int]$Timeout=50){
    $source=New-Object 'System.Threading.Tasks.TaskCompletionSource[bool]';$owner=New-Object LatencyFixtureOwner
    $operation=New-Object Zapret.Diagnostics.ConnectOperation -ArgumentList $source.Task,$owner,([Diagnostics.Stopwatch]::GetTimestamp()),$Timeout
    return [pscustomobject]@{Source=$source;Owner=$owner;Operation=$operation}
}
$pending=Pending-Operation;Wait-Operation $pending.Operation
Check 'pending task expires with no invented latency and closes its owner' ($pending.Operation.Outcome -eq 'Timeout' -and $null -eq $pending.Operation.Milliseconds -and $pending.Owner.Disposals -eq 1)
$pending.Source.SetResult($true);$pending.Operation.Dispose()
Check 'late completion and repeated dispose cannot change timeout or double-close' ($pending.Operation.Outcome -eq 'Timeout' -and $pending.Owner.Disposals -eq 1)
$cancel=Pending-Operation 1000;$cancel.Operation.Dispose();Wait-Operation $cancel.Operation
Check 'explicit cancellation is separate from network timeout' ($cancel.Operation.Outcome -eq 'Cancelled' -and $cancel.Owner.Disposals -eq 1 -and $null -eq $cancel.Operation.Milliseconds)
$fault=Pending-Operation 1000;$fault.Source.SetException((New-Object InvalidOperationException 'fixture'));Wait-Operation $fault.Operation
Check 'faulted connect releases resources without reporting success or zero RTT' ($fault.Operation.Outcome -eq 'Error' -and $fault.Owner.Disposals -eq 1 -and $null -eq $fault.Operation.Milliseconds)
$success=Pending-Operation 1000;$success.Source.SetResult($true);Wait-Operation $success.Operation
$captured=$success.Operation.Milliseconds;$capturedAt=$success.Operation.CompletedSeconds;Start-Sleep -Milliseconds 150
Check 'collection delay is excluded from captured connection duration and completion time' ($success.Operation.Outcome -eq 'Success' -and $null -ne $captured -and $success.Operation.Milliseconds -eq $captured -and $success.Operation.CompletedSeconds -eq $capturedAt -and $success.Owner.Disposals -eq 1)
$oldStart=(Get-LatencyTime)-121
$stamp=New-Object Zapret.Diagnostics.CompletionStamp -ArgumentList $success.Source.Task,$oldStart,1000
Check 'completion observer cannot refresh a request after process suspension' ($stamp.IsCompleted -and $stamp.CompletedSeconds -le $oldStart+1)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/track.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
$Replay='';$latencyStore=New-LatencyStore;$probePending=@{};$ping=@{};$pingTask=@{};$tcpProbeAt=@{}
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
try{
    $listener.Start();$port=$listener.LocalEndpoint.Port
    $started=Invoke-TcpProbe '127.0.0.1' $port
    Check 'tracker starts a loopback TCP probe without waiting for its result' ($started -eq $true -and $probePending.Count -eq 1)
    Check 'TCP success is not displayed for a UDP endpoint' ((Get-PingText '127.0.0.1' udp 27015) -eq '—')
    if(-not(Get-Command Update-LatencyTasks -ErrorAction SilentlyContinue)){throw 'FAIL asynchronous tracker collector missing'}
    $op=@($probePending.Values)[0].Operation;Wait-Operation $op;$realMs=$op.Milliseconds
    Start-Sleep -Milliseconds 150;Update-LatencyTasks
    $summary=Get-LatencySummary $latencyStore '127.0.0.1' tcp $port
    Check 'real socket result is captured once with its original timing and exact port' ($summary.SuccessCount -eq 1 -and $summary.MedianMs -eq $realMs -and $probePending.Count -eq 0 -and $op.Outcome -eq 'Success')
    Check 'immediate repeat respects endpoint cooldown' (-not(Invoke-TcpProbe '127.0.0.1' $port))
    $icmpOperation=Start-LatencyIcmpOperation '127.0.0.1' 1000
    $icmpKey=Get-LatencyKey '127.0.0.1' icmp 0;$probePending[$icmpKey]=$icmpOperation
    $icmpClock=[Diagnostics.Stopwatch]::StartNew()
    while($probePending.ContainsKey($icmpKey) -and $icmpClock.ElapsedMilliseconds -lt 2000){Update-LatencyTasks;Start-Sleep -Milliseconds 5}
    $icmpResult=Get-LatencySummary $latencyStore '127.0.0.1' icmp 0
    Check 'actual loopback ICMP task supplies native RTT and completion timestamp' ($icmpResult.SuccessCount -eq 1 -and $null -ne $icmpResult.LastMs -and $icmpResult.Fresh -and -not $probePending.ContainsKey($icmpKey))
}finally{$listener.Stop();if(Get-Command Close-TrackProbes -ErrorAction SilentlyContinue){Close-TrackProbes}}
$latencyStore=New-LatencyStore;$probePending=@{};$script:owners=@()
function Start-LatencyTcpOperation {param($Ip,$Port,$TimeoutMs);$item=Pending-Operation 1000;$script:owners+=,$item.Owner;return $item.Operation}
foreach($port in @(4001,4002,4003)){Invoke-TcpProbe '127.0.0.1' $port | Out-Null}
Check 'three pending TCP operations prevent an additional connect' ($probePending.Count -eq 3 -and -not(Invoke-TcpProbe '127.0.0.1' 4004))
Close-TrackProbes
Check 'tracker exit closes every pending TCP operation without counting cancellations' ($probePending.Count -eq 0 -and @($script:owners|Where-Object{$_.Disposals -ne 1}).Count -eq 0 -and (Get-LatencySummary $latencyStore '127.0.0.1' tcp 4001).Count -eq 0)
function Ping-Owner {$owner=[pscustomobject]@{Disposals=0;Cancels=0};$owner|Add-Member ScriptMethod Dispose {$this.Disposals++};$owner|Add-Member ScriptMethod SendAsyncCancel {$this.Cancels++};return $owner}
foreach($outcome in @('Success','TimedOut','Fault','Cancelled','Pending')){
    $latencyStore=New-LatencyStore;$probePending=@{};$owner=Ping-Owner
    $source=New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
    if($outcome -eq 'Fault'){$source.SetException((New-Object InvalidOperationException 'fixture'))}
    elseif($outcome -eq 'Cancelled'){$source.SetCanceled()}
    elseif($outcome -ne 'Pending'){$source.SetResult([pscustomobject]@{Status=$outcome;RoundtripTime=7})}
    $key=Get-LatencyKey '203.0.113.9' icmp 0
    $probePending[$key]=[pscustomobject]@{Kind='icmp';Ip='203.0.113.9';Port=0;Owner=$owner;Task=$source.Task;Started=((Get-LatencyTime)-2);Completion=[pscustomobject]@{IsCompleted=$source.Task.IsCompleted;CompletedSeconds=((Get-LatencyTime)-0.5)}}
    Update-LatencyTasks
    $summary=Get-LatencySummary $latencyStore '203.0.113.9' icmp 0
    $ok=$owner.Disposals -eq 1 -and $probePending.Count -eq 0
    if($outcome -eq 'Success'){$ok=$ok -and $summary.SuccessCount -eq 1 -and $summary.MedianMs -eq 7}
    elseif($outcome -eq 'Fault'){$ok=$ok -and $summary.Errors -eq 1 -and $null -eq $summary.MedianMs}
    elseif($outcome -eq 'Cancelled'){$ok=$ok -and $summary.Count -eq 0}
    else{$ok=$ok -and $summary.Timeouts -eq 1 -and $null -eq $summary.MedianMs}
    Check ('ICMP '+$outcome+' collection preserves outcome and disposes owner') $ok
}
$Replay='fixture';$latencyStore=New-LatencyStore;$probePending=@{}
Check 'replay mode cannot schedule TCP probes' (-not(Invoke-TcpProbe '127.0.0.1' 4001))
Update-Ping @('203.0.113.9')
Check 'replay mode cannot schedule ICMP probes' ($probePending.Count -eq 0)
$Replay=''
foreach($kind in @('icmp','tcp')){
    $latencyStore=New-LatencyStore;$probePending=@{};$now=Get-LatencyTime;$oldAt=$now-121;$owner=Ping-Owner
    if($kind -eq 'icmp'){
        $source=New-Object 'System.Threading.Tasks.TaskCompletionSource[object]';$source.SetResult([pscustomobject]@{Status='Success';RoundtripTime=7})
        $item=[pscustomobject]@{Kind='icmp';Ip='203.0.113.9';Port=0;Owner=$owner;Task=$source.Task;Started=($oldAt-0.01);Completion=[pscustomobject]@{IsCompleted=$true;CompletedSeconds=$oldAt}}
    }else{
        $operation=[pscustomobject]@{IsCompleted=$true;Outcome='Success';Milliseconds=7;CompletedSeconds=$oldAt;Disposals=0};$operation|Add-Member ScriptMethod Dispose {$this.Disposals++}
        $item=[pscustomobject]@{Kind='tcp';Ip='203.0.113.9';Port=443;Operation=$operation}
    }
    $probePending[(Get-LatencyKey $item.Ip $kind $item.Port)]=$item
    Update-LatencyTasks
    $summary=Get-LatencySummary $latencyStore $item.Ip $kind $item.Port
    Check ($kind+' delayed collector preserves completion age instead of refreshing it') ($summary.SuccessCount -eq 1 -and $summary.LastSuccessAge -ge 121 -and -not $summary.Fresh)
}
$latencyStore=New-LatencyStore;$probePending=@{};$script:collectorClockRead=0
function Get-LatencyTime {$script:collectorClockRead++;if($script:collectorClockRead -eq 1){return 100.0};return 102.0}
$racing=[pscustomobject]@{IsCompleted=$true;Outcome='Success';Milliseconds=8;CompletedSeconds=101.0;Disposals=0};$racing|Add-Member ScriptMethod Dispose {$this.Disposals++}
$probePending['tcp|203.0.113.9|443']=[pscustomobject]@{Kind='tcp';Ip='203.0.113.9';Port=443;Operation=$racing}
Update-LatencyTasks
Check 'completion racing the collector clock is retained with its actual timestamp' ((Get-LatencySummary $latencyStore '203.0.113.9' tcp 443 102).SuccessCount -eq 1 -and $racing.Disposals -eq 1)
. (Join-Path $Pkg 'tools/latency.ps1')
$script:icmpStarted=@();$script:failPingStart=$false
function New-Object {
    param($TypeName,$ArgumentList,$Property)
    if($TypeName -match '^(System\.)?Net\.NetworkInformation\.Ping$'){
        $fake=Ping-Owner
        $fake|Add-Member ScriptMethod SendPingAsync {param($Address,$Timeout);$script:icmpStarted+=,$Address.ToString();if($script:failPingStart){throw 'fixture local start error'};return (Microsoft.PowerShell.Utility\New-Object 'System.Threading.Tasks.TaskCompletionSource[object]').Task}
        return $fake
    }
    return Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
}
function Get-LatencyTime {return 100.0}
try{
    $addresses=@(1..20|ForEach-Object{'203.0.113.'+$_})
    foreach($scheduled in @(100,95)){
        $latencyStore=New-LatencyStore;$probePending=@{};$script:icmpStarted=@()
        foreach($address in $addresses[0..11]){Set-LatencyProbeScheduled $latencyStore $address icmp 0 $scheduled | Out-Null}
        Update-Ping $addresses[0..12]
        Check ('later endpoint is not starved when earlier12 were scheduled at'+$scheduled) ($script:icmpStarted -contains $addresses[12] -and $script:icmpStarted.Count -le 12 -and $probePending.Count -le 12)
        Close-TrackProbes
    }
    $latencyStore=New-LatencyStore;$probePending=@{};$script:icmpStarted=@();$script:failPingStart=$true
    Update-Ping $addresses
    Check 'local start failures cannot exceed12 attempts per update' ($script:icmpStarted.Count -eq 12 -and $probePending.Count -eq 0)
}finally{Close-TrackProbes;Remove-Item Function:\New-Object; . (Join-Path $Pkg 'tools/latency.ps1')}
# Full replay path: block all active network and ETW controls before they can run.
$trackPath=Join-Path $Pkg 'tools/track.ps1';$trackBytes=[IO.File]::ReadAllBytes($trackPath)
$etl=Join-Path $Script:Runtime 'latency-replay.etl';[IO.File]::WriteAllText($etl,'fixture')
$blocked=Join-Path $Script:Runtime 'latency-replay-blocked.txt'
$guards=@'
function Block-FixtureActive { [IO.File]::WriteAllText((Join-Path $Script:Runtime 'latency-replay-blocked.txt'),'blocked');throw 'Unexpected active replay operation' }
function Get-DirectConnectionInfo { Block-FixtureActive }
function Get-IpInfo { Block-FixtureActive }
function Start-NetTrace { Block-FixtureActive }
function Stop-NetTrace { Block-FixtureActive }
function Get-Process { return @() }
function Get-ProxyWarnings { return @() }
function Get-TunAdapters { return @() }
function Clear-Host {}
function Get-NetIPAddress { return [pscustomobject]@{IPAddress='10.0.0.2'} }
function New-Object {param($TypeName,$ArgumentList,$Property);if($TypeName -match '^(System\.)?Net\.(NetworkInformation\.Ping|Sockets\.TcpClient)$'){Block-FixtureActive};Microsoft.PowerShell.Utility\New-Object @PSBoundParameters}
function Get-WinEvent {
    param($Path,[switch]$Oldest,$FilterXPath,$FilterHashtable,$MaxEvents,$ErrorAction)
    if(-not $Path){return @()}
    foreach($eventId in @(42,43)){
        $remote=[BitConverter]::ToUInt32([Net.IPAddress]::Parse('203.0.113.9').GetAddressBytes(),0);$local=[BitConverter]::ToUInt32([Net.IPAddress]::Parse('10.0.0.2').GetAddressBytes(),0)
        $destination=if($eventId -eq 42){$remote}else{$local};$source=if($eventId -eq 42){$local}else{$remote}
        $values=@(12345,100,$destination,$source,27015,40000)
        [pscustomobject]@{Id=$eventId;TimeCreated=[datetime]::UtcNow;Properties=@($values|ForEach-Object{[pscustomobject]@{Value=$_}})}
    }
}
'@
try{
    $trackText=[IO.File]::ReadAllText($trackPath)
    $trackText=$trackText.Replace(". (Join-Path `$PSScriptRoot 'lib.ps1')",(". (Join-Path `$PSScriptRoot 'lib.ps1')"+[Environment]::NewLine+$guards))
    [IO.File]::WriteAllText($trackPath,$trackText,(New-Object Text.UTF8Encoding($true)))
    foreach($name in @('track-a.etl','track-b.etl')){[IO.File]::WriteAllText((Join-Path $Script:Runtime $name),'sentinel')}
    $args0=ConvertTo-WinCmdLine @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$trackPath,'-Replay',$etl,'-ReplayPid','12345')
    $child=Invoke-Native (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') $args0 $Pkg 15
    $report=Join-Path $Script:Runtime 'track-replay.txt'
    Check 'complete replay renders evidence without active network or ETW control' ($child.ExitCode -eq 0 -and -not $child.TimedOut -and -not(Test-Path $blocked) -and (Test-Path $report) -and [IO.File]::ReadAllText($report).Contains('203.0.113.9'))
    Check 'replay does not delete unrelated live trace chunks' ((Test-Path (Join-Path $Script:Runtime 'track-a.etl')) -and (Test-Path (Join-Path $Script:Runtime 'track-b.etl')))
    if($child.ExitCode -ne 0 -or -not(Test-Path $report) -or -not[IO.File]::ReadAllText($report).Contains('203.0.113.9')){Write-Host $child.Output;if(Test-Path $report){Get-Content -LiteralPath $report -Tail 10}}
}finally{[IO.File]::WriteAllBytes($trackPath,$trackBytes)}
if($fails){exit 1}
