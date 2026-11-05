# Coherent, owned input snapshots for explicit strategy tests; never used by normal play.
if(-not (Get-Variable RunSnapshotStates -Scope Script -ErrorAction SilentlyContinue)){$Script:RunSnapshotStates=@{}}

function ConvertTo-RunSettingsJson([hashtable]$Settings){
    $value=[ordered]@{}
    foreach($key in @($Settings.Keys|Sort-Object)){
        if($Settings[$key] -is [array] -or $Settings[$key] -is [Collections.IDictionary]){throw 'Snapshot settings must be scalar.'}
        $value[([string]$key).ToLowerInvariant()]=[Convert]::ToString($Settings[$key],[Globalization.CultureInfo]::InvariantCulture)
    }
    return ConvertTo-Json -InputObject $value -Compress
}
function ConvertTo-RunTargetsJson($Targets){
    $value=@(foreach($target in @($Targets)){
        foreach($key in @('Group','Name','Url')){if(-not $target.PSObject.Properties[$key]){throw 'Incomplete snapshot target.'}}
        $post=$false;if($target.PSObject.Properties['Post']){$post=[bool]$target.Post}
        [pscustomobject][ordered]@{Group=[string]$target.Group;Name=[string]$target.Name;Url=[string]$target.Url;Post=$post}
    })
    if(-not $value.Count){throw 'Snapshot has no targets.'}
    return ConvertTo-Json -InputObject $value -Depth 4 -Compress
}
function Get-RunSnapshotHash([string[]]$Parts){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Parts -join "`n")))).Replace('-','')}finally{$sha.Dispose()}
}
function Get-RunSnapshotFiles {
    $files=@(Get-ScoreInputFiles)+@('tools/targets.txt','tools/dpi-suite.json')
    foreach($directory in @('bin','strategies','windivert','tools')){
        # A menu-invoked test also inherits menu function ASTs. Capture every package PS module.
        $files+=@(Get-ChildItem -LiteralPath (Join-Path $Script:Root $directory) -File -ErrorAction Stop|Where-Object{$directory -ne 'tools' -or $_.Extension -eq '.ps1'}|ForEach-Object{$directory+'/'+$_.Name})
    }
    foreach($relative in @('lists/autohostlist.txt','runtime/settings.ini','runtime/test-rank.txt','runtime/test-cover.txt','runtime/tested-strategies.txt','runtime/post64k.bin','runtime/dpi-suite.json','runtime/ipset-any.txt')){
        $path=if($relative.StartsWith('runtime/')){Join-Path $Script:Runtime $relative.Substring(8)}else{Join-Path $Script:Root $relative}
        if([IO.File]::Exists($path)){$files+=@($relative)}
    }
    $names=[string[]]@($files|Select-Object -Unique);[Array]::Sort($names,[StringComparer]::Ordinal)
    return $names
}
function Open-RunSnapshotInputFile([string]$Path){
    return [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
}
function Open-RunSnapshotDirectory([string]$Path){
    if(-not ('ZapretRecipe.DirectoryPin' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ZapretRecipe {
    public static class DirectoryPin {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        public static SafeFileHandle Open(string path) {
            // FILE_LIST_DIRECTORY participates in delete sharing; READ_ATTRIBUTES alone does not.
            SafeFileHandle handle=CreateFile(path,0x81,3,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
            if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
            return handle;
        }
    }
}
'@ -ErrorAction Stop
    }
    return [ZapretRecipe.DirectoryPin]::Open($Path)
}
function Remove-RunSnapshotStorage([string]$Root,$DirectoryPin,[string]$Generation,[string]$Parent){
    if($null -eq $DirectoryPin -or $DirectoryPin.IsClosed -or $DirectoryPin.IsInvalid){throw 'Snapshot directory is not pinned.'}
        if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Root)) -cne $Parent -or [IO.Path]::GetFileName($Root) -cne ('zapret-recipe-'+$Generation)){throw 'Unsafe snapshot cleanup root.'}
        $item=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or -not (Test-UpdateTrustedPath $Root)){throw 'Snapshot storage ownership changed.'}
        # Keep the directory's no-delete handle until the recursive part is over.
        foreach($child in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)){
            if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected reparse point in snapshot storage.'}
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
    # A failed child deletion leaves this handle owned by the registry for a safe retry.
    $DirectoryPin.Dispose()
    # A namespace change after releasing the handle can never trigger recursive deletion.
    [IO.Directory]::Delete($Root,$false)
}
function Get-RunSnapshotState($Snapshot){
    if($null -eq $Snapshot -or -not $Snapshot.PSObject.Properties['Generation'] -or -not $Script:RunSnapshotStates.ContainsKey([string]$Snapshot.Generation)){throw 'Unknown or closed run snapshot.'}
    $state=$Script:RunSnapshotStates[[string]$Snapshot.Generation]
    if(-not [object]::ReferenceEquals($Snapshot,$state.Public) -or $Snapshot.ConfigHash -cne $state.ConfigHash -or $Snapshot.ContextKey -cne $state.ContextKey -or $Snapshot.SchemaVersion -ne 1 -or $Snapshot.NetworkKnown -ne $state.NetworkKnown){throw 'Run snapshot metadata changed.'}
    return $state
}
function Get-RunSnapshot {
    param([Parameter(Mandatory=$true)][hashtable]$Settings,[Parameter(Mandatory=$true)]$Targets,[Parameter(Mandatory=$true)]$NetworkObservation,[switch]$MetadataOnly,[switch]$RequireSavedSettings,[hashtable]$ExpectedCode=$null)
    $settingsJson=ConvertTo-RunSettingsJson $Settings;$targetsJson=ConvertTo-RunTargetsJson $Targets
    if($null -eq $ExpectedCode){$ExpectedCode=Get-LoadedPackageCodeSnapshot ${function:Get-RunSnapshot}.Ast 'tools/recipe.ps1'}
    if($null -eq $ExpectedCode -or -not $ExpectedCode.Count){throw 'Loaded snapshot code cannot be identified.'}
    $generation=[guid]::NewGuid().ToString('N');$sourceRoot=$Script:Root;$sourceRuntime=$Script:Runtime
    $root=$null;$rootOwned=$false;$registered=$false;$items=@();$pins=@();$copies=@();$sha=$null;$directoryPin=$null
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    try{
        $files=@(Get-RunSnapshotFiles)
        if(-not $files.Count -or $files.Count -gt 2048){throw 'Snapshot file count exceeds its budget.'}
        $directories=@{};$total=0L
        foreach($relative in $files){
            $path=if($relative.StartsWith('runtime/')){Join-Path $sourceRuntime $relative.Substring(8)}else{Join-Path $sourceRoot $relative}
            $cursor=[IO.Path]::GetFullPath($path)
            while($cursor -and -not $directories.ContainsKey($cursor)){
                $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Snapshot input uses a reparse point: '+$relative)}
                $directories[$cursor]=$true;$cursor=[IO.Path]::GetDirectoryName($cursor)
            }
            $stream=Open-RunSnapshotInputFile $path
            $items+=@([pscustomobject]@{Path=$relative;Stream=$stream;Source=$path})
            $total+=$stream.Length;if($total -gt 64MB){throw 'Snapshot inputs exceed64MiB.'}
        }
        if(@(Compare-Object $files @(Get-RunSnapshotFiles) -CaseSensitive).Count){throw 'Input catalog changed while capturing the snapshot.'}
        if(-not $MetadataOnly){
            $root=Join-Path $parent ('zapret-recipe-'+$generation)
            if(Test-Path -LiteralPath $root){throw 'Snapshot directory already exists.'}
            $security=New-Object Security.AccessControl.DirectorySecurity
            $security.SetAccessRuleProtection($true,$false);$trusted=@(Get-UpdateTrustSids)
            $security.SetOwner((New-Object Security.Principal.SecurityIdentifier($trusted[-1])))
            foreach($sid in $trusted){
                $identity=New-Object Security.Principal.SecurityIdentifier($sid)
                $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
                $security.AddAccessRule($rule)
            }
            [IO.Directory]::CreateDirectory($root,$security)|Out-Null
            $directoryPin=Open-RunSnapshotDirectory $root
            if(-not (Test-UpdateTrustedPath $root) -or @(Get-ChildItem -LiteralPath $root -Force).Count){throw 'Snapshot storage is not empty and trusted.'}
            $rootOwned=$true
        }
        $manifest=@();$hashes=@{};$sha=[Security.Cryptography.SHA256]::Create()
        foreach($item in $items){
            $hash=[BitConverter]::ToString($sha.ComputeHash($item.Stream)).Replace('-','');$hashes[$item.Path]=$hash
            $manifest+=@([pscustomobject][ordered]@{Path=$item.Path;Hash=$hash;Length=$item.Stream.Length})
            if(-not $MetadataOnly){
                $destination=Join-Path $root $item.Path
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
                $target=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$item.Stream.Position=0;$item.Stream.CopyTo($target)}finally{$target.Dispose()}
                $copies+=@(Open-RunSnapshotInputFile $destination)
            }
        }
        foreach($name in $ExpectedCode.Keys){if(-not $hashes.ContainsKey($name) -or $hashes[$name] -cne $ExpectedCode[$name]){throw ('Loaded code differs from snapshot input: '+$name)}}
        if($RequireSavedSettings){
            $runtimeSaved=$Script:Runtime
            try{
                if($MetadataOnly){
                    # Current-file read is safe while the source handles deny writers.
                    $actual=Get-Settings
                }else{$Script:Runtime=Join-Path $root 'runtime';$actual=Get-Settings}
                if((ConvertTo-RunSettingsJson $actual) -cne $settingsJson){throw 'Saved settings differ from the requested run settings.'}
            }finally{$Script:Runtime=$runtimeSaved}
        }
        $known=$NetworkObservation.PSObject.Properties['Known'] -and $NetworkObservation.Known -and $NetworkObservation.PSObject.Properties['Key'] -and $NetworkObservation.Key -match '^[A-Fa-f0-9]{64}$'
        $configHash=Get-RunSnapshotHash @('run-recipe-v1',$Script:Version,$settingsJson,$targetsJson,(ConvertTo-Json -InputObject $manifest -Depth 4 -Compress))
        $networkKey=if($known){([string]$NetworkObservation.Key).ToUpperInvariant()}else{''}
        $contextKey=if($known){Get-RunSnapshotHash @('run-context-v1',$networkKey,$configHash)}else{'unknown-'+$generation}
        $public=[pscustomobject]@{SchemaVersion=1;Generation=$generation;ConfigHash=$configHash;ContextKey=$contextKey;NetworkKnown=[bool]$known;FileCount=$files.Count}
        $state=@{Public=$public;ConfigHash=$configHash;ContextKey=$contextKey;NetworkKnown=[bool]$known;NetworkKey=$networkKey;SettingsJson=$settingsJson;TargetsJson=$targetsJson;Manifest=$manifest;SourceRoot=$sourceRoot;SourceRuntime=$sourceRuntime;Root=$root;RootOwned=$rootOwned;Parent=$parent;DirectoryPin=$directoryPin;Pins=@();Copies=$copies;Exe=$Script:Exe;Bin=$Script:Bin;ScopeDepth=0;Closing=$false;RequireSavedSettings=[bool]$RequireSavedSettings;ExpectedCode=$ExpectedCode.Clone();Processes=@()}
        foreach($item in $items){if(-not $MetadataOnly -and $item.Path.StartsWith('bin/')){$pins+=@($item.Stream)}}
        $state.Pins=$pins
        $Script:RunSnapshotStates[$generation]=$state;$registered=$true
        return $public
    }finally{
        if($sha){$sha.Dispose()}
        foreach($item in $items){if(-not $registered -or -not $pins.Contains($item.Stream)){$item.Stream.Dispose()}}
        if(-not $registered){
            try{
                foreach($copy in $copies){$copy.Dispose()}
                if($rootOwned){Remove-RunSnapshotStorage $root $directoryPin $generation $parent}
            }finally{if($directoryPin){$directoryPin.Dispose()}}
        }
    }
}
function Get-RunSnapshotSettings($Snapshot){
    $state=Get-RunSnapshotState $Snapshot;$decoded=$state.SettingsJson|ConvertFrom-Json -ErrorAction Stop;$settings=@{}
    foreach($property in $decoded.PSObject.Properties){$settings[$property.Name]=[string]$property.Value}
    return $settings
}
function Get-RunSnapshotTargets($Snapshot){
    $state=Get-RunSnapshotState $Snapshot
    $targets=ConvertFrom-Json -InputObject $state.TargetsJson -ErrorAction Stop
    foreach($target in $targets){Write-Output $target}
}
function Get-RunSnapshotPostFile($Snapshot){
    $state=Get-RunSnapshotState $Snapshot
    if(-not $state.Root -or -not [IO.File]::Exists((Join-Path $state.Root 'runtime/post64k.bin'))){throw 'Snapshot POST body is missing.'}
    return Join-Path $state.Root 'runtime/post64k.bin'
}
function Get-RunSnapshotSummary($Snapshot){
    $state=Get-RunSnapshotState $Snapshot
    return [pscustomobject]@{SchemaVersion=1;Generation=$state.Public.Generation;ConfigHash=$state.ConfigHash;ContextKey=$state.ContextKey;NetworkKnown=$state.NetworkKnown;FileCount=$state.Manifest.Count}
}
function Test-RunSnapshot($Before,$After){
    $reasons=@()
    try{
        $a=Get-RunSnapshotState $Before;$b=Get-RunSnapshotState $After
        if(-not $a.NetworkKnown -or -not $b.NetworkKnown){$reasons+=@('NetworkUnknown')}
        elseif($a.NetworkKey -cne $b.NetworkKey){$reasons+=@('NetworkChanged')}
        if($a.ConfigHash -cne $b.ConfigHash){$reasons+=@('InputsChanged')}
    }catch{$reasons+=@('InvalidSnapshot')}
    return [pscustomobject]@{Compatible=($reasons.Count -eq 0);Reasons=$reasons}
}
function Test-RunSnapshotCurrent($Snapshot){
    $current=$null
    try{
        $state=Get-RunSnapshotState $Snapshot
        if($state.Closing -or $Script:Root -cne $state.SourceRoot -or $Script:Runtime -cne $state.SourceRuntime){return $false}
        $current=Get-RunSnapshot (Get-RunSnapshotSettings $Snapshot) @(Get-RunSnapshotTargets $Snapshot) (Get-NetworkObservation) -MetadataOnly -RequireSavedSettings:$state.RequireSavedSettings -ExpectedCode $state.ExpectedCode
        return (Test-RunSnapshot $Snapshot $current).Compatible
    }catch{return $false}finally{if($null -ne $current){Close-RunSnapshot $current}}
}
function Assert-TestRunSnapshotCurrent {
    if($null -ne $Script:TestRunSnapshot -and -not (Test-RunSnapshotCurrent $Script:TestRunSnapshot)){
        throw 'Сеть, настройки или входные файлы изменились во время теста. Результат не применяется; повторите проверку после завершения правок.'
    }
}
function Invoke-RunSnapshotScope($Snapshot,[hashtable]$Settings,[scriptblock]$Action){
    $state=Get-RunSnapshotState $Snapshot
    if(-not $state.Root -or $state.Closing -or $state.ScopeDepth -ne 0 -or $null -ne $Script:RecipeContext){throw 'Run snapshot scope is unavailable or nested.'}
    $runtime=Join-Path $state.Root ('views/'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runtime -ErrorAction Stop|Out-Null
    foreach($name in @('test-rank.txt','test-cover.txt','tested-strategies.txt','ipset-any.txt')){
        $baseline=Join-Path $state.Root ('runtime/'+$name)
        if([IO.File]::Exists($baseline)){[IO.File]::Copy($baseline,(Join-Path $runtime $name),$false)}
    }
    $normalized=(ConvertTo-RunSettingsJson $Settings)|ConvertFrom-Json -ErrorAction Stop
    $lines=@($normalized.PSObject.Properties|Sort-Object Name|ForEach-Object{$_.Name+'='+[string]$_.Value})
    Write-TextNoBom (Join-Path $runtime 'settings.ini') (($lines -join "`r`n")+"`r`n")
    $auto=Join-Path $runtime 'autohostlist.txt';$baselineAuto=Join-Path $state.Root 'lists/autohostlist.txt'
    if([IO.File]::Exists($baselineAuto)){[IO.File]::Copy($baselineAuto,$auto,$false)}else{Write-TextNoBom $auto $Script:AutolistHeader}
    $saved=@{};$variables=@('Root','Lists','StratDir','Runtime','Exe','Bin','StrategiesCache','RingCache','RingCompositionKey','RingNetworkKey','RingPersistAllowed','RecipeContext')
    foreach($name in $variables){$variable=Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue;$saved[$name]=@{Exists=($null -ne $variable);Value=$(if($variable){$variable.Value}else{$null})}}
    $state.ScopeDepth++
    try{
        $Script:Root=$state.Root;$Script:Lists=Join-Path $state.Root 'lists';$Script:StratDir=Join-Path $state.Root 'strategies';$Script:Runtime=$runtime
        $Script:Exe=$state.Exe;$Script:Bin=$state.Bin;$Script:StrategiesCache=$null;$Script:RingCache=@{}
        $Script:RecipeContext=[pscustomobject]@{Runtime=$runtime;Autolist=$auto}
        return & $Action
    }finally{
        foreach($name in $variables){if($saved[$name].Exists){Set-Variable -Name $name -Scope Script -Value $saved[$name].Value}else{Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue}}
        $state.ScopeDepth--
    }
}
function Close-RunSnapshot($Snapshot){
    $state=Get-RunSnapshotState $Snapshot
    if($state.ScopeDepth -ne 0){throw 'Cannot close an active snapshot scope.'}
    foreach($process in $state.Processes){if(-not $process.HasExited){throw 'Cannot remove inputs of a running experimental engine.'}}
    $state.Closing=$true
    foreach($stream in @($state.Copies)+@($state.Pins)){$stream.Dispose()}
    if($state.RootOwned){
        # Root deletion is nonrecursive after releasing the pin. If that last step failed,
        # reacquire namespace protection before validating and traversing on a retry.
        if($state.DirectoryPin.IsClosed){$state.DirectoryPin=Open-RunSnapshotDirectory $state.Root}
        Remove-RunSnapshotStorage $state.Root $state.DirectoryPin ([string]$Snapshot.Generation) $state.Parent
    }
    $Script:RunSnapshotStates.Remove([string]$Snapshot.Generation)
}
function Add-RunSnapshotProcess($Snapshot,$Process){
    $state=Get-RunSnapshotState $Snapshot
    if(-not $state.Root -or $state.ScopeDepth -ne 1 -or $null -eq $Process){throw 'Experimental process must be registered inside its input scope.'}
    $state.Processes+=@($Process)
}
function Stop-RunSnapshotProcesses($Snapshot){
    $state=Get-RunSnapshotState $Snapshot
    foreach($process in $state.Processes){
        if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit(5000)){throw 'Experimental process did not exit; its input snapshot is retained.'}}
    }
}
