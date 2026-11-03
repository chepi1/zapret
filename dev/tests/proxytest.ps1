param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$realEndpointState = ${function:Get-ProxyEndpointState}
$fails = 0
function Check($Name, $Ok) { if ($Ok) { Write-Host ('ok   ' + $Name) } else { Write-Host ('FAIL ' + $Name); $script:fails++ } }
$script:settings = [pscustomobject]@{ Known = $true; Proxy = ''; Pac = ''; AutoDetect = $false }
$script:clients = @([pscustomobject]@{ ProcessName = 'happd' })
$script:listeners = @()
$script:adapters = @()
$script:routes = @()
function Get-WindowsProxySettings { return $script:settings }
function Get-ProxyEnvironment { return @() }
function Get-Process { param($Name, $ErrorAction) return $script:clients }
function Get-ProxyListeners { return ,$script:listeners }
$script:probeState = 'Closed'
function Get-ProxyEndpointState { param($Endpoint) return $script:probeState }
function Get-NetAdapter { param([switch]$IncludeHidden, $ErrorAction) return $script:adapters }
function Get-NetRoute { param($PolicyStore, $ErrorAction) return $script:routes }
# Old registry values can survive after disconnecting Happ.
function Get-ItemProperty { param($Path, $ErrorAction) return [pscustomobject]@{ ProxyEnable = 0; ProxyServer = '127.0.0.1:10809'; AutoConfigURL = 'http://127.0.0.1:10809/old.pac' } }
$w = @(Get-ProxyWarnings) -join '; '
Check 'Happ process alone is explicitly unconfirmed' ($w -match 'happd' -and $w -match 'не подтвержд')
Check 'disabled saved PAC is not reported as enabled' ($w -notmatch 'PAC')
$script:clients = @()
Check 'no client or enabled configuration produces no warning' (@(Get-ProxyWarnings).Count -eq 0)
$script:settings.Proxy = 'http=127.0.0.1:10809;https=[::1]:10810'
$w = @(Get-ProxyWarnings) -join '; '
Check 'enabled local proxy with no listener is diagnosed' ($w -match 'включён' -and $w -match 'не слушает')
$script:listeners = @([pscustomobject]@{ Address = [Net.IPAddress]::Parse('192.168.1.2'); Port = 10809 })
Check 'same port on another address does not prove loopback listener' ((@(Get-ProxyWarnings) -join '; ') -match 'не слушает')
$script:listeners = @([pscustomobject]@{ Address = [Net.IPAddress]::Parse('127.0.0.1'); Port = 10809 })
Check 'partially unavailable proxy endpoints stay visible' ((@(Get-ProxyWarnings) -join '; ') -match 'не слушает')
$script:listeners += [pscustomobject]@{ Address = [Net.IPAddress]::Parse('::1'); Port = 10810 }
$w = @(Get-ProxyWarnings) -join '; '
Check 'both loopback families can listen' ($w -match 'слушает' -and $w -notmatch 'не слушает')
$script:listeners = @([pscustomobject]@{ Address = [Net.IPAddress]::Any; Port = 10809 }, [pscustomobject]@{ Address = [Net.IPAddress]::IPv6Any; Port = 10810 })
Check 'wildcard listeners match their own address family' ((@(Get-ProxyWarnings) -join '; ') -notmatch 'не слушает')
$script:listeners = $null
$script:probeState = 'Unknown'
Check 'listener read failure is not reported as a closed port' ((@(Get-ProxyWarnings) -join '; ') -match 'не удалось проверить')
$script:probeState = 'Open'; $script:listeners = @()
Check 'reachable proxy is detected even when listener enumeration omits it' ((@(Get-ProxyWarnings) -join '; ') -notmatch 'не слушает|не удалось проверить')
$script:probeState = 'Closed'
$script:settings.Proxy = 'http://user:topsecret@proxy.example:3128'
$w = @(Get-ProxyWarnings) -join '; '
Check 'remote proxy is configured without claiming reachability' ($w -match 'включён' -and $w -notmatch 'слушает')
Check 'proxy credentials are not printed' ($w -notmatch 'topsecret|user:')
$script:settings.Proxy = ''
$script:settings.Pac = 'http://localhost:10809/pac?token=topsecret'
$w = @(Get-ProxyWarnings) -join '; '
Check 'enabled PAC is described without claiming every app uses it' ($w -match 'PAC' -and $w -match 'зависит')
Check 'PAC secrets are not printed' ($w -notmatch 'topsecret')
$script:settings.Proxy = ''; $script:settings.Pac = ''
Check 'switching proxy off is reflected immediately' (@(Get-ProxyWarnings).Count -eq 0)
function Get-ProxyEnvironment { return @('HTTPS_PROXY') }
$w = @(Get-ProxyWarnings) -join '; '
Check 'environment proxy is described as app specific' ($w -match 'HTTPS_PROXY' -and $w -match 'приложения')
function Get-ProxyEnvironment { return @() }
$script:settings.Pac = ''
$script:settings.AutoDetect = $true
Check 'WPAD alone is not treated as confirmed VPN' ((@(Get-ProxyWarnings) -join '; ') -match 'не подтвержд')
$script:settings.Known = $false
Check 'read failure is unknown rather than disabled' ((@(Get-ProxyWarnings) -join '; ') -match 'не удалось')
$script:adapters = @([pscustomobject]@{ Status = 'Up'; Name = 'Happ'; InterfaceDescription = 'Wintun'; ifIndex = 42 })
Check 'up tunnel without routes does not block as active' (@(Get-TunAdapters).Count -eq 0)
$script:routes = @([pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = '0.0.0.0/1' })
Check 'split default tunnel route is detected' (@(Get-TunAdapters).Count -eq 1)
$script:routes = @([pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = 'fe80::/64' }, [pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = '224.0.0.0/4' })
Check 'link local and multicast routes do not prove active tunnel' (@(Get-TunAdapters).Count -eq 0)
$script:routes = @([pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = '::/1' })
Check 'IPv6 tunnel route is detected' (@(Get-TunAdapters).Count -eq 1)
function Get-NetRoute { param($PolicyStore, $ErrorAction) throw 'simulated route read failure' }
Check 'unknown routes remain a conservative tunnel blocker' (@(Get-TunAdapters).Count -eq 1)
$localServer = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
try {
    $localServer.Start()
    $endpoint = [pscustomobject]@{ Host = '127.0.0.1'; Port = $localServer.LocalEndpoint.Port }
    Check 'real local listener accepts bounded confirmation' ((& $realEndpointState $endpoint) -eq 'Open')
    $localServer.Stop()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $closedState = & $realEndpointState $endpoint
    Check 'closed local port is not open and confirmation stays bounded' ($closedState -in @('Closed','Unknown') -and $timer.ElapsedMilliseconds -lt 1500)
} finally { $localServer.Stop() }
Check 'endpoint confirmation refuses remote addresses' ((& $realEndpointState ([pscustomobject]@{ Host = '203.0.113.1'; Port = 10808 })) -eq 'Unknown')
if ($fails) { exit 1 }
Write-Host 'all ok'
