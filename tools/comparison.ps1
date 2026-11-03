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
function New-FinalistPlan([string]$AId,[string]$BId,[string]$AHash,[string]$BHash,$Targets,[string]$NetworkKey,[string]$InputsHash,[int]$Seed,[int]$Blocks,[string]$RunId) {
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
    return [pscustomobject]@{Schema=1;Protocol='finalists-v1';RunId=$RunId;Seed=$Seed;Blocks=$Blocks;AId=$AId;BId=$BId;AHash=$AHash;BHash=$BHash
        CapturedNetworkKey=$NetworkKey;CapturedInputsHash=$InputsHash;Targets=$targetKeys;RequiredGroups=@($targetKeys.Group | Sort-Object -Unique)
        Slots=@(New-FinalistSlots $AId $BId $AHash $BHash $Seed $Blocks)}
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
        if ($stage -notin @('comparison','comparison-warmup')) { throw 'invalid-evidence-stage' }
        $parts=@(foreach ($field in $fields) {
            $value=if ($numeric -contains $field) { Get-ProbeMetric $row $field } else { Get-ProbeField $row $field }
            if ($null -eq $value) { '-' } else {
                $s=if ($numeric -contains $field) { $value.ToString('R',[Globalization.CultureInfo]::InvariantCulture) } else { [string]$value }
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
    return [pscustomobject]@{Schema=1;Stage='comparison-complete';RunId=$Plan.RunId;Seed=$Plan.Seed;CapturedNetworkKey=$Plan.CapturedNetworkKey;CapturedInputsHash=$Plan.CapturedInputsHash
        ValidatedSlots=@($Plan.Slots).Count;FirstAttempts=@($Rows | Where-Object { $_.Stage -eq 'comparison' -and $_.Attempt -eq 1 }).Count;RetryAttempts=@($Rows | Where-Object { $_.Stage -eq 'comparison' -and $_.Attempt -eq 2 }).Count;EvidenceHash=(Get-FinalistEvidenceHash $Rows)}
}
function Get-FinalistAssessment($Plan,$Rows) {
    try {
        if ($Plan.Schema -ne 1 -or $Plan.Protocol -cne 'finalists-v1' -or $Plan.AId -notmatch '^\d+$' -or $Plan.BId -notmatch '^\d+$' -or $Plan.AId -eq $Plan.BId -or $Plan.RunId -notmatch '^[A-Fa-f0-9]{32}$') { throw 'invalid-plan' }
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
        return [pscustomobject]@{Schema=1;RunId=$Plan.RunId;Status=$status;CanRecommend=($status -eq 'ConsistentImprovement');ShadowOnly=$true;Reasons=@($reasons | Sort-Object -Unique);FirstAttempts=$firstCount;RetryAttempts=$retryCount;Groups=$groups;Targets=$details}
    } catch {
        return [pscustomobject]@{Schema=1;Status='Invalid';CanRecommend=$false;ShadowOnly=$true;Reasons=@('invalid-plan-or-evidence');FirstAttempts=$null;RetryAttempts=$null;Groups=@();Targets=@()}
    }
}
