$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/lib.ps1')
$log=Join-Path $root 'dist/v2-admin-native.log'
Start-Transcript -Path $log -Force|Out-Null
$stage=$null
try{
    if(-not(Test-Admin)){throw 'An administrator token is required.'}
    if(@(Get-RunningGames).Count){throw 'Native acceptance deferred while a game is open.'}
    $stage=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('zapret-native-accept-'+[guid]::NewGuid().ToString('N'))))
    if([IO.Path]::GetDirectoryName($stage) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')){throw 'Unsafe native test stage.'}
    & robocopy.exe $root $stage /E /XD .git dist runtime /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
    if($LASTEXITCODE -lt 0 -or $LASTEXITCODE -ge 8){throw 'Native acceptance copy failed.'}
    $nativeExe=Join-Path $root 'bin/winws2.exe';$nativeBin=Join-Path $root 'bin'
    $quotedExe="'"+$nativeExe.Replace("'","''")+"'";$quotedBin="'"+$nativeBin.Replace("'","''")+"'"
    $names=@('watchluatest','linkguardtest','storeluatest','guardtest','luatest')
    foreach($name in $names){
        $scriptPath=Join-Path $stage ('dev/tests/'+$name+'.ps1')
        $text=[IO.File]::ReadAllText($scriptPath)
        if($name -eq 'luatest'){
            $text=$text.Replace("Join-Path `$Pkg 'bin\winws2.exe'",$quotedExe).Replace("Join-Path `$Pkg 'bin'",$quotedBin)
        }else{
            $import=". (Join-Path `$Pkg 'tools/lib.ps1')"
            if(-not $text.Contains($import)){throw ('Cannot bind original native executable: '+$name)}
            $binding=$import+"`r`n"+'$Script:Exe='+$quotedExe+"`r`n"+'$Script:Bin='+$quotedBin
            $text=$text.Replace($import,$binding)
        }
        [IO.File]::WriteAllText($scriptPath,$text,(New-Object Text.UTF8Encoding($true)))
    }
    Remove-Item Env:\ZAPRET_LUA_TEST_RUNTIME -ErrorAction SilentlyContinue
    $failed=@();$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    foreach($name in $names){
        Write-Output ('===== Native '+$name+' (original persistent bin, private fixture data)')
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stage ('dev/tests/'+$name+'.ps1')) -Pkg $stage
        if($LASTEXITCODE -ne 0){$failed+=@($name)}
    }
    if($failed.Count){throw ('Native checks failed: '+($failed -join ', '))}
    Write-Output 'PASS all5 native acceptance groups; no service/adapter/strategy changes.'
}finally{
    if($stage -and [IO.Directory]::Exists($stage) -and [IO.Path]::GetDirectoryName($stage) -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')){Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    Stop-Transcript|Out-Null
}
