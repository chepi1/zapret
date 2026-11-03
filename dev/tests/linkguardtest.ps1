param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if(-not(Get-Command Get-WifiInterruptionState -ErrorAction SilentlyContinue)){throw 'FAIL Wi-Fi interruption reducer missing'}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
$id='1'*32;$other='2'*32;$now=[datetime]::SpecifyKind([datetime]'2026-11-04T01:00:00',[DateTimeKind]::Utc)
function AdapterFixture($Id,[bool]$Up,[bool]$Gateway){
    $adapterFixture=[pscustomobject]@{Id=([guid]$Id).ToString('B');NetworkInterfaceType=[Net.NetworkInformation.NetworkInterfaceType]::Wireless80211;OperationalStatus=$(if($Up){[Net.NetworkInformation.OperationalStatus]::Up}else{[Net.NetworkInformation.OperationalStatus]::Down});FixtureGateway=$Gateway}
    $adapterFixture | Add-Member ScriptMethod GetIPProperties {return [pscustomobject]@{GatewayAddresses=@(if($this.FixtureGateway){[pscustomobject]@{Address=[Net.IPAddress]::Parse('192.0.2.1')}})}}
    return $adapterFixture
}
$script:interfaceFixtures=@((AdapterFixture $id $true $true))+@(1..25|ForEach-Object{AdapterFixture ([guid]::NewGuid().ToString('N')) $false $false})+@((AdapterFixture $other $true $false))
function Get-SystemWifiInterfaces {return $script:interfaceFixtures}
$observed=Get-WifiLinkObservation
Check 'many inactive virtual adapters do not hide the routed Wi-Fi interface' ($observed.Known -and $observed.Interfaces.Count -eq 1 -and $observed.Interfaces[0].Id -eq $id)
$script:interfaceFixtures=@((AdapterFixture $id $false $false),(AdapterFixture $other $true $false))
$observed=Get-WifiLinkObservation -TrackedIds @($id)
Check 'previously tracked adapter stays observable after losing its gateway' ($observed.Known -and $observed.Interfaces.Count -eq 1 -and $observed.Interfaces[0].Id -eq $id -and -not $observed.Interfaces[0].Up)
function Observe([datetime]$At,[bool]$Up=$true,[bool]$Known=$true){[pscustomobject]@{Known=$Known;ObservedUtc=$At.ToString('o');Interfaces=@([pscustomobject]@{Id=$id;Up=$Up;HasGateway=$Up},[pscustomobject]@{Id=$other;Up=$true;HasGateway=$false})}}
$initial=Get-WifiInterruptionState $null (Observe $now) $null $now
Check 'stable initial Wi-Fi does not invent an outage' ($initial.LastEventEpoch -eq 0 -and $initial.PauseUntil -eq 0)
Check 'Wi-Fi Direct without a gateway is not monitored as the uplink' (@(Get-WifiWatchScope $initial (Observe $now)).Count -eq 1 -and @(Get-WifiWatchScope $initial (Observe $now))[0] -eq $id)
$dropTime=$now.AddSeconds(1);$drop=Get-WifiInterruptionState $initial (Observe $dropTime $false) $null $dropTime
$dropEpoch=ConvertTo-LinkEpoch $dropTime
Check 'confirmed down transition creates a bounded20s guard' ($drop.LastEventEpoch -eq $dropEpoch -and $drop.PauseUntil -eq $dropEpoch+20)
$later=$now.AddSeconds(2)
$unknown=Get-WifiInterruptionState $drop (Observe $later $false $false) $null $later
Check 'unknown observation does not prolong an existing guard' ($unknown.PauseUntil -eq $drop.PauseUntil -and $unknown.LastEventEpoch -eq $drop.LastEventEpoch)
$recoveryTime=$now.AddSeconds(3);$recovered=Get-WifiInterruptionState $unknown (Observe $recoveryTime) $null $recoveryTime
Check 'confirmed recovery protects late failures and handshake settling' ($recovered.LastEventEpoch -eq (ConvertTo-LinkEpoch $recoveryTime) -and $recovered.PauseUntil -eq (ConvertTo-LinkEpoch $recoveryTime)+20)
$steadyTime=$now.AddSeconds(30);$steady=Get-WifiInterruptionState $recovered (Observe $steadyTime) $null $steadyTime
Check 'normal traffic cannot keep the guard alive indefinitely' ($steady.PauseUntil -lt (ConvertTo-LinkEpoch $steadyTime) -and $steady.LastEventEpoch -eq $recovered.LastEventEpoch)
$newUnknown=Get-WifiInterruptionState $initial (Observe $later $true $false) $null $later
Check 'query failure is not proof of Wi-Fi failure' ($newUnknown.LastEventEpoch -eq 0)
$stale=Get-WifiInterruptionState $initial (Observe $now $false) $null $now.AddMinutes(1)
Check 'stale adapter snapshot cannot fabricate a transition' ($stale.LastEventEpoch -eq 0)
$back=Get-WifiInterruptionState $recovered (Observe $now) $null $now
Check 'clock rollback does not create an unbounded future pause' ($back.LastEventEpoch -eq 0 -and $back.PauseUntil -eq 0)
$record=Get-LinkGuardRecord $drop $dropTime
Check 'guard wire record contains only bounded epochs and no adapter identity' ($record -eq ('1 '+$dropEpoch+' '+$dropEpoch+' '+($dropEpoch+20)+"`n") -and $record.Length -le 64 -and -not $record.Contains($id))
$fixtureFile=Join-Path $Script:Runtime 'link-guard-fixture.txt'
Check 'atomic guard publication accepts bounded protocol' (Write-LinkGuardRecord $fixtureFile $record)
Check 'invalid publication cannot overwrite a valid guard' (-not(Write-LinkGuardRecord $fixtureFile "1 1 x 2`n") -and [IO.File]::ReadAllText($fixtureFile) -ceq $record)
Check 'no atomic temporary files remain' (@(Get-ChildItem $Script:Runtime -Filter 'link-guard-fixture.txt.*.tmp').Count -eq 0)
function EventFixture($Guid,[datetime]$At,[int]$EventId=8003){
    $eventFixture=[pscustomobject]@{Id=$EventId;TimeCreated=$At;Xml=('<Event><EventData><Data Name="InterfaceGuid">'+([guid]$Guid).ToString('B')+'</Data><Data Name="SSID">private fixture</Data></EventData></Event>')}
    $eventFixture | Add-Member ScriptMethod ToXml {return $this.Xml}
    return $eventFixture
}
$script:query=$null;$script:events=@((EventFixture $other $now))
function Get-WinEvent {param($FilterHashtable,$MaxEvents,$ErrorAction);$script:query=@{Filter=$FilterHashtable;Max=$MaxEvents};return $script:events}
Check 'disconnect of another adapter does not guard the uplink' ($null -eq (Get-WifiDisconnectEpoch @($id) $now))
Check 'event query is local and bounded by id/time/count' ($script:query.Max -eq 64 -and $script:query.Filter.Id -eq 8003 -and $script:query.Filter.LogName -eq 'Microsoft-Windows-WLAN-AutoConfig/Operational' -and $script:query.Filter.StartTime -eq $now.AddSeconds(-30))
$script:events=@((EventFixture $id $now.AddSeconds(-31)),(EventFixture $id $now.AddSeconds(1)),(EventFixture $id $now 8001))
Check 'old future and unrelated event types are ignored' ($null -eq (Get-WifiDisconnectEpoch @($id) $now))
$script:events=@((EventFixture $id $now.AddSeconds(-2)),(EventFixture $id $now.AddSeconds(-1)))
$eventEpoch=Get-WifiDisconnectEpoch @($id) $now
Check 'same-adapter XML event catches an outage between polling samples' ($eventEpoch -eq (ConvertTo-LinkEpoch $now.AddSeconds(-1)))
$between=Get-WifiInterruptionState $initial (Observe $now) $eventEpoch $now
Check 'between-sample disconnection guards even when adapter is already up' ($between.LastEventEpoch -eq $eventEpoch -and $between.PauseUntil -eq $eventEpoch+20)
$again=Get-WifiInterruptionState $between (Observe $later) $eventEpoch $later
Check 'rereading an event does not extend its window' ($again.PauseUntil -eq $between.PauseUntil)
function Get-WinEvent {throw 'access unavailable'}
Check 'unavailable event log does not invent an outage or enable logging' ($null -eq (Get-WifiDisconnectEpoch @($id) $now))
Check 'no Wi-Fi interfaces require no event-log query' ($null -eq (Get-WifiDisconnectEpoch @() $now))
# Exercise the real watcher loop on the TEMP package, substituting only local observations.
$watchPath=Join-Path $Pkg 'tools/netwatch.ps1';$watchBytes=[IO.File]::ReadAllBytes($watchPath)
$stubs=@'
function Get-OurProcesses {return [pscustomobject]@{Id=1234}}
function Get-NetworkObservation {param([switch]$Machine);return [pscustomobject]@{Known=$true;Key=('A'*64);ObservedUtc=[datetime]::UtcNow.ToString('o')}}
function Get-RingCompositionKey {return ('C'*64)}
$script:linkFixtureSample=0
function Get-WifiLinkObservation {$script:linkFixtureSample++;return [pscustomobject]@{Known=$true;ObservedUtc=[datetime]::UtcNow.ToString('o');Interfaces=@([pscustomobject]@{Id=('1'*32);Up=($script:linkFixtureSample -eq 1);HasGateway=($script:linkFixtureSample -eq 1)})}}
function Get-WifiDisconnectEpoch {return $null}
function Start-Sleep {}
'@
try{
    $patched=[IO.File]::ReadAllText($watchPath).Replace(". (Join-Path `$PSScriptRoot 'lib.ps1')",(". (Join-Path `$PSScriptRoot 'lib.ps1')"+[Environment]::NewLine+$stubs))
    [IO.File]::WriteAllText($watchPath,$patched,(New-Object Text.UTF8Encoding($true)))
    $nativeArgs=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$watchPath,'-MaxSamples','2')
    $child=Invoke-Native (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') $nativeArgs $Pkg 15
    $networkMarker=Get-PkgPath ($Script:RingDir+'/network-context.txt');$linkMarker=Get-PkgPath ($Script:RingDir+'/link-guard.txt')
    Check 'real watcher loop publishes matching context and active link guard from local observations' ($child.ExitCode -eq 0 -and -not $child.TimedOut -and [IO.File]::ReadAllText($networkMarker) -match '^3 [0-9]+ A{64} C{24}\n$' -and [IO.File]::ReadAllText($linkMarker) -match '^1 ([0-9]+) \1 [0-9]+\n$')
    if($child.ExitCode -ne 0){Write-Host $child.Output}
}finally{[IO.File]::WriteAllBytes($watchPath,$watchBytes)}
$settings=Get-Settings;$settings.auto='on';Update-RuntimeLists | Out-Null
$config=New-BypassArgList -Settings $settings
Check 'learning profiles explicitly opt into the packaged guard' (@($config|Where-Object{$_ -like '--lua-desync=circular*link_guard=link-guard.txt*'}).Count -gt 0)
$gameBody=(($config -join "`n") -split '--new=game_tcp',2)[1]
Check 'game TCP retains its ordinary detector without learning guard' (-not $gameBody.Contains('link_guard='))
if($env:ZAPRET_LUA_TEST_RUNTIME){
    & python (Join-Path $PSScriptRoot 'lua-unit.py') --pkg $Pkg --runtime $env:ZAPRET_LUA_TEST_RUNTIME --test linkguardtest.lua
    Check 'real developer Lua executes parser and detector integration' ($LASTEXITCODE -eq 0)
}elseif(Test-Admin){
    $nativeArgs=@('--intercept=0',('--lua-init=@'+(Join-Path $Pkg 'lua/ring-store.lua')),('--lua-init=@'+(Join-Path $Pkg 'lua/autoring.lua')),('--lua-init=@'+(Join-Path $PSScriptRoot 'linkguardtest.lua')))
    $native=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $nativeArgs) $Script:Bin 10
    Write-Host $native.Output
    Check 'native Lua detector integration without traffic interception' ($native.ExitCode -eq 0 -and -not $native.TimedOut -and $native.Output.Contains('link guard parser exists'))
}else{Write-Host 'skip Lua link guard: administrator or developer Lua runtime required'}
if($fails){exit 1}
