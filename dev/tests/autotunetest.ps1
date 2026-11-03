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
$autotuneAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/autotune.ps1'),[ref]$null,[ref]$null)
$gate = $autotuneAst.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if (-not $Force -and $before')},$true)
if (-not $gate) { throw 'Scheduled selection interval gate missing' }
$condition = [scriptblock]::Create($gate.Clauses[0].Item1.Extent.Text)
$Force = $false; $before = Get-Date
function Get-TestRank { return $null }
Check 'old network ranking does not postpone selection for another week' (-not (& $condition))
function Get-TestRank { return [pscustomobject]@{Date='fixture'} }
Check 'compatible recent ranking retains weekly interval' (& $condition)
$invocation = $autotuneAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.StartsWith('& (Join-Path $PSScriptRoot ''test.ps1'')')},$true)
if (-not $invocation) { throw 'Scheduled strategy test invocation missing' }
Write-TextNoBom (Join-Path $Script:Runtime 'scheduler-probe.ps1') $invocation.Extent.Text
Write-TextNoBom (Join-Path $Script:Runtime 'test.ps1') @'
param([switch]$NoPrompt,[switch]$ReportOnly,[switch]$KeepPrimary,[switch]$Full)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'flags.json'),(@{NoPrompt=[bool]$NoPrompt;ReportOnly=[bool]$ReportOnly;KeepPrimary=[bool]$KeepPrimary;Full=[bool]$Full} | ConvertTo-Json -Compress))
'@
$ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$probe = Invoke-Native $ps ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $Script:Runtime 'scheduler-probe.ps1')+'"') $Script:Runtime 15
$flags = [IO.File]::ReadAllText((Join-Path $Script:Runtime 'flags.json')) | ConvertFrom-Json
Check 'scheduler requests verified rank refresh while retaining primary' ($probe.ExitCode -eq 0 -and $flags.NoPrompt -and $flags.Full -and $flags.KeepPrimary -and -not $flags.ReportOnly)
Remove-Item $Script:Runtime -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
