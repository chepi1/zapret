# Один наблюдатель папки. Не запускает/останавливает обход, не меняет сеть и не выполняет внешних запросов.
param([ValidateRange(0,1000000)][int]$MaxSamples=0)
. (Join-Path $PSScriptRoot 'lib.ps1')
foreach($required in @('Get-NetworkObservation','Get-RingCompositionKey','Write-NetworkWatchRecord','Get-NetworkWatchRecord','Get-WifiInterruptionState','Write-LinkGuardRecord')){
    if(-not(Get-Command $required -ErrorAction SilentlyContinue)){exit 1}
}
$lease=$null
try{
    try{$lease=[IO.File]::Open((Join-Path $Script:Runtime 'network-watch.lock'),'OpenOrCreate','ReadWrite','Read')}catch{exit 0}
    Initialize-RingDir
    $file=Get-PkgPath ($Script:RingDir+'/network-context.txt')
    $linkFile=Get-PkgPath ($Script:RingDir+'/link-guard.txt')
    Write-NetworkWatchRecord $file "3 0 - -`n" | Out-Null
    Write-LinkGuardRecord $linkFile "1 0 0 0`n" | Out-Null
    $before=$null;$linkState=$null
    for($sample=0;$MaxSamples -eq 0 -or $sample -lt $MaxSamples;$sample++){
        if(-not @(Get-OurProcesses).Count){
            if(-not(Get-OurService)){break}
            Write-NetworkWatchRecord $file "3 0 - -`n" | Out-Null
            Write-LinkGuardRecord $linkFile "1 0 0 0`n" | Out-Null
            $before=$null;$linkState=$null
            Start-Sleep -Seconds 5
            continue
        }
        $trackedIds=@(if($null -ne $linkState){$linkState.Links.Keys})
        $wifi=Get-WifiLinkObservation -TrackedIds $trackedIds
        $scope=@(Get-WifiWatchScope $linkState $wifi)
        $now=[datetime]::UtcNow
        $eventEpoch=Get-WifiDisconnectEpoch $scope $now
        $linkState=Get-WifiInterruptionState $linkState $wifi $eventEpoch $now
        Write-LinkGuardRecord $linkFile (Get-LinkGuardRecord $linkState $now) | Out-Null
        $after=Get-NetworkObservation -Machine
        $after | Add-Member NoteProperty CompositionKey (Get-RingCompositionKey (Get-Settings))
        Write-NetworkWatchRecord $file (Get-NetworkWatchRecord $before $after) | Out-Null
        $before=$after
        Start-Sleep -Seconds 5
    }
}finally{
    if($lease){$lease.Dispose()}
    # Старый heartbeat автоматически истекает; чужой экземпляр после освобождения lease не затираем.
}
