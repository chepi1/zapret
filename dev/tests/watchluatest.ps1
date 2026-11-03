param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if(-not(Test-Admin)){
    if($env:ZAPRET_LUA_TEST_RUNTIME){
        & python (Join-Path $PSScriptRoot 'lua-unit.py') --pkg $Pkg --runtime $env:ZAPRET_LUA_TEST_RUNTIME
        exit $LASTEXITCODE
    }
    Write-Host 'skip Lua watchdog unit: administrator or developer Lua runtime required';exit 0
}
$args0=@('--intercept=0',('--lua-init=@'+(Join-Path $Pkg 'lua/autoring.lua')),('--lua-init=@'+(Join-Path $PSScriptRoot 'watchtest.lua')))
$r=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $args0) $Script:Bin 10
Write-Host $r.Output
if($r.ExitCode -ne 0 -or $r.TimedOut -or $r.Output -notmatch 'network marker parser exists'){exit 1}
