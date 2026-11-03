# Один наблюдатель папки. Не запускает/останавливает обход, не меняет сеть и не выполняет внешних запросов.
param([ValidateRange(0,1000000)][int]$MaxSamples=0)
. (Join-Path $PSScriptRoot 'lib.ps1')
$lease=$null
try{
    try{$lease=[IO.File]::Open((Join-Path $Script:Runtime 'network-watch.lock'),'OpenOrCreate','ReadWrite','Read')}catch{exit 0}
    Initialize-RingDir
    $file=Get-PkgPath ($Script:RingDir+'/network-context.txt')
    Write-NetworkWatchRecord $file "3 0 - -`n" | Out-Null
    $before=$null
    for($sample=0;$MaxSamples -eq 0 -or $sample -lt $MaxSamples;$sample++){
        if(-not @(Get-OurProcesses).Count){
            if(-not(Get-OurService)){break}
            Write-NetworkWatchRecord $file "3 0 - -`n" | Out-Null
            $before=$null
            Start-Sleep -Seconds 5
            continue
        }
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
