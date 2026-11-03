param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach ($definition in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
if (-not (Get-Command Invoke-ControlWindow -ErrorAction SilentlyContinue)) { throw 'FAIL control windows are not integrated' }
$Parallel=16;$TimeoutSec=5;$HarmSlowMs=500;$RetryMax=16
$script:workers=@();$script:batchCalls=0;$script:contaminate=$false;$script:widths=@()
function Get-OurProcesses { return $script:workers }
function Invoke-CurlBatch($Targets,$PostFile,$Width=0) {
    $script:batchCalls++;$script:widths+=,$Width
    if ($script:contaminate) { $script:workers=@([pscustomobject]@{Id=1234}) }
    foreach ($target in $Targets) { [pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State='OK';Code='200';Exit=0;Up=0;Down=1;ConnMs=50;TlsMs=100;Tries=1;Flaky=$false} }
}
$controls=@(1..5 | ForEach-Object { [pscustomobject]@{Group='Clean';Name=('control'+$_);Url=('https://control'+$_.ToString()+'.example/')} })
$metadata=@{RunId='fixture';Seed=42;Sequence=0;Round=0;Stage='control-before';StrategyId='0';StrategyHash='';NetworkKey=('A'*64);InputsHash=('B'*64)}
$path=Join-Path $Script:Runtime 'control-fixture.jsonl'
$result=@(Invoke-ControlWindow $controls '' $path $metadata -Warmup)
Check 'warmup is excluded from two measured samples' ($result.Count -eq 10 -and $script:batchCalls -eq 3 -and ($result.Attempt | Sort-Object -Unique) -join ',' -eq '1,2')
Check 'control concurrency is bounded at four' (@($script:widths | Where-Object { $_ -gt 4 -or $_ -lt 1 }).Count -eq 0)
$events=@([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json })
Check 'all real warmup and measured attempts are journaled' ($events.Count -eq 15 -and @($events | Where-Object { $_.Stage -eq 'control-warmup' }).Count -eq 5 -and @($events | Where-Object { $_.ControlUncontaminated -ne $true }).Count -eq 0)
$script:workers=@([pscustomobject]@{Id=1234});$calls=$script:batchCalls;$blocked=$false
try { Invoke-ControlWindow $controls '' $path $metadata | Out-Null } catch { $blocked=$true }
Check 'live test process refuses direct baseline before probing' ($blocked -and $script:batchCalls -eq $calls)
$script:workers=@();$script:contaminate=$true;$blocked=$false
try { Invoke-ControlWindow $controls '' $path $metadata | Out-Null } catch { $blocked=$true }
$events=@([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json })
Check 'process appearing during probe invalidates control evidence' ($blocked -and @($events | Where-Object { $_.ControlUncontaminated -eq $false }).Count -eq 5)
$script:workers=@();$script:contaminate=$false
$loop=$ast.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.StartsWith('foreach ($roundPlan in $measurementOrder.Rounds)')},$true)
if (-not $loop) { throw 'FAIL measured strategy loop does not use planned order' }
$script:stageCalls=@{};$script:fakeProcess=$null
function Invoke-CurlBatch($Targets,$PostFile,$Width=0) {
    $id=[string]$metadata.StrategyId
    $script:stageCalls[$id]=1+[int]$script:stageCalls[$id]
    foreach ($target in $Targets) {
        $state=if ($target.Name -eq 'blocked' -or ($target.Name -eq 'flaky' -and ($id -eq '0' -or $script:stageCalls[$id] -eq 1))) { 'FAIL' } else { 'OK' }
        [pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State=$state;Code=$(if ($state -eq 'OK') {'200'} else {'000'});Exit=0;Up=0;Down=1;ConnMs=50;TlsMs=100;Tries=1;Flaky=$false}
    }
}
function Start-TestInstance {
    $script:fakeProcess=[pscustomobject]@{Id=1234;HasExited=$false}
    $script:fakeProcess | Add-Member ScriptMethod WaitForExit { return $true }
    return $script:fakeProcess
}
function Stop-Process { $script:fakeProcess.HasExited=$true }
function Start-Sleep { }
function Get-IpBlocked { return 'blocked' }
function Format-Summary { return 'fixture summary' }
$targets=@($controls[0],[pscustomobject]@{Group='DPI';Name='blocked';Url='https://blocked.example/'},[pscustomobject]@{Group='DPI';Name='flaky';Url='https://flaky.example/'})
$measurementOrder=New-TestMeasurementOrder @([pscustomobject]@{Id='12';Name='fixture'}) 1 42
$Rounds=1;$HopelessRuns=3;$GroupNames=[ordered]@{DPI='DPI';Clean='Clean'}
$table=@{};$ipSkip=@{};$failRuns=@{};$everOk=@{};$settings=@{};$testLifetimeMs=120000;$postFile='';$p=$null
$scoreFingerprints=@{'12'=('C'*64)}
$journalFile=Join-Path $Script:Runtime 'scan-fixture.jsonl'
$metadata.Stage='baseline';$metadata.StrategyId='0'
. ([scriptblock]::Create($loop.Extent.Text))
$events=@([IO.File]::ReadAllLines($journalFile) | ForEach-Object { $_ | ConvertFrom-Json })
$flaky=@($events | Where-Object { $_.StrategyId -eq '12' -and $_.Name -eq 'flaky' })
Check 'real scan journals failure before mutable retry merge' ($flaky.Count -eq 2 -and $flaky[0].State -eq 'FAIL' -and $flaky[1].State -eq 'OK' -and @($table['12'] | Where-Object { $_.Name -eq 'flaky' -and $_.Flaky }).Count -eq 1)
Check 'IP-skipped copies are not logged as real strategy requests' (@($events | Where-Object { $_.StrategyId -eq '12' -and $_.Name -eq 'blocked' }).Count -eq 0 -and @($table['12'] | Where-Object { $_.Name -eq 'blocked' }).Count -eq 1)
# Execute the real gate and following history write in a child; do not rewrite exit statements.
$gate=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if (-not $controlAssessment.CanApply)')},$true)
$history=$ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Extent.Text.StartsWith('$historySaved = Add-ScoreHistory')},$true)
if (-not $gate -or -not $history -or $gate.Extent.StartOffset -ge $history.Extent.StartOffset) { throw 'FAIL control gate must precede history publication' }
$span=$gate.Extent.Text+"`n"+$history.Extent.Text
$prefix=@'
param($Pkg,$Case,[switch]$Changed)
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:Runtime=$Case
$report=New-Object 'System.Collections.Generic.List[string]'
$repFile=Join-Path $Case 'report.txt'
$wasRunning=$false;$ReportOnly=$false;$alts=@();$scoreContext='fixture';$scoreFingerprints=@{}
$controlAssessment=[pscustomobject]@{CanApply=(-not $Changed);Status=$(if ($Changed) {'Changed'} else {'Stable'});Reasons=@('latency-shift')}
function Add-ScoreHistory { [IO.File]::WriteAllText((Join-Path $Case 'history-written.txt'),'written');return $true }
function Start-Bypass { throw 'must not touch live bypass' }
'@
$wrapper=Join-Path $Script:Runtime 'measurement-gate.ps1'
[IO.File]::WriteAllText($wrapper,($prefix+"`n"+$span),(New-Object Text.UTF8Encoding($true)))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach ($changed in @($true,$false)) {
    $case=Join-Path $Script:Runtime ('gate-'+$changed)
    New-Item -ItemType Directory $case | Out-Null
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper,'-Pkg',$Pkg,'-Case',$case)
    if ($changed) { $arguments+='-Changed' }
    $run=Invoke-Native $ps (ConvertTo-WinCmdLine $arguments) $case 15
    Check ('control gate publication changed='+$changed) ($(if ($changed) {$run.ExitCode -eq 1 -and -not (Test-Path (Join-Path $case 'history-written.txt')) -and (Test-Path (Join-Path $case 'report.txt'))}else{$run.ExitCode -eq 0 -and (Test-Path (Join-Path $case 'history-written.txt'))}))
    if (($changed -and $run.ExitCode -ne 1) -or (-not $changed -and $run.ExitCode -ne 0)) { Write-Host $run.Output }
}
if ($fails) { exit 1 }
