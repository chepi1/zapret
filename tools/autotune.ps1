# Автонастройка по расписанию: её запускает задача планировщика "zapret autotune" (Настройки -> 7 в меню)
# каждый день в 4:00 или позже, когда ПК простаивает. Решает сама, пора ли:
#  - раз в месяц скачивает свежие списки Flowseal (ipset-all, ipset-exclude, list-general, list-google, list-exclude);
#  - раз в неделю узнаёт, не вышли ли новые версии zapret2 и Flowseal (видно в шапке меню);
#  - раз в неделю (ручной автоподбор тоже считается) - полный автоподбор (все стратегии) без вопросов: обновляет
#    рейтинг, по которому строятся круги автосмены. Основную стратегию не меняет. Обход на время теста выключается и включается обратно.
# Автоподбор откладывается на следующий день, если запущена игра, включён VPN или работает другой обход.
# Журнал - runtime\autotune.log, вывод последнего автоподбора - runtime\autotune-last.txt.
# -Force: всё сразу, не глядя на сроки (для проверки вручную).
param([switch]$Force)

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not (Test-Admin)) { exit 1 }

# списки - раз в месяц, по времени ipset-all (оно обновляется и когда списки не изменились)
$ipsetFile = Join-Path $Script:Lists 'ipset-all.txt'
if ($Force -or -not (Test-Path $ipsetFile) -or ((Get-Date) - (Get-Item $ipsetFile).LastWriteTime).TotalDays -ge $Script:IpsetDays) {
    Add-AutotuneLog ('списки Flowseal: ' + ((@(Update-FlowsealLists) | ForEach-Object { $_.Text }) -join '; '))
}

$newsBefore = @(Get-UpstreamNews) -join '; '
if (Update-UpstreamCheck -Force:$Force) {
    $news = @(Get-UpstreamNews) -join '; '
    if ($news -and $news -ne $newsBefore) { Add-AutotuneLog ('вышли новые версии: ' + $news) }
}

$rankFile = Get-PkgPath $Script:RankFile
$before = if (Test-Path $rankFile) { (Get-Item $rankFile).LastWriteTime } else { $null }
if (-not $Force -and $before -and ((Get-Date) - $before).TotalDays -lt $Script:AutotuneDays) { exit 0 }

$bad = @(Test-PackageIntegrity)
if ($bad.Count) { Add-AutotuneLog ('автоподбор не запущен: файлы zapret2 изменены - ' + ($bad -join ', ')); exit 1 }

$why = @(Get-AutotuneBlockers)
if ($why.Count) { Add-AutotuneLog ('автоподбор отложен до завтра: ' + ($why -join '; ')); exit 0 }

$lock = Join-Path $Script:Runtime 'autotune.lock'
Write-TextNoBom $lock ([string]$PID)
$wasRunning = (@(Get-OurProcesses).Count -gt 0) -or [bool](Get-OurService | Where-Object { $_.Status -eq 'Running' })
try { Start-Transcript -Path (Join-Path $Script:Runtime 'autotune-last.txt') -Force | Out-Null } catch { }
try {
    & (Join-Path $PSScriptRoot 'test.ps1') -NoPrompt -ReportOnly -Full
    $after = if (Test-Path $rankFile) { (Get-Item $rankFile).LastWriteTime } else { $null }
    if ($after -and $after -ne $before) {
        $best = @([System.IO.File]::ReadAllLines((Join-Path $Script:Runtime 'test-last.txt')) | Where-Object { $_ -like 'Лучший результат:*' }) | Select-Object -First 1
        $s = Get-Settings
        $msg = 'автоподбор: ' + $(if ($best) { $best } else { 'готово' }) + '. Стратегия: ' + (Get-AltText $s)
        foreach ($x in @(Get-RingsText $s)) { $msg += '; ' + $x }
        Add-AutotuneLog $msg
    } else {
        Add-AutotuneLog 'автоподбор не завершился, подробности в runtime\autotune-last.txt'
    }
} catch {
    Add-AutotuneLog ('автоподбор: ошибка ' + $_.Exception.Message)
} finally {
    # тест сам включает обход обратно; это - на случай, если он упал посередине
    if ($wasRunning -and @(Get-OurProcesses).Count -eq 0) {
        Start-Bypass -Quiet | Out-Null
        Add-AutotuneLog 'обход включён обратно после сбоя теста'
    }
    try { Stop-Transcript | Out-Null } catch { }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
