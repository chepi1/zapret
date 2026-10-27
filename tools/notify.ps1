# zapret: уведомления Windows. Запускается задачей "zapret notify" раз в 5 минут от имени пользователя
# (Настройки -> 10). Об одном и том же уведомляет один раз: что уже показано - в runtime\notify-state.txt.
# Совместимо с Windows PowerShell 5.1.
. (Join-Path $PSScriptRoot 'lib.ps1')

$stateFile = Get-PkgPath 'runtime/notify-state.txt'
$state = @{}
if (Test-Path $stateFile) {
    foreach ($l in [System.IO.File]::ReadAllLines($stateFile)) { if ($l -match '^(\w+)=(.*)$') { $state[$matches[1]] = $matches[2] } }
}
function Get-State([string]$Key) { if ($state.ContainsKey($Key)) { return $state[$Key] } return '' }

# служба обхода стоит, но не работает (автоперезапуск не помог)
$svc = Get-OurService
# не сбой: остановлен пунктом 2, идёт автонастройка или автоподбор (он пишет args-test.txt перед каждой стратегией)
$testFile = Join-Path $Script:Runtime 'args-test.txt'
$testing = (Test-Path $testFile) -and ((Get-Date) - (Get-Item $testFile).LastWriteTime).TotalMinutes -lt 3
$manual = Test-Path (Get-PkgPath $Script:ManualStopFile)
$down = if ($svc -and $svc.Status -ne 'Running' -and -not $manual -and -not $testing -and -not (Test-AutotuneRunning)) { 'down' } else { '' }
if ($down -and (Get-State 'service') -ne 'down') { Show-Toast 'zapret: обход не работает' 'Служба обхода остановлена. Откройте zapret.bat и нажмите 1 - меню покажет причину.' | Out-Null }
$state['service'] = $down

# Steam / Discord застряли на выключенном прокси
$stuck = @(Get-ProxyStuckApps) -join ', '
if ($stuck -and (Get-State 'stuck') -ne $stuck) {
    Show-Toast ('zapret: ' + $stuck + ' без сети') ($stuck + ' запущен, когда был включён прокси, и шлёт запросы в выключенный прокси. Перезапустите его (в Доте иначе нет цен и не работает "Играть").') | Out-Null
}
$state['stuck'] = $stuck

# новая версия zapret: раз в 3 дня спрашиваем GitHub, о каждой версии - один раз
try { Update-UpstreamCheck -Days 3 | Out-Null } catch { }
$upd = Get-ZapretUpdate
if ($upd -and (Get-State 'version') -ne $upd) { Show-Toast ('zapret: вышла версия ' + $upd) 'Обновить: zapret.bat -> Настройки -> 9.' | Out-Null }
if ($upd) { $state['version'] = $upd }

# автонастройка: последняя запись журнала, если появилась новая
$log = Join-Path $Script:Runtime 'autotune.log'
if (Test-Path $log) {
    $last = @([System.IO.File]::ReadAllLines($log) | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if ($last.Count -and (Get-State 'autotune') -ne $last[0]) {
        if ((Get-State 'autotune') -and $last[0] -match 'автоподбор|круг|списки|новые версии|не запущен') { Show-Toast 'zapret: автонастройка' ($last[0] -replace '^\S+ \S+\s+', '') | Out-Null }
        $state['autotune'] = $last[0]
    }
}

Write-TextNoBom $stateFile ((@($state.Keys | Sort-Object | ForEach-Object { $_ + '=' + $state[$_] }) -join "`r`n") + "`r`n")
