param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$settings=Get-Settings;$settings.alt='12';$settings.auto='on';$settings.game='all'
Update-RuntimeLists | Out-Null
$arguments=New-BypassArgList -Settings $settings
$autoIndex=[array]::IndexOf($arguments,('--lua-init=@'+(Get-PkgPath 'lua/zapret-auto.lua')))
$cacheIndex=[array]::IndexOf($arguments,('--lua-init=@'+(Get-PkgPath 'lua/host-cache.lua')))
if($autoIndex -lt 0 -or $cacheIndex -ne $autoIndex+1){throw 'Host cache must load immediately after upstream automation.'}
$learned=@($arguments|Where-Object{$_ -like '--lua-desync=circular:*success_detector=ring_success*'})
if(-not $learned.Count -or @($learned|Where-Object{$_ -notmatch ':hostcache=bounded(?:[:]|$)'}).Count){throw 'Learning circular must use the bounded cache.'}
$profile='';$gameCircular=$false
foreach($argument in $arguments){
    if($argument -match '^--(?:name|new)=(.+)$'){$profile=$Matches[1]}
    if($profile -like 'game_*'){
        if($argument -match ':hostcache='){throw 'Game profiles must retain upstream host records.'}
        if($argument -like '--lua-desync=circular:*'){$gameCircular=$true}
    }
}
if(-not $gameCircular){throw 'Fixture did not exercise game circular.'}
$settings.auto='off'
if(@((New-BypassArgList -Settings $settings)|Where-Object{$_ -match ':hostcache='}).Count){throw 'Fixed strategies must not opt into host learning.'}
$cachePath=Get-PkgPath 'lua/host-cache.lua';$original=[IO.File]::ReadAllBytes($cachePath)
$stamp=Get-RingCompositionKey $settings
try{
    [IO.File]::AppendAllText($cachePath,"`n-- fingerprint fixture",$Script:Utf8NoBom)
    if((Get-RingCompositionKey $settings) -eq $stamp){throw 'Cache implementation must affect the composition fingerprint.'}
}finally{[IO.File]::WriteAllBytes($cachePath,$original)}
Write-Host 'ok host cache load order, learning opt-in, game isolation and fingerprint'
if(-not(Test-Admin)){
    if(-not $env:ZAPRET_LUA_TEST_RUNTIME){Write-Host 'skip host cache Lua: administrator or developer Lua runtime required';exit 0}
    & python (Join-Path $PSScriptRoot 'lua-unit.py') --pkg $Pkg --runtime $env:ZAPRET_LUA_TEST_RUNTIME --test hostcachetest.lua
    exit $LASTEXITCODE
}
$modules=@('zapret-auto.lua','host-cache.lua','ring-store.lua','autoring.lua')
$arguments=@('--intercept=0')+@($modules|ForEach-Object {'--lua-init=@'+(Join-Path $Pkg ('lua/'+$_))})+@('--lua-init=@'+(Join-Path $PSScriptRoot 'hostcachetest.lua'))
$result=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $arguments) $Script:Bin 30
Write-Host $result.Output
if($result.ExitCode -ne 0 -or $result.TimedOut -or $result.Output -notmatch 'all host cache checks passed'){exit 1}
