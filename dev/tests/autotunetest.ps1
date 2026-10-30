# автонастройка без изменений в системе - задача собирается, но не регистрируется.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { Write-Host 'Тест пишет файлы в runtime: запускайте его через run-all.ps1, на копии папки.' -ForegroundColor Red; exit 1 }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }

# объекты задачи - те же параметры, что в Install-AutotuneTask, без Register
$body = (Get-Command Install-AutotuneTask).Definition
$body = $body -replace '(?s)try \{\s*Register-ScheduledTask.*?\} catch \{.*?\}\s*return \[bool\]\(Get-AutotuneTask\)', 'return (New-ScheduledTask -Action $action -Trigger $trigger -Settings $set -Principal $pr)'
$task = & ([scriptblock]::Create($body))
Check 'task object built' ($task -ne $null)
Check 'runs as SYSTEM highest' ($task.Principal.UserId -eq 'SYSTEM' -and $task.Principal.RunLevel -eq 'Highest')
Check 'idle settings' ($task.Settings.RunOnlyIfIdle -and -not $task.Settings.IdleSettings.StopOnIdleEnd -and $task.Settings.StartWhenAvailable)
Check 'battery settings' (-not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries)
Check 'time limit 30m' ($task.Settings.ExecutionTimeLimit -eq 'PT30M')
Write-Host ('  action: ' + $task.Actions[0].Execute + ' ' + $task.Actions[0].Arguments)
Write-Host ('  trigger: ' + $task.Triggers[0].StartBoundary + ' idle ' + $task.Settings.IdleSettings.IdleDuration + ' wait ' + $task.Settings.IdleSettings.WaitTimeout)
Check 'script exists' (Test-Path (Get-AutotuneScript))
Check 'text when off' ((Get-AutotuneText) -eq 'выключена')

$t = [Diagnostics.Stopwatch]::StartNew()
$why = @(Get-AutotuneBlockers)
Write-Host ('  blockers now (' + [math]::Round($t.Elapsed.TotalSeconds, 1) + ' s): ' + $(if ($why.Count) { $why -join ' | ' } else { 'нет' }))

# журнал и блокировка - в отдельной папке
$Script:Runtime = Join-Path $env:TEMP ('nba-autotune-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $Script:Runtime | Out-Null
for ($i = 0; $i -lt 305; $i++) { Add-AutotuneLog ("строка $i") }
$log = [System.IO.File]::ReadAllLines((Join-Path $Script:Runtime 'autotune.log'))
Check ('log trimmed to 300: ' + $log.Count) ($log.Count -eq 300 -and $log[-1] -like '* строка 304')
Check 'no lock -> not running' (-not (Test-AutotuneRunning))
Write-TextNoBom (Join-Path $Script:Runtime 'autotune.lock') ([string]$PID)
Check 'own pid -> not running' (-not (Test-AutotuneRunning))
$other = Start-Process powershell -ArgumentList '-NoProfile -Command Start-Sleep 20' -WindowStyle Hidden -PassThru
Write-TextNoBom (Join-Path $Script:Runtime 'autotune.lock') ([string]$other.Id)
Check 'other powershell -> running' (Test-AutotuneRunning)
Stop-Process -Id $other.Id -Force; Start-Sleep -Milliseconds 300
Check 'dead pid -> not running' (-not (Test-AutotuneRunning))
Remove-Item $Script:Runtime -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
