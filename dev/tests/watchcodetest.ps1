param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$watch=Join-Path $Pkg 'tools/netwatch.ps1';$watchBytes=[IO.File]::ReadAllBytes($watch)
$helper=Get-Command Get-NetworkWatchCodeSnapshot -ErrorAction SilentlyContinue
Check 'loaded-code snapshot helper exists' ($null -ne $helper)
if($helper){
    $tokens=$null;$errors=$null
    $entry=[Management.Automation.Language.Parser]::ParseFile($watch,[ref]$tokens,[ref]$errors)
    $snapshot=Get-NetworkWatchCodeSnapshot $entry
    Check 'snapshot pins entry library and observation implementation' ($snapshot.ContainsKey('tools/netwatch.ps1') -and $snapshot.ContainsKey('tools/lib.ps1') -and $snapshot.ContainsKey('tools/netstate.ps1') -and $snapshot.ContainsKey('tools/watchcode.ps1'))
    # Installed module catalogs may advertise functions that this session never loaded.
    $catalogPath=Join-Path $Pkg 'tools/unloaded-catalog-fixture.ps1'
    [IO.File]::WriteAllText($catalogPath,'function UnloadedCatalogFixture { return 1 }',(New-Object Text.UTF8Encoding($true)))
    $catalogAst=[Management.Automation.Language.Parser]::ParseFile($catalogPath,[ref]$null,[ref]$null)
    $catalogFunction=$catalogAst.Find({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
    $script:catalogOnlyCommand=[pscustomobject]@{ScriptBlock=$catalogFunction.Body.GetScriptBlock()}
    $script:loadedFunctionCommands=@(Microsoft.PowerShell.Core\Get-Command -CommandType Function -ListImported)
    function Get-Command {
        [CmdletBinding()]param([Management.Automation.CommandTypes]$CommandType,[switch]$ListImported)
        $script:loadedFunctionCommands
        if(-not $ListImported){$script:catalogOnlyCommand}
    }
    try{
        $loadedOnly=Get-NetworkWatchCodeSnapshot $entry
        $same=$null -ne $loadedOnly -and $loadedOnly.Count -eq $snapshot.Count
        foreach($name in $snapshot.Keys){if($null -eq $loadedOnly -or $loadedOnly[$name] -cne $snapshot[$name]){$same=$false}}
        Check 'installed but unloaded module code cannot enter a loaded-code snapshot' ($same -and -not $loadedOnly.ContainsKey('tools/unloaded-catalog-fixture.ps1'))
    }finally{Remove-Item -LiteralPath 'Function:\Get-Command';Remove-Item -LiteralPath $catalogPath -Force}
    Check 'unchanged loaded code matches the actual source files' ((Get-NetworkWatchCodeState $snapshot) -eq 'Current')
    $settings=Get-Settings
    $before=Get-RingCompositionKey $settings
    Check 'guarded composition matches the ordinary current fingerprint' ($before -match '^[A-F0-9]{64}$' -and (Get-RingCompositionKey $settings -ExpectedCode $snapshot) -ceq $before)
    $script:hashReads=0
    function Get-FileHash {
        [CmdletBinding()]param([string]$LiteralPath,[string]$Algorithm)
        $script:hashReads++
        Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters
    }
    try{
        $plainHash=Get-RingCompositionKey $settings;$plainReads=$script:hashReads
        $script:hashReads=0;$guardedHash=Get-RingCompositionKey $settings -ExpectedCode $snapshot
        Check 'normal guard reuses existing fingerprint reads' ($plainReads -gt 0 -and $script:hashReads -eq $plainReads -and $guardedHash -ceq $plainHash)
    }finally{Remove-Item -LiteralPath 'Function:\Get-FileHash'}
    $path=Join-Path $Pkg 'tools/netstate.ps1';$bytes=[IO.File]::ReadAllBytes($path);$modified=[IO.File]::GetLastWriteTimeUtc($path)
    try{
        $text=[IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path,$text.Replace('network-v4','network-x4'),(New-Object Text.UTF8Encoding($true)))
        [IO.File]::SetLastWriteTimeUtc($path,$modified)
        Check 'same-size same-timestamp source edit is detected' ((Get-NetworkWatchCodeState $snapshot) -eq 'Changed')
        Check 'old code cannot claim a composition built from new source' (-not (Get-RingCompositionKey $settings -ExpectedCode $snapshot) -and (Get-RingCompositionKey $settings) -cne $before)
    }finally{[IO.File]::WriteAllBytes($path,$bytes);[IO.File]::SetLastWriteTimeUtc($path,$modified)}
    $lock=[IO.File]::Open($path,'Open','Read','None')
    try{
        Check 'temporary read denial is unknown rather than changed' ((Get-NetworkWatchCodeState $snapshot) -eq 'Unknown')
        Check 'inaccessible source cannot enable persisted memory' (-not (Get-RingCompositionKey $settings -ExpectedCode $snapshot))
    }finally{$lock.Dispose()}
    Check 'read recovery restores a matching snapshot' ((Get-NetworkWatchCodeState $snapshot) -eq 'Current')
    $changed=$settings.Clone();$changed.auto=if($settings.auto -eq 'on'){'off'}else{'on'}
    $changedHash=Get-RingCompositionKey $changed -ExpectedCode $snapshot
    Check 'settings may change without invalidating loaded code' ($changedHash -match '^[A-F0-9]{64}$' -and $changedHash -cne $before -and (Get-NetworkWatchCodeState $snapshot) -eq 'Current')
    Check 'empty expected-code manifest cannot be trusted' (-not (Get-RingCompositionKey $settings -ExpectedCode @{}))
    $uncovered=$snapshot.Clone();$uncovered['tools/uncovered.ps1']='A'*64
    Check 'uncovered code dependency cannot be silently ignored' (-not (Get-RingCompositionKey $settings -ExpectedCode $uncovered))
}
# Проверить сам источник entry AST: файл меняется до обращения к MyCommand.ScriptBlock.
$probe=Join-Path $Script:Runtime 'entry-source-fixture.ps1'
$probeCode=@'
param()
$loadedValue='executed-original-512'
$text=[IO.File]::ReadAllText($PSCommandPath)
[IO.File]::WriteAllText($PSCommandPath,$text.Replace('executed-original-512','disk-replacement-512'),(New-Object Text.UTF8Encoding($true)))
$entry=$MyInvocation.MyCommand.ScriptBlock.Ast.Extent.Text
if($entry.Contains('executed-original-512') -and -not [IO.File]::ReadAllText($PSCommandPath).Contains('executed-original-512')){
    Write-Output 'entry AST retains executed source';exit 0
}
exit 1
'@
[IO.File]::WriteAllText($probe,$probeCode,(New-Object Text.UTF8Encoding($true)))
$probeArgs=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$probe)
$probeResult=Invoke-Native (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') $probeArgs $Pkg 10
Check 'entry AST retains executed source after an early disk change' ($probeResult.ExitCode -eq 0 -and -not $probeResult.TimedOut -and $probeResult.Output.Contains('entry AST retains executed source'))
$stub=@'
$script:fixtureSample=0;$script:fixtureCodeLock=$null
function Get-OurProcesses {return [pscustomobject]@{Id=1234}}
function Get-WifiLinkObservation {return [pscustomobject]@{Known=$true;ObservedUtc=[datetime]::UtcNow.ToString('o');Interfaces=@()}}
function Get-WifiDisconnectEpoch {return $null}
function Get-NetworkObservation {
    param([switch]$Machine)
    $script:fixtureSample++
    if($script:fixtureSample -eq 2){
        if($env:ZAPRET_WATCH_FIXTURE -eq 'code'){
            [IO.File]::AppendAllText((Join-Path $Script:Root 'tools/netwatch.ps1'),"`n# changed after this process loaded",$Script:Utf8NoBom)
        }elseif($env:ZAPRET_WATCH_FIXTURE -eq 'data'){
            [IO.File]::AppendAllText((Join-Path $Script:Root 'lists/list-general-user.txt'),"`nexample.org",$Script:Utf8NoBom)
        }elseif($env:ZAPRET_WATCH_FIXTURE -eq 'unknown'){
            $script:fixtureCodeLock=[IO.File]::Open((Join-Path $Script:Root 'tools/netstate.ps1'),'Open','Read','None')
        }
    }
    return [pscustomobject]@{Known=$true;Key=('A'*64);ObservedUtc=[datetime]::UtcNow.ToString('o')}
}
function Start-Sleep {
    if($null -ne $script:fixtureCodeLock){
        $network=[IO.File]::ReadAllText((Get-PkgPath ($Script:RingDir+'/network-context.txt')))
        $link=[IO.File]::ReadAllText((Get-PkgPath ($Script:RingDir+'/link-guard.txt')))
        [IO.File]::WriteAllText((Join-Path $Script:Runtime 'fixture-unknown.txt'),('closed='+($network -ceq "3 0 - -`n" -and $link -ceq "1 0 0 0`n")))
        $script:fixtureCodeLock.Dispose();$script:fixtureCodeLock=$null
    }
}
function Start-NetworkWatcher {
    $released=$false
    try{$testLease=[IO.File]::Open((Join-Path $Script:Runtime 'network-watch.lock'),'OpenOrCreate','ReadWrite','Read');$testLease.Dispose();$released=$true}catch{}
    [IO.File]::AppendAllText((Join-Path $Script:Runtime 'fixture-handoff.txt'),('released='+$released+"`n"))
    return $true
}
if($env:ZAPRET_WATCH_FIXTURE -eq 'startup'){
    [IO.File]::AppendAllText((Join-Path $Script:Root 'tools/netwatch.ps1'),"`n# changed before startup validation",$Script:Utf8NoBom)
}
'@
$list=Join-Path $Pkg 'lists/list-general-user.txt';$listBytes=[IO.File]::ReadAllBytes($list)
$oldFixture=$env:ZAPRET_WATCH_FIXTURE
try{
    foreach($case in @('code','data','unknown','startup')){
        [IO.File]::WriteAllBytes($list,$listBytes)
        $patched=[Text.Encoding]::UTF8.GetString($watchBytes).TrimStart([char]0xFEFF).Replace(". (Join-Path `$PSScriptRoot 'lib.ps1')",(". (Join-Path `$PSScriptRoot 'lib.ps1')"+[Environment]::NewLine+$stub))
        [IO.File]::WriteAllText($watch,$patched,(New-Object Text.UTF8Encoding($true)))
        $env:ZAPRET_WATCH_FIXTURE=$case
        $handoff=Join-Path $Script:Runtime 'fixture-handoff.txt'
        if(Test-Path -LiteralPath $handoff){Remove-Item -LiteralPath $handoff}
        $arguments=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$watch,'-MaxSamples','4')
        $child=Invoke-Native (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') $arguments $Pkg 15
        $network=Get-PkgPath ($Script:RingDir+'/network-context.txt');$link=Get-PkgPath ($Script:RingDir+'/link-guard.txt')
        $marker=[IO.File]::ReadAllText($network);$guard=[IO.File]::ReadAllText($link)
        if($case -eq 'code'){
            Check 'old real watcher invalidates both markers after source update' ($marker -ceq "3 0 - -`n" -and $guard -ceq "1 0 0 0`n")
            $calls=@(if(Test-Path -LiteralPath $handoff){[IO.File]::ReadAllLines($handoff)})
            Check 'one replacement is requested after releasing the lease' (@($calls).Count -eq 1 -and $calls[0] -ceq 'released=True')
        }elseif($case -eq 'data'){
            Check 'data-only update can reconfirm context without reloading watcher' ($child.ExitCode -eq 0 -and $marker -match '^3 [0-9]+ A{64} [A-F0-9]{24}\n$' -and -not (Test-Path -LiteralPath $handoff))
        }elseif($case -eq 'unknown'){
            Check 'unknown source invalidates markers and later recovers without restart' ($child.ExitCode -eq 0 -and [IO.File]::ReadAllText((Join-Path $Script:Runtime 'fixture-unknown.txt')) -ceq 'closed=True' -and $marker -match '^3 [0-9]+ A{64} [A-F0-9]{24}\n$' -and -not (Test-Path -LiteralPath $handoff))
        }else{
            Check 'inconsistent startup stays closed without a restart loop' ($marker -ceq "3 0 - -`n" -and $guard -ceq "1 0 0 0`n" -and -not (Test-Path -LiteralPath $handoff))
        }
        Check ($case+' fixture exits within its bound') (-not $child.TimedOut)
        if($child.TimedOut -or ($child.ExitCode -ne 0 -and $case -ne 'startup')){Write-Host $child.Output}
    }
}finally{
    [IO.File]::WriteAllBytes($watch,$watchBytes);[IO.File]::WriteAllBytes($list,$listBytes);$env:ZAPRET_WATCH_FIXTURE=$oldFixture
}
if($fails){exit 1}
