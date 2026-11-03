param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if(-not(Get-Command Get-NetworkObservation -ErrorAction SilentlyContinue)){throw 'Network context missing'}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
$script:network='wifi-one';$script:gateway='192.168.1.1';$script:proxy='';$script:broken=$false
function Get-NetConnectionProfile { if($script:broken){throw 'denied'};[pscustomobject]@{Name=$script:network;InterfaceIndex=7;IPv4Connectivity='Internet';IPv6Connectivity='NoTraffic'} }
$script:extraRoutes=@();$script:assigned=@('192.168.1.100')
function Get-LocalAssignedAddresses { return $script:assigned }
function Get-NetRoute { [pscustomobject]@{InterfaceIndex=7;DestinationPrefix='0.0.0.0/0';NextHop=$script:gateway;RouteMetric=10};$script:extraRoutes }
function Get-DnsClientServerAddress { [pscustomobject]@{InterfaceIndex=7;AddressFamily=2;ServerAddresses=@('192.168.1.1')} }
function Get-WindowsProxySettings { [pscustomobject]@{Known=$true;Proxy=$script:proxy;Pac='';AutoDetect=$false} }
$one=Get-NetworkObservation
Check 'known context has opaque key' ($one.Known -and $one.Key -match '^[A-F0-9]{64}$')
Check 'same inputs have stable context' ((Get-NetworkObservation).Key -eq $one.Key)
$script:extraRoutes=@([pscustomobject]@{InterfaceIndex=90;DestinationPrefix='203.0.113.0/24';NextHop='0.0.0.0';RouteMetric=1})
Check 'on-link split TUN route changes network context' ((Get-NetworkObservation).Key -ne $one.Key)
$script:extraRoutes=@([pscustomobject]@{InterfaceIndex=7;DestinationPrefix='192.168.1.100/32';NextHop='0.0.0.0';RouteMetric=1})
Check 'own DHCP host route is not a new network' ((Get-NetworkObservation).Key -eq $one.Key)
$script:extraRoutes=@();$script:assigned=@('192.168.1.101')
Check 'DHCP address change alone does not invalidate context' ((Get-NetworkObservation).Key -eq $one.Key)
Check 'export does not expose network name or gateway' (($one|ConvertTo-Json -Compress) -notmatch 'wifi-one|192.168.1.1')
$script:network='wifi-two'
Check 'WiFi change invalidates context' ((Get-NetworkObservation).Key -ne $one.Key)
$script:network='wifi-one';$script:gateway='192.168.1.2'
Check 'gateway change invalidates context' ((Get-NetworkObservation).Key -ne $one.Key)
$script:gateway='192.168.1.1';$script:proxy='127.0.0.1:10808'
Check 'proxy mode change invalidates context' ((Get-NetworkObservation).Key -ne $one.Key)
$script:proxy='';$script:broken=$true
Check 'unknown context is never shared' (-not (Get-NetworkObservation).Known -and -not (Get-NetworkObservation).Key)
$script:broken=$false
$targets=@([pscustomobject]@{Group='DPI';Name='fixture';Url='https://example.com/'})
$stamp=Get-ScoreInputsHash $targets
$fingerprints=@{'50'=(Get-StrategyFingerprint '50')}
Check 'same network and inputs can apply' (Test-ScoreInputs $stamp $targets @{} $fingerprints -NetworkBefore $one)
$script:network='changed'
Check 'network change prevents applying measurements' (-not (Test-ScoreInputs $stamp $targets @{} $fingerprints -NetworkBefore $one))
$script:network='wifi-one'
$list=Join-Path $Script:Lists 'list-general-user.txt';$bytes=[IO.File]::ReadAllBytes($list)
try{[IO.File]::AppendAllText($list,"`nexample.org");Check 'list-only edit invalidates captured inputs' (-not (Test-ScoreInputs $stamp $targets @{} $fingerprints))}finally{[IO.File]::WriteAllBytes($list,$bytes)}
$Script:RingNetworkKey=$one.Key
Set-RingNetworkContext $one
$settings=Get-Settings; $settings.auto='on'
$argsText=(New-BypassArgList -Settings $settings) -join ' '
Check 'startup uses dynamic watchdog context instead of static network key' ($argsText -match ':context=network-context.txt:state=')
Check 'final verification cannot modify persisted production memory' ((Get-BypassCmdLine -Settings $settings -Name 'final-check') -notmatch ':state=')
Check 'in-memory adaptive detectors remain enabled' ($argsText -match 'success_detector=ring_success')
$ring=@([pscustomobject]@{Id='50';Name='unchanged'})
$first=Get-RingStateName general $ring
$Script:RingNetworkKey='different'
Check 'service command line does not freeze network identity' ((Get-RingStateName general $ring) -eq $first)
$Script:RingNetworkKey=$one.Key
$file=Join-Path $Script:StratDir 'alt50.txt';$original=[IO.File]::ReadAllBytes($file)
try{[IO.File]::AppendAllText($file,"`n# changed");Check 'same-name strategy edit separates ring memory' ((Get-RingStateName general $ring) -ne $first)}finally{[IO.File]::WriteAllBytes($file,$original)}
if($fails){exit 1}
