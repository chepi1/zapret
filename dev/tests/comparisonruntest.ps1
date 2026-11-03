param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:Runtime=Join-Path $Script:Runtime ('comparison-run-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Script:Runtime)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach ($definition in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
if (-not (Get-Command Invoke-FinalistExperiment -ErrorAction SilentlyContinue)) { throw 'FAIL finalist executor is missing' }
$targets=@('Clean','YouTube','Discord' | ForEach-Object { [pscustomobject]@{Group=$_;Name='main';Url=('https://'+$_.ToLowerInvariant()+'.example/');Post=$false} })
$plan=New-FinalistPlan '12' '13' ('C'*64) ('D'*64) $targets ('A'*64) ('B'*64) 42 4 ('2'*32)
$Parallel=16;$TimeoutSec=5
$settings=@{alt='12';auto='yes';ipset='none';game='tcp'}
$script:launches=@();$script:fakeProcess=$null;$script:batchCalls=0;$script:probeWidths=@();$script:probeDeadlines=@();$script:abortContext=$false;$script:abortGame=$false;$script:dieDuringProbe=$false;$script:dieAtLast=$false;$script:failFirst=$false;$script:refuseStop=$false;$script:denyJournal=$false;$script:deniedStream=$null
function ControlState {
    @(@($Script:RankFile,$Script:CoverFile,$Script:ScoreHistoryFile) | ForEach-Object { $path=Get-PkgPath $_;if (Test-Path $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { '-' } }) -join '|'
}
$controlBefore=ControlState
function Get-OurProcesses { if ($script:fakeProcess -and -not $script:fakeProcess.HasExited) { return $script:fakeProcess } }
function Start-TestInstance($Settings,$Alt,[switch]$Final,$LifetimeMs) {
    $script:launches+=,[pscustomobject]@{Alt=$Alt;Auto=$Settings.auto;Ipset=$Settings.ipset;Final=[bool]$Final;LifetimeMs=$LifetimeMs}
    $script:fakeProcess=[pscustomobject]@{Id=123456;HasExited=$false}
    $script:fakeProcess | Add-Member ScriptMethod WaitForExit { param($Timeout) return $this.HasExited }
    return $script:fakeProcess
}
function Stop-Process { param($Id,[switch]$Force,$ErrorAction) if ($Id -ne 123456) { throw 'Fixture refuses a real PID' };if (-not $script:refuseStop) { $script:fakeProcess.HasExited=$true } }
function Assert-BypassControlAllowed { if ($script:abortGame) { throw 'fixture game started' } }
function Get-NetworkObservation { return [pscustomobject]@{Known=$true;Key=('A'*64)} }
function Get-TestResultContext { return [pscustomobject]@{InputsHash=('F'*64)} }
function Test-ScoreInputs { return (-not $script:abortContext) }
function Invoke-CurlBatch($Targets,$PostFile,$Width=0,[long]$DeadlineTicks=0) {
    $script:batchCalls++;$script:probeWidths+=,$Width;$script:probeDeadlines+=,$DeadlineTicks
    if ($script:denyJournal -and -not $script:deniedStream) { $script:deniedStream=[IO.File]::Open($journalFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
    $slot=$plan.Slots[$script:launches.Count-1]
    $time=$slot.Index*1000+$script:batchCalls*10
    foreach ($target in $Targets) {
        $state=if ($script:failFirst -and $metadata.Stage -eq 'comparison' -and $slot.Index -eq 5 -and $script:batchCalls%2 -eq 0) { 'FAIL' } else { 'OK' }
        $tls=if ($slot.Kind -eq 'Compare' -and $slot.Arm -eq 'B') {60} else {100}
        [pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State=$state;TlsMs=$tls;StartedMs=$time;ObservedMs=($time+1)}
    }
    if ($script:dieDuringProbe) { $script:fakeProcess.HasExited=$true }
    if ($script:dieAtLast -and $slot.Index -eq 24 -and $metadata.Stage -eq 'comparison') { $script:fakeProcess.HasExited=$true }
}
$active=$null
$result=Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active)
Check 'executor follows all planned strategies including reference calibration' (($script:launches.Alt -join ',') -eq ($plan.Slots.StrategyId -join ',') -and $script:launches.Count -eq 24)
Check 'working IPSet is retained and both fixed arms disable auto without changing settings' ($settings.auto -eq 'yes' -and @($script:launches | Where-Object { $_.Auto -ne 'no' -or $_.Ipset -ne 'none' -or -not $_.Final -or $_.LifetimeMs -lt 120000 }).Count -eq 0)
Check 'one warmup per slot is excluded from evaluation' ($script:batchCalls -eq 48 -and $result.Assessment.FirstAttempts -eq 72 -and $result.Assessment.CanRecommend)
Check 'comparison uses bounded concurrency and leaves no active process' (@($script:probeWidths | Where-Object { $_ -gt 4 -or $_ -lt 1 }).Count -eq 0 -and $null -eq $active -and @(Get-OurProcesses).Count -eq 0)
Check 'every probe batch receives the same run deadline' (@($script:probeDeadlines | Sort-Object -Unique).Count -eq 1 -and $script:probeDeadlines[0] -gt [Diagnostics.Stopwatch]::GetTimestamp())
$events=@([IO.File]::ReadLines($result.JournalFile) | ForEach-Object { $_ | ConvertFrom-Json })
Check 'journal captures monotonic observations and exact slot identities' ($events.Count -eq 145 -and $events[0].ComparisonSlot -eq 1 -and $events[0].ComparisonKind -eq 'Calibration' -and $null -ne $events[0].StartedMs -and $events[0].ObservedMs -gt $events[0].StartedMs -and $events[-1].Stage -eq 'comparison-complete')
Check 'shadow creates only its own artifacts without ranking or settings writes' ((ControlState) -ceq $controlBefore -and -not (Test-Path (Join-Path $Script:Runtime 'settings.ini')) -and (Test-Path $result.PlanFile) -and (Test-Path $result.ResultFile))
# Reuse a fresh run ID per experiment, keeping fixture time/slot order independent.
$script:launches=@();$script:batchCalls=0;$script:failFirst=$true;$plan.RunId='3'*32
$active=$null
$flaky=Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active)
$events=@([IO.File]::ReadLines($flaky.JournalFile) | ForEach-Object { $_ | ConvertFrom-Json })
Check 'failed first attempts and recovery stay separate in actual runner output' (@($events | Where-Object { $_.Stage -eq 'comparison' -and $_.ComparisonSlot -eq 5 -and $_.Attempt -eq 1 -and $_.State -eq 'FAIL' }).Count -eq 3 -and @($events | Where-Object { $_.Stage -eq 'comparison' -and $_.ComparisonSlot -eq 5 -and $_.Attempt -eq 2 -and $_.State -eq 'OK' }).Count -eq 3)
$script:failFirst=$false
$script:launches=@();$script:batchCalls=0;$script:dieAtLast=$true;$plan.RunId=[guid]::NewGuid().ToString('N');$active=$null;$blocked=$false
try { Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active) | Out-Null } catch { $blocked=$true }
$lastJournal=Join-Path $Script:Runtime ('comparison-'+$plan.RunId+'.attempts.jsonl')
$lastEvents=@([IO.File]::ReadLines($lastJournal) | ForEach-Object { $_ | ConvertFrom-Json })
$lastAssessment=Get-FinalistAssessment $plan $lastEvents
Check 'death after the last measured batch cannot become a winner during replay' ($blocked -and $lastAssessment.Status -eq 'Inconclusive' -and $lastAssessment.FirstAttempts -eq 72 -and -not $lastAssessment.CanRecommend)
$script:dieAtLast=$false
foreach ($mode in @('context','game','process','stop')) {
    $script:launches=@();$script:batchCalls=0;$plan.RunId=[guid]::NewGuid().ToString('N')
    $script:abortContext=$mode -eq 'context';$script:abortGame=$mode -eq 'game';$script:dieDuringProbe=$mode -eq 'process';$script:refuseStop=$mode -eq 'stop'
    $active=$null;$blocked=$false
    try { Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active) | Out-Null } catch { $blocked=$true }
    if ($mode -eq 'stop') { Check 'refused process exit retains ownership for outer cleanup' ($blocked -and $null -ne $active -and $script:launches.Count -eq 1);$active.HasExited=$true;$script:fakeProcess.HasExited=$true }
    else { Check ($mode+' abort cannot leave a candidate running') ($blocked -and $null -eq $active -and @(Get-OurProcesses).Count -eq 0) }
}
$script:abortContext=$false;$script:abortGame=$false;$script:dieDuringProbe=$false;$script:refuseStop=$false
# Keep filesystem failure real: pre-existing artifacts must not be overwritten on a reused RunId.
$script:launches=@();$script:batchCalls=0;$plan.RunId='2'*32;$active=$null;$blocked=$false
try { Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active) | Out-Null } catch { $blocked=$true }
Check 'a reused artifact identity refuses before probing' ($blocked -and $script:launches.Count -eq 0)
$script:launches=@();$script:batchCalls=0;$plan.RunId=[guid]::NewGuid().ToString('N');$active=$null;$blocked=$false;$script:denyJournal=$true
try { Invoke-FinalistExperiment $settings $targets '' $plan @{} ([pscustomobject]@{Key=('A'*64)}) ([ref]$active) | Out-Null } catch { $blocked=$true } finally { if ($script:deniedStream) { $script:deniedStream.Dispose() };$script:denyJournal=$false }
Check 'real journal write failure cleans PID and leaves no accepted result' ($blocked -and $null -eq $active -and -not (Test-Path (Join-Path $Script:Runtime ('comparison-'+$plan.RunId+'.result.json'))))
$blocked=$false
try { Assert-FinalistExperiment $plan $targets @{} ([pscustomobject]@{Key=('A'*64)}) $settings ([pscustomobject]@{Elapsed=[timespan]::FromMinutes(30)}) } catch { $blocked=$true }
Check 'total deadline is checked without waiting thirty real minutes' $blocked
# Real preflight helper with only its native dry-run boundary substituted.
$script:dryCalls=@();$script:rejectDry=$false
function Test-ConfigDry($Settings,$Alt,[switch]$NoAuto,$IpsetMode) {
    $script:dryCalls+=,[pscustomobject]@{Alt=$Alt;Auto=$Settings.auto;Ipset=$Settings.ipset;NoAuto=[bool]$NoAuto;Override=$IpsetMode}
    return [pscustomobject]@{Ok=(-not $script:rejectDry);Output='fixture'}
}
$spec=New-FinalistExperimentSpec $settings $targets '12' '13' 42 4
Check 'preflight validates both arms with working IPSet before any start' ($script:dryCalls.Count -eq 2 -and ($script:dryCalls.Alt -join ',') -eq '12,13' -and @($script:dryCalls | Where-Object { $_.Auto -ne 'no' -or $_.Ipset -ne 'none' -or -not $_.NoAuto -or $_.Override }).Count -eq 0)
$script:rejectDry=$true;$blocked=$false
try { New-FinalistExperimentSpec $settings $targets '12' '13' 42 4 | Out-Null } catch { $blocked=$true }
Check 'rejected dry configuration cannot produce a runnable experiment' $blocked
# Use the real parser and journal, no external process.
$item=[pscustomobject]@{T=$targets[0];P=[pscustomobject]@{ExitCode=0};Out=[pscustomobject]@{Result='200 0 65536 0.1 0.2'};StartedTicks=[Diagnostics.Stopwatch]::GetTimestamp()}
$parsed=Convert-CurlResult $item
Check 'curl parser records an ordered monotonic interval' ($null -ne $parsed.StartedMs -and $parsed.ObservedMs -ge $parsed.StartedMs)
# Execute actual shadow branch + following scoring sentinel in a child; exit must run finally.
$branch=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($comparisonMode)') -and $node.Extent.Text.Contains('$comparison=Invoke-FinalistExperiment')},$true)
if (-not $branch) { throw 'FAIL no separate shadow execution branch' }
$childPath=Join-Path $Script:Runtime 'comparison-branch-child.ps1'
$prefix=@'
param($Case,[switch]$Compare)
$ErrorActionPreference='Stop'
$comparisonMode=[bool]$Compare;$targets=@();$postFile='';$p=$null
$comparisonSpec=[pscustomobject]@{Settings=@{};Plan='fixture';Parameters=@{};Network='fixture';AName='Reference';BName='Candidate'}
function Write-Color { }
function Invoke-FinalistExperiment { return [pscustomobject]@{Assessment=[pscustomobject]@{Status='Inconclusive'};ResultFile='fixture.json'} }
try {
'@
$suffix=@'
[IO.File]::WriteAllText(($Case+'.scored'),'ordinary path')
} finally { [IO.File]::WriteAllText(($Case+'.finally'),'cleanup') }
'@
[IO.File]::WriteAllText($childPath,($prefix+"`n"+$branch.Extent.Text+"`n"+$suffix),(New-Object Text.UTF8Encoding($true)))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach ($mode in @('shadow','ordinary')) {
    $case=Join-Path $Script:Runtime ('branch-'+$mode)
    $argsLine='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-WinArg $childPath)+' -Case '+(ConvertTo-WinArg $case)+$(if ($mode -eq 'shadow') {' -Compare'} else {''})
    $run=Invoke-Native $ps $argsLine $Script:Runtime 10
    Check ($mode+' branch preserves exit/finally and scoring separation') ($run.ExitCode -eq 0 -and (Test-Path ($case+'.finally')) -and (Test-Path ($case+'.scored')) -eq ($mode -eq 'ordinary'))
}
if ($fails) { exit 1 }
