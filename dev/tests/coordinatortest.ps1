param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$Script:ControlMutexName='Local\zapret-test-'+[guid]::NewGuid().ToString('N')
$childRuntime=Join-Path $Script:Runtime 'other-copy';New-Item -ItemType Directory $childRuntime | Out-Null
$childScript=Join-Path $Script:Runtime 'coordinator-child.ps1'
$output=Join-Path $Script:Runtime 'child-result.txt'
$escapedLib=(Join-Path $Pkg 'tools/lib.ps1').Replace("'","''")
$body=". '$escapedLib'`n" + '$Script:Runtime=' + "'"+$childRuntime.Replace("'","''")+"'`n" + '$Script:ControlMutexName=' + "'"+$Script:ControlMutexName+"'`n" + 'try { $ok=Enter-BypassControl child; [IO.File]::WriteAllText(' + "'"+$output.Replace("'","''")+"'" + ',[string]$ok) } finally { Exit-BypassControl }'
[IO.File]::WriteAllText($childScript,$body,(New-Object Text.UTF8Encoding($true)))
$holdFile=Join-Path $Script:Runtime 'hold-child'
$body=$body.Replace('} finally {',("; if(Test-Path '"+$holdFile.Replace("'","''")+"'){Start-Sleep -Seconds 30} } finally {"))
[IO.File]::WriteAllText($childScript,$body,(New-Object Text.UTF8Encoding($true)))
function Run-Child {
    $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $p=Start-Process $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$childScript+'"') -WindowStyle Hidden -PassThru
    try{if(-not $p.WaitForExit(10000)){throw 'Child did not finish'};return [IO.File]::ReadAllText($output)}finally{if(-not $p.HasExited){Stop-Process -Id $p.Id -Force}}
}
try{
    Check 'first owner enters' (Enter-BypassControl owner)
    Check 'different package folder cannot enter shared coordinator' ((Run-Child) -eq 'False')
    Check 'nested entry keeps ownership' (Enter-BypassControl nested)
    Exit-BypassControl
    Check 'nested exit does not release machine ownership' ((Run-Child) -eq 'False')
    Exit-BypassControl
    Check 'next process can enter after release' ((Run-Child) -eq 'True')
    $fileOwner=[IO.File]::Open((Join-Path $Script:Runtime 'control.lock'),'OpenOrCreate','ReadWrite','Read')
    try{
        Check 'folder lease failure refuses operation' (-not(Enter-BypassControl blocked-folder))
        Check 'folder lease failure releases machine mutex' ((Run-Child) -eq 'True')
    }finally{$fileOwner.Dispose()}
    Remove-Item -LiteralPath $output
    [IO.File]::WriteAllText($holdFile,'hold')
    $keeper=New-Object Threading.Mutex($false,$Script:ControlMutexName)
    $child=$null
    try{
        $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $child=Start-Process $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$childScript+'"') -WindowStyle Hidden -PassThru
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while(-not(Test-Path $output) -and $timer.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 50}
        Check 'child owns coordinator before crash' ((Test-Path $output) -and [IO.File]::ReadAllText($output) -eq 'True')
        Check 'other owner cannot be bypassed' (-not(Enter-BypassControl contender))
        Stop-Process -Id $child.Id -Force; $child.WaitForExit()
        Check 'abandoned owner can be recovered without stale file lock' (Enter-BypassControl recovery)
        Exit-BypassControl
    }finally{
        if($child -and -not $child.HasExited){Stop-Process -Id $child.Id -Force}
        $keeper.Dispose()
        Remove-Item -LiteralPath $holdFile -ErrorAction SilentlyContinue
    }
}finally{while($Script:ControlDepth -gt 0){Exit-BypassControl}}
if($fails){exit 1}
