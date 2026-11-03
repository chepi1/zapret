param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if(-not(Get-Command Get-NetworkWatchRecord -ErrorAction SilentlyContinue)){throw 'Network watchdog protocol missing'}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
$a='A'*64;$b='B'*64
$now=[datetime]::UtcNow
$known=[pscustomobject]@{Known=$true;Key=$a;CompositionKey=('C'*64);ObservedUtc=$now.ToString('o')}
Check 'first sample cannot unlock persisted memory' ((Get-NetworkWatchRecord $null $known $now) -eq "3 0 - -`n")
Check 'two consistent samples enable fresh context' ((Get-NetworkWatchRecord $known $known $now) -match '^3 \d+ A{64} C{24}\n$')
$changed=[pscustomobject]@{Known=$true;Key=$b;CompositionKey=('C'*64);ObservedUtc=$now.ToString('o')}
Check 'network transition immediately invalidates marker' ((Get-NetworkWatchRecord $known $changed $now) -eq "3 0 - -`n")
Check 'two new samples confirm new network' ((Get-NetworkWatchRecord $changed $changed $now) -match 'B{64}')
$newComposition=[pscustomobject]@{Known=$true;Key=$a;CompositionKey=('D'*64);ObservedUtc=$now.ToString('o')}
Check 'composition transition invalidates marker before confirmation' ((Get-NetworkWatchRecord $known $newComposition $now) -eq "3 0 - -`n")
Check 'stable new composition receives its own confirmation' ((Get-NetworkWatchRecord $newComposition $newComposition $now) -match 'D{24}')
$unknown=[pscustomobject]@{Known=$false;Key='';CompositionKey=('C'*64);ObservedUtc=$now.ToString('o')}
Check 'unknown does not preserve last known permission' ((Get-NetworkWatchRecord $known $unknown $now) -eq "3 0 - -`n")
$old=[pscustomobject]@{Known=$true;Key=$a;CompositionKey=('C'*64);ObservedUtc=$now.AddMinutes(-1).ToString('o')}
Check 'stale observation cannot refresh heartbeat' ((Get-NetworkWatchRecord $old $old $now) -eq "3 0 - -`n")
$future=[pscustomobject]@{Known=$true;Key=$a;CompositionKey=('C'*64);ObservedUtc=$now.AddMinutes(1).ToString('o')}
Check 'future timestamp fails closed' ((Get-NetworkWatchRecord $future $future $now) -eq "3 0 - -`n")
$dir=Join-Path $Script:Runtime 'watch-fixture';New-Item -ItemType Directory -Path $dir | Out-Null
$file=Join-Path $dir 'network-context.txt'
Check 'atomic marker publication succeeds' (Write-NetworkWatchRecord $file "3 0 - -`n")
Check 'atomic marker replacement succeeds' (Write-NetworkWatchRecord $file (Get-NetworkWatchRecord $known $known $now))
Check 'marker contains no raw network data' ([IO.File]::ReadAllText($file) -match '^3 \d+ A{64} C{24}\n$')
Check 'temporary files are removed' (@(Get-ChildItem $dir -Filter '*.tmp').Count -eq 0)
$script:registered=$null
# Load CIM cmdlets before shadowing registration; module autoload must not replace the mock.
Import-Module ScheduledTasks -ErrorAction Stop
function Register-ScheduledTask {
    param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force,$ErrorAction)
    $script:registered=[pscustomobject]@{Name=$TaskName;Action=$Action;Trigger=$Trigger;Principal=$Principal;Settings=$Settings}
}
Check 'watchdog startup task can be constructed without registering it' (Install-NetworkWatchTask)
Check 'watchdog covers boot and logon under SYSTEM' ($script:registered.Trigger.Count -eq 2 -and $script:registered.Principal.UserId -eq 'SYSTEM')
Check 'task invokes packaged watcher only' ($script:registered.Action.Arguments -match 'netwatch.ps1' -and $script:registered.Action.WorkingDirectory -eq $Script:Root)
Check 'watchdog task does not expire after default task time limit' ($script:registered.Settings.ExecutionTimeLimit -eq 'PT0S')
$script:launch=$null
function Start-Process {
    param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle)
    $script:launch=[pscustomobject]@{File=$FilePath;Args=$ArgumentList;Dir=$WorkingDirectory;Style=$WindowStyle}
}
Check 'direct startup can launch watcher without blocking' (Start-NetworkWatcher)
Check 'watcher launch uses hidden window and fixed package script' ($script:launch.Style -eq 'Hidden' -and $script:launch.Args -match 'netwatch.ps1' -and $script:launch.Dir -eq $Script:Root)
# A duplicate publisher must exit before invalidating the current marker.
Initialize-RingDir
$marker=Get-PkgPath ($Script:RingDir+'/network-context.txt')
$seed=Get-NetworkWatchRecord $known $known $now
Write-NetworkWatchRecord $marker $seed | Out-Null
$lease=[IO.File]::Open((Join-Path $Script:Runtime 'network-watch.lock'),'OpenOrCreate','ReadWrite','Read')
$child=$null
try{
    $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $args0=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Get-PkgPath 'tools/netwatch.ps1'),'-MaxSamples','1')
    $child=Microsoft.PowerShell.Management\Start-Process -FilePath $ps -ArgumentList $args0 -WindowStyle Hidden -PassThru
    if(-not $child.WaitForExit(10000)){throw 'Duplicate watchdog did not exit'}
    Check 'duplicate publisher leaves active marker intact' ($child.ExitCode -eq 0 -and [IO.File]::ReadAllText($marker) -ceq $seed)
}finally{
    if($child -and -not $child.HasExited){Microsoft.PowerShell.Management\Stop-Process -Id $child.Id -Force}
    $lease.Dispose()
}
if($fails){exit 1}
