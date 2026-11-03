# Process-only counters. Import has no I/O or process-control side effects.
function Get-ProcessResourceSample($Process) {
    $begin=[Diagnostics.Stopwatch]::GetTimestamp()
    $sample=[pscustomobject]@{Schema=1;ResourceStatus='Unavailable';ResourceReason='counter-unavailable';ProcessId=$null;ProcessStartKey=$null;ObservedMs=$null;ReadDurationMs=$null;CpuTotalMs=$null;PrivateBytes=$null;WorkingSetBytes=$null;OsPeakWorkingSetBytes=$null}
    try {
        if ($null -eq $Process) { $sample.ResourceReason='no-process';return $sample }
        $sample.ProcessId=$Process.Id
        $Process.Refresh()
        if ($Process.HasExited) { $sample.ResourceStatus='Exited';$sample.ResourceReason='process-exited';return $sample }
        [void]$Process.Handle # Hold the associated process handle; never look the PID up again.
        $key=$Process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        $cpu=$Process.TotalProcessorTime.TotalMilliseconds
        $private=$Process.PrivateMemorySize64;$working=$Process.WorkingSet64;$peak=$Process.PeakWorkingSet64
        if ($Process.HasExited) { $sample.ResourceStatus='Exited';$sample.ResourceReason='process-exited';return $sample }
        if ($Process.Id -ne $sample.ProcessId -or $Process.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture) -cne $key) { $sample.ResourceReason='identity-changed';return $sample }
        $sample.ProcessStartKey=$key;$sample.CpuTotalMs=$cpu;$sample.PrivateBytes=$private;$sample.WorkingSetBytes=$working;$sample.OsPeakWorkingSetBytes=$peak
        $sample.ResourceStatus='Ready';$sample.ResourceReason=''
        return $sample
    } catch { return $sample }
    finally {
        $end=[Diagnostics.Stopwatch]::GetTimestamp()
        $sample.ObservedMs=500.0*($begin+$end)/[Diagnostics.Stopwatch]::Frequency
        $sample.ReadDurationMs=1000.0*($end-$begin)/[Diagnostics.Stopwatch]::Frequency
    }
}
function Get-ProcessResourceWindow($Samples) {
    $all=@($Samples)
    $result=[pscustomobject]@{Schema=1;Status='Unavailable';Reasons=@('insufficient-samples');SampleCount=$all.Count;ProcessId=$null;ProcessStartKey=$null;CpuTimeMs=$null;ElapsedMs=$null;CpuPercentOneCore=$null;PrivateBytesStart=$null;PrivateBytesEnd=$null;ObservedMaxPrivateBytes=$null;WorkingSetBytesEnd=$null;ObservedMaxWorkingSetBytes=$null;OsPeakWorkingSetBytesEnd=$null;ReadDurationMsSum=$null}
    if ($all.Count -lt 2) { return $result }
    $values=@();$identity=$null;$previous=$null
    foreach ($sample in $all) {
        if ((Get-ProbeField $sample 'Schema') -ne 1) { $result.Status='Invalid';$result.Reasons=@('invalid-schema');return $result }
        if ((Get-ProbeField $sample 'ResourceStatus') -ne 'Ready') { $result.Reasons=@('counter-unavailable');return $result }
        $key=[string](Get-ProbeField $sample 'ProcessStartKey');$id=Get-ProbeMetric $sample 'ProcessId'
        if ($null -eq $id -or $id -lt 1 -or $id -gt [int]::MaxValue -or $id -ne [int]$id -or $key -notmatch '^\d{18}$') { $result.Status='Invalid';$result.Reasons=@('invalid-identity');return $result }
        $current=[ordered]@{ProcessId=$id;ProcessStartKey=$key}
        foreach ($name in @('ObservedMs','ReadDurationMs','CpuTotalMs','PrivateBytes','WorkingSetBytes','OsPeakWorkingSetBytes')) {
            $value=Get-ProbeMetric $sample $name
            if ($null -eq $value) { $result.Reasons=@('missing-or-nonfinite-counter');return $result }
            if ($value -lt 0) { $result.Status='Invalid';$result.Reasons=@('negative-counter');return $result }
            $current[$name]=$value
        }
        $current=[pscustomobject]$current
        $tuple=[string]$id+'|'+$key
        if ($null -ne $identity -and $tuple -cne $identity) { $result.Status='Invalid';$result.Reasons=@('process-identity-changed');return $result }
        if ($previous -and ($current.ObservedMs -le $previous.ObservedMs -or $current.CpuTotalMs -lt $previous.CpuTotalMs)) { $result.Status='Invalid';$result.Reasons=@('nonmonotonic-counters');return $result }
        $identity=$tuple;$previous=$current;$values+=,$current
    }
    $first=$values[0];$last=$values[-1]
    $cpuDelta=$last.CpuTotalMs-$first.CpuTotalMs;$elapsed=$last.ObservedMs-$first.ObservedMs
    $percentage=100*($cpuDelta/$elapsed);$readSum=($values.ReadDurationMs | Measure-Object -Sum).Sum
    foreach ($derived in @($cpuDelta,$elapsed,$percentage,$readSum)) {
        if ([double]::IsNaN($derived) -or [double]::IsInfinity($derived)) { $result.Status='Invalid';$result.Reasons=@('derived-counter-overflow');return $result }
    }
    $result.Status='Ready';$result.Reasons=@();$result.ProcessId=$first.ProcessId;$result.ProcessStartKey=$first.ProcessStartKey
    $result.CpuTimeMs=$cpuDelta;$result.ElapsedMs=$elapsed;$result.CpuPercentOneCore=$percentage
    $result.PrivateBytesStart=$first.PrivateBytes;$result.PrivateBytesEnd=$last.PrivateBytes;$result.WorkingSetBytesEnd=$last.WorkingSetBytes
    $result.ObservedMaxPrivateBytes=($values.PrivateBytes | Measure-Object -Maximum).Maximum
    $result.ObservedMaxWorkingSetBytes=($values.WorkingSetBytes | Measure-Object -Maximum).Maximum
    $result.OsPeakWorkingSetBytesEnd=$last.OsPeakWorkingSetBytes;$result.ReadDurationMsSum=$readSum
    return $result
}
function Write-ProcessResourceJournal([string]$Path,[hashtable]$Metadata,[ValidateSet('Ready','Warm','End')][string]$Phase,$Sample,[long]$MaxBytes=67108864) {
    $Metadata.Sequence=1+[int]$Metadata['Sequence']
    $record=[ordered]@{Schema=1;ResourceSchema=(Get-ProbeField $Sample 'Schema');Stage='comparison-resource';RunId=$Metadata['RunId'];Seed=$Metadata['Seed'];Sequence=$Metadata.Sequence;CapturedNetworkKey=$Metadata['NetworkKey'];CapturedInputsHash=$Metadata['InputsHash'];ComparisonSlot=$Metadata['ComparisonSlot'];ComparisonBlock=$Metadata['ComparisonBlock'];ComparisonKind=$Metadata['ComparisonKind'];ComparisonArm=$Metadata['ComparisonArm'];StrategyId=$Metadata['StrategyId'];StrategyHash=$Metadata['StrategyHash'];ResourcePhase=$Phase}
    foreach ($name in @('ResourceStatus','ResourceReason','ProcessStartKey')) { $record[$name]=Get-ProbeField $Sample $name }
    foreach ($name in @('ProcessId','ObservedMs','ReadDurationMs','CpuTotalMs','PrivateBytes','WorkingSetBytes','OsPeakWorkingSetBytes')) { $record[$name]=Get-ProbeMetric $Sample $name }
    $line=($record | ConvertTo-Json -Compress)+"`n"
    $size=if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } else { 0 }
    if ($MaxBytes -le 0 -or $size+[Text.Encoding]::UTF8.GetByteCount($line) -gt $MaxBytes) { throw 'Лимит журнала измерений превышен; метрики не подтверждены.' }
    [IO.File]::AppendAllText($Path,$line,(New-Object Text.UTF8Encoding($false)))
}
