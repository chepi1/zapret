# Official Flowseal TG WS Proxy component; user state is kept outside the bundled binary.
function Get-TgWsRelease {
    return [pscustomobject]@{Tag='v1.11.4';RelativePath='bin/tgws/TgWsProxy_windows.exe';Bytes=21805650L;Sha256='454205cbcf76f333934108d893b58a528373bce8096624e27f0b6dc16eea660f';Url='https://github.com/Flowseal/tg-ws-proxy/releases/download/v1.11.4/TgWsProxy_windows.exe'}
}
function Initialize-TgWsRunner {
    if(-not ('ZapretTgWs.Runner' -as [type])){Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tgwsrunner.cs'))) -Language CSharp}
}
function Get-TgWsBridgeJob {
    try{
        $process=Get-TgBridgeProcess
        if($null -eq $process){return ''}
        $marker=Join-Path $Script:Runtime 'tgws-engine.txt'
        if((Get-Item -LiteralPath $marker -ErrorAction Stop).Length -gt 512){return ''}
        $parts=@([IO.File]::ReadAllText($marker).Trim() -split '\|')
        $expected='{0}|{1}|{2}' -f $process.Id,$process.StartTime.Ticks,(Get-TgWsRelease).Tag
        if($parts.Count -eq 4 -and ($parts[0..2] -join '|') -ceq $expected -and $parts[3] -cmatch '^Local\\zapret-tgws-[a-f0-9]{32}$'){return $parts[3]}
    }catch{}
    return ''
}
function Assert-TgWsBinary([string]$Root=''){
    if(-not $Root){$Root=Split-Path -Parent $PSScriptRoot}
    $release=Get-TgWsRelease;$path=Join-Path $Root $release.RelativePath
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -ne $release.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $release.Sha256){throw 'Файл TG WS Proxy повреждён или отличается от официальной версии. Восстановите компонент из сборки zapret.'}
    return $path
}
function Test-TgWsBridgeCurrent {
    return [bool](Get-TgWsBridgeJob)
}
function Test-TgWsLegacyRunCommand([string]$Command,[string]$Directory){
    try{
        Initialize-TgWsRunner
        $exe=[Environment]::ExpandEnvironmentVariables([ZapretTgWs.Runner]::ExecutableFromCommand($Command))
        if(-not [IO.Path]::IsPathRooted($exe)){return $false}
        return [IO.Path]::GetFullPath($exe).StartsWith(([IO.Path]::GetFullPath($Directory).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)
    }catch{return $false}
}
function Initialize-TgWsConfig {
    param([ValidateRange(1,65535)][int]$Port,[ValidatePattern('^[a-fA-F0-9]{32}$')][string]$Secret)
    if($Script:Runtime -cne (Join-Path $Script:Root 'runtime')){throw 'Telegram component requires the package runtime.'}
    $path=Resolve-UpdateFilePath $Script:Root 'runtime/tgws/TgWsProxy/config.json'
    $directory=Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force|Out-Null
    $config=[ordered]@{port=$Port;host='127.0.0.1';secret=$Secret.ToLowerInvariant();dc_ip=@('2:149.154.167.220','4:149.154.167.220');verbose=$false;check_updates=$false;autostart=$false;log_max_mb=2;buf_kb=256;pool_size=4;cfproxy=$true;h2=$true;no_secure=$false;force_test_dc=$false;language='ru'}
    if([IO.File]::Exists($path)){
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.Length -gt 65536){throw 'TG WS Proxy config exceeds its size budget.'}
        $previous=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -ErrorAction Stop
        if($previous -isnot [pscustomobject]){throw 'TG WS Proxy config must be a JSON object.'}
        foreach($property in $previous.PSObject.Properties){$config[$property.Name]=$property.Value}
    }
    # Only listener identity and lifecycle belong to zapret. Keep upstream's advanced settings.
    $config.port=$Port;$config.host='127.0.0.1';$config.secret=$Secret.ToLowerInvariant();$config.autostart=$false;$config.check_updates=$false
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        Write-TextNoBom $temporary (ConvertTo-Json -InputObject $config -Depth 12)
        $stream=[IO.File]::Open($temporary,'Open','Write','None');try{$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[NullString]::Value)}else{[IO.File]::Move($temporary,$path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    foreach($marker in @('.first_run_done_mtproto','.ipv6_warned')){Write-TextNoBom (Join-Path $directory $marker) ''}
    return [pscustomobject]@{Exe=(Join-Path $Script:Root (Get-TgWsRelease).RelativePath);AppData=(Split-Path -Parent $directory);Config=$path;Log=(Join-Path $directory 'proxy.log')}
}
