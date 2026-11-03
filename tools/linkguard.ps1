# Local Wi-Fi disruption evidence. No probing, adapter changes or event-log setup.
function ConvertTo-LinkEpoch([datetime]$Time){
    return [long][math]::Floor(($Time.ToUniversalTime()-[datetime]::SpecifyKind([datetime]'1970-01-01',[DateTimeKind]::Utc)).TotalSeconds)
}
function Get-SystemWifiInterfaces {
    return [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
}
function Get-WifiLinkObservation([string[]]$TrackedIds=@()) {
    try{
        $links=@(foreach($adapter in Get-SystemWifiInterfaces){
            if($adapter.NetworkInterfaceType -ne [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211){continue}
            $id=([guid]$adapter.Id).ToString('N')
            if($id -eq ('0'*32)){continue}
            $up=$adapter.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up
            if(-not $up -and $TrackedIds -notcontains $id){continue}
            $gateway=$false
            if($up){$gateway=@($adapter.GetIPProperties().GatewayAddresses | Where-Object{$_.Address -ne [Net.IPAddress]::Any -and $_.Address -ne [Net.IPAddress]::IPv6Any}).Count -gt 0}
            if(-not $gateway -and $TrackedIds -notcontains $id){continue}
            [pscustomobject]@{Id=$id;Up=$up;HasGateway=$gateway}
        })
        if($links.Count -gt 32){throw 'Too many routed wireless interfaces'}
        return [pscustomobject]@{Known=$true;ObservedUtc=[datetime]::UtcNow.ToString('o');Interfaces=$links}
    }catch{return [pscustomobject]@{Known=$false;ObservedUtc=[datetime]::UtcNow.ToString('o');Interfaces=@()}}
}
function Get-WifiWatchScope($State,$Observation){
    $ids=[ordered]@{}
    if($null -ne $Observation -and $Observation.Known){
        foreach($link in $Observation.Interfaces | Sort-Object Id){
            if($link.Id -match '^[a-fA-F0-9]{32}$' -and $link.Up -eq $true -and $link.HasGateway -eq $true){$ids[$link.Id.ToLowerInvariant()]=$true}
        }
    }
    if($null -ne $State){foreach($id in $State.Links.Keys | Sort-Object){if($id -match '^[a-fA-F0-9]{32}$'){$ids[$id.ToLowerInvariant()]=$true}}}
    return @($ids.Keys | Select-Object -First 16)
}
function Get-WifiDisconnectEpoch([string[]]$InterfaceIds,[datetime]$Now=[datetime]::UtcNow){
    if(-not $InterfaceIds.Count){return $null}
    try{
        $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational';Id=8003;StartTime=$Now.AddSeconds(-30);EndTime=$Now} -MaxEvents 64 -ErrorAction Stop)
        $last=$null
        foreach($entry in $events){
            try{
                if($entry.Id -ne 8003){continue}
                $age=($Now.ToUniversalTime()-$entry.TimeCreated.ToUniversalTime()).TotalSeconds
                if($age -lt 0 -or $age -gt 30){continue}
                $xml=[xml]$entry.ToXml()
                $node=@($xml.Event.EventData.Data | Where-Object{$_.Name -ieq 'InterfaceGuid'})
                if($node.Count -ne 1){continue}
                $id=([guid]$node[0].InnerText).ToString('N')
                if($InterfaceIds -notcontains $id){continue}
                $epoch=ConvertTo-LinkEpoch $entry.TimeCreated
                if($null -eq $last -or $epoch -gt $last){$last=$epoch}
            }catch{continue}
        }
        return $last
    }catch{return $null}
}
function Get-WifiInterruptionState($State,$Observation,[Nullable[long]]$EventEpoch,[datetime]$Now=[datetime]::UtcNow){
    $epoch=ConvertTo-LinkEpoch $Now
    $links=@{};$last=0L;$until=0L
    if($null -ne $State){
        foreach($id in $State.Links.Keys | Sort-Object | Select-Object -First 16){$links[$id]=[bool]$State.Links[$id]}
        if($epoch -ge $State.ObservedEpoch){$last=[long]$State.LastEventEpoch;$until=[long]$State.PauseUntil}
    }
    $known=$false
    try{
        $age=($Now.ToUniversalTime()-[datetime]::Parse($Observation.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()).TotalSeconds
        $known=$Observation.Known -eq $true -and $age -ge 0 -and $age -le 10
    }catch{}
    if($known){
        $scope=@(Get-WifiWatchScope $State $Observation)
        foreach($id in @($links.Keys)){if($scope -notcontains $id){$links.Remove($id)}}
        $current=@{}
        foreach($link in $Observation.Interfaces){if($link.Id -match '^[a-fA-F0-9]{32}$'){$current[$link.Id.ToLowerInvariant()]=$link}}
        $changed=$false
        foreach($id in @($links.Keys)){
            $up=$current.ContainsKey($id) -and $current[$id].Up -eq $true
            if($links[$id] -ne $up){$changed=$true}
            $links[$id]=$up
        }
        foreach($id in $current.Keys | Sort-Object){
            if(-not $links.ContainsKey($id) -and $links.Count -lt 16 -and $current[$id].Up -eq $true -and $current[$id].HasGateway -eq $true){$links[$id]=$true}
        }
        if($changed){$last=$epoch;$until=$epoch+20}
    }
    if($null -ne $EventEpoch -and $EventEpoch -le $epoch -and $EventEpoch -ge $epoch-30 -and $EventEpoch -gt $last){$last=[long]$EventEpoch;$until=[math]::Max($until,$last+20)}
    return [pscustomobject]@{Links=$links;ObservedEpoch=$epoch;LastEventEpoch=$last;PauseUntil=$until}
}
function Get-LinkGuardRecord($State,[datetime]$Now=[datetime]::UtcNow){
    try{
        $epoch=ConvertTo-LinkEpoch $Now
        $last=[long]$State.LastEventEpoch;$until=[long]$State.PauseUntil
        if($epoch -lt 0 -or $last -lt 0 -or $last -gt $epoch -or $until -lt 0 -or (($last -eq 0) -ne ($until -eq 0)) -or ($until -ne 0 -and $until -lt $last) -or $until -gt $epoch+20){return "1 0 0 0`n"}
        return ('1 '+$epoch.ToString([Globalization.CultureInfo]::InvariantCulture)+' '+$last.ToString([Globalization.CultureInfo]::InvariantCulture)+' '+$until.ToString([Globalization.CultureInfo]::InvariantCulture)+"`n")
    }catch{return "1 0 0 0`n"}
}
function Write-LinkGuardRecord([string]$Path,[string]$Record){
    if($Record.Length -gt 64 -or $Record -notmatch '^1 [0-9]+ [0-9]+ [0-9]+\n$'){return $false}
    return Write-WatchRecordFile $Path $Record
}
