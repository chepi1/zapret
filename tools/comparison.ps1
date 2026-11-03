# Pure shadow comparison. Import does not launch probes or change settings.
function New-FinalistSlots([string]$AId,[string]$BId,[string]$AHash,[string]$BHash,[int]$Seed,[int]$Blocks) {
    if ($Seed -lt 0 -or $Blocks -lt 4 -or $Blocks -gt 12 -or $Blocks%2) { throw 'invalid-comparison-size' }
    $random=New-Object System.Random($Seed)
    $slots=New-Object 'System.Collections.Generic.List[object]'
    $pattern='ABBA'
    for ($block=1; $block -le $Blocks+2; $block++) {
        $kind=if ($block -eq 1 -or $block -eq $Blocks+2) { 'Calibration' } else { 'Compare' }
        if ($kind -eq 'Compare') {
            if ($block%2 -eq 0) { $pattern=if ($random.Next(2)) { 'ABBA' } else { 'BAAB' } }
            else { $pattern=if ($pattern -eq 'ABBA') { 'BAAB' } else { 'ABBA' } }
        } else { $pattern='ABBA' }
        for ($position=1; $position -le 4; $position++) {
            $arm=[string]$pattern[$position-1]
            $useA=$kind -eq 'Calibration' -or $arm -eq 'A'
            $slots.Add([pscustomobject]@{Index=($slots.Count+1);Block=$block;Position=$position;Kind=$kind;Arm=$arm;StrategyId=$(if ($useA) {$AId} else {$BId});StrategyHash=$(if ($useA) {$AHash} else {$BHash})})
        }
    }
    return $slots.ToArray()
}
function New-FinalistPlan([string]$AId,[string]$BId,[string]$AHash,[string]$BHash,$Targets,[string]$NetworkKey,[string]$InputsHash,[int]$Seed,[int]$Blocks,[string]$RunId,[switch]$MeasureResources) {
    if ($AId -notmatch '^\d+$' -or $BId -notmatch '^\d+$' -or $AId -eq $BId -or $RunId -notmatch '^[A-Fa-f0-9]{32}$') { throw 'invalid-candidates' }
    foreach ($hash in @($AHash,$BHash,$NetworkKey,$InputsHash)) { if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'unknown-comparison-context' } }
    $seen=@{};$targetKeys=@()
    foreach ($target in $Targets) {
        $key=Get-ProbeKey $target
        if (-not $key -or $seen.ContainsKey($key)) { throw 'invalid-target-identity' }
        $seen[$key]=$true
        $targetKeys+=[pscustomobject]@{Key=$key;Group=[string]$target.Group;Name=[string]$target.Name}
    }
    if (-not $targetKeys.Count) { throw 'missing-targets' }
    $plan=[pscustomobject]@{Schema=1;Protocol='finalists-v1';RunId=$RunId;Seed=$Seed;Blocks=$Blocks;AId=$AId;BId=$BId;AHash=$AHash;BHash=$BHash
        CapturedNetworkKey=$NetworkKey;CapturedInputsHash=$InputsHash;Targets=$targetKeys;RequiredGroups=@($targetKeys.Group | Sort-Object -Unique)
        Slots=@(New-FinalistSlots $AId $BId $AHash $BHash $Seed $Blocks)}
    if ($MeasureResources) { $plan.Protocol='finalists-v2';$plan | Add-Member NoteProperty ResourcePolicy 'process-v1' }
    return $plan
}
function Get-FinalistBlockDelta([double[]]$Values,[double[]]$Times,[string]$Pattern) {
    if ($Values.Count -ne 4 -or $Times.Count -ne 4 -or $Pattern -notin @('ABBA','BAAB') -or $Times[3] -le $Times[0]) { throw 'invalid-block' }
    $deltas=@(foreach ($i in 1,2) {
        $estimate=$Values[0]+($Values[3]-$Values[0])*($Times[$i]-$Times[0])/($Times[3]-$Times[0])
        if ($Pattern -eq 'ABBA') { $Values[$i]-$estimate } else { $estimate-$Values[$i] }
    })
    return [pscustomobject]@{Mean=(($deltas[0]+$deltas[1])/2);MaxResidual=[math]::Max([math]::Abs($deltas[0]),[math]::Abs($deltas[1]))}
}
function Get-FinalistEvidenceHash($Rows) {
    $fields=@('Schema','RunId','Seed','Stage','ComparisonSlot','ComparisonBlock','ComparisonKind','ComparisonArm','StrategyId','StrategyHash','CapturedNetworkKey','CapturedInputsHash','TargetKey','Group','Name','Attempt','State','Code','Exit','Up','Down','ConnMs','TlsMs','DnsMs','FirstByteMs','TotalMs','StartedMs','ObservedMs')
    $numeric=@('Schema','Seed','ComparisonSlot','ComparisonBlock','Attempt','Exit','Up','Down','ConnMs','TlsMs','DnsMs','FirstByteMs','TotalMs','StartedMs','ObservedMs')
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $Rows) {
        $stage=Get-ProbeField $row 'Stage'
        if ($stage -eq 'comparison-complete') { continue }
        if ($stage -notin @('comparison','comparison-warmup','comparison-resource')) { throw 'invalid-evidence-stage' }
        # V1 probe canonicalization must stay byte-identical. Only resource rows add fields.
        $rowFields=$fields;$rowNumeric=$numeric
        if ($stage -eq 'comparison-resource') {
            $rowFields+=@('ResourceSchema','ResourcePhase','ResourceStatus','ResourceReason','ProcessId','ProcessStartKey','ReadDurationMs','CpuTotalMs','PrivateBytes','WorkingSetBytes','OsPeakWorkingSetBytes')
            $rowNumeric+=@('ResourceSchema','ProcessId','ReadDurationMs','CpuTotalMs','PrivateBytes','WorkingSetBytes','OsPeakWorkingSetBytes')
        }
        $parts=@(foreach ($field in $rowFields) {
            $value=if ($rowNumeric -contains $field) { Get-ProbeMetric $row $field } else { Get-ProbeField $row $field }
            if ($null -eq $value) { '-' } else {
                $s=if ($rowNumeric -contains $field) { $value.ToString('R',[Globalization.CultureInfo]::InvariantCulture) } else { [string]$value }
                [string]([Text.Encoding]::UTF8.GetByteCount($s))+':'+$s
            }
        })
        $lines.Add(($parts -join '|'))
    }
    $lines.Sort([StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','') } finally { $sha.Dispose() }
}
function New-FinalistCompletion($Plan,$Rows) {
    $completion=[pscustomobject]@{Schema=1;Stage='comparison-complete';RunId=$Plan.RunId;Seed=$Plan.Seed;CapturedNetworkKey=$Plan.CapturedNetworkKey;CapturedInputsHash=$Plan.CapturedInputsHash
        ValidatedSlots=@($Plan.Slots).Count;FirstAttempts=@($Rows | Where-Object { $_.Stage -eq 'comparison' -and $_.Attempt -eq 1 }).Count;RetryAttempts=@($Rows | Where-Object { $_.Stage -eq 'comparison' -and $_.Attempt -eq 2 }).Count;EvidenceHash=(Get-FinalistEvidenceHash $Rows)}
    if ($Plan.Protocol -eq 'finalists-v2') { $completion | Add-Member NoteProperty ResourceSamples @($Rows | Where-Object { $_.Stage -eq 'comparison-resource' }).Count }
    return $completion
}
function Get-FinalistResourceAssessment($Plan,$Rows) {
    $frames=@($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison-resource' })
    if ($frames.Count -ne 3*@($Plan.Slots).Count) { throw 'incomplete-resource-matrix' }
    $index=@{}
    foreach ($frame in $frames) {
        $number=Get-ProbeMetric $frame 'ComparisonSlot'
        if ($null -eq $number -or $number -lt 1 -or $number -gt @($Plan.Slots).Count -or $number -ne [int]$number) { throw 'invalid-resource-slot' }
        $slot=$Plan.Slots[[int]$number-1]
        if ($frame.Schema -ne 1 -or $frame.ResourceSchema -ne 1 -or $frame.RunId -cne $Plan.RunId -or $frame.Seed -ne $Plan.Seed -or $frame.CapturedNetworkKey -cne $Plan.CapturedNetworkKey -or $frame.CapturedInputsHash -cne $Plan.CapturedInputsHash) { throw 'mixed-resource-context' }
        foreach ($pair in @(@('ComparisonBlock','Block'),@('ComparisonKind','Kind'),@('ComparisonArm','Arm'),@('StrategyId','StrategyId'),@('StrategyHash','StrategyHash'))) {
            if ([string](Get-ProbeField $frame $pair[0]) -cne [string](Get-ProbeField $slot $pair[1])) { throw 'mixed-resource-identity' }
        }
        if ($frame.ResourcePhase -cnotin @('Ready','Warm','End') -or $frame.ResourceStatus -cnotin @('Ready','Unavailable')) { throw 'invalid-resource-state' }
        foreach ($field in @('ObservedMs','ReadDurationMs')) { $n=Get-ProbeMetric $frame $field;if ($null -eq $n -or $n -lt 0) { throw 'invalid-resource-clock' } }
        $id=Get-ProbeMetric $frame 'ProcessId';$start=Get-ProbeField $frame 'ProcessStartKey'
        if ($null -ne $id -and ($id -lt 1 -or $id -gt [int]::MaxValue -or $id -ne [int]$id)) { throw 'invalid-resource-process' }
        if ($null -ne $start -and [string]$start -notmatch '^\d{18}$') { throw 'invalid-resource-process' }
        if ($frame.ResourceStatus -eq 'Ready') {
            if ($null -eq $id -or $null -eq $start) { throw 'missing-resource-process' }
            foreach ($field in @('CpuTotalMs','PrivateBytes','WorkingSetBytes','OsPeakWorkingSetBytes')) { $n=Get-ProbeMetric $frame $field;if ($null -eq $n -or $n -lt 0) { throw 'invalid-resource-counter' } }
        }
        $key=[string]$number+'|'+$frame.ResourcePhase
        if ($index.ContainsKey($key)) { throw 'duplicate-resource-phase' }
        $index[$key]=$frame
    }
    $windows=@();$previousSlotEnd=$null
    foreach ($slot in $Plan.Slots) {
        $samples=@(foreach ($phase in @('Ready','Warm','End')) { $key=[string]$slot.Index+'|'+$phase;if (-not $index.ContainsKey($key)) { throw 'missing-resource-phase' };$index[$key] })
        $times=@($samples | ForEach-Object { Get-ProbeMetric $_ 'ObservedMs' })
        if ($times[0] -ge $times[1] -or $times[1] -ge $times[2]) { throw 'reversed-resource-clock' }
        if ($null -ne $previousSlotEnd -and $times[0] -le $previousSlotEnd) { throw 'overlapping-resource-launches' }
        $previousSlotEnd=$times[2]
        $ids=@($samples | ForEach-Object { Get-ProbeField $_ 'ProcessId' } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        $starts=@($samples | ForEach-Object { Get-ProbeField $_ 'ProcessStartKey' } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        if ($ids.Count -gt 1 -or $starts.Count -gt 1) { throw 'resource-process-reused' }
        foreach ($probe in @($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -in @('comparison','comparison-warmup') -and $_.ComparisonSlot -eq $slot.Index })) {
            $lo=if ($probe.Stage -eq 'comparison') { $times[1] } else { $times[0] }
            $hi=if ($probe.Stage -eq 'comparison') { $times[2] } else { $times[1] }
            $begin=Get-ProbeMetric $probe 'StartedMs';$end=Get-ProbeMetric $probe 'ObservedMs'
            if ($null -eq $begin -or $null -eq $end -or $begin -lt $lo -or $end -gt $hi) { throw 'probe-outside-resource-window' }
        }
        $warm=Get-ProcessResourceWindow @($samples[0],$samples[1]);$measured=Get-ProcessResourceWindow @($samples[1],$samples[2])
        if ($warm.Status -eq 'Invalid' -or $measured.Status -eq 'Invalid') { throw 'invalid-resource-window' }
        $windows+=[pscustomobject]@{Slot=$slot.Index;Kind=$slot.Kind;Arm=$slot.Arm;StrategyId=$slot.StrategyId;Warmup=$warm;Measured=$measured}
    }
    $result=[pscustomobject]@{Schema=1;Status='Unavailable';Scope='CompareMeasured';A=$null;B=$null;Windows=$windows}
    $known=0
    foreach ($arm in @('A','B')) {
        $matches=@($windows | Where-Object { $_.Kind -eq 'Compare' -and $_.Arm -eq $arm -and $_.Measured.Status -eq 'Ready' })
        $summary=[pscustomobject]@{WindowsKnown=$matches.Count;WindowsExpected=(2*$Plan.Blocks);CpuTimeMsSum=$null;ElapsedMsSum=$null;CpuPercentOneCoreWeighted=$null;PrivateBytesEndMedian=$null;ObservedMaxPrivateBytes=$null;FirstAttempts=@($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq $arm -and $_.Attempt -eq 1 }).Count;RetryAttempts=@($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison' -and $_.ComparisonKind -eq 'Compare' -and $_.ComparisonArm -eq $arm -and $_.Attempt -eq 2 }).Count}
        if ($matches.Count) {
            $measured=@($matches.Measured);$summary.CpuTimeMsSum=($measured.CpuTimeMs | Measure-Object -Sum).Sum;$summary.ElapsedMsSum=($measured.ElapsedMs | Measure-Object -Sum).Sum
            $summary.CpuPercentOneCoreWeighted=100*($summary.CpuTimeMsSum/$summary.ElapsedMsSum)
            foreach ($derived in @($summary.CpuTimeMsSum,$summary.ElapsedMsSum,$summary.CpuPercentOneCoreWeighted)) { if ([double]::IsNaN($derived) -or [double]::IsInfinity($derived)) { throw 'resource-aggregate-overflow' } }
            $private=@($measured.PrivateBytesEnd | Sort-Object);$middle=[int][math]::Floor($private.Count/2)
            $summary.PrivateBytesEndMedian=if ($private.Count%2) { $private[$middle] } else { $private[$middle-1]+($private[$middle]-$private[$middle-1])/2 }
            $summary.ObservedMaxPrivateBytes=($measured.ObservedMaxPrivateBytes | Measure-Object -Maximum).Maximum
        }
        $result.$arm=$summary;$known+=$matches.Count
    }
    if ($known -eq 4*$Plan.Blocks) { $result.Status='Ready' } elseif ($known -gt 0) { $result.Status='Partial' }
    return $result
}
function Format-FinalistResourceSummary($Resources) {
    if ($Resources.Status -eq 'NotRequested') { return @() }
    if ($Resources.Status -notin @('Ready','Partial')) { return 'Затраты движка: нет завершённых сопоставимых окон измерений.' }
    foreach ($arm in @('A','B')) {
        $cost=$Resources.$arm
        if (-not $cost.WindowsKnown) { 'Движок '+$arm+': счётчики недоступны (окон0/'+$cost.WindowsExpected+').';continue }
        'Движок '+$arm+': CPU '+$cost.CpuTimeMsSum.ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)+' мс суммарно; private bytes, медиана конца '+($cost.PrivateBytesEndMedian/1MB).ToString('0.##',[Globalization.CultureInfo]::InvariantCulture)+' МиБ; измерено окон '+$cost.WindowsKnown+'/'+$cost.WindowsExpected+'.'
    }
}
function Get-FinalistAssessment($Plan,$Rows) {
    try {
        if ($Plan.Schema -ne 1 -or $Plan.Protocol -cnotin @('finalists-v1','finalists-v2') -or $Plan.AId -notmatch '^\d+$' -or $Plan.BId -notmatch '^\d+$' -or $Plan.AId -eq $Plan.BId -or $Plan.RunId -notmatch '^[A-Fa-f0-9]{32}$') { throw 'invalid-plan' }
        if ($Plan.Protocol -eq 'finalists-v2' -and $Plan.ResourcePolicy -cne 'process-v1') { throw 'invalid-resource-policy' }
        foreach ($hash in @($Plan.AHash,$Plan.BHash,$Plan.CapturedNetworkKey,$Plan.CapturedInputsHash)) { if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'invalid-plan' } }
        $slots=@(New-FinalistSlots $Plan.AId $Plan.BId $Plan.AHash $Plan.BHash $Plan.Seed $Plan.Blocks)
        if ($slots.Count -ne @($Plan.Slots).Count) { throw 'invalid-plan' }
        for ($i=0; $i -lt $slots.Count; $i++) {
            foreach ($field in @('Index','Block','Position','Kind','Arm','StrategyId','StrategyHash')) {
                if ([string](Get-ProbeField $Plan.Slots[$i] $field) -cne [string](Get-ProbeField $slots[$i] $field)) { throw 'invalid-plan' }
            }
        }
        $targets=@{}
        foreach ($target in $Plan.Targets) {
            if ($target.Key -notmatch '^[A-Fa-f0-9]{64}$' -or -not $target.Group -or -not $target.Name -or $targets.ContainsKey($target.Key)) { throw 'invalid-target' }
            $targets[$target.Key]=$target
        }
        $required=@($Plan.Targets.Group | Sort-Object -Unique)
        if (-not $targets.Count -or ($required -join '|') -cne (@($Plan.RequiredGroups | Sort-Object -Unique) -join '|')) { throw 'invalid-required-groups' }
        $completions=@($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison-complete' })
        if ($completions.Count -gt 1) { throw 'duplicate-completion' }
        if ($completions.Count -eq 1) {
            $completion=$completions[0]
            if ($completion.Schema -ne 1 -or $completion.RunId -cne $Plan.RunId -or $completion.Seed -ne $Plan.Seed -or $completion.CapturedNetworkKey -cne $Plan.CapturedNetworkKey -or $completion.CapturedInputsHash -cne $Plan.CapturedInputsHash -or $completion.ValidatedSlots -ne $slots.Count -or $completion.EvidenceHash -cne (Get-FinalistEvidenceHash $Rows)) { throw 'invalid-completion' }
        }
        $resourceRows=@($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison-resource' })
        if ($Plan.Protocol -eq 'finalists-v1' -and $resourceRows.Count) { throw 'unexpected-resource-records' }
        $resources=[pscustomobject]@{Schema=1;Status='NotRequested';Scope='CompareMeasured';A=$null;B=$null;Windows=@()}
        if ($Plan.Protocol -eq 'finalists-v2') {
            if ($completions.Count) {
                if ($completion.ResourceSamples -ne $resourceRows.Count) { throw 'invalid-resource-count' }
                $resources=Get-FinalistResourceAssessment $Plan $Rows
            } else { $resources.Status='NotFinalized' }
        }
        $index=@{};$firstCount=0;$retryCount=0
        foreach ($row in @($Rows | Where-Object { (Get-ProbeField $_ 'Stage') -eq 'comparison' })) {
            $number=Get-ProbeMetric $row 'ComparisonSlot';$attempt=Get-ProbeMetric $row 'Attempt'
            if ($null -eq $number -or $number -ne [int]$number -or $number -lt 1 -or $number -gt $slots.Count -or $attempt -notin @(1,2)) { throw 'invalid-slot' }
            $slot=$slots[[int]$number-1]
            if ($row.Schema -ne 1 -or $row.RunId -cne $Plan.RunId -or $row.Seed -ne $Plan.Seed -or $row.CapturedNetworkKey -cne $Plan.CapturedNetworkKey -or $row.CapturedInputsHash -cne $Plan.CapturedInputsHash) { throw 'mixed-context' }
            foreach ($pair in @(@('ComparisonBlock','Block'),@('ComparisonKind','Kind'),@('ComparisonArm','Arm'),@('StrategyId','StrategyId'),@('StrategyHash','StrategyHash'))) {
                if ([string](Get-ProbeField $row $pair[0]) -cne [string](Get-ProbeField $slot $pair[1])) { throw 'mixed-slot-identity' }
            }
            if (-not $targets.ContainsKey($row.TargetKey) -or $row.Group -cne $targets[$row.TargetKey].Group -or $row.Name -cne $targets[$row.TargetKey].Name -or $row.State -notin @('OK','FAIL','FREEZE','NA')) { throw 'invalid-target-row' }
            $key=([string]$number+'|'+$row.TargetKey+'|'+[string]$attempt)
            if ($index.ContainsKey($key)) { throw 'duplicate-attempt' }
            $index[$key]=$row
            if ($attempt -eq 1) { $firstCount++ } else { $retryCount++ }
        }
        $details=@();$reasons=@()
        if (-not $completions.Count) { $reasons+='collection-not-finalized' }
        elseif ($completion.FirstAttempts -ne $firstCount -or $completion.RetryAttempts -ne $retryCount) { throw 'invalid-completion-counts' }
        if ($firstCount -ne $slots.Count*$targets.Count) { $reasons+='incomplete-first-attempts' }
        foreach ($target in $Plan.Targets) {
            $values=@{};$times=@{};$complete=$true;$aOk=0;$bOk=0;$aCount=0;$bCount=0;$calibrationCount=0;$aRecovered=0;$bRecovered=0;$calibrationOk=0;$previousEnd=$null
            foreach ($slot in $slots) {
                $key=([string]$slot.Index+'|'+$target.Key+'|')
                $first=if ($index.ContainsKey($key+'1')) { $index[$key+'1'] } else { $null }
                $retry=if ($index.ContainsKey($key+'2')) { $index[$key+'2'] } else { $null }
                if ($retry -and -not $first) { throw 'retry-without-first' }
                if ($retry -and $first.State -eq 'OK') { throw 'unexpected-success-retry' }
                $ok=$first -and $first.State -eq 'OK'
                if ($slot.Kind -eq 'Calibration') { if ($first) { $calibrationCount++ };if ($ok) { $calibrationOk++ } }
                elseif ($slot.Arm -eq 'A') { if ($first) { $aCount++ };if ($ok) { $aOk++ };if (-not $ok -and $retry -and $retry.State -eq 'OK') { $aRecovered++ } }
                else { if ($first) { $bCount++ };if ($ok) { $bOk++ };if (-not $ok -and $retry -and $retry.State -eq 'OK') { $bRecovered++ } }
                foreach ($sample in @($first,$retry)) {
                    if (-not $sample) { continue }
                    $start=Get-ProbeMetric $sample 'StartedMs';$end=Get-ProbeMetric $sample 'ObservedMs'
                    if ($null -eq $start -or $null -eq $end) { $complete=$false;continue }
                    if ($start -lt 0 -or $end -lt $start -or ($null -ne $previousEnd -and $start -le $previousEnd)) { throw 'invalid-monotonic-order' }
                    $previousEnd=$end
                }
                $tls=Get-ProbeMetric $first 'TlsMs';$start=Get-ProbeMetric $first 'StartedMs';$end=Get-ProbeMetric $first 'ObservedMs'
                if (-not $ok -or $null -eq $tls -or $tls -le 0 -or $null -eq $start -or $null -eq $end) { $complete=$false;continue }
                $values[$slot.Index]=$tls;$times[$slot.Index]=($start+$end)/2
            }
            $blockDeltas=@();$noise=$null;$threshold=$null;$conclusion='Insufficient'
            if ($complete) {
                $noise=0.0
                for ($block=1; $block -le $Plan.Blocks+2; $block++) {
                    $members=@($slots | Where-Object { $_.Block -eq $block })
                    $delta=Get-FinalistBlockDelta @($members | ForEach-Object { $values[$_.Index] }) @($members | ForEach-Object { $times[$_.Index] }) ($members.Arm -join '')
                    if ($members[0].Kind -eq 'Calibration') { $noise=[math]::Max($noise,$delta.MaxResidual) } else { $blockDeltas+=$delta.Mean }
                }
                $aValues=@($slots | Where-Object { $_.Kind -eq 'Compare' -and $_.Arm -eq 'A' } | ForEach-Object { $values[$_.Index] } | Sort-Object)
                $median=($aValues[$aValues.Count/2-1]+$aValues[$aValues.Count/2])/2
                $threshold=[math]::Max(10,[math]::Max(0.05*$median,$noise))
                $conclusion=if (@($blockDeltas | Where-Object { $_ -gt $threshold }).Count) { 'Regressed' } elseif (@($blockDeltas | Where-Object { $_ -ge -$threshold }).Count -eq 0) { 'Improved' } else { 'Uncertain' }
            }
            $referencePreserved=$aOk -ne 2*$Plan.Blocks -or $bOk -eq 2*$Plan.Blocks
            if (-not $referencePreserved) { $reasons+='reference-endpoint-not-preserved' }
            if ($bOk -lt $aOk) { $reasons+='first-attempt-availability-decreased' }
            if ($aOk -eq 2*$Plan.Blocks -and -not $complete) { $reasons+='incomplete-reference-evidence' }
            if ($conclusion -eq 'Regressed') { $reasons+='observed-latency-regression' }
            $details+=[pscustomobject]@{Key=$target.Key;Group=$target.Group;Name=$target.Name;Conclusion=$conclusion;Comparable=$complete;ReferencePreserved=$referencePreserved
                AFirstCount=$aCount;BFirstCount=$bCount;AFirstSuccess=$aOk;BFirstSuccess=$bOk;ARecovered=$aRecovered;BRecovered=$bRecovered;CalibrationCount=$calibrationCount;CalibrationSuccess=$calibrationOk
                NoiseMs=$noise;ThresholdMs=$threshold;BlockDeltas=$blockDeltas}
        }
        $groups=@(foreach ($group in $required) { [pscustomobject]@{Group=$group;Comparable=(@($details | Where-Object { $_.Group -eq $group -and $_.Comparable }).Count -gt 0)} })
        if (@($groups | Where-Object { -not $_.Comparable }).Count) { $reasons+='required-group-not-comparable' }
        $status=if ($reasons.Count) { 'Inconclusive' } elseif (@($details | Where-Object { $_.Conclusion -eq 'Improved' }).Count) { 'ConsistentImprovement' } else { 'NoClearDifference' }
        return [pscustomobject]@{Schema=1;RunId=$Plan.RunId;Status=$status;CanRecommend=($status -eq 'ConsistentImprovement');ShadowOnly=$true;Reasons=@($reasons | Sort-Object -Unique);FirstAttempts=$firstCount;RetryAttempts=$retryCount;Groups=$groups;Targets=$details;Resources=$resources}
    } catch {
        return [pscustomobject]@{Schema=1;Status='Invalid';CanRecommend=$false;ShadowOnly=$true;Reasons=@('invalid-plan-or-evidence');FirstAttempts=$null;RetryAttempts=$null;Groups=@();Targets=@();Resources=[pscustomobject]@{Schema=1;Status='Invalid';Scope='CompareMeasured';A=$null;B=$null;Windows=@()}}
    }
}
