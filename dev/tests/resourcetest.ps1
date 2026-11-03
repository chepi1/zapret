param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
if (-not (Get-Command Get-ProcessResourceWindow -ErrorAction SilentlyContinue)) { throw 'FAIL process resource measurements are missing' }
function Sample($Time,$Cpu,$Private=10485760,$ProcessId=123) {
    [pscustomobject]@{Schema=1;ResourceStatus='Ready';ResourceReason='';ProcessId=$ProcessId;ProcessStartKey='639000000000000001';ObservedMs=[double]$Time;ReadDurationMs=0.5;CpuTotalMs=[double]$Cpu;PrivateBytes=$Private;WorkingSetBytes=20971520;OsPeakWorkingSetBytes=62914560}
}
$samples=@((Sample 0 100),(Sample 1000 120 31457280),(Sample 2000 160 15728640))
$window=Get-ProcessResourceWindow $samples
Check 'resource window reports actual CPU delta and monotonic wall time' ($window.Status -eq 'Ready' -and $window.CpuTimeMs -eq 60 -and $window.ElapsedMs -eq 2000 -and $window.CpuPercentOneCore -eq 3)
Check 'private endpoints and sampled maximum retain distinct meanings' ($window.PrivateBytesStart -eq 10485760 -and $window.PrivateBytesEnd -eq 15728640 -and $window.ObservedMaxPrivateBytes -eq 31457280 -and $window.SampleCount -eq 3)
Check 'OS working-set peak remains separate from sampled private memory' ($window.OsPeakWorkingSetBytesEnd -eq 62914560 -and $window.ObservedMaxWorkingSetBytes -eq 20971520 -and $window.ReadDurationMsSum -eq 1.5)
$multi=Get-ProcessResourceWindow @((Sample 0 0),(Sample 1000 2000))
Check 'multithread CPU percentage is not clamped to one core' ($multi.Status -eq 'Ready' -and $multi.CpuPercentOneCore -eq 200)
$zero=Get-ProcessResourceWindow @((Sample 0 15.625),(Sample 1000 15.625))
Check 'OS-accounted zero CPU delta is retained as a measured zero' ($zero.Status -eq 'Ready' -and $zero.CpuTimeMs -eq 0)
$none=Get-ProcessResourceWindow @()
Check 'no samples remain unavailable rather than zero cost' ($none.Status -eq 'Unavailable' -and $null -eq $none.CpuTimeMs -and $null -eq $none.PrivateBytesEnd)
Check 'one sample is insufficient for CPU delta' ((Get-ProcessResourceWindow @($samples[0])).Status -eq 'Unavailable')
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].ResourceStatus='Exited';$bad[1].CpuTotalMs=$null
$exit=Get-ProcessResourceWindow $bad
Check 'process exit leaves metrics unknown' ($exit.Status -eq 'Unavailable' -and $null -eq $exit.CpuTimeMs)
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].ProcessId=124
Check 'different PID cannot form one resource window' ((Get-ProcessResourceWindow $bad).Status -eq 'Invalid')
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].ProcessStartKey='639000000000000002'
Check 'PID reuse is detected even when start keys differ below double precision' ((Get-ProcessResourceWindow $bad).Status -eq 'Invalid')
$bad=@((Sample 0 10),(Sample 1000 20),(Sample 2000 15))
Check 'CPU decrease between intermediate samples is invalid' ((Get-ProcessResourceWindow $bad).Status -eq 'Invalid')
$bad=@((Sample 0 10),(Sample 0 20))
Check 'equal or reversed monotonic times are invalid' ((Get-ProcessResourceWindow $bad).Status -eq 'Invalid')
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].CpuTotalMs=[double]::NaN
Check 'nonfinite CPU is never a good resource measurement' ((Get-ProcessResourceWindow $bad).Status -ne 'Ready')
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].PrivateBytes=-1
Check 'negative memory is invalid' ((Get-ProcessResourceWindow $bad).Status -eq 'Invalid')
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].PrivateBytes=$null
Check 'missing memory remains unavailable without changing it to zero' ((Get-ProcessResourceWindow $bad).Status -eq 'Unavailable')
$snapshot=Get-ProcessResourceSample ([pscustomobject]@{Id=123})
Check 'unreadable process counters fail closed without throwing or inventing metrics' ($snapshot.ResourceStatus -eq 'Unavailable' -and $null -eq $snapshot.CpuTotalMs -and $null -eq $snapshot.PrivateBytes)
$bad=@((Sample 0 10),(Sample 1000 20));$bad[1].ProcessId=2147483648
try { $badId=Get-ProcessResourceWindow $bad;Check 'out-of-range PID is invalid data rather than an uncaught cast error' ($badId.Status -eq 'Invalid') } catch { Check 'out-of-range PID is invalid data rather than an uncaught cast error' $false }
$overflow=Get-ProcessResourceWindow @((Sample 0 0),(Sample 1e-300 1e308))
Check 'finite but corrupt inputs cannot yield an infinite ready CPU percentage' ($overflow.Status -eq 'Invalid' -and $null -eq $overflow.CpuPercentOneCore)
if (-not (Get-Command Get-FinalistResourceAssessment -ErrorAction SilentlyContinue)) { throw 'FAIL resource comparison evidence is missing' }
$legacy=[pscustomobject]@{Schema=1;RunId=('1'*32);Seed=42;Stage='comparison';ComparisonSlot=1;ComparisonBlock=1;ComparisonKind='Calibration';ComparisonArm='A';StrategyId='12';StrategyHash=('C'*64);CapturedNetworkKey=('A'*64);CapturedInputsHash=('B'*64);TargetKey=('F'*64);Group='Clean';Name='fixture';Attempt=1;State='OK';Code='200';Exit=0;Up=0;Down=1;ConnMs=50;TlsMs=100;DnsMs=10;FirstByteMs=120;TotalMs=150;StartedMs=1000;ObservedMs=1200}
Check 'legacy probe canonical hash is unchanged from 7b91be5' ((Get-FinalistEvidenceHash @($legacy)) -ceq '4A2D727AAE9C51B7D1A9C99A43FD170DEA5BFE4CD2800223F308587FBD4CE8AB')
$targets=@('Clean','Discord','YouTube' | ForEach-Object { [pscustomobject]@{Group=$_;Name='main';Url=('https://'+$_.ToLowerInvariant()+'.example/')} })
$plan=New-FinalistPlan '12' '13' ('C'*64) ('D'*64) $targets ('A'*64) ('B'*64) 42 4 ('4'*32) -MeasureResources
Check 'explicit resource policy versions the plan without changing old constructors' ($plan.Protocol -eq 'finalists-v2' -and $plan.ResourcePolicy -eq 'process-v1' -and (New-FinalistPlan '12' '13' ('C'*64) ('D'*64) $targets ('A'*64) ('B'*64) 42 4 ('5'*32)).Protocol -eq 'finalists-v1')
function Evidence {
    foreach ($slot in $plan.Slots) {
        $common=@{Schema=1;RunId=$plan.RunId;Seed=$plan.Seed;ComparisonSlot=$slot.Index;ComparisonBlock=$slot.Block;ComparisonKind=$slot.Kind;ComparisonArm=$slot.Arm;StrategyId=$slot.StrategyId;StrategyHash=$slot.StrategyHash;CapturedNetworkKey=$plan.CapturedNetworkKey;CapturedInputsHash=$plan.CapturedInputsHash}
        $isB=$slot.Kind -eq 'Compare' -and $slot.Arm -eq 'B'
        foreach ($target in $plan.Targets) {
            $row=$common.Clone();$row.Stage='comparison';$row.Group=$target.Group;$row.Name=$target.Name;$row.TargetKey=$target.Key;$row.Attempt=1;$row.State='OK';$row.TlsMs=$(if ($isB) {60} else {100});$row.StartedMs=$slot.Index*1000+200;$row.ObservedMs=$slot.Index*1000+300
            [pscustomobject]$row
        }
        foreach ($phase in @('Ready','Warm','End')) {
            $row=$common.Clone();$row.Stage='comparison-resource';$row.ResourceSchema=1;$row.ResourcePhase=$phase;$row.ResourceStatus='Ready';$row.ResourceReason='';$row.ProcessId=123;$row.ProcessStartKey=(639000000000000000L+$slot.Index).ToString([Globalization.CultureInfo]::InvariantCulture);$row.ReadDurationMs=0.25;$row.WorkingSetBytes=8388608;$row.OsPeakWorkingSetBytes=67108864
            $row.ObservedMs=$slot.Index*1000+$(switch ($phase) {Ready {0};Warm {100};End {400}})
            $row.CpuTotalMs=$(switch ($phase) {Ready {0};Warm {500};End {if ($isB) {510} else {520}}})
            $row.PrivateBytes=1024*1024*$(switch ($phase) {Ready {10};Warm {20};End {if ($isB) {15} else {30}}})
            [pscustomobject]$row
        }
    }
}
function Assess($Rows) { Get-FinalistAssessment $plan (@($Rows)+(New-FinalistCompletion $plan $Rows)) }
$rows=@(Evidence);$assessment=Assess $rows;$resources=$assessment.Resources
Check 'valid resource evidence preserves the existing HTTPS recommendation' ($assessment.Status -eq 'ConsistentImprovement' -and $assessment.CanRecommend -and $resources.Status -eq 'Ready')
Check 'CPU aggregate excludes calibration and the much larger warmup cost' ($resources.A.WindowsKnown -eq 8 -and $resources.B.WindowsKnown -eq 8 -and $resources.A.CpuTimeMsSum -eq 160 -and $resources.B.CpuTimeMsSum -eq 80 -and $resources.A.ElapsedMsSum -eq 2400)
Check 'end private median and sampled maximum are reported separately' ($resources.B.PrivateBytesEndMedian -eq 15728640 -and $resources.B.ObservedMaxPrivateBytes -eq 20971520 -and $resources.A.PrivateBytesEndMedian -eq 31457280)
$unavailable=@(Evidence)
$unavailable | Where-Object { $_.Stage -eq 'comparison-resource' -and $_.ComparisonSlot -eq 5 -and $_.ResourcePhase -eq 'Warm' } | ForEach-Object { $_.ResourceStatus='Unavailable';$_.ResourceReason='counter-unavailable';$_.CpuTotalMs=$null;$_.PrivateBytes=$null }
$partial=Assess $unavailable
Check 'one unavailable resource window is partial without erasing valid HTTPS evidence' ($partial.CanRecommend -and $partial.Resources.Status -eq 'Partial' -and $partial.Resources.A.WindowsKnown+$partial.Resources.B.WindowsKnown -eq 15)
$unavailable=@(Evidence)
$unavailable | Where-Object { $_.Stage -eq 'comparison-resource' } | ForEach-Object { $_.ResourceStatus='Unavailable';$_.ResourceReason='counter-unavailable';$_.CpuTotalMs=$null;$_.PrivateBytes=$null }
$unknown=Assess $unavailable
Check 'all unavailable counters never become a zero-cost engine' ($unknown.CanRecommend -and $unknown.Resources.Status -eq 'Unavailable' -and $null -eq $unknown.Resources.A.CpuTimeMsSum -and $unknown.Resources.A.WindowsKnown -eq 0)
$missing=@(Evidence | Where-Object { -not ($_.Stage -eq 'comparison-resource' -and $_.ComparisonSlot -eq 1 -and $_.ResourcePhase -eq 'Warm') })
Check 'missing mandatory resource phase invalidates a finalized v2 collection' ((Assess $missing).Status -eq 'Invalid')
$duplicated=@(Evidence);$duplicated+=($duplicated | Where-Object { $_.Stage -eq 'comparison-resource' } | Select-Object -First 1).PSObject.Copy()
Check 'duplicate resource phase cannot inflate observation counts' ((Assess $duplicated).Status -eq 'Invalid')
$mixed=@(Evidence);($mixed | Where-Object { $_.Stage -eq 'comparison-resource' } | Select-Object -First 1).CapturedInputsHash='E'*64
Check 'resource context must match its HTTPS run' ((Assess $mixed).Status -eq 'Invalid')
$reused=@(Evidence);($reused | Where-Object { $_.Stage -eq 'comparison-resource' -and $_.ComparisonSlot -eq 1 -and $_.ResourcePhase -eq 'End' }).ProcessStartKey='639000000000000002'
Check 'resource identity cannot change inside one engine launch' ((Assess $reused).Status -eq 'Invalid')
$outside=@(Evidence);($outside | Where-Object { $_.Stage -eq 'comparison-resource' -and $_.ComparisonSlot -eq 1 -and $_.ResourcePhase -eq 'Warm' }).ObservedMs=1250
Check 'a measured request outside the resource window cannot be attributed to it' ((Assess $outside).Status -eq 'Invalid')
$overlap=@(Evidence);($overlap | Where-Object { $_.Stage -eq 'comparison-resource' -and $_.ComparisonSlot -eq 2 -and $_.ResourcePhase -eq 'Ready' }).ObservedMs=1300
Check 'resource windows follow actual sequential engine launches' ((Assess $overlap).Status -eq 'Invalid')
$reordered=@(Evidence);$reordered+=New-FinalistCompletion $plan $reordered;[array]::Reverse($reordered)
$same=Get-FinalistAssessment $plan $reordered
Check 'JSONL transport order does not replace captured clocks and phase identities' ($same.Status -eq 'ConsistentImprovement' -and $same.Resources.A.CpuTimeMsSum -eq 160)
$huge=@(Evidence | Where-Object { $_.Stage -eq 'comparison-resource' })
foreach ($frame in $huge) {
    $frame.ObservedMs=$frame.ComparisonSlot*1e306+$(switch ($frame.ResourcePhase) {Ready {0};Warm {1e305};End {8e305}})
    $frame.CpuTotalMs=if ($frame.ResourcePhase -eq 'End') {1e308} else {0}
}
$blocked=$false;try { Get-FinalistResourceAssessment $plan $huge | Out-Null } catch { $blocked=$true }
Check 'resource aggregate overflow is rejected rather than reported as ready' $blocked
$largeMemory=@(Evidence)
$largeMemory | Where-Object { $_.Stage -eq 'comparison-resource' -and $_.ResourcePhase -eq 'End' } | ForEach-Object { $_.PrivateBytes=1e308 }
$large=Assess $largeMemory
Check 'median of large finite memory observations remains finite' ($large.Resources.Status -eq 'Ready' -and $large.Resources.A.PrivateBytesEndMedian -eq 1e308)
$tampered=@(Evidence);$tampered+=New-FinalistCompletion $plan $tampered
($tampered | Where-Object { $_.Stage -eq 'comparison-resource' } | Select-Object -First 1).PrivateBytes=1
Check 'completion hash binds resource metrics' ((Get-FinalistAssessment $plan $tampered).Status -eq 'Invalid')
$tampered=@(Evidence);$tampered+=New-FinalistCompletion $plan $tampered
($tampered | Where-Object { $_.Stage -eq 'comparison-resource' } | Select-Object -First 1).ProcessStartKey='639000000000000002'
Check 'completion hash preserves exact start-key low digits' ((Get-FinalistAssessment $plan $tampered).Status -eq 'Invalid')
Check 'unfinalized resource collection cannot present a completed cost comparison' (-not (Get-FinalistAssessment $plan @(Evidence)).CanRecommend)
$path=Join-Path $Script:Runtime ('resource-writer-'+[guid]::NewGuid().ToString('N')+'.jsonl')
$metadata=@{RunId=$plan.RunId;Seed=42;Sequence=0;NetworkKey=('A'*64);InputsHash=('B'*64);ComparisonSlot=1;ComparisonBlock=1;ComparisonKind='Calibration';ComparisonArm='A';StrategyId='12';StrategyHash=('C'*64);ProxySecret='never-store-this'}
$written=@(Write-ProcessResourceJournal $path $metadata Ready (Sample 1000 1))
$text=[IO.File]::ReadAllText($path);$decoded=$text | ConvertFrom-Json
Check 'resource writer is silent and serializes only approved fields' ($written.Count -eq 0 -and $decoded.ResourcePhase -eq 'Ready' -and $decoded.ProcessStartKey -ceq '639000000000000001' -and $text -notmatch 'never-store-this|https://')
$blocked=$false;try { Write-ProcessResourceJournal $path $metadata Warm (Sample 2000 2) -MaxBytes 1 } catch { $blocked=$true }
Check 'resource byte budget failure preserves earlier evidence' ($blocked -and [IO.File]::ReadAllText($path) -ceq $text)
if ($fails) { exit 1 }
