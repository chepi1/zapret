# распознавание игровых ускорителей - на подставном процессе ExitLag.exe (копия ping.exe).
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
. (Join-Path $Pkg 'tools\lib.ps1')
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }

$t = [Diagnostics.Stopwatch]::StartNew()
$before = @(Get-GameBoosters)
Write-Host ('  now (' + $t.ElapsedMilliseconds + ' ms): ' + $(if ($before.Count) { $before -join ', ' } else { 'нет' }))
Check 'no false positives on this PC' ($before.Count -eq 0)

$dir = Join-Path $env:TEMP ('nba-boost-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') (Join-Path $dir 'ExitLag.exe')
$p = Start-Process (Join-Path $dir 'ExitLag.exe') -ArgumentList '-n 15 127.0.0.1' -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 500
$found = @(Get-GameBoosters)
Write-Host ('  with fake ExitLag: ' + ($found -join ', '))
Check 'ExitLag detected' ($found -contains 'ExitLag')
$why = @(Get-AutotuneBlockers)
Check ('autotune skips: ' + ($why -join ' | ')) (@($why | Where-Object { $_ -like '*ExitLag*' }).Count -eq 1)
Write-Host '  --- connection check output:'
Show-ConnectionCheck | Out-Null
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Check 'gone after exit' (@(Get-GameBoosters).Count -eq 0)
Remove-Item $dir -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
