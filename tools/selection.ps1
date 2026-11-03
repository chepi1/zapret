# Measurement evidence helpers. No processes, network requests or settings writes on import.
function Get-PrimaryDecisionText($Choice,[hashtable]$Averages,[string]$CurrentName,[double]$Margin,[switch]$ReportOnly,[switch]$KeepPrimary) {
    if ($ReportOnly) { return ('Решение по основной: '+$CurrentName+' сохраняется — режим отчёта.') }
    if ($KeepPrimary) { return ('Решение по основной: '+$CurrentName+' сохраняется; рейтинг и круги автосмены обновляются после итоговой проверки.') }
    $top=$Choice.Top;$mean=Format-Points $Averages[$top.Id].Avg;$runs=$Averages[$top.Id].Runs
    if ($Choice.Current -and $top.Id -eq $Choice.Current.Id) {
        return ('Решение по основной: '+$CurrentName+' сохраняется — она лидирует по среднему баллу '+$mean+'; совместимых прогонов: '+$runs+'.')
    }
    if ($Choice.Noise) {
        $current=Format-Points $Averages[$Choice.Current.Id].Avg
        $gap=Format-Points ($Averages[$top.Id].Avg-$Averages[$Choice.Current.Id].Avg)
        return ('Решение по основной: '+$CurrentName+' сохраняется. По среднему впереди '+$top.Name+' ('+$mean+'), у основной '+$current+'; преимущество '+$gap+' меньше порога смены '+(Format-Points $Margin)+'.')
    }
    $line='Решение по основной: по среднему предлагается '+$top.Name+' ('+$mean+'; совместимых прогонов: '+$runs+'). Применение возможно после итоговой проверки рабочего режима.'
    if (-not $Choice.Current) { $line+=' Текущая основная в этом прогоне не проверялась.' }
    return $line
}
function Get-PrimaryResultText([string]$PrimaryName,[string]$CandidateName,[ValidateSet('Applied','Kept','Rejected','ReportOnly','QualityRejected')][string]$Status,[string]$Details='') {
    $head='Основная после теста: '+$PrimaryName+'. '
    switch ($Status) {
        'Applied' { return ($head+'Применена после итоговой проверки рабочего режима.') }
        'Kept' { return ($head+'Сохранена; итоговая комбинация подтверждена в рабочем режиме.') }
        'Rejected' { return ($head+'Итоговая комбинация с «'+$CandidateName+'» отклонена, смена не применена. Прежние настройки и рейтинг сохранены. '+$Details) }
        'ReportOnly' { return ($head+'Сохранена — режим отчёта.') }
        'QualityRejected' { return ($head+'Сохранена: результаты измерений отклонены. '+$Details) }
    }
}
function New-TestMeasurementOrder($Strategies, [ValidateRange(1,10)][int]$Rounds, [ValidateRange(0,2147483647)][int]$Seed) {
    $all=@($Strategies)
    if (-not $all.Count) { throw 'Нет стратегий для измерения.' }
    $random=New-Object System.Random($Seed)
    $items=New-Object 'System.Collections.Generic.List[object]'
    for ($round=1; $round -le $Rounds; $round+=2) {
        $shuffled=@($all | ForEach-Object { $_ })
        for ($i=$shuffled.Count-1; $i -gt 0; $i--) {
            $j=$random.Next($i+1);$temporary=$shuffled[$i];$shuffled[$i]=$shuffled[$j];$shuffled[$j]=$temporary
        }
        $items.Add([pscustomobject]@{Number=$round;Strategies=@($shuffled)})
        if ($round -lt $Rounds) {
            $reverse=@($shuffled | ForEach-Object { $_ });[array]::Reverse($reverse)
            $items.Add([pscustomobject]@{Number=($round+1);Strategies=@($reverse)})
        }
    }
    return [pscustomobject]@{Schema=1;Seed=$Seed;Rounds=@($items.ToArray())}
}
function Get-ProbeField($Row,[string]$Name) {
    if ($null -eq $Row) { return $null }
    $property=$Row.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}
function Get-ProbeMetric($Row,[string]$Name) {
    $raw=Get-ProbeField $Row $Name
    if ($null -eq $raw) { return $null }
    $value=0.0
    if (-not [double]::TryParse([string]$raw,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
    return $value
}
function Get-ProbeKey($Row) {
    $parts=@(foreach ($name in @('Group','Name','Url')) { Get-ProbeField $Row $name })
    if ($parts.Count -ne 3 -or @($parts | Where-Object { -not $_ }).Count) { return '' }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','') } finally { $sha.Dispose() }
}
function Get-ControlTargets($Targets) {
    $clean=@($Targets | Where-Object { $_.Group -eq 'Clean' })
    $ordered=@()
    foreach ($name in @('bing','github','pypi','aws','steam')) { $ordered+=@($clean | Where-Object { $_.Name -eq $name }) }
    $ordered+=@($clean | Where-Object { $ordered -notcontains $_ })
    $hosts=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $out=@()
    foreach ($target in $ordered) {
        $uri=$null
        if (-not [uri]::TryCreate($target.Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or -not $hosts.Add($uri.DnsSafeHost)) { continue }
        $out+=$target
        if ($out.Count -eq 5) { break }
    }
    return $out
}
function Get-ControlAssessment($Targets,$Before,$After) {
    $Targets=@(Get-ControlTargets $Targets)
    $maps=@()
    foreach ($rows in @(@{Rows=@($Before)},@{Rows=@($After)})) {
        $map=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($row in $rows.Rows) {
            $key=Get-ProbeKey $row
            if (-not $key) { continue }
            if (-not $map.ContainsKey($key)) { $map.Add($key,(New-Object 'System.Collections.Generic.List[object]')) }
            $map[$key].Add($row)
        }
        $maps+=,$map
    }
    $matched=0;$availability=@();$up=@();$down=@();$uncertain=@()
    foreach ($target in $Targets) {
        $key=Get-ProbeKey $target
        $b=@(if ($key -and $maps[0].ContainsKey($key)) { $maps[0][$key] })
        $a=@(if ($key -and $maps[1].ContainsKey($key)) { $maps[1][$key] })
        $complete=$true
        foreach ($window in @(@{Rows=$b},@{Rows=$a})) {
            if ($window.Rows.Count -ne 2 -or (@($window.Rows | ForEach-Object { Get-ProbeMetric $_ 'Attempt' } | Sort-Object -Unique) -join ',') -ne '1,2') { $complete=$false }
        }
        if (-not $complete) { $uncertain+=$target.Name;continue }
        $bok=@($b | Where-Object { (Get-ProbeField $_ 'State') -eq 'OK' }).Count
        $aok=@($a | Where-Object { (Get-ProbeField $_ 'State') -eq 'OK' }).Count
        $bknown=@($b | Where-Object { (Get-ProbeField $_ 'State') -in @('OK','FAIL','FREEZE') }).Count
        $aknown=@($a | Where-Object { (Get-ProbeField $_ 'State') -in @('OK','FAIL','FREEZE') }).Count
        if ($bknown -eq 2 -and $aknown -eq 2 -and (($bok -eq 2 -and $aok -eq 0) -or ($bok -eq 0 -and $aok -eq 2))) { $availability+=$target.Name;continue }
        $bt=@($b | ForEach-Object { Get-ProbeMetric $_ 'TlsMs' } | Where-Object { $null -ne $_ -and $_ -gt 0 })
        $at=@($a | ForEach-Object { Get-ProbeMetric $_ 'TlsMs' } | Where-Object { $null -ne $_ -and $_ -gt 0 })
        if ($bok -ne 2 -or $aok -ne 2 -or $bt.Count -ne 2 -or $at.Count -ne 2) { $uncertain+=$target.Name;continue }
        $matched++
        $threshold=[math]::Max(250,0.5*[math]::Min(($bt[0]+$bt[1])/2,($at[0]+$at[1])/2))
        if ([math]::Min($at[0],$at[1])-[math]::Max($bt[0],$bt[1]) -gt $threshold) { $up+=$target.Name }
        if ([math]::Min($bt[0],$bt[1])-[math]::Max($at[0],$at[1]) -gt $threshold) { $down+=$target.Name }
    }
    $reasons=@()
    if ($availability.Count) { $reasons+='availability-changed' }
    if ($up.Count -ge 3 -or $down.Count -ge 3) { $reasons+='latency-shift' }
    if ($matched -lt 3) { $reasons+='insufficient-control' }
    $status=if ($availability.Count -or $up.Count -ge 3 -or $down.Count -ge 3) { 'Changed' } elseif ($matched -lt 3) { 'Unknown' } else { 'Stable' }
    return [pscustomobject]@{Schema=1;Status=$status;CanApply=($status -eq 'Stable');MatchedTargets=$matched;AvailabilityChanged=@($availability);ShiftedUp=@($up);ShiftedDown=@($down);UncertainTargets=@($uncertain);Reasons=@($reasons)}
}
function Write-ProbeJournal([string]$Path,[hashtable]$Metadata,$Rows,[ValidateRange(1,2)][int]$Attempt,[long]$MaxBytes=67108864) {
    if (-not @($Rows).Count) { return }
    $Metadata.Sequence=1+[int]$Metadata['Sequence']
    $lines=New-Object Text.StringBuilder
    $captured=[datetime]::UtcNow.ToString('o')
    foreach ($row in $Rows) {
        $entry=[ordered]@{Schema=1;RunId=$Metadata['RunId'];Seed=$Metadata['Seed'];Sequence=$Metadata.Sequence;Round=$Metadata['Round'];Stage=$Metadata['Stage'];StrategyId=$Metadata['StrategyId'];StrategyHash=$Metadata['StrategyHash'];CapturedNetworkKey=$Metadata['NetworkKey'];CapturedInputsHash=$Metadata['InputsHash'];Attempt=$Attempt;CapturedUtc=$captured
            Group=(Get-ProbeField $row 'Group');Name=(Get-ProbeField $row 'Name');TargetKey=(Get-ProbeKey $row);State=(Get-ProbeField $row 'State');Code=(Get-ProbeField $row 'Code');Exit=(Get-ProbeMetric $row 'Exit');Up=(Get-ProbeMetric $row 'Up');Down=(Get-ProbeMetric $row 'Down')
            ConnMs=(Get-ProbeMetric $row 'ConnMs');TlsMs=(Get-ProbeMetric $row 'TlsMs');DnsMs=(Get-ProbeMetric $row 'DnsMs');FirstByteMs=(Get-ProbeMetric $row 'FirstByteMs');TotalMs=(Get-ProbeMetric $row 'TotalMs');StartedUtc=(Get-ProbeField $row 'StartedUtc');ObservedUtc=(Get-ProbeField $row 'ObservedUtc');ControlUncontaminated=$Metadata['ControlUncontaminated']
            StartedMs=(Get-ProbeMetric $row 'StartedMs');ObservedMs=(Get-ProbeMetric $row 'ObservedMs');ComparisonSlot=$Metadata['ComparisonSlot'];ComparisonBlock=$Metadata['ComparisonBlock'];ComparisonKind=$Metadata['ComparisonKind'];ComparisonArm=$Metadata['ComparisonArm']}
        [void]$lines.AppendLine(($entry | ConvertTo-Json -Compress))
    }
    $text=$lines.ToString()
    $size=if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } else { 0 }
    if ($MaxBytes -le 0 -or $size+[Text.Encoding]::UTF8.GetByteCount($text) -gt $MaxBytes) { throw 'Лимит журнала измерений превышен; результаты не применены.' }
    [IO.File]::AppendAllText($Path,$text,(New-Object Text.UTF8Encoding($false)))
}
