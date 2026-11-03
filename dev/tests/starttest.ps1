param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
function Start-NetworkWatcher { return $true }
$Script:ControlMutexName='Local\zapret-starttest-'+[guid]::NewGuid().ToString('N')
$originals = @{}
$originalStop = ${function:Stop-Bypass}
$originalWait = ${function:Wait-BypassAlive}
foreach ($n in @('Get-Settings','Get-BypassCmdLine','Test-ConfigDry','Update-RuntimeLists')) { $originals[$n] = (Get-Item ('function:' + $n)).ScriptBlock }
$fails = 0
function Check($Name, $Ok) { if ($Ok) { Write-Host ('ok   ' + $Name) } else { Write-Host ('FAIL ' + $Name); $script:fails++ } }
# OS/service effects are isolated: these tests must never stop the real bypass.
$script:stops = 0; $script:games = @()
function Test-PackageIntegrity { return @() }
function Get-Settings { return @{ gamepins = 'off' } }
function Get-BypassCmdLine { return 'invalid candidate' }
function Test-ConfigDry { return @{ Ok = $false; Output = 'invalid candidate' } }
function Get-RunningGames { return $script:games }
function Stop-Bypass { $script:stops++ }
function Repair-WinDivertService { }
function Enable-TcpTimestamps { }
function Update-RuntimeLists { }
$ok = Start-Bypass -Quiet
Check 'invalid candidate preserves running bypass' (-not $ok -and $script:stops -eq 0)
$script:stops = 0
$ok = Install-BypassService
Check 'invalid service candidate preserves existing bypass' (-not $ok -and $script:stops -eq 0)
$script:stops = 0; $script:games = @('NBA2K27')
$ok = Start-Bypass -Quiet
Check 'game prevents a restart before any stop' (-not $ok -and $script:stops -eq 0)
$rejected = $false
try { & $originalStop } catch { $rejected = $true }
Check 'direct unattended stop is rejected during game' ($rejected -and $script:stops -eq 0)
$script:games = @()
function Get-Service { return $null }
function Test-TaskExists { return $false }
$script:games = @('NBA2K27')
try { Update-LegacyNames; Check 'opening menu during a game needs no migration' $true } catch { Check 'opening menu during a game needs no migration' $false }
$script:games = @()
if (Get-Command Enter-BypassControl -ErrorAction SilentlyContinue) {
    Check 'first operation acquires lease' (Enter-BypassControl 'test')
    Check 'nested operation is reentrant' (Enter-BypassControl 'nested')
    Exit-BypassControl
    $other = $null
    try { $other = [IO.File]::Open((Join-Path $Script:Runtime 'control.lock'), 'OpenOrCreate', 'ReadWrite', 'Read') } catch [IO.IOException] { }
    Check 'nested release keeps outer lease held' ($null -eq $other)
    if ($other) { $other.Dispose() }
    Exit-BypassControl
    $other = [IO.File]::Open((Join-Path $Script:Runtime 'control.lock'), 'OpenOrCreate', 'ReadWrite', 'Read')
    try {
        Check 'competing owner is refused' (-not (Enter-BypassControl 'contender'))
        try { Update-LegacyNames; Check 'opening another menu while busy needs no migration' $true } catch { Check 'opening another menu while busy needs no migration' $false }
        $menuAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools\menu.ps1'), [ref]$null, [ref]$null)
        foreach ($fn in $menuAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Confirm-GameRunning','Invoke-MenuAction')}, $true)) { Invoke-Expression $fn.Extent.Text }
        function Pause-Menu { }
        $mockStop = ${function:Stop-Bypass}
        ${function:Stop-Bypass} = $originalStop
        try { Invoke-MenuAction 'stop'; Check 'busy control returns to menu without terminating it' $true } catch { Check 'busy control returns to menu without terminating it' $false }
        finally { ${function:Stop-Bypass} = $mockStop }
    } finally { $other.Dispose() }
    Check 'lease reacquired after owner closes' (Enter-BypassControl 'after-close')
    Exit-BypassControl
} else { Check 'operation lease is available' $false }
if (Get-Command Get-BypassDiagnosis -ErrorAction SilentlyContinue) {
    $text = (Get-BypassDiagnosis $false '0x8032000A' @('NBA2K27') @('happd')) -join "`n"
    Check 'summary includes error and observations' ($text -match '0x8032000A' -and $text -match 'NBA2K27' -and $text -match 'happd')
    $text = (Get-BypassDiagnosis $true '0x8032000A' @() @()) -join "`n"
    Check 'running bypass does not inherit old failure' ($text -notmatch '0x8032000A')
} else { Check 'short diagnosis is available' $false }
$hint = (Get-StartFailureHints '0x8032000A') -join "`n"
Check 'filter busy hint avoids asserting an unproved old-filter cause' ($hint -notmatch 'Windows держит фильтры прошлого запуска')
function Get-CimInstance { return $null }
function Get-ServiceEvents { return @() }
function Invoke-Native { throw 'Known busy error must not launch another probe' }
$fallback = Show-StartFailure '0x8032000A' (Get-Date)
$saved = [IO.File]::ReadAllText((Join-Path $Script:Runtime 'start-error.txt'))
Check 'skipped probe does not invent a standalone process failure' (-not $fallback -and $saved -notmatch 'без службы завершился')
$script:scCalls = @()
function sc.exe { $script:scCalls += ($args -join ' ') }
function Get-CimInstance { return (New-Object PSObject -Property @{ ExitCode=0; StartMode='Manual' }) }
try { Show-StartFailure 'unknown launch failure' (Get-Date) | Out-Null } catch { }
Check 'diagnostic exception restores original manual service mode' (@($script:scCalls | Where-Object { $_ -match 'start= demand' }).Count -eq 1)
Remove-Item Function:\sc.exe,Function:\Get-CimInstance
# Real dry-run on a fresh copied package, with all live service/process effects replaced.
foreach ($n in $originals.Keys) { Set-Item ('function:' + $n) $originals[$n] }
Remove-Item Function:\Invoke-Native
. (Join-Path $Pkg 'tools\lib.ps1')
function Start-NetworkWatcher { return $true }
function Get-OurService { return $null }
function Get-RunningGames { return @() }
function Stop-Bypass { $script:stops++ }
function Repair-WinDivertService { }
function Enable-TcpTimestamps { }
function Start-Process { }
function Wait-BypassAlive { return $true }
function Set-HighPriority { }
function Remove-OldRingMemory { }
function Update-GamePins { return $null }
Remove-Item -LiteralPath (Get-PkgPath $Script:AutolistFile) -ErrorAction SilentlyContinue
function Get-Settings { return @{ alt='12'; auto='on'; autolist='on'; game='all'; gametcp='1024-65535'; gameudp='1024-65535'; ipset='any'; gamepins='off' } }
function Test-ConfigDry { return @{ Ok = (Test-Path (Join-Path $Script:Runtime 'ipset-any.txt')); Output = 'required runtime file missing' } }
$ok = Start-Bypass -Quiet
Check 'fresh package prepares required ipset file before preflight' $ok
$script:launches = 0; $script:games = @()
function Get-RunningGames { return $script:games }
function Start-Process { $script:launches++ }
function Wait-BypassAlive { $script:games = @('NBA2K27'); return $false }
$ok = Start-Bypass -Quiet
Check 'game appearing during wait prevents another live launch' (-not $ok -and $script:launches -eq 1)
$script:games = @(); $script:poll = 0
function Get-OurProcesses { $script:poll++; return (New-Object PSObject -Property @{ Id=$script:poll }) }
$ok = & $originalWait -TimeoutMs 450 -AliveMs 220
Check 'restarting PIDs do not prove one stable process' (-not $ok)
function Get-OurProcesses { return (New-Object PSObject -Property @{ Id=4242 }) }
$ok = & $originalWait -TimeoutMs 100 -AliveMs 1000
Check 'timeout does not accept a process without its full stability window' (-not $ok)
$ok = & $originalWait -TimeoutMs 650 -AliveMs 150
Check 'one stable process is accepted' $ok
$script:launches = 0
function Wait-BypassAlive { return $false }
$savedFailure = ${function:Show-StartFailure}
function Show-StartFailure { return $false }
$ok = Start-Bypass -Quiet
Check 'an existing unstable process prevents a second launch' (-not $ok -and $script:launches -eq 1)
${function:Show-StartFailure} = $savedFailure
function Start-Sleep { }
function Stop-Process { throw 'simulated OS refusal' }
$script:unloaded = $false
function Remove-WinDivertDriver { $script:unloaded=$true; return $true }
$refused = $false
try { & $originalStop -Unload | Out-Null } catch { $refused = $true }
Check 'failed stop neither unloads driver nor reports success' ($refused -and -not $script:unloaded)
${function:Stop-Bypass} = $originalStop
$script:launches = 0
$ok = Start-Bypass -Quiet
Check 'failed stop prevents replacement process launch' (-not $ok -and $script:launches -eq 0)
$menuAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools\menu.ps1'), [ref]$null, [ref]$null)
$fn = $menuAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Diagnostics'}, $true)
Invoke-Expression ($fn.Extent.Text.Replace('$PSScriptRoot', ("'" + (Join-Path $Pkg 'tools') + "'")))
function Stop-Bypass { }
function Pause-Menu { }
function Read-YesNo { $script:games = @('NBA2K27'); return $false }
$script:games = @(); $script:launches = 0
$rejected = $false
try { Start-Diagnostics } catch { $rejected = $_.Exception.Message -match 'запущена игра' }
Check 'game appearing during diagnostic prompt prevents child launch' ($rejected -and $script:launches -eq 0)
Check 'aborted diagnostic releases control lease' (Enter-BypassControl 'after-diag')
Exit-BypassControl
if ($fails) { exit 1 }
Write-Host 'all ok'
