param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if (-not (Test-Admin)) {
    if ($env:ZAPRET_LUA_TEST_RUNTIME) {
        & python (Join-Path $PSScriptRoot 'lua-unit.py') --pkg $Pkg --runtime $env:ZAPRET_LUA_TEST_RUNTIME --test storetest.lua
        Write-Host 'skip native store timer/file I/O: administrator token required'
        exit $LASTEXITCODE
    }
    Write-Host 'skip Lua store unit: administrator or developer Lua runtime required'; exit 0
}
$arguments=@('--intercept=0',('--lua-init=@'+(Join-Path $Pkg 'lua/ring-store.lua')),('--lua-init=@'+(Join-Path $PSScriptRoot 'storetest.lua')))
$result=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $arguments) $Script:Bin 15
Write-Host $result.Output
if ($result.ExitCode -ne 0 -or $result.TimedOut -or $result.Output -notmatch 'default bound retains two thousand'){exit 1}
$writable=Join-Path $Script:Runtime ('store-io-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $writable | Out-Null
$arguments=@('--wf-raw=false',('--writable='+$writable),('--lua-init=@'+(Join-Path $Pkg 'lua/zapret-lib.lua')),
    ('--lua-init=@'+(Join-Path $Pkg 'lua/ring-store.lua')),('--lua-init=@'+(Join-Path $PSScriptRoot 'storeiotest.lua')))
$result=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $arguments) $Script:Bin 15
Write-Host $result.Output
if ($result.ExitCode -ne 0 -or $result.TimedOut -or $result.Output -notmatch 'ok native timer atomically replaces'){exit 1}
