param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok) { if($Ok){Write-Host ('ok   '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++} }
$script:portState='Open'
function Get-ProxyEndpointState { param($Endpoint) return $script:portState }
function Get-ProxyListeners { return ,@() }
function Get-TgConfig { return @{Port=10809} }
function Get-TgBridgeProcess { return [pscustomobject]@{Id=401} }
function Get-LocalProxyPorts { return @(10809) }
function Get-ProxyClientPids { return @(401) }
function Get-Process { return [pscustomobject]@{Id=401;StartTime=(Get-Date)} }
function Test-SteamProxyLog { return $true }
Check 'legacy port check confirms a listener missing from table' (Test-PortListening 10809)
Check 'Telegram recognizes reachable bridge' (Test-TgBridgeRunning)
$script:portState='Unknown'
Check 'Telegram status preserves unknown separately from stopped' ((Get-TgBridgeState) -eq 'Unknown')
Check 'unknown port is not reported as Telegram waiting on closed proxy' (-not (Test-TelegramWaitsForProxy))
Check 'unknown port does not accuse Steam of using closed proxy' (@(Get-ProxyStuckApps).Count -eq 0)
$script:portState='Closed'
Check 'confirmed closed proxy still reports waiting Telegram' (Test-TelegramWaitsForProxy)
Check 'confirmed closed proxy with Steam evidence is reported' (@(Get-ProxyStuckApps) -contains 'Steam')
function Get-RunningGames { return @() }
function Get-TunAdapters { return @() }
function Get-ForeignBypass { return @() }
function Get-GameBoosters { return @() }
function Get-DirectConnectionInfo { return $null }
Check 'geolocation failure is not declared internet failure' ((@(Get-AutotuneBlockers) -join ';') -notmatch 'нет интернета')
function Get-DirectConnectionInfo { return @{IsRussia=$false;CountryCode='DE'} }
Check 'foreign geolocation is not declared proven VPN routing' ((@(Get-AutotuneBlockers) -join ';') -notmatch 'трафик идёт не напрямую')
if($fails){exit 1}
Write-Host 'all ok'
