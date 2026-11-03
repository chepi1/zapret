# Локальный отпечаток подключения. В результате только хеш: имена сетей и адреса не экспортируются.
function Get-LocalAssignedAddresses {
    return @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object {
        $_.GetIPProperties().UnicastAddresses | ForEach-Object { $_.Address.ToString() }
    })
}
function Get-NetworkObservation {
    param([switch]$Machine)
    try {
        $profiles=@(Get-NetConnectionProfile -ErrorAction Stop)
        if(-not $profiles.Count){throw 'No network profile'}
        $parts=@('network-v3',('machine='+[bool]$Machine))
        $parts+=@($profiles | ForEach-Object {
            $id=if($_.PSObject.Properties.Name -contains 'InstanceID'){[string]$_.InstanceID}else{''}
            'profile|'+$_.InterfaceIndex+'|'+$_.Name+'|'+$id
        } | Sort-Object)
        # Включая on-link split-TUN. Собственные host routes DHCP и служебные local/multicast исключены.
        $assigned=@(Get-LocalAssignedAddresses)
        $parts+=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
            $prefix=$_.DestinationPrefix
            $hostAddress=($prefix -split '/')[0]
            $prefix -notmatch '^(127\.|169\.254\.|224\.|255\.|fe[89ab]|ff|::1/)' -and -not($prefix -match '/(32|128)$' -and $assigned -contains $hostAddress)
        } | ForEach-Object { 'route|'+$_.InterfaceIndex+'|'+$_.DestinationPrefix+'|'+$_.NextHop+'|'+$_.RouteMetric } | Sort-Object)
        $parts+=@(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { @($_.ServerAddresses).Count -gt 0 } | ForEach-Object { 'dns|'+$_.InterfaceIndex+'|'+$_.AddressFamily+'|'+(@($_.ServerAddresses) -join ',') } | Sort-Object)
        if(-not $Machine){
            $proxy=Get-WindowsProxySettings
            if(-not $proxy.Known){throw 'Unknown proxy settings'}
            $parts+=('proxy|'+$proxy.Proxy+'|'+$proxy.Pac+'|'+$proxy.AutoDetect)
        }
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','')}finally{$sha.Dispose()}
        return [pscustomobject]@{Known=$true;Key=$key;ObservedUtc=[datetime]::UtcNow.ToString('o')}
    } catch { return [pscustomobject]@{Known=$false;Key='';ObservedUtc=[datetime]::UtcNow.ToString('o')} }
}

function Set-RingNetworkContext($Observation) {
    # Разрешение на диск теперь проверяет Lua по свежему маркеру watchdog, а не сохранённому ключу CLI.
    $Script:RingPersistAllowed=$true
    if($Observation.Known -and $Observation.Key){$Script:RingNetworkKey=$Observation.Key}
    else{$Script:RingNetworkKey='unknown-'+[guid]::NewGuid().ToString('N')}
}

function Get-NetworkWatchRecord($Before,$After,[datetime]$Now=[datetime]::UtcNow) {
    $invalid="3 0 - -`n"
    if($null -eq $Before -or -not(Test-NetworkObservation $Before $After) -or $After.Key -notmatch '^[A-Fa-f0-9]{64}$'){return $invalid}
    try {
        if($After.CompositionKey -notmatch '^[A-Fa-f0-9]{64}$' -or $Before.CompositionKey -cne $After.CompositionKey){return $invalid}
        foreach($sample in @($Before,$After)){
            $time=[datetime]::Parse($sample.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $age=($Now.ToUniversalTime()-$time).TotalSeconds
            if($age -lt 0 -or $age -gt 15){return $invalid}
        }
        $epoch=[math]::Floor(($time-[datetime]::SpecifyKind([datetime]'1970-01-01',[DateTimeKind]::Utc)).TotalSeconds)
        return ('3 '+$epoch.ToString([Globalization.CultureInfo]::InvariantCulture)+' '+$After.Key.ToUpperInvariant()+' '+$After.CompositionKey.Substring(0,24).ToUpperInvariant()+"`n")
    } catch{return $invalid}
}

function Write-NetworkWatchRecord([string]$Path,[string]$Record) {
    if($Record.Length -gt 128 -or $Record -notmatch '^3 \d+ (?:[A-F0-9]{64} [A-F0-9]{24}|- -)\n$'){return $false}
    return Write-WatchRecordFile $Path $Record
}
function Write-WatchRecordFile([string]$Path,[string]$Record) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=[Text.Encoding]::ASCII.GetBytes($Record)
        if($bytes.Length -gt 128){return $false}
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
        return $true
    }catch{return $false}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

# Наблюдатель не управляет обходом: его отказ лишь временно запрещает загрузку/сохранение памяти.
function Start-NetworkWatcher {
    try{
        $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $script=Get-PkgPath 'tools/netwatch.ps1'
        Start-Process -FilePath $ps -ArgumentList (ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script)) -WorkingDirectory $Script:Root -WindowStyle Hidden | Out-Null
        return $true
    }catch{return $false}
}

$Script:NetworkWatchTask='zapret network watch'
function Install-NetworkWatchTask {
    try{
        $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $args0=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Get-PkgPath 'tools/netwatch.ps1'))
        $action=New-ScheduledTaskAction -Execute $ps -Argument $args0 -WorkingDirectory $Script:Root
        $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn))
        $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $Script:NetworkWatchTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        return $true
    }catch{return $false}
}

function Remove-NetworkWatchTask {
    try{Unregister-ScheduledTask -TaskName $Script:NetworkWatchTask -Confirm:$false -ErrorAction Stop}catch{}
}

function Test-NetworkObservation($Before,$After) {
    return ($Before.Known -and $After.Known -and $Before.Key -ceq $After.Key)
}
