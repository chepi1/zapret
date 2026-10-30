# Проверка lua\autoring.lua и lua\fooling.lua внутри настоящего winws2 с --intercept=0: трафик не перехватывается,
# но драйверу WinDivert (с пустым фильтром) нужны права администратора. Без них тест пропускается.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { Write-Host 'Тест пишет файлы в runtime: запускайте его через run-all.ps1, на копии папки.' -ForegroundColor Red; exit 1 }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host '  пропущено: нужны права администратора (запустите run-all.ps1 из окна администратора)'; exit 0 }
$w = Join-Path $Pkg 'runtime\luatest'
$lua = @('zapret-lib.lua', 'zapret-antidpi.lua', 'zapret-auto.lua', 'fooling.lua', 'autoring.lua') | ForEach-Object { '"--lua-init=@' + (Join-Path $Pkg ('lua\' + $_)) + '"' }
$test = '"--lua-init=@' + (Join-Path $PSScriptRoot 'luatest.lua') + '"'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $Pkg 'bin\winws2.exe'
$psi.Arguments = '--intercept=0 "--writable=' + $w + '" ' + ($lua -join ' ') + ' ' + $test
$psi.WorkingDirectory = Join-Path $Pkg 'bin'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$psi.StandardErrorEncoding = [Text.Encoding]::UTF8
$p = [Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit(30000)) { $p.Kill(); Write-Host 'FAIL winws2 не завершился за 30 секунд' -ForegroundColor Red; exit 1 }
$p.WaitForExit()
$text = $so.Result + $se.Result
foreach ($l in ($text -split "`r?`n")) {
    if ($l -match '^FAIL|FAILED|error|rror:') { Write-Host $l -ForegroundColor Red }
    elseif ($l -match '^(ok  |     |all ok)') { Write-Host $l }
}
if ($p.ExitCode -ne 0 -or $text -notmatch 'all ok') { Write-Host ('FAIL код выхода ' + $p.ExitCode) -ForegroundColor Red; Write-Host $text; exit 1 }
Write-Host 'all ok' -ForegroundColor Green
