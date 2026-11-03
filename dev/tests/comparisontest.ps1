param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:Runtime=Join-Path $Script:Runtime ('comparison-fixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Script:Runtime)
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
if (-not (Get-Command New-FinalistPlan -ErrorAction SilentlyContinue)) { throw 'FAIL finalist comparison is missing' }
$targets=@('Clean','YouTube','Discord' | ForEach-Object { [pscustomobject]@{Group=$_;Name='main';Url=('https://'+$_.ToLowerInvariant()+'.example/?private=secret')} })
function Plan([int]$Seed=42,[int]$Blocks=4) { New-FinalistPlan '12' '13' ('C'*64) ('D'*64) $targets ('A'*64) ('B'*64) $Seed $Blocks ('1'*32) }
function Assess-Fixture($Plan,$Rows) {
    if (Get-Command New-FinalistCompletion -ErrorAction SilentlyContinue) { return Get-FinalistAssessment $Plan (@($Rows)+(New-FinalistCompletion $Plan $Rows)) }
    return Get-FinalistAssessment $Plan $Rows
}
$plan=Plan
$again=Plan
Check 'seed reproduces a complete fixed comparison plan' (($plan | ConvertTo-Json -Depth 8 -Compress) -ceq ($again | ConvertTo-Json -Depth 8 -Compress))
Check 'calibration brackets four balanced comparison blocks' ($plan.Slots.Count -eq 24 -and $plan.Slots[0].Kind -eq 'Calibration' -and $plan.Slots[23].Kind -eq 'Calibration' -and (@($plan.Slots | Where-Object { $_.Kind -eq 'Compare' -and $_.Arm -eq 'A' }).Count -eq 8))
$patterns=@(2..5 | ForEach-Object { $block=$_; (@($plan.Slots | Where-Object { $_.Block -eq $block }).Arm -join '') })
Check 'paired blocks reverse ABBA and BAAB' ($patterns[0] -in @('ABBA','BAAB') -and $patterns[1] -ne $patterns[0] -and $patterns[2] -ne $patterns[3])
Check 'calibration runs the reference for both logical arms' (@($plan.Slots | Where-Object { $_.Kind -eq 'Calibration' -and $_.StrategyId -ne '12' }).Count -eq 0)
Check 'plan stores target identity without URLs' (($plan | ConvertTo-Json -Depth 8) -notmatch 'https://|private=|secret' -and $plan.Targets.Count -eq 3 -and ($plan.RequiredGroups -join ',') -eq 'Clean,Discord,YouTube')
$rejected=$false;try { Plan 42 5 | Out-Null } catch { $rejected=$true }
Check 'unbalanced odd block counts are refused' $rejected
$rejected=$false;try { New-FinalistPlan '12' '12' ('C'*64) ('C'*64) $targets ('A'*64) ('B'*64) 42 4 ('1'*32) | Out-Null } catch { $rejected=$true }
Check 'two identical candidates cannot pretend to be an A/B experiment' $rejected
function Samples([double]$Gain=0,[switch]$Drift) {
    foreach ($slot in $plan.Slots) {
        foreach ($target in $plan.Targets) {
            $t=($slot.Block-1)*2000+@(0,100,400,1000)[$slot.Position-1]
            $tls=100.0
            if ($Drift) { $tls+=0.01*($t+5) }
            if ($slot.Kind -eq 'Compare' -and $slot.Arm -eq 'B') { $tls-=$Gain }
            [pscustomobject]@{Schema=1;RunId=$plan.RunId;Seed=$plan.Seed;Stage='comparison';ComparisonSlot=$slot.Index;ComparisonBlock=$slot.Block;ComparisonKind=$slot.Kind;ComparisonArm=$slot.Arm
                StrategyId=$slot.StrategyId;StrategyHash=$slot.StrategyHash;CapturedNetworkKey=$plan.CapturedNetworkKey;CapturedInputsHash=$plan.CapturedInputsHash
                TargetKey=$target.Key;Group=$target.Group;Name=$target.Name;Attempt=1;State='OK';TlsMs=$tls;StartedMs=$t;ObservedMs=($t+10)}
        }
    }
}
$flat=Assess-Fixture $plan @(Samples)
Check 'a full but unvalidated collection cannot recommend on replay' (-not (Get-FinalistAssessment $plan @(Samples 40)).CanRecommend)
Check 'identical strategies produce no clear difference' ($flat.Status -eq 'NoClearDifference' -and -not $flat.CanRecommend -and $flat.Targets.Count -eq 3)
$linear=Assess-Fixture $plan @(Samples -Drift)
Check 'linear drift with unequal intervals does not invent improvement' ($linear.Status -eq 'NoClearDifference' -and @($linear.Targets | Where-Object { [math]::Abs($_.BlockDeltas[0]) -gt 0.00001 }).Count -eq 0)
$improved=Assess-Fixture $plan @(Samples 40 -Drift)
Check 'repeatable improvement survives unequal durations and linear drift' ($improved.Status -eq 'ConsistentImprovement' -and $improved.CanRecommend -and @($improved.Targets | Where-Object { $_.Conclusion -ne 'Improved' -or [math]::Abs($_.BlockDeltas[0]+40) -gt 0.00001 }).Count -eq 0)
Check 'report includes observation counts without statistical confidence claims' ($improved.Targets[0].AFirstSuccess -eq 8 -and $improved.Targets[0].BFirstSuccess -eq 8 -and $improved.Targets[0].CalibrationCount -eq 8 -and ($improved | ConvertTo-Json -Depth 8) -notmatch 'P95|P99|ConfidenceInterval')
$noisy=@(Samples 40)
$noisy | Where-Object { $_.ComparisonKind -eq 'Calibration' -and $_.ComparisonArm -eq 'B' } | ForEach-Object { $_.TlsMs+=80 }
$noise=Assess-Fixture $plan $noisy
Check 'A/A variability raises the evidence threshold' (-not $noise.CanRecommend -and $noise.Targets[0].NoiseMs -eq 80 -and $noise.Targets[0].ThresholdMs -eq 80)
$regress=@(Samples 40)
$regress | Where-Object { $_.Group -eq 'YouTube' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'B' } | ForEach-Object { $_.TlsMs=150 }
Check 'one slower required service is not compensated by other fast services' (-not (Assess-Fixture $plan $regress).CanRecommend)
$lost=@(Samples 40)
$lost | Where-Object { $_.Group -eq 'YouTube' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'B' } | ForEach-Object { $_.State='FAIL';$_.TlsMs=0 }
$loss=Assess-Fixture $plan $lost
Check 'a lost required service blocks candidate recommendation' (-not $loss.CanRecommend -and $loss.Reasons -contains 'reference-endpoint-not-preserved' -and @($loss.Groups | Where-Object { $_.Group -eq 'YouTube' -and -not $_.Comparable }).Count -eq 1)
$flaky=@(Samples 40)
$bad=$flaky | Where-Object { $_.Group -eq 'YouTube' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'B' } | Select-Object -First 1
$retry=$bad.PSObject.Copy();$retry.Attempt=2;$retry.StartedMs+=20;$retry.ObservedMs+=20
$bad.State='FAIL';$bad.TlsMs=0
$flaky+=$retry
$flakyResult=Assess-Fixture $plan $flaky
$yt=$flakyResult.Targets | Where-Object { $_.Group -eq 'YouTube' }
Check 'successful retry cannot erase the first failed attempt' (-not $flakyResult.CanRecommend -and $yt.BFirstSuccess -eq 7 -and $yt.BRecovered -eq 1)
$originalTargets=$targets
$targets+=,[pscustomobject]@{Group='YouTube';Name='backup';Url='https://backup.example/'}
$plan=Plan
$lessReliable=@(Samples 40)
$lessReliable | Where-Object { $_.Group -eq 'YouTube' -and $_.Name -eq 'main' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'B' } | ForEach-Object { $_.State='FAIL' }
($lessReliable | Where-Object { $_.Group -eq 'YouTube' -and $_.Name -eq 'main' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'A' } | Select-Object -First 1).State='FAIL'
Check 'a partly reliable reference endpoint cannot disappear behind a healthy group peer' (-not (Assess-Fixture $plan $lessReliable).CanRecommend)
$targets=$originalTargets;$plan=Plan
$unknown=@(Samples 40);$unknown | Where-Object { $_.Group -eq 'YouTube' } | ForEach-Object { $_.State='NA';$_.TlsMs=$null }
Check 'unknown mandatory group is not zero latency or success' (-not (Assess-Fixture $plan $unknown).CanRecommend)
$missing=@(Samples 40 | Select-Object -Skip 1)
Check 'missing calibration stays inconclusive' ((Assess-Fixture $plan $missing).Status -eq 'Inconclusive')
$missing=@(Samples 40 | Where-Object { -not ($_.Group -eq 'Clean' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq 'A') } | Select-Object -Skip 0)
$partial=Assess-Fixture $plan $missing
Check 'reported sample counts are actual observations rather than planned counts' (($partial.Targets | Where-Object { $_.Group -eq 'Clean' }).AFirstCount -eq 0 -and $partial.FirstAttempts -eq 64)
$nan=@(Samples 40);$nan[0].TlsMs=[double]::NaN
Check 'nonfinite timing cannot create a winner' (-not (Assess-Fixture $plan $nan).CanRecommend)
$badClock=@(Samples 40);$badClock[3].StartedMs=$badClock[0].StartedMs;$badClock[3].ObservedMs=$badClock[0].ObservedMs
Check 'overlapping or repeated monotonic times invalidate order' ((Assess-Fixture $plan $badClock).Status -eq 'Invalid')
$changed=@(Samples 40);$changed[0].CapturedNetworkKey='E'*64
Check 'mixed network contexts are invalid evidence' ((Assess-Fixture $plan $changed).Status -eq 'Invalid')
$changed=@(Samples 40);$changed[0].StrategyHash='E'*64
Check 'wrong strategy bytes are invalid evidence' ((Assess-Fixture $plan $changed).Status -eq 'Invalid')
$duplicated=@(Samples 40);$duplicated+=$duplicated[0].PSObject.Copy()
Check 'duplicate first attempts cannot inflate sample counts' ((Assess-Fixture $plan $duplicated).Status -eq 'Invalid')
$shuffled=@(Samples 40 | Sort-Object -Property ComparisonSlot -Descending)
Check 'replay uses captured monotonic order rather than JSONL line order' ((Assess-Fixture $plan $shuffled).CanRecommend)
$wrongPlan=($plan | ConvertTo-Json -Depth 8 | ConvertFrom-Json);$wrongPlan.Slots[4].Arm='X'
Check 'tampered slot plans are refused' ((Assess-Fixture $wrongPlan @(Samples 40)).Status -eq 'Invalid')
# The replay command must work without importing control/network modules or touching settings.
$planPath=Join-Path $Script:Runtime 'finalists-plan.json';$journalPath=Join-Path $Script:Runtime 'finalists-attempts.jsonl';$outPath=Join-Path $Script:Runtime 'finalists-assessment.json'
[IO.File]::WriteAllText($planPath,($plan | ConvertTo-Json -Depth 8))
$offlineRows=@(Samples 40)
if (Get-Command New-FinalistCompletion -ErrorAction SilentlyContinue) { $offlineRows+=New-FinalistCompletion $plan $offlineRows }
[IO.File]::WriteAllLines($journalPath,[string[]]@($offlineRows | ForEach-Object { $_ | ConvertTo-Json -Compress }))
& (Join-Path $Pkg 'dev/perfbench.ps1') -PlanFile $planPath -JournalFile $journalPath -OutFile $outPath | Out-Null
$replayed=Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json
Check 'offline command reproduces evidence without probes or ranking writes' ($replayed.Status -eq 'ConsistentImprovement' -and -not (Test-Path (Join-Path $Script:Runtime 'test-rank.txt')))
$tampered=@(Samples 40)
$tampered+=New-FinalistCompletion $plan $tampered
$tampered[0].TlsMs=50
Check 'completion binds exact measured values rather than just record count' ((Get-FinalistAssessment $plan $tampered).Status -eq 'Invalid')
$tampered=@(Samples 40)
$tampered+=New-FinalistCompletion $plan $tampered
$tampered[0].Stage='unknown-stage'
Check 'changing stage cannot remove evidence from a finalized collection' ((Get-FinalistAssessment $plan $tampered).Status -eq 'Invalid')
$successRetry=@(Samples 40)
$extra=$successRetry[0].PSObject.Copy();$extra.Attempt=2;$extra.StartedMs+=20;$extra.ObservedMs+=20;$successRetry+=$extra
Check 'unexpected retry after a first success is invalid in this protocol' ((Assess-Fixture $plan $successRetry).Status -eq 'Invalid')
if ($fails) { exit 1 }
