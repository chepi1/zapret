param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$script:calls=@();$script:silentFirst=$false
function Invoke-Native {
    param($File,$Arguments,$WorkDir,$TimeoutSec)
    $script:calls+=@([string]$Arguments)
    if($script:silentFirst -and $script:calls.Count -eq 1){return @{ExitCode=1;TimedOut=$false;Output=''}}
    if($Arguments -match '--bad-option=1'){return @{ExitCode=2;TimedOut=$false;Output='invalid candidate'}}
    $flags=[regex]::Matches($Arguments,'--wf-dup-check=([01])')
    $ok=$Arguments -match '--dry-run' -and $flags.Count -gt 0 -and $flags[$flags.Count-1].Groups[1].Value -eq '0'
    return @{ExitCode=$(if($ok){0}else{1});TimedOut=$false;Output=$(if($ok){'command line parameters verified'}else{'A copy of winws2 is already running with the same filter'})}
}
function Start-Sleep {}
$candidate='--wf-dup-check=1 --wf-tcp-out=443 --comment=exact-candidate'
$result=Test-ConfigDry @{} -CmdLine $candidate
Check 'preflight succeeds beside an existing identical filter' $result.Ok
Check 'preflight preserves the exact candidate and interception setting' ($script:calls[-1].Contains($candidate) -and $script:calls[-1] -notmatch '--intercept=0' -and $script:calls[-1] -match '--wf-dup-check=0\s*$')
$script:calls=@();$script:silentFirst=$true
$result=Test-ConfigDry @{} -CmdLine $candidate
Check 'silent startup retry retains the same isolated dry-run' ($result.Ok -and $script:calls.Count -eq 2 -and $script:calls[0] -ceq $script:calls[1])
$script:silentFirst=$false
Check 'invalid candidate remains rejected' (-not (Test-ConfigDry @{} -CmdLine '--bad-option=1').Ok)
Update-RuntimeLists | Out-Null
$settings=Get-Settings;$settings.alt='12';$settings.auto='on'
$result=Test-ConfigDry $settings
Check 'generated dry-run also skips only the duplicate-instance mutex' $result.Ok
$dry=New-BypassArgList -Settings $settings -DryRun
$live=New-BypassArgList -Settings $settings
Check 'all explicit dry configurations carry the isolated mutex flag' ($dry -contains '--dry-run' -and $dry -contains '--wf-dup-check=0')
Check 'actual launch retains default duplicate protection and interception' (-not ($live -contains '--wf-dup-check=0') -and -not ($live -contains '--dry-run') -and -not ($live -contains '--intercept=0'))
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/menu.ps1'),[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Start-WithChecks','Confirm-GameRunning','Invoke-MenuAction')},$true)){Invoke-Expression $fn.Extent.Text}
function Test-AutotuneRunning {return $false}
function Resolve-ForeignBypass {return $true}
function Get-RunningGames {return $script:games}
function Read-YesNo {return $false}
function Pause-Menu {}
$script:games=@();$script:startOk=$false;$script:starts=0;$script:bridges=0
function Start-Bypass {$script:starts++;return $script:startOk}
function Start-TelegramWithBypass {$script:bridges++}
Invoke-MenuAction start
Check 'menu1 does not print bridge success after failed restart' ($script:starts -eq 1 -and $script:bridges -eq 0)
$script:starts=0;$script:bridges=0;$script:startOk=$true
Invoke-MenuAction start
Check 'successful menu1 restart starts the bridge normally' ($script:starts -eq 1 -and $script:bridges -eq 1)
$script:starts=0;$script:bridges=0;$script:games=@('NBA2K27')
Invoke-MenuAction start
Check 'game-declined menu1 still performs no restart' ($script:starts -eq 0 -and $script:bridges -eq 0)
if($fails){exit 1}
