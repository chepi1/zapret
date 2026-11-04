# Bounded diagnostic evidence. Import performs no network requests or settings writes.
function Get-LatencyTime {return [Diagnostics.Stopwatch]::GetTimestamp()/[double][Diagnostics.Stopwatch]::Frequency}
function New-LatencyStore([ValidateRange(1,512)][int]$Capacity=128,[ValidateRange(1,1000)][int]$MaxSamples=120,[ValidateRange(1,3600)][double]$WindowSeconds=600){
    return [pscustomobject]@{Streams=@{};Capacity=$Capacity;MaxSamples=$MaxSamples;WindowSeconds=$WindowSeconds;Clock=$null;Sequence=0L}
}
function Get-LatencyKey([string]$Ip,[string]$Kind,[int]$Port=0){
    $address=$null
    if(-not[Net.IPAddress]::TryParse($Ip,[ref]$address)){return ''}
    if($Kind -eq 'icmp'){return ('icmp|'+$address.ToString())}
    if($Kind -eq 'tcp' -and $Port -ge 1 -and $Port -le 65535){return ('tcp|'+$address.ToString()+'|'+$Port)}
    return ''
}
function Get-LatencyEntry($Store,[string]$Key,[double]$Now,[switch]$Create){
    if(-not $Key -or [double]::IsNaN($Now) -or [double]::IsInfinity($Now) -or $Now -lt 0 -or ($null -ne $Store.Clock -and $Now -lt $Store.Clock)){return $null}
    $Store.Clock=$Now
    $cutoff=$Now-$Store.WindowSeconds
    if($Create){foreach($oldKey in @($Store.Streams.Keys)){if($Store.Streams[$oldKey].LastActive -lt $cutoff){$Store.Streams.Remove($oldKey)}}}
    if($Store.Streams.ContainsKey($Key) -and $Store.Streams[$Key].LastActive -lt $cutoff){$Store.Streams.Remove($Key)}
    if(-not $Store.Streams.ContainsKey($Key)){
        if(-not $Create){return $null}
        if($Store.Streams.Count -ge $Store.Capacity){
            $oldest=$Store.Streams.Keys | Sort-Object {$Store.Streams[$_].Touch} | Select-Object -First 1
            $Store.Streams.Remove($oldest)
        }
        $Store.Streams[$Key]=[pscustomobject]@{Samples=(New-Object 'System.Collections.Generic.List[object]');LastScheduled=$null;LastActive=$Now;Touch=0L}
    }
    $entry=$Store.Streams[$Key]
    while($entry.Samples.Count -gt 0 -and $entry.Samples[0].At -lt $cutoff){$entry.Samples.RemoveAt(0)}
    $Store.Sequence++;$entry.Touch=$Store.Sequence
    return $entry
}
function Add-LatencyResult($Store,[string]$Ip,[string]$Kind,[int]$Port,[string]$Outcome,[Nullable[double]]$Ms,[double]$Now=(Get-LatencyTime),[Nullable[double]]$CompletedAt=$null){
    if($Outcome -notin @('Success','Timeout','Error')){return $false}
    if($Outcome -eq 'Success'){
        if($null -eq $Ms -or [double]::IsNaN($Ms) -or [double]::IsInfinity($Ms) -or $Ms -lt 0){return $false}
    }elseif($null -ne $Ms){return $false}
    $at=if($null -eq $CompletedAt){$Now}else{[double]$CompletedAt}
    if([double]::IsNaN($at) -or [double]::IsInfinity($at) -or $at -lt 0 -or $at -gt $Now -or $at -lt $Now-$Store.WindowSeconds){return $false}
    $entry=Get-LatencyEntry $Store (Get-LatencyKey $Ip $Kind $Port) $Now -Create
    if($null -eq $entry){return $false}
    $index=$entry.Samples.Count
    while($index -gt 0 -and $entry.Samples[$index-1].At -gt $at){$index--}
    $entry.Samples.Insert($index,[pscustomobject]@{At=$at;Outcome=$Outcome;Ms=$Ms})
    if($entry.Samples.Count -gt $Store.MaxSamples){$entry.Samples.RemoveAt(0)}
    $entry.LastActive=[math]::Max($entry.Samples[$entry.Samples.Count-1].At,$(if($null -ne $entry.LastScheduled){$entry.LastScheduled}else{0}))
    return $true
}
function Get-LatencySummary($Store,[string]$Ip,[string]$Kind,[int]$Port=0,[double]$Now=(Get-LatencyTime)){
    $entry=Get-LatencyEntry $Store (Get-LatencyKey $Ip $Kind $Port) $Now
    $samples=@(if($null -ne $entry){$entry.Samples.ToArray()})
    $success=@($samples|Where-Object{$_.Outcome -eq 'Success'})
    $sorted=@($success|ForEach-Object{$_.Ms}|Sort-Object)
    $min=$null;$max=$null;$median=$null;$p95=$null;$last=$null;$age=$null;$spikes=0
    if($sorted.Count){
        $min=$sorted[0];$max=$sorted[-1];$last=$success[-1].Ms;$age=$Now-$success[-1].At
        $middle=[int][math]::Floor($sorted.Count/2)
        $median=if($sorted.Count%2){$sorted[$middle]}else{$sorted[$middle-1]/2+$sorted[$middle]/2}
        if($sorted.Count -ge 20){$p95=$sorted[[int][math]::Ceiling($sorted.Count*0.95)-1]}
        $spikes=@($sorted|Where-Object{$_ -ge $median+50}).Count
    }
    $consecutive=0
    for($i=$samples.Count-1;$i -ge 0;$i--){if($samples[$i].Outcome -eq 'Success'){break};$consecutive++}
    return [pscustomobject]@{Count=$samples.Count;SuccessCount=$success.Count;Timeouts=@($samples|Where-Object{$_.Outcome -eq 'Timeout'}).Count;Errors=@($samples|Where-Object{$_.Outcome -eq 'Error'}).Count;MinMs=$min;MaxMs=$max;MedianMs=$median;P95Ms=$p95;LastMs=$last;LastSuccessAge=$age;Spikes=$spikes;ConsecutiveFailures=$consecutive;Fresh=($null -ne $age -and $age -le 60);LastScheduled=$(if($null -ne $entry){$entry.LastScheduled}else{$null})}
}
function Get-LatencyProbeSchedule($Store,[string]$Ip,[string]$Kind,[int]$Port=0,[double]$Now=(Get-LatencyTime)){
    $key=Get-LatencyKey $Ip $Kind $Port
    if(-not $key -or [double]::IsNaN($Now) -or [double]::IsInfinity($Now) -or $Now -lt 0 -or ($null -ne $Store.Clock -and $Now -lt $Store.Clock)){return [pscustomobject]@{Due=$false;LastScheduled=$null}}
    $entry=Get-LatencyEntry $Store $key $Now
    if($null -eq $entry){return [pscustomobject]@{Due=$true;LastScheduled=$null}}
    $failures=0
    for($i=$entry.Samples.Count-1;$i -ge 0 -and $failures -lt 3;$i--){if($entry.Samples[$i].Outcome -eq 'Success'){break};$failures++}
    $gap=if($Kind -eq 'tcp'){20}elseif($failures -ge 3){60}else{5}
    return [pscustomobject]@{Due=($null -eq $entry.LastScheduled -or $Now-$entry.LastScheduled -ge $gap);LastScheduled=$entry.LastScheduled}
}
function Test-LatencyProbeDue($Store,[string]$Ip,[string]$Kind,[int]$Port=0,[double]$Now=(Get-LatencyTime)){
    return (Get-LatencyProbeSchedule $Store $Ip $Kind $Port $Now).Due
}
function Set-LatencyProbeScheduled($Store,[string]$Ip,[string]$Kind,[int]$Port=0,[double]$Now=(Get-LatencyTime)){
    $entry=Get-LatencyEntry $Store (Get-LatencyKey $Ip $Kind $Port) $Now -Create
    if($null -eq $entry){return $false}
    $entry.LastScheduled=$Now;$entry.LastActive=$Now
    return $true
}
function Get-LatencyDisplay($Store,[string]$Ip,[string]$Proto='udp',[int]$Port=0,[double]$Now=(Get-LatencyTime)){
    $icmp=Get-LatencySummary $Store $Ip icmp 0 $Now
    $chosen=$icmp;$kind='icmp';$label='ICMP';$suffix='i'
    if(-not $icmp.Fresh -and $Proto -eq 'tcp' -and $Port -gt 0){
        $tcp=Get-LatencySummary $Store $Ip tcp $Port $Now
        if($tcp.Count -gt 0){$chosen=$tcp;$kind='tcp';$label='TCP'+$Port;$suffix='t'}
    }
    $text='—'
    if($chosen.Fresh){
        $med=([math]::Round($chosen.MedianMs)).ToString('0',[Globalization.CultureInfo]::InvariantCulture)
        $tail=if($null -eq $chosen.P95Ms){'—'}else{([math]::Round($chosen.P95Ms)).ToString('0',[Globalization.CultureInfo]::InvariantCulture)}
        $text=$med+'/'+$tail+$suffix
        $detail=$label+': мед '+$med+' мс, P95 '+$tail+' мс (n='+$chosen.SuccessCount+'), мин/макс '+[math]::Round($chosen.MinMs)+'/'+[math]::Round($chosen.MaxMs)+' мс; скачки +50 мс '+$chosen.Spikes
    }else{$detail=$label+': нет свежих ответов'}
    $detail+='; ответы '+$chosen.SuccessCount+'/'+$chosen.Count+', тайм-ауты '+$chosen.Timeouts+', ошибки '+$chosen.Errors
    if($kind -eq 'tcp'){$detail+='; ICMP ответы '+$icmp.SuccessCount+'/'+$icmp.Count}
    return [pscustomobject]@{Text=$text;Detail=$detail;Replies=($chosen.SuccessCount.ToString()+'/'+$chosen.Count);Kind=$kind}
}
