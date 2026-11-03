param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
Update-RuntimeLists | Out-Null
$guard="--lua-init=timer_set('test_lifetime_guard',function() os.exit(23) end,100,true)"
$cmd=Get-BypassCmdLine -Settings (Get-Settings) -Name 'guard-check' -DryRun
$compat=$env:__COMPAT_LAYER
try { $env:__COMPAT_LAYER='RunAsInvoker'; $result=Invoke-Native $Script:Exe ($cmd+' '+(ConvertTo-WinArg $guard)) $Script:Bin 15 }
finally { $env:__COMPAT_LAYER=$compat }
if($result.ExitCode -ne 0 -or $result.TimedOut){throw ('Timer initialization dry-run failed: '+$result.Output)}
Write-Host 'ok actual engine accepts generated timer argument'
if(-not(Test-Admin)){Write-Host 'skip actual timer expiry: administrator token required';exit 0}
# --intercept=0 exits after lua-init, before timer events. A false filter leaves the event loop active without capturing traffic.
$result=Invoke-Native $Script:Exe ('--wf-raw=false '+(ConvertTo-WinArg $guard)) $Script:Bin 5
if($result.TimedOut -or $result.ExitCode -ne 23){throw ('Timer did not terminate empty-filter process: '+$result.ExitCode+' '+$result.Output)}
Write-Host 'ok actual timer terminates its own empty-filter process'
