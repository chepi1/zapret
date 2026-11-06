param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$env:__COMPAT_LAYER='RunAsInvoker'
$Script:ControlMutexName='Local\zapret-launchtest-'+[guid]::NewGuid().ToString('N')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
if(-not(Get-Command New-BypassLaunchRecipe -ErrorAction SilentlyContinue)){
    Check 'launch owns one frozen recipe through preflight and failure analysis' $false
    exit 1
}
Update-RuntimeLists|Out-Null
$settings=Get-Settings;$settings.auto='off';$settings.gamepins='off'
$recipe=New-BypassLaunchRecipe -Settings $settings
try{
    $state=Get-BypassLaunchState $recipe
    $command=$state.CommandLine
    $settings.alt='11'
    Check 'changing caller settings cannot change the captured launch' ($state.SettingsJson -match '"alt":"12"' -and $state.CommandLine -ceq $command)
    Check 'recipe keeps native binaries at their original package location' ($state.Exe -ceq (Join-Path $Pkg 'bin/winws2.exe') -and $state.Bin -ceq (Join-Path $Pkg 'bin'))
    $refused=$false
    try{[IO.File]::AppendAllText((Join-Path $Pkg 'strategies/alt12.txt'),'unexpected mutation')}catch [IO.IOException]{$refused=$true}
    Check 'profile bytes cannot change between preflight and launch' $refused
    $refused=$false
    try{Move-Item -LiteralPath (Join-Path $Pkg 'lists') -Destination (Join-Path $Pkg 'lists-moved') -ErrorAction Stop}catch{$refused=$true}
    if(Test-Path (Join-Path $Pkg 'lists-moved')){Move-Item -LiteralPath (Join-Path $Pkg 'lists-moved') -Destination (Join-Path $Pkg 'lists')}
    Check 'a leased input directory cannot be renamed' $refused
    $auto=Join-Path $Pkg 'lists/autohostlist.txt'
    [IO.File]::AppendAllText($auto,"`nlearning-fixture.invalid`n")
    Check 'native autolist learning stays writable during a launch' ([IO.File]::ReadAllText($auto).Contains('learning-fixture.invalid'))
    Check 'the exact leased recipe passes native CLI and filter preflight' ((Test-ConfigDry $settings -Recipe $recipe).Ok)
    $foreign=[pscustomobject]@{Generation=$recipe.Generation}
    $refused=$false;try{Get-BypassLaunchState $foreign|Out-Null}catch{$refused=$true}
    Check 'a copied public handle cannot impersonate an owned recipe' $refused
    $extra=Join-Path $Pkg 'fake/launch-extra-fixture.bin'
    try{
        [IO.File]::WriteAllText($extra,'extra input')
        $refused=$false;try{Assert-BypassLaunchCurrent $recipe}catch{$refused=$true}
        Check 'adding a static input invalidates the recipe before replacement' $refused
    }finally{Remove-Item -LiteralPath $extra}
}finally{Close-BypassLaunchRecipe $recipe}
$strategyPath=Join-Path $Pkg 'strategies/alt12.txt'
$writer=[IO.File]::Open($strategyPath,'Open','ReadWrite','Read')
$writer.Dispose()
Check 'closing a recipe releases its static input leases' $true
$refused=$false;try{Get-BypassLaunchState $recipe|Out-Null}catch{$refused=$true}
Check 'closed recipes cannot be used for another launch' $refused

$settings=Get-Settings;$settings.auto='off';$settings.gamepins='off'
$recipe=New-BypassLaunchRecipe -Settings $settings -Name 'test' -NoAuto -IpsetMode any -LifetimeMs 12345
try{
    $state=Get-BypassLaunchState $recipe
    Check 'the experimental lifetime guard is part of the captured command' ($state.CommandLine.Contains("timer_set('test_lifetime_guard',function() os.exit(3) end,12345,true)") -and $state.Experimental)
}finally{Close-BypassLaunchRecipe $recipe}

# Only OS/process effects are replaced; composition, leases and native preflight above were real.
function Get-RunningGames{return @()}
function Get-OurService{return $null}
function Get-CimInstance{return $null}
function Get-ServiceEvents{return @()}
function Stop-Bypass{}
function Repair-WinDivertService{}
function Enable-TcpTimestamps{}
function Start-NetworkWatcher{return $true}
function Set-HighPriority{}
function Remove-OldRingMemory{}
function Get-OurProcesses{return @()}
$script:probeArguments=''
$savedNative=${function:Invoke-Native};$savedComposer=${function:Get-BypassCmdLine}
$recipe=New-BypassLaunchRecipe -Settings $settings
try{
    $expected=(Get-BypassLaunchState $recipe).CommandLine
    function Get-BypassCmdLine{return '--wf-raw=false --comment=unexpected-recomposition'}
    function Invoke-Native{param($File,$Arguments,$WorkDir,$TimeoutSec);$script:probeArguments=$Arguments;return @{ExitCode=3;TimedOut=$false;Output='fixture startup failure'}}
    Show-StartFailure 'fixture OS failure' (Get-Date) -Recipe $recipe|Out-Null
    Check 'failure analysis probes the exact failed recipe instead of recomposing settings' ($script:probeArguments -ceq $expected)
}finally{
    Close-BypassLaunchRecipe $recipe
    Set-Item -LiteralPath Function:\Invoke-Native -Value $savedNative
    Set-Item -LiteralPath Function:\Get-BypassCmdLine -Value $savedComposer
}
$script:checkedCommand='';$script:launchedCommand=''
function Test-ConfigDry{param($Settings,$CmdLine,$Recipe);$script:checkedCommand=(Get-BypassLaunchState $Recipe).CommandLine;return @{Ok=$true;Output='fixture accepted'}}
function Start-Process{param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle);$script:launchedCommand=$ArgumentList}
function Wait-BypassAlive{return $true}
function Get-Settings{return $settings.Clone()}
function Get-UpdateTrustSids{return @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
$ok=Start-Bypass -Quiet
Check 'ordinary startup launches exactly the recipe accepted by preflight' ($ok -and $script:checkedCommand -and $script:launchedCommand -ceq $script:checkedCommand)

if(-not(Get-Command Save-ConfirmedBypassRecipe -ErrorAction SilentlyContinue)){
    Check 'confirmed startup can recover a failed replacement without experimental state' $false
    exit 1
}
# Local state ACLs use the test user's SID; no administrator token is needed.
function Get-UpdateTrustSids{return @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
Remove-Item -LiteralPath Function:\Get-Settings
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:ControlMutexName='Local\zapret-launchtest-'+[guid]::NewGuid().ToString('N')
function Get-UpdateTrustSids{return @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
$settings=Get-Settings;$settings.alt='12';$settings.auto='off';$settings.gamepins='off';$settings.telegram='on';Save-Settings $settings
$script:launches=@();$script:waitCalls=0;$script:failNew=$false;$script:games=@()
function Get-RunningGames{return $script:games}
function Start-Process{param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle);$script:launches+=@($ArgumentList)}
function Wait-BypassAlive{$script:waitCalls++;return (-not $script:failNew -or $script:waitCalls -gt 2)}
function Test-ConfigDry{param($Settings,$CmdLine,$Recipe);return @{Ok=$true;Output='fixture accepted'}}
function Show-StartFailure{return $false}
function Stop-Bypass{}
function Repair-WinDivertService{}
function Enable-TcpTimestamps{}
function Start-NetworkWatcher{return $true}
function Set-HighPriority{}
function Remove-OldRingMemory{}
function Get-OurService{return $null}
function Get-OurProcesses{return @()}
$ok=Start-Bypass -Quiet
$confirmed=Read-ConfirmedBypassSettings
$confirmedPath=Join-Path $Script:Runtime 'launch-state/confirmed.json'
Check 'stable startup writes trusted last-confirmed engine settings' ($ok -and $confirmed -and $confirmed.Settings.alt -ceq '12' -and (Test-UpdateTrustedPath $confirmedPath))
$goodCommand=$script:launches[-1];$savedRecord=[IO.File]::ReadAllBytes($confirmedPath)
$settings=Get-Settings;$settings.alt='11';$settings.telegram='off';Save-Settings $settings
$script:launches=@();$script:waitCalls=0;$script:failNew=$true
$ok=Start-Bypass -Quiet
$after=Get-Settings
Check 'failed replacement restores the exact confirmed command once' ($ok -and $script:launches.Count -eq 3 -and $script:launches[0] -ceq $script:launches[1] -and $script:launches[2] -ceq $goodCommand)
Check 'restoration persists engine settings while preserving Telegram preference' ($after.alt -ceq '12' -and $after.telegram -ceq 'off')

$savedRecord=[IO.File]::ReadAllBytes($confirmedPath)
foreach($bad in @('{broken',('{"SchemaVersion":1}'),('x'*17000))){
    try{[IO.File]::WriteAllText($confirmedPath,$bad);Check 'malformed or oversized confirmation cannot authorize recovery' ($null -eq (Read-ConfirmedBypassSettings))}
    finally{[IO.File]::WriteAllBytes($confirmedPath,$savedRecord)}
}
$foreign=([Text.Encoding]::UTF8.GetString($savedRecord)|ConvertFrom-Json);$foreign.Root='C:\unrelated-zapret'
try{[IO.File]::WriteAllText($confirmedPath,($foreign|ConvertTo-Json -Depth 5));Check 'confirmation from another installation is rejected' ($null -eq (Read-ConfirmedBypassSettings))}
finally{[IO.File]::WriteAllBytes($confirmedPath,$savedRecord)}
$recipe=New-BypassLaunchRecipe -Settings (Get-Settings) -Name 'test' -NoAuto -LifetimeMs 12345
try{
    (Get-BypassLaunchState $recipe).StartupConfirmed=$true
    $accepted=Save-ConfirmedBypassRecipe $recipe
    Check 'even a surviving experiment cannot replace the confirmed configuration' (-not $accepted -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($confirmedPath)) -ceq [Convert]::ToBase64String($savedRecord))
}finally{Close-BypassLaunchRecipe $recipe}

$settings=Get-Settings;$settings.alt='11';Save-Settings $settings
$script:launches=@();$script:waitCalls=0
function Wait-BypassAlive{$script:games=@('NBA2K27');return $false}
$ok=Start-Bypass -Quiet
Check 'a game appearing during startup prevents automatic restoration' (-not $ok -and $script:launches.Count -eq 1)
$script:games=@();$script:launches=@()
function Test-ConfigDry{return @{Ok=$false;Output='fixture preflight refusal'}}
$ok=Start-Bypass -Quiet
Check 'preflight refusal does not trigger a recovery launch' (-not $ok -and $script:launches.Count -eq 0)

# Service side effects are isolated. A failed registry write or stale SCM command must not be confirmed.
$script:serviceStarts=0;$script:serviceImage='unrelated service command'
function Get-OurService{return [pscustomobject]@{Status='Stopped'}}
function Get-CimInstance{return [pscustomobject]@{PathName=$script:serviceImage}}
function Test-ConfigDry{return @{Ok=$true;Output='fixture accepted'}}
function Wait-BypassAlive{return $true}
function Start-OurService{$script:serviceStarts++;return ''}
function Set-ItemProperty{[CmdletBinding()]param($Path,$Name,$Value);Write-Error 'fixture registry write failure'}
$ok=Start-Bypass -Quiet
Check 'failed service command write cannot start or confirm another configuration' (-not $ok -and $script:serviceStarts -eq 0)
function Set-ItemProperty{}
$ok=Start-Bypass -Quiet
Check 'SCM command mismatch cannot be confirmed as a successful requested launch' (-not $ok -and $script:serviceStarts -eq 0)

$settings=Get-Settings;$settings.alt='11';Save-Settings $settings
$script:serviceExists=$false;$script:serviceStarts=0;$script:serviceWaits=0;$script:serviceImage='';$script:startedServiceImages=@()
function Get-OurService{if($script:serviceExists){return [pscustomobject]@{Status='Stopped'}}else{return $null}}
function New-Service{param($Name,$BinaryPathName,$DisplayName,$Description,$StartupType);$script:serviceExists=$true;$script:serviceImage=$BinaryPathName}
function Set-ItemProperty{param($Path,$Name,$Value);$script:serviceImage=$Value}
function sc.exe{$global:LASTEXITCODE=0}
function Start-OurService{$script:serviceStarts++;$script:startedServiceImages+=@($script:serviceImage);return ''}
function Wait-BypassAlive{$script:serviceWaits++;return ($script:serviceWaits -gt 1)}
function Test-BypassServiceProcess{return $true}
$ok=Install-BypassService
Check 'failed service installation restores confirmed bypass while reporting install failure' (-not $ok -and $script:serviceStarts -eq 2 -and $script:startedServiceImages[-1] -ceq ('"'+$Script:Exe+'" '+$goodCommand) -and (Get-Settings).alt -ceq '12')
Remove-Item Function:\Test-BypassServiceProcess
$libAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/lib.ps1'),[ref]$null,[ref]$null)
$proofDefinition=$libAst.Find({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-BypassServiceProcess'},$true)
Invoke-Expression $proofDefinition.Extent.Text
$recipe=New-BypassLaunchRecipe -Settings (Get-Settings)
try{
    $script:longServiceCommand='"'+$Script:Exe+'" '+(Get-BypassLaunchState $recipe).CommandLine
    function Get-CimInstance{return [pscustomobject]@{PathName=''}}
    function Get-ItemProperty{return [pscustomobject]@{ImagePath=$script:longServiceCommand}}
    $accepted=$true;try{Assert-BypassServiceRecipe $recipe}catch{$accepted=$false}
    Check 'empty SCM metadata for a long command permits only a matching persisted launch attempt' $accepted
    $refused=$false;try{Assert-BypassServiceRecipe $recipe -Started}catch{$refused=$true}
    Check 'empty SCM metadata cannot confirm startup without an exact owned process' $refused
}finally{Close-BypassLaunchRecipe $recipe}
$global:LASTEXITCODE=0
if($fails){exit 1}
Write-Host 'all ok'
