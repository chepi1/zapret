# One exact launch command and short-lived leases on its original static inputs.
if(-not(Get-Variable BypassLaunchStates -Scope Script -ErrorAction SilentlyContinue)){$Script:BypassLaunchStates=@{}}

function Get-BypassLaunchInputs {
    $items=@()
    foreach($relative in @(Get-RunSnapshotFiles)){
        if($relative.StartsWith('runtime/') -or $relative -eq $Script:AutolistFile){continue}
        $items+=@([pscustomobject]@{Name=$relative;Path=(Join-Path $Script:Root $relative)})
    }
    foreach($name in @('test-rank.txt','test-cover.txt','tested-strategies.txt','ipset-any.txt')){
        $path=Join-Path $Script:Runtime $name
        if([IO.File]::Exists($path)){$items+=@([pscustomobject]@{Name=('runtime/'+$name);Path=$path})}
    }
    foreach($file in @(Get-ChildItem -LiteralPath $Script:Bin -File -ErrorAction Stop)){
        $items+=@([pscustomobject]@{Name=('native/'+$file.Name);Path=$file.FullName})
    }
    return @($items|Sort-Object Name)
}
function Get-BypassLaunchState($Recipe){
    if($null -eq $Recipe -or -not $Recipe.PSObject.Properties['Generation'] -or -not $Script:BypassLaunchStates.ContainsKey([string]$Recipe.Generation)){throw 'Launch recipe is closed or unknown.'}
    $state=$Script:BypassLaunchStates[[string]$Recipe.Generation]
    if(-not [object]::ReferenceEquals($state.Public,$Recipe)){throw 'Launch recipe is not owned by this operation.'}
    return $state
}
function Assert-BypassLaunchCurrent($Recipe){
    $state=Get-BypassLaunchState $Recipe
    if($Script:Root -cne $state.Root -or $Script:Runtime -cne $state.Runtime -or $Script:Exe -cne $state.Exe -or $Script:Bin -cne $state.Bin){throw 'Launch recipe source context changed.'}
    $catalog=ConvertTo-Json -InputObject @(Get-BypassLaunchInputs) -Compress
    if($catalog -cne $state.Catalog){throw 'Launch recipe input catalog changed; repeat the operation.'}
}
function New-BypassLaunchRecipe {
    param([Parameter(Mandatory=$true)][hashtable]$Settings,[ValidateSet('active','test','final-check','diag','check')][string]$Name='active',[string]$Alt,[switch]$NoAuto,[string]$IpsetMode,[string]$DebugFile,[int]$LifetimeMs=0)
    if($LifetimeMs -ne 0 -and ($LifetimeMs -lt 1000 -or $LifetimeMs -gt 1800000)){throw 'Invalid experimental engine lifetime.'}
    $settingsJson=ConvertTo-RunSettingsJson $Settings
    $captured=@{};foreach($property in ($settingsJson|ConvertFrom-Json).PSObject.Properties){$captured[$property.Name]=[string]$property.Value}
    $pins=@();$directories=@{};$registered=$false;$sha=$null;$generation=$null
    try{
        $inputs=@(Get-BypassLaunchInputs)
        if(-not $inputs.Count -or $inputs.Count -gt 2048){throw 'Launch input catalog exceeds its budget.'}
        # Pin ancestors before children. Recheck reparse attributes after opening each directory.
        foreach($launchInput in $inputs){
            $chain=@();$cursor=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($launchInput.Path))
            while($cursor -and -not $directories.ContainsKey($cursor)){$chain=@($cursor)+$chain;$cursor=[IO.Path]::GetDirectoryName($cursor)}
            foreach($directory in $chain){
                $item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Launch input directory uses a reparse point.'}
                # Do not lease drive/user/TEMP ancestors outside the source package/native/runtime roots.
                $roots=@($Script:Root,$Script:Runtime,[IO.Path]::GetDirectoryName($Script:Bin))
                if(@($roots|Where-Object{$directory -ieq $_ -or $directory.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){
                    $pins+=@(Open-RunSnapshotDirectory $directory)
                    if((Get-Item -LiteralPath $directory -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Launch input directory changed.'}
                }
                $directories[$directory]=$true
            }
        }
        $manifest=@();$hashes=@{};$total=0L;$sha=[Security.Cryptography.SHA256]::Create()
        foreach($launchInput in $inputs){
            if((Get-Item -LiteralPath $launchInput.Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Launch input file uses a reparse point.'}
            $stream=Open-RunSnapshotInputFile $launchInput.Path;$pins+=@($stream)
            $total+=$stream.Length;if($total -gt 64MB){throw 'Launch inputs exceed64MiB.'}
            $hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','');$hashes[$launchInput.Name]=$hash
            $manifest+=@([pscustomobject][ordered]@{Name=$launchInput.Name;Hash=$hash;Length=$stream.Length})
        }
        # Experimental scopes intentionally execute inherited ASTs against their captured copy.
        $code=if($null -ne $Script:RecipeContext){$Script:RecipeContext.ExpectedCode}else{Get-LoadedPackageCodeSnapshot ${function:New-BypassLaunchRecipe}.Ast 'tools/launch.ps1'}
        if($null -eq $code -or -not $code.Count){throw 'Loaded launch code cannot be identified.'}
        foreach($codeName in $code.Keys){if(-not $hashes.ContainsKey($codeName) -or $hashes[$codeName] -cne $code[$codeName]){throw ('Loaded launch code differs from its source: '+$codeName)}}
        foreach($coreName in $Script:UpstreamHashes.Keys){
            $relative=$coreName.Replace('\','/')
            if(-not $hashes.ContainsKey($relative) -or $hashes[$relative] -ine $Script:UpstreamHashes[$coreName]){throw ('Launch core differs from its pinned release: '+$relative)}
            if($relative.StartsWith('bin/') -and $hashes['native/'+$relative.Substring(4)] -ine $Script:UpstreamHashes[$coreName]){throw ('Native launch core differs from its pinned release: '+$relative)}
        }
        $catalog=ConvertTo-Json -InputObject $inputs -Compress
        if($catalog -cne (ConvertTo-Json -InputObject @(Get-BypassLaunchInputs) -Compress)){throw 'Launch input catalog changed during capture.'}
        # Metadata-based strategy caches can miss same-size edits; compose only from the leased bytes.
        $Script:StrategiesCache=$null;$Script:RingCache=@{}
        $command=Get-BypassCmdLine -Settings $captured -Name $Name -Alt $Alt -NoAuto:$NoAuto -IpsetMode $IpsetMode -DebugFile $DebugFile
        if($LifetimeMs){
            $guard="--lua-init=timer_set('test_lifetime_guard',function() os.exit(3) end,"+$LifetimeMs.ToString([Globalization.CultureInfo]::InvariantCulture)+',true)'
            $command+=' '+(ConvertTo-WinArg $guard)
            [IO.File]::AppendAllText((Join-Path $Script:Runtime ('args-'+$Name+'.txt')),($guard+"`r`n"),$Script:Utf8NoBom)
        }
        if($command.Length -gt 32000){throw 'Launch command exceeds the Windows command line budget.'}
        $static=@($manifest|Where-Object{-not $_.Name.StartsWith('runtime/')})
        $inputsHash=Get-RunSnapshotHash @('launch-inputs-v1',(ConvertTo-Json -InputObject $static -Compress))
        $configHash=Get-RunSnapshotHash @('launch-config-v1',$inputsHash,(ConvertTo-Json -InputObject @($Script:Exe,$Script:Bin,$command) -Compress))
        $generation=[guid]::NewGuid().ToString('N')
        $public=[pscustomobject]@{Generation=$generation;ConfigHash=$configHash}
        $state=@{Public=$public;Root=$Script:Root;Runtime=$Script:Runtime;Exe=$Script:Exe;Bin=$Script:Bin;CommandLine=$command;SettingsJson=$settingsJson;Catalog=$catalog;InputsHash=$inputsHash;ConfigHash=$configHash;Experimental=($Name -ne 'active' -or $LifetimeMs -ne 0 -or $NoAuto -or $Alt -or $IpsetMode -or $DebugFile);Pins=$pins}
        $Script:BypassLaunchStates[$generation]=$state
        Assert-BypassLaunchCurrent $public
        $registered=$true
        return $public
    }finally{
        if($sha){$sha.Dispose()}
        if(-not $registered){if($generation){$Script:BypassLaunchStates.Remove($generation)};foreach($pin in $pins){$pin.Dispose()}}
    }
}
function Close-BypassLaunchRecipe($Recipe){
    $state=Get-BypassLaunchState $Recipe
    $Script:BypassLaunchStates.Remove([string]$Recipe.Generation)
    foreach($pin in $state.Pins){$pin.Dispose()}
}

# Confirmation contains data only: never deserialize executable command lines from local state.
function Open-BypassConfirmationStore([switch]$Create){
    if($Script:Runtime -cne (Join-Path $Script:Root 'runtime')){throw 'Confirmation storage is outside the package runtime.'}
    $path=Resolve-UpdateFilePath $Script:Root 'runtime/launch-state/confirmed.json'
    $store=[IO.Path]::GetDirectoryName($path)
    if(-not [IO.Directory]::Exists($store)){
        if(-not $Create){return $null}
        $security=New-Object Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true,$false);$trusted=@(Get-UpdateTrustSids)
        $security.SetOwner((New-Object Security.Principal.SecurityIdentifier($trusted[-1])))
        foreach($sid in $trusted){
            $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            $security.AddAccessRule($rule)
        }
        [IO.Directory]::CreateDirectory($store,$security)|Out-Null
    }
    $pin=Open-RunSnapshotDirectory $store
    try{
        if(-not(Test-UpdateTrustedPath $store)){throw 'Confirmation storage is not trusted.'}
        if([IO.File]::Exists($path) -and -not(Test-UpdateTrustedPath $path)){throw 'Confirmation file is not trusted.'}
        return @{Pin=$pin;Path=$path;Store=$store}
    }catch{$pin.Dispose();throw}
}
function Get-ConfirmedEngineSettings($Value){
    $keys=@('alt','auto','game','ipset','gametcp','gameudp','autolist')
    if($null -eq $Value -or @($Value.PSObject.Properties).Count -ne $keys.Count){throw 'Incomplete confirmed engine settings.'}
    $settings=@{}
    foreach($key in $keys){
        if(-not $Value.PSObject.Properties[$key] -or $Value.$key -isnot [string]){throw 'Invalid confirmed engine setting.'}
        $settings[$key]=[string]$Value.$key
    }
    if($settings.alt -notmatch '^[0-9]{1,5}$' -or $settings.auto -notin @('on','off') -or $settings.game -notin @('all','tcp','udp','off') -or $settings.ipset -notin @('loaded','any','none') -or $settings.autolist -notin @('on','off') -or -not(Test-PortList $settings.gametcp) -or -not(Test-PortList $settings.gameudp)){throw 'Confirmed engine settings are outside their allowed domain.'}
    return $settings
}


function Save-ConfirmedBypassRecipe($Recipe){
    $store=$null;$temporary=$null
    try{
        $state=Get-BypassLaunchState $Recipe
        if($state.Experimental -or $null -ne $Script:RecipeContext -or -not $state.ContainsKey('StartupConfirmed') -or -not $state.StartupConfirmed){return $false}
        Assert-BypassLaunchCurrent $Recipe
        $decoded=$state.SettingsJson|ConvertFrom-Json
        $engine=[ordered]@{};foreach($key in @('alt','auto','game','ipset','gametcp','gameudp','autolist')){$engine[$key]=[string]$decoded.$key}
        Get-ConfirmedEngineSettings ([pscustomobject]$engine)|Out-Null
        $record=[ordered]@{SchemaVersion=1;Root=$state.Root;Version=$Script:Version;InputsHash=$state.InputsHash;ConfigHash=$state.ConfigHash;Settings=[pscustomobject]$engine}
        $bytes=$Script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $record -Depth 4 -Compress))
        if($bytes.Length -gt 16384){throw 'Confirmation exceeds its size budget.'}
        $store=Open-BypassConfirmationStore -Create
        $temporary=Join-Path $store.Store ([guid]::NewGuid().ToString('N')+'.tmp')
        $stream=[IO.File]::Open($temporary,'CreateNew','Write','None')
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if(-not(Test-UpdateTrustedPath $temporary)){throw 'Temporary confirmation is not trusted.'}
        if([IO.File]::Exists($store.Path)){[IO.File]::Replace($temporary,$store.Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$store.Path)}
        $temporary=$null
        return $true
    }catch{Add-BypassAction 'confirm-launch' $_.Exception.Message;return $false}
    finally{if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)};if($store){$store.Pin.Dispose()}}
}
function Read-ConfirmedBypassSettings {
    $store=$null;$stream=$null
    try{
        $store=Open-BypassConfirmationStore
        if($null -eq $store -or -not [IO.File]::Exists($store.Path)){return $null}
        $stream=Open-RunSnapshotInputFile $store.Path
        if($stream.Length -lt 2 -or $stream.Length -gt 16384){return $null}
        $bytes=New-Object byte[] ([int]$stream.Length);$offset=0
        while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -le 0){throw 'Incomplete confirmation read.'};$offset+=$read}
        $utf8=New-Object Text.UTF8Encoding($false,$true)
        $record=ConvertFrom-Json -InputObject ($utf8.GetString($bytes)) -ErrorAction Stop
        $keys=@('SchemaVersion','Root','Version','InputsHash','ConfigHash','Settings')
        if(@($record.PSObject.Properties).Count -ne $keys.Count -or @($keys|Where-Object{-not $record.PSObject.Properties[$_]}).Count){return $null}
        if($record.SchemaVersion -isnot [int] -or $record.SchemaVersion -ne 1 -or $record.Root -cne $Script:Root -or $record.Version -cne $Script:Version -or $record.InputsHash -cnotmatch '^[A-F0-9]{64}$' -or $record.ConfigHash -cnotmatch '^[A-F0-9]{64}$'){return $null}
        $engine=Get-ConfirmedEngineSettings $record.Settings
        return [pscustomobject]@{Settings=$engine;InputsHash=[string]$record.InputsHash;ConfigHash=[string]$record.ConfigHash}
    }catch{return $null}finally{if($stream){$stream.Dispose()};if($store){$store.Pin.Dispose()}}
}
function Try-RestoreConfirmedBypass($Attempt){
    try{
        if($null -eq $Attempt -or -not $Attempt.ReplacementStarted -or @(Get-RunningGames).Count -or @(Get-OurProcesses).Count){return $false}
        $service=Get-OurService
        if($service -and $service.Status -ne 'Stopped'){return $false}
        $confirmed=Read-ConfirmedBypassSettings
        if($null -eq $confirmed -or $confirmed.ConfigHash -ceq $Attempt.ConfigHash){return $false}
        $current=Get-Settings
        if((ConvertTo-RunSettingsJson $current) -cne $Attempt.SettingsJson){return $false}
        $restored=$current.Clone();foreach($key in $confirmed.Settings.Keys){$restored[$key]=$confirmed.Settings[$key]}
        Assert-BypassControlAllowed
        $ok=Start-BypassCore -Quiet -SettingsOverride $restored -ExpectedConfigHash $confirmed.ConfigHash -ExpectedInputsHash $confirmed.InputsHash
        if(-not $ok){return $false}
        # Another settings writer must not be overwritten after the startup wait.
        if((ConvertTo-RunSettingsJson (Get-Settings)) -ceq $Attempt.SettingsJson){
            try{Save-Settings $restored}catch{Write-Color 'Обход восстановлен, но сохранить прежние настройки не удалось. Проверьте права на runtime.' Yellow}
        }else{Write-Color 'Обход восстановлен; настройки изменились во время запуска и оставлены как есть.' Yellow}
        Add-BypassAction 'restore-launch' 'вернулась последняя конфигурация с подтверждённым запуском; новые настройки не применены'
        Write-Color 'Новые настройки не запустились. Вернул последнюю конфигурацию с подтверждённым запуском.' Yellow
        return $true
    }catch{Add-BypassAction 'restore-launch' $_.Exception.Message;return $false}
}
