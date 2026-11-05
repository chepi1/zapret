param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$env:__COMPAT_LAYER='RunAsInvoker' # --dry-run exits before any driver open.
function Get-UpdateTrustSids{return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$exists=$null -ne (Get-Command Get-RunSnapshot -ErrorAction SilentlyContinue)
Check 'coherent run snapshot API exists' $exists
if(-not $exists){exit 1}
$network=[pscustomobject]@{Known=$true;Key=('A'*64);ObservedUtc=[datetime]::UtcNow.ToString('o')}
$targets=@([pscustomobject]@{Group='DPI';Name='fixture';Url='https://fixture.invalid/';Post=$true})
$settings=Get-Settings;$settings.auto='off';$settings.alt='12'
Update-RuntimeLists|Out-Null
Write-TextNoBom (Get-PkgPath $Script:TestedFile) "12|ALT12`r`n"
$one=$null;$two=$null;$unknownA=$null;$unknownB=$null
try{
    $one=Get-RunSnapshot $settings $targets $network
    $two=Get-RunSnapshot $settings $targets $network
    Check 'identical captures have stable content and context with distinct generations' ($one.ConfigHash -ceq $two.ConfigHash -and $one.ContextKey -ceq $two.ContextKey -and $one.Generation -cne $two.Generation)
    Check 'coherent equal snapshots are compatible' ((Test-RunSnapshot $one $two).Compatible)
    $settings.alt='13';$targets[0].Name='mutated caller'
    Check 'settings and targets are captured by value' ((Get-RunSnapshotSettings $one).alt -ne '13' -and @(Get-RunSnapshotTargets $one)[0].Name -eq 'fixture')
    $network2=[pscustomobject]@{Known=$true;Key=('B'*64)}
    $differentNetwork=Get-RunSnapshot (Get-RunSnapshotSettings $one) @(Get-RunSnapshotTargets $one) $network2
    try{Check 'same inputs on a new Wi-Fi/TUN context are incompatible' (-not (Test-RunSnapshot $one $differentNetwork).Compatible -and $one.ConfigHash -ceq $differentNetwork.ConfigHash)}finally{Close-RunSnapshot $differentNetwork}
    $unknown=[pscustomobject]@{Known=$false;Key='unknown'}
    $unknownA=Get-RunSnapshot $settings $targets $unknown;$unknownB=Get-RunSnapshot $settings $targets $unknown
    Check 'unknown networks never acquire a shared trusted context' ($unknownA.ContextKey -cne $unknownB.ContextKey -and -not (Test-RunSnapshot $unknownA $unknownB).Compatible)
    $rootBefore=$Script:Root;$runtimeBefore=$Script:Runtime;$exeBefore=$Script:Exe;$binBefore=$Script:Bin
    $script:views=@()
    foreach($index in @(1,2)){
        Invoke-RunSnapshotScope $one (Get-RunSnapshotSettings $one) {
            $auto=Get-PkgPath 'lists/autohostlist.txt'
            $script:views+=@([pscustomobject]@{Auto=$auto;Runtime=$Script:Runtime;Root=$Script:Root;Exe=$Script:Exe;Bin=$Script:Bin;Seed=[IO.File]::ReadAllText($auto)})
            [IO.File]::AppendAllText($auto,"`nprivate-engine-learned.invalid`n",$Script:Utf8NoBom)
            Write-TextNoBom (Get-PkgPath 'runtime/autohostlist-debug.log') 'owned engine debug'
        }
    }
    Check 'each engine receives its own autohostlist and runtime seeded from the same snapshot' ($script:views.Count -eq 2 -and $script:views[0].Auto -cne $script:views[1].Auto -and $script:views[0].Runtime -cne $script:views[1].Runtime -and $script:views[0].Seed -ceq $script:views[1].Seed)
    Check 'native executable and driver directory stay in the persistent source package' (@($script:views|Where-Object{$_.Exe -cne $exeBefore -or $_.Bin -cne $binBefore}).Count -eq 0)
    Check 'native input scope uses a materialized root and restores caller variables' ($script:views[0].Root -cne $rootBefore -and $Script:Root -ceq $rootBefore -and $Script:Runtime -ceq $runtimeBefore -and $Script:Exe -ceq $exeBefore)
    $renameRejected=$false
    try{[IO.Directory]::Move($script:views[0].Root,($script:views[0].Root+'.moved'))}catch{$renameRejected=$true}
    Check 'snapshot directory is pinned against namespace replacement' $renameRejected
    Check 'test learning never changes the working autohostlist' ([IO.File]::ReadAllText((Get-PkgPath 'lists/autohostlist.txt')) -notmatch 'private-engine-learned')
    Check 'engine scope retains the captured tested-strategy marker' (Invoke-RunSnapshotScope $one (Get-RunSnapshotSettings $one) {Test-StrategyTested (Get-Strategy '12') ([pscustomobject]@{Rows=@()})})
    $rejected=$false
    try{Invoke-RunSnapshotScope $one (Get-RunSnapshotSettings $one) {throw 'injected scoped failure'}}catch{$rejected=$true}
    Check 'scope exception restores package variables' ($rejected -and $Script:Root -ceq $rootBefore -and $Script:Runtime -ceq $runtimeBefore)
    foreach($relative in @('lists/list-general-user.txt','fake/stun.bin','strategies/alt12.txt')){
        $path=Join-Path $Pkg $relative;$bytes=[IO.File]::ReadAllBytes($path)
        try{
            [IO.File]::WriteAllBytes($path,($bytes+[byte[]]@(10)))
            $changed=Get-RunSnapshot (Get-RunSnapshotSettings $one) @(Get-RunSnapshotTargets $one) $network
            try{Check ('input edit invalidates snapshot: '+$relative) (-not (Test-RunSnapshot $one $changed).Compatible)}finally{Close-RunSnapshot $changed}
        }finally{[IO.File]::WriteAllBytes($path,$bytes)}
    }
    $locked=Join-Path $Pkg 'lists/list-general.txt'
    $writer=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    $rejected=$false
    try{try{$unexpected=Get-RunSnapshot $settings $targets $network;Close-RunSnapshot $unexpected}catch{$rejected=$true}}finally{$writer.Dispose()}
    Check 'source already open for writing cannot be captured as coherent' $rejected
    $native=$null;$pinRejected=$false
    try{$native=[IO.File]::Open($exeBefore,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}catch [IO.IOException]{$pinRejected=$true}finally{if($native){$native.Dispose()}}
    Check 'native binaries stay pinned for the run' $pinRejected

    function Get-NetworkObservation{return [pscustomobject]@{Known=$true;Key=('A'*64)}}
    Check 'publication guard accepts unchanged coherent inputs' (Test-RunSnapshotCurrent $one)
    $inputPath=Join-Path $Pkg 'lists/list-general-user.txt';$inputBytes=[IO.File]::ReadAllBytes($inputPath)
    try{
        [IO.File]::WriteAllBytes($inputPath,($inputBytes+[byte[]]@(10)))
        Check 'publication guard rejects a source edit while frozen inputs remain readable' (-not (Test-RunSnapshotCurrent $one) -and (Invoke-RunSnapshotScope $one (Get-RunSnapshotSettings $one) {(Get-Item (Get-PkgPath 'lists/list-general-user.txt')).Length}) -eq $inputBytes.Length)
    }finally{[IO.File]::WriteAllBytes($inputPath,$inputBytes)}
    $summary=Get-RunSnapshotSummary $one|ConvertTo-Json -Compress
    Check 'persisted snapshot summary contains no target URL or source/temp path' ($summary -notmatch 'fixture.invalid|zapret-recipe|[A-Za-z]:\\' -and $summary -match 'ConfigHash')
    $one|Add-Member NoteProperty Root (Join-Path $Pkg 'lists')
    $generation=$one.Generation;$one.Generation=[guid]::NewGuid().ToString('N');$rejected=$false
    try{Close-RunSnapshot $one}catch{$rejected=$true}finally{$one.Generation=$generation}
    Check 'mutated caller metadata cannot redirect or authorize cleanup' ($rejected -and (Test-Path (Join-Path $Pkg 'lists/list-general.txt')))

    $codePath=Join-Path $Pkg 'tools/lib.ps1';$codeBytes=[IO.File]::ReadAllBytes($codePath);$rejected=$false
    try{
        [IO.File]::WriteAllBytes($codePath,($codeBytes+[byte[]]@(10)))
        try{$unexpected=Get-RunSnapshot $settings $targets $network;Close-RunSnapshot $unexpected}catch{$rejected=$true}
    }finally{[IO.File]::WriteAllBytes($codePath,$codeBytes)}
    Check 'snapshot rejects disk code different from the loaded PowerShell AST' $rejected
    $luaPath=Join-Path $Pkg 'lua/zapret-lib.lua';$luaBytes=[IO.File]::ReadAllBytes($luaPath);$rejected=$false
    try{
        [IO.File]::WriteAllBytes($luaPath,($luaBytes+[byte[]]@(10)))
        try{$unexpected=Get-RunSnapshot $settings $targets $network;Close-RunSnapshot $unexpected}catch{$rejected=$true}
    }finally{[IO.File]::WriteAllBytes($luaPath,$luaBytes)}
    Check 'official Lua changed after initial integrity cannot enter a captured run' $rejected
    $script:originalInputOpen=${function:Open-RunSnapshotInputFile};$script:catalogInjected=$false
    $script:extraInput=Join-Path $Pkg 'lists/snapshot-catalog-fixture.txt';$rejected=$false
    function Open-RunSnapshotInputFile($Path){
        if(-not $script:catalogInjected){$script:catalogInjected=$true;[IO.File]::WriteAllText($script:extraInput,'fixture')}
        & $script:originalInputOpen $Path
    }
    try{try{$unexpected=Get-RunSnapshot $settings $targets $network;Close-RunSnapshot $unexpected}catch{$rejected=$true}}
    finally{${function:Open-RunSnapshotInputFile}=$script:originalInputOpen;Remove-Item -LiteralPath $script:extraInput -Force}
    Check 'a changing input catalog cannot produce a coherent snapshot' $rejected

    $menuAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/menu.ps1'),[ref]$null,[ref]$null)
    $menuFunction=$menuAst.Find({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-BoxWidth'},$true)
    Set-Item -LiteralPath Function:\SnapshotMenuFixture -Value ($menuFunction.Body.GetScriptBlock())
    $fromMenu=$null;$menuOk=$false
    try{
        $fromMenu=Get-RunSnapshot $settings $targets $network
        $menuOk=(Get-RunSnapshotState $fromMenu).ExpectedCode.ContainsKey('tools/menu.ps1')
    }catch{Write-Host ('menu context: '+$_.Exception.Message)}
    finally{Remove-Item -LiteralPath Function:\SnapshotMenuFixture;if($null -ne $fromMenu){Close-RunSnapshot $fromMenu}}
    Check 'visible menu functions are included in a valid snapshot' $menuOk

    $cleanup=Get-RunSnapshot $settings $targets $network;$cleanupState=Get-RunSnapshotState $cleanup
    $held=[IO.File]::Open((Join-Path $cleanupState.Root 'CHECKSUMS.txt'),'Open','Read','Read')
    $cleanupFailed=$false;$moved=$false
    try{
        try{Close-RunSnapshot $cleanup}catch{$cleanupFailed=$true}
        $pinAlive=-not $cleanupState.DirectoryPin.IsClosed
        $scopeBlocked=$false;try{Invoke-RunSnapshotScope $cleanup $settings {throw 'scope action must not be reached after cleanup began'}}catch{$scopeBlocked=$_.Exception.Message -ne 'scope action must not be reached after cleanup began'}
        $held.Dispose();$held=$null
        try{[IO.Directory]::Move($cleanupState.Root,($cleanupState.Root+'.moved'));$moved=$true}catch{}
        if($moved){[IO.Directory]::Move(($cleanupState.Root+'.moved'),$cleanupState.Root)}
        Check 'failed child deletion retains namespace protection until cleanup can be retried' ($cleanupFailed -and $pinAlive -and -not $moved -and $scopeBlocked)
        if(-not ($cleanupFailed -and $pinAlive -and -not $moved -and $scopeBlocked)){Write-Host ('cleanup failure='+$cleanupFailed+'; pinned='+$pinAlive+'; moved='+$moved+'; scopeBlocked='+$scopeBlocked)}
    }finally{if($held){$held.Dispose()};Close-RunSnapshot $cleanup}

    $drySettings=Get-RunSnapshotSettings $one;$drySettings.autolist='on'
    $compilerPath=Join-Path $Pkg 'tools/filtercheck.cs';$compilerBytes=[IO.File]::ReadAllBytes($compilerPath)
    try{
        [IO.File]::WriteAllText($compilerPath,'injected invalid source; the frozen compiler source must be used')
        $dry=Invoke-RunSnapshotScope $one $drySettings {Test-ConfigDry $drySettings '12' -NoAuto -IpsetMode 'any'}
    }finally{[IO.File]::WriteAllBytes($compilerPath,$compilerBytes)}
    Check 'native dry-run and filter compiler read frozen data with a writable private autolist' $dry.Ok
    if(-not $dry.Ok){Write-Host $dry.Output}

    # Actual strategy-test launch helper and command composition; only the OS process boundary is fake.
    $testAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
    foreach($definition in $testAst.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -like 'Start-TestInstance*'},$false)){. ([scriptblock]::Create($definition.Extent.Text))}
    $script:launches=@();$script:fixtureProcesses=@()
    function Assert-BypassControlAllowed{}
    function Start-Sleep{}
    function Start-Process($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru){
        $script:launches+=@([pscustomobject]@{Exe=$FilePath;Bin=$WorkingDirectory;Cmd=$ArgumentList;Root=$Script:Root;Auto=(Get-PkgPath 'lists/autohostlist.txt')})
        $result=[pscustomobject]@{Id=(800000+$script:launches.Count);HasExited=$false}
        $script:fixtureProcesses+=@($result);return $result
    }
    $Script:TestRunSnapshot=$one
    try{
        $first=Start-TestInstance (Get-RunSnapshotSettings $one) '12'
        $blocked=$false;try{Close-RunSnapshot $one}catch{$blocked=$true}
        Check 'running test process prevents snapshot cleanup' ($blocked -and (Test-Path $script:views[0].Root))
        $first.HasExited=$true
        $second=Start-TestInstance (Get-RunSnapshotSettings $one) '12' -Final
        Check 'normal and final launch helpers compose from frozen inputs and private engine autolists' ($script:launches.Count -eq 2 -and $script:launches[0].Root -cne $rootBefore -and $script:launches[1].Root -ceq $script:launches[0].Root -and $script:launches[0].Auto -cne $script:launches[1].Auto -and @($script:launches|Where-Object{$_.Exe -cne $exeBefore -or $_.Bin -cne $binBefore}).Count -eq 0)
        $second.HasExited=$true
    }finally{$Script:TestRunSnapshot=$null;foreach($process in $script:fixtureProcesses){$process.HasExited=$true}}
}finally{
    foreach($snapshot in @($one,$two,$unknownA,$unknownB)){if($null -ne $snapshot){Close-RunSnapshot $snapshot}}
}
if($fails){exit 1}
