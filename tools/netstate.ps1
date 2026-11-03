# Локальный отпечаток подключения. В результате только хеш: имена сетей и адреса не экспортируются.
function Get-NetworkObservation {
    try {
        $profiles=@(Get-NetConnectionProfile -ErrorAction Stop)
        if(-not $profiles.Count){throw 'No network profile'}
        $indexes=@($profiles | ForEach-Object { $_.InterfaceIndex })
        $parts=@('network-v2')
        $parts+=@($profiles | ForEach-Object { 'profile|'+$_.InterfaceIndex+'|'+$_.Name+'|'+$_.IPv4Connectivity+'|'+$_.IPv6Connectivity } | Sort-Object)
        # Маршруты через шлюз и default/split-default. Локальные адреса DHCP в ключ не входят.
        $parts+=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
            ($indexes -contains $_.InterfaceIndex -and $_.NextHop -notin @('0.0.0.0','::')) -or $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0','::/1','8000::/1')
        } | ForEach-Object { 'route|'+$_.InterfaceIndex+'|'+$_.DestinationPrefix+'|'+$_.NextHop+'|'+$_.RouteMetric } | Sort-Object)
        $parts+=@(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $indexes -contains $_.InterfaceIndex } | ForEach-Object { 'dns|'+$_.InterfaceIndex+'|'+$_.AddressFamily+'|'+(@($_.ServerAddresses) -join ',') } | Sort-Object)
        $proxy=Get-WindowsProxySettings
        if(-not $proxy.Known){throw 'Unknown proxy settings'}
        $parts+=('proxy|'+$proxy.Proxy+'|'+$proxy.Pac+'|'+$proxy.AutoDetect)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','')}finally{$sha.Dispose()}
        return [pscustomobject]@{Known=$true;Key=$key;ObservedUtc=[datetime]::UtcNow.ToString('o')}
    } catch { return [pscustomobject]@{Known=$false;Key='';ObservedUtc=[datetime]::UtcNow.ToString('o')} }
}

function Set-RingNetworkContext($Observation) {
    # Персистентная память включится после появления координатора, проверяющего сеть в течение жизни процесса.
    $Script:RingPersistAllowed=$false
    if($Observation.Known -and $Observation.Key){$Script:RingNetworkKey=$Observation.Key}
    else{$Script:RingNetworkKey='unknown-'+[guid]::NewGuid().ToString('N')}
}

function Test-NetworkObservation($Before,$After) {
    return ($Before.Known -and $After.Known -and $Before.Key -ceq $After.Key)
}
