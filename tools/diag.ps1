# Диагностика (Инструменты -> 5 в меню): winws2 в видимом окне - видно его сообщения и ошибку, если он не запускается.
# Параметры собираются здесь же, а не читаются из файла в runtime: так их не подменить между записью и запуском.
# Командная строка winws2 (~13 тыс. символов) длиннее предела cmd.exe (8191), поэтому он запускается напрямую.
# -DebugLog: подробный лог каждого пакета в runtime\debug.log (сам по себе поднимает пинг - только для поиска ошибки).
param([switch]$DebugLog)

. (Join-Path $PSScriptRoot 'lib.ps1')

try { $Host.UI.RawUI.WindowTitle = 'winws2 - диагностика' } catch { }
if (-not (Test-Admin)) { Write-Color 'Нужны права администратора. Запускайте через zapret.bat: Инструменты -> 5.' Red; Read-Host 'Enter - закрыть' | Out-Null; exit 1 }
$bad = @(Test-PackageIntegrity)
if ($bad.Count) { Write-IntegrityError $bad; Read-Host 'Enter - закрыть' | Out-Null; exit 1 }

Enable-TcpTimestamps
Update-RuntimeLists
$log = if ($DebugLog) { Get-PkgPath 'runtime/debug.log' } else { $null }
try { $cmd = Get-BypassCmdLine -Settings (Get-Settings) -Name 'diag' -DebugFile $log }
catch { Write-Color $_.Exception.Message Red; Read-Host 'Enter - закрыть' | Out-Null; exit 1 }

Write-Color 'winws2 работает в этом окне. Остановить - закрыть окно или Ctrl+C.' Cyan
if ($log) { Write-Color 'Пишется подробный лог runtime\debug.log. Повторите проблему, потом остановите winws2 и сделайте отчёт (Инструменты -> 4).' Cyan }
$p = Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -NoNewWindow -PassThru -Wait
Write-Host ''
Write-Color ('winws2 завершился с кодом ' + $p.ExitCode + '. Сообщение об ошибке - выше.') Yellow
Read-Host 'Enter - закрыть' | Out-Null
