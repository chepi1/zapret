param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
$text=$ast.Extent.Text;$main=$text.Substring($text.IndexOf('$targets = @(Read-DpiSuite)'))
$functions=@($ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|ForEach-Object{$_.Extent.Text}) -join "`r`n"
$fixture=Join-Path $Script:Runtime 'recipe-run-child.ps1'
$prefix=@'
param($Pkg,$Case,$Result)
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:ControlMutexName='Local\zapret-recipe-workflow-'+[guid]::NewGuid().ToString('N')
$Script:Runtime=Join-Path $Script:Runtime ('recipe-'+$Case)
[void][IO.Directory]::CreateDirectory($Script:Runtime)
$Script:TestEntryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
function Get-UpdateTrustSids{return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
'@
$boundary=@'
$TimeoutSec=1;$Parallel=2;$Rounds=1;$Seed=42;$NoPrompt=$true;$ReportOnly=$true;$KeepPrimary=$false;$Full=$false
$CompareA='12';$CompareB='13';$CompareBlocks=4;$comparisonMode=$Case -in @('comparison','comparisonsettings')
$HarmSlowMs=500;$RetryMax=16;$HopelessRuns=3;$GroupNames=[ordered]@{DPI='DPI';Clean='Clean'}
$report=New-Object 'Collections.Generic.List[string]';$info=$null
$script:launches=@();$script:processes=@();$script:restores=0;$script:editDone=$false;$script:dryRoots=@();$script:postPaths=@()
$menuAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/menu.ps1'),[ref]$null,[ref]$null)
$menuFunction=$menuAst.Find({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-BoxWidth'},$true)
Set-Item -LiteralPath Function:\SnapshotMenuFixture -Value ($menuFunction.Body.GetScriptBlock())
$script:original=[pscustomobject]@{Id=700000;HasExited=$false}
$settings=Get-Settings;$settings.auto='off';$settings.alt='12';Save-Settings $settings
function Read-DpiSuite{return [pscustomobject]@{Group='DPI';Name='blocked';Url='https://blocked.invalid/';Post=$true}}
function Read-Targets{return [pscustomobject]@{Group='Clean';Name='clean';Url='https://clean.invalid/';Post=$false}}
function Get-RunningGames{return @()}
function Get-OurProcesses{if(-not $script:original.HasExited){return $script:original};foreach($item in $script:processes){if(-not $item.HasExited){$item}}}
function Stop-Bypass{$script:original.HasExited=$true}
function Start-Bypass{
    if($Script:Root -cne $Pkg -or $null -ne $Script:RecipeContext -or $null -ne $Script:TestRunSnapshot){throw 'Restoration escaped the source package or retained a snapshot.'}
    $script:restores++;return $true
}
function Enable-TcpTimestamps{}
function Get-Ipv6Addresses{return @()}
function Start-HostsPinProbes{return @()}
function Get-Ipv6Report{return [pscustomobject]@{Text='fixture';Broken=@();PreferV4=$false}}
function Test-HostsPins{return @()}
function Get-HostsStatus{return @()}
function Get-HostsReportText{return 'fixture'}
function Get-IpBlocked{return @()}
function Get-NetworkObservation{return [pscustomobject]@{Known=$true;Key=('A'*64)}}
function Get-TestStrategies{return Get-Strategy '12'}
function Test-ConfigDry{$script:dryRoots+=@($Script:Root);return [pscustomobject]@{Ok=$true;Output='fixture'}}
function Start-Process($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru){
    $script:launches+=@([pscustomobject]@{Root=$Script:Root;Exe=$FilePath;Bin=$WorkingDirectory;Auto=(Get-PkgPath 'lists/autohostlist.txt')})
    $process=[pscustomobject]@{Id=(710000+$script:launches.Count);HasExited=$false}
    $process|Add-Member ScriptMethod Kill {if($Case -eq 'refused'){throw 'injected stop refusal'};$this.HasExited=$true}
    $process|Add-Member ScriptMethod WaitForExit {param($Ms);return $this.HasExited}
    $script:processes+=@($process);return $process
}
function Start-Sleep{if($Case -in @('interrupted','refused') -and $script:launches.Count){throw 'injected interruption after OS launch'}}
function Stop-Process($Id,[switch]$Force,$ErrorAction){$owned=@($script:processes|Where-Object{$_.Id -eq $Id});if($owned.Count -ne 1){throw 'Fixture refuses a real PID'};$owned[0].HasExited=$true}
function Invoke-CurlBatch($Targets,$PostFile,$Width=0,[long]$DeadlineTicks=0,$RequiredProcess=$null){
    $script:postPaths+=@($PostFile)
    if($Case -eq 'changed' -and -not $script:editDone){$script:editDone=$true;[IO.File]::AppendAllText((Join-Path $Pkg 'lists/list-general-user.txt'),"`nrecipe-source-edit.invalid`n")}
    if($Case -in @('settings','comparisonsettings') -and -not $script:editDone){$script:editDone=$true;$changed=Get-Settings;$changed.notify=if($changed.notify -eq 'on'){'off'}else{'on'};Save-Settings $changed}
    foreach($target in $Targets){
        [pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State='OK';Code='200';Exit=0;Up=65536;Down=1;ConnMs=50;TlsMs=100;Tries=1;Flaky=$false;StartedMs=100;ObservedMs=200}
    }
}
try {
'@
$suffix=@'
} finally {
    $roots=@($script:launches|ForEach-Object{$_.Root}|Select-Object -Unique)
    $accepted=@(Get-ChildItem -LiteralPath $Script:Runtime -Filter 'comparison-*.result.json' -ErrorAction SilentlyContinue).Count
    [IO.File]::WriteAllText($Result,([pscustomobject]@{
        Launches=$script:launches.Count;Frozen=($roots.Count -eq 1 -and $roots[0] -cne $Pkg)
        Cleaned=(@($roots|Where-Object{$_ -cne $Pkg -and (Test-Path -LiteralPath $_)}).Count -eq 0)
        PrivateAuto=(@($script:launches|ForEach-Object{$_.Auto}|Select-Object -Unique).Count -eq $script:launches.Count)
        Active=@($script:processes|Where-Object{-not $_.HasExited}).Count;Restores=$script:restores
        SourceRestored=($Script:Root -ceq $Pkg -and $null -eq $Script:TestRunSnapshot)
        FrozenPost=($roots.Count -eq 1 -and $script:postPaths.Count -gt 0 -and @($script:postPaths|Where-Object{-not $_.StartsWith($roots[0]+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0)
        FrozenDry=@($script:dryRoots|Where-Object{$_ -cne $Pkg}).Count;Accepted=$accepted
    }|ConvertTo-Json -Compress))
    # Only fake processes exist here. Capture refusal evidence, then release the fixture's retained storage.
    if($Case -eq 'refused' -and $null -ne $Script:TestRunSnapshot){foreach($item in $script:processes){$item.HasExited=$true};Close-RunSnapshot $Script:TestRunSnapshot;$Script:TestRunSnapshot=$null}
}
'@
[IO.File]::WriteAllText($fixture,($prefix+"`r`n"+$functions+"`r`n"+$boundary+"`r`n"+$main+"`r`n"+$suffix),(New-Object Text.UTF8Encoding($true)))
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$source=Join-Path $Pkg 'lists/list-general-user.txt';$bytes=[IO.File]::ReadAllBytes($source)
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
foreach($case in @('ordinary','changed','settings','interrupted','refused','comparison','comparisonsettings')){
    $result=Join-Path $Script:Runtime ('recipe-'+$case+'.json')
    $argsLine=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Pkg',$Pkg,'-Case',$case,'-Result',$result)
    try{$run=Invoke-Native $ps $argsLine $Pkg 60}finally{[IO.File]::WriteAllBytes($source,$bytes)}
    if(-not (Test-Path $result)){Write-Host $run.Output;Check ($case+' executes the real workflow through cleanup') $false;continue}
    $state=[IO.File]::ReadAllText($result)|ConvertFrom-Json
    Check ($case+' runs only with frozen inputs and private autolists') ($state.Launches -gt 0 -and $state.Frozen -and $state.PrivateAuto)
    if($case -eq 'refused'){Check 'refused exit retains engine inputs and prevents restoring over the live process' (-not $state.Cleaned -and $state.Active -eq 1 -and $state.Restores -eq 0 -and -not $state.SourceRestored -and $run.ExitCode -ne 0)}
    else{Check ($case+' cleans owned processes and snapshot before restoring the original bypass') ($state.Cleaned -and $state.Active -eq 0 -and $state.Restores -gt 0 -and $state.SourceRestored)}
    if($case -notin @('interrupted','refused')){Check ($case+' validates materialized inputs before launch') ($state.FrozenDry -gt 0)}
    Check ($case+' uses the captured POST body for every probe') $state.FrozenPost
    if($case -eq 'comparison'){Check 'A/B completes its full fixed-arm workflow under the snapshot' ($run.ExitCode -eq 0 -and $state.Launches -eq 24 -and $state.Accepted -eq 1)}
    elseif($case -in @('changed','settings','interrupted','comparisonsettings')){Check ($case+' cannot publish a successful run') ($run.ExitCode -ne 0 -and $state.Accepted -eq 0)}
}
if($fails){exit 1}
