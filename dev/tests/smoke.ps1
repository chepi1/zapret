# Дымовой прогон настоящих скриптов без перехвата трафика и без прав администратора:
#  - функции меню: шапка, проверка подключения, тексты кругов и автонастройки (strict mode из lib.ps1);
#  - отчёт R целиком (report.ps1 -NoPrompt -NoOpen);
#  - трекер по записанному журналу сети: -Etl <файл.etl> -EtlPid <PID игры> (track.ps1 -Replay).
# Лучше запускать на копии папки (run-all.ps1 так и делает): отчёт и трекер пишут файлы в runtime.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), [string]$Etl, [int]$EtlPid = 0)
$fails = 0
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $Pkg 'tools\lib.ps1')
# функции меню без его главного цикла
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools\menu.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$s = Get-Settings
# вопросы меню - сразу пустой ответ ("ничего не менять")
function Read-Host { return '' }
function Pause-Menu { }
$steps = [ordered]@{
    'шапка меню'           = { Show-Header }
    'главный экран'        = { Show-Main }
    'настройки (N)'        = { Show-SettingsMenu }
    'инструменты (I)'      = { Show-ToolsMenu }
    'выбор стратегии (4)'  = { Select-AltManual }
    'неизвестное действие' = { Invoke-MenuAction 'нет-такого' }
    'проверка обходов (C)'      = { Show-PcCheck }
    'проверка подключения' = { Show-ConnectionCheck | Out-Null }
    'стратегия и круги'    = { Get-AltText $s; Get-RingsText $s }
    'автонастройка'        = { Get-AutotuneText; Test-AutotuneRunning }
    'hosts'                = { Get-HostsStatusText (Get-HostsStatus); Get-HostsYoutube }
    'ускорители'           = { Get-GameBoosters }
    'командная строка'     = { Get-BypassCmdLine -Settings $s -Name 'smoke' }
}
foreach ($k in $steps.Keys) {
    try { & $steps[$k] *> $null; Write-Host ('ok   ' + $k) -ForegroundColor Green }
    catch { Write-Host ('FAIL ' + $k + ': ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) -ForegroundColor Red; $fails++ }
}
$before = @(Get-ChildItem (Join-Path $Pkg 'runtime') -Filter 'report-*.txt' -ErrorAction SilentlyContinue).Count
$out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Pkg 'tools\report.ps1') -NoPrompt -NoOpen 2>&1
$rep = @(Get-ChildItem (Join-Path $Pkg 'runtime') -Filter 'report-*.txt' | Sort-Object LastWriteTime -Descending)
if ($LASTEXITCODE -eq 0 -and $rep.Count -gt $before) {
    $text = [System.IO.File]::ReadAllText($rep[0].FullName)
    Write-Host ('ok   отчёт R: ' + $rep[0].Name + ', ' + $text.Length + ' символов')
    # отчёт пересылают: свой внешний IP в нём должен быть замаскирован (последний октет - x)
    $self = Get-DirectConnectionInfo
    if ($self -and $text.Contains($self.Ip)) { Write-Host 'FAIL в отчёте открытый внешний IP' -ForegroundColor Red; $fails++ }
    if ($text -match ('\\Users\\' + [regex]::Escape($env:USERNAME) + '\\')) { Write-Host 'FAIL в отчёте имя пользователя Windows' -ForegroundColor Red; $fails++ }
} else { Write-Host ('FAIL отчёт R: ' + ($out | Out-String)) -ForegroundColor Red; $fails++ }
if ($Etl) {
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Pkg 'tools\track.ps1') -Replay $Etl -ReplayPid $EtlPid 2>&1
    $tr = Join-Path $Pkg 'runtime\track-replay.txt'
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tr) -and ([System.IO.File]::ReadAllText($tr) -match 'Итог')) {
        Write-Host ('ok   трекер по журналу: ' + @([System.IO.File]::ReadAllLines($tr)).Count + ' строк')
    } else { Write-Host ('FAIL трекер по журналу: ' + (($out | Select-Object -Last 8) -join ' | ')) -ForegroundColor Red; $fails++ }
}
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
