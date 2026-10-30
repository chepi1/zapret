# Отчёт: настройки, состояние, параметры winws2, последние тест и сканер - в один файл runtime\report-*.txt,
# чтобы переслать тому, кто помогает с настройкой, или приложить к issue на GitHub. Последний октет IP скрыт.
# Совместимо с Windows PowerShell 5.1.
# -NoPrompt: без вопроса про подробный лог (он в отчёт не попадёт); -NoOpen: не открывать Проводник с файлом.
param([switch]$NoPrompt, [switch]$NoOpen)

. (Join-Path $PSScriptRoot 'lib.ps1')

$r = New-Object System.Collections.Generic.List[string]
function Add-Section([string]$Title) { $r.Add(''); $r.Add('===== ' + $Title + ' =====') }
# $StopAt - строка, с которой начинаются подробности: дальше файл в отчёт не берём (сам файл остаётся в runtime)
function Add-File([string]$Title, [string]$Path, [int]$Tail = 0, [string]$StopAt = '') {
    Add-Section $Title
    if (-not (Test-Path $Path)) { $r.Add('(нет файла)'); return }
    $lines = [System.IO.File]::ReadAllLines($Path)
    if ($Tail -gt 0 -and $lines.Count -gt $Tail) { $r.Add("(последние $Tail строк из $($lines.Count))"); $lines = $lines[($lines.Count - $Tail)..($lines.Count - 1)] }
    foreach ($l in $lines) {
        if ($StopAt -and $l.StartsWith($StopAt)) { $r.Add('(подробности по каждому адресу - в ' + (Split-Path -Leaf $Path) + ')'); break }
        $r.Add($l)
    }
}

Write-Color 'Собираю отчёт...' Cyan
$s = Get-Settings
$r.Add('zapret v' + $Script:Version + ' - отчёт ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$r.Add('Папка: ' + $Script:Root)
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $r.Add('Windows: ' + $os.Caption + ' ' + $os.Version) } catch { }

Add-Section 'Настройки'
$r.Add('Стратегия: ' + (Get-AltText $s))
foreach ($x in @(Get-RingsText $s)) { $r.Add('  свой круг - ' + $x) }
$r.Add('Game Filter: ' + (Get-GameText $s))
$r.Add('IPSet: ' + $s.ipset)
$r.Add('Автонастройка: ' + (Get-AutotuneText))
foreach ($x in @(Get-AllNews)) { $r.Add('Вышла новая версия: ' + $x) }
foreach ($k in ($s.Keys | Sort-Object)) { $r.Add("$k=$($s[$k])") }

Add-Section 'Состояние'
try { $r.Add('Windows: ' + (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption + ' ' + [Environment]::OSVersion.Version) } catch { }
# "Целостность памяти" (изоляция ядра) может не пустить драйвер WinDivert
$hvci = $null
try { $hvci = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction Stop).Enabled } catch { }
$r.Add('Целостность памяти: ' + $(if ($hvci -eq 1) { 'вкл' } else { 'выкл' }))
$procs = @(Get-OurProcesses)
$r.Add('winws2 запущен: ' + ($procs.Count -gt 0))
foreach ($p in $procs) { try { $r.Add(('  PID {0}, приоритет {1}, запущен {2}' -f $p.Id, $p.PriorityClass, $p.StartTime)) } catch { } }
$svc = Get-OurService
$r.Add('Служба: ' + $(if ($svc) { '' + $svc.Status + ' / ' + $svc.StartType } else { 'нет' }))
foreach ($n in @('WinDivert', 'WinDivert14', 'zapret')) {
    $x = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($x) { $r.Add(('Служба {0}: {1} / {2}' -f $n, $x.Status, $x.StartType)) }
}
$foreign = @(Get-ForeignBypass)
$r.Add('Другие обходы: ' + $(if ($foreign.Count) { $foreign -join ', ' } else { 'нет' }))
$ts = (& netsh interface tcp show global 2>&1 | Select-String -Pattern 'Timestamps|Метки времени|RFC 1323') -join '; '
$r.Add('TCP timestamps: ' + $ts.Trim())

Add-Section 'Подключение'
$info = Get-DirectConnectionInfo
if ($info) {
    # последний октет скрыт: для диагностики хватает провайдера и страны
    $r.Add(('Внешний IP: {0} ({1}, {2}), провайдер: {3} [{4}]' -f (Get-MaskedIp ([string]$info.Ip)), $info.CountryCode, $info.City, $info.Isp, $info.As))
} else { $r.Add('Внешний IP: не удалось узнать') }
foreach ($x in @(Get-ProxyWarnings)) { $r.Add('Прокси/VPN: ' + $x) }
foreach ($b in @(Get-GameBoosters)) { $r.Add('Игровой ускоритель: ' + $b) }
$r.Add('hosts: ' + (Get-HostsStatusText (Get-HostsStatus)) + $(if (@(Get-HostsYoutube).Count) { '; есть записи YouTube!' } else { '' }))
$r.Add('IPv6-адрес в интернете: ' + $(if (@(Get-Ipv6Addresses).Count) { 'есть' } else { 'нет' }) + '; "предпочитать IPv4": ' + $(if (Get-PreferIpv4) { 'включено' } else { 'нет' }))

Add-Section 'Списки'
foreach ($f in @('ipset-all.txt', 'ipset-taketwo.txt', 'ipset-user.txt', 'ipset-exclude-user.txt', 'list-general.txt', 'list-general-user.txt', 'list-exclude-user.txt')) {
    $path = Join-Path $Script:Lists $f
    if (Test-Path $path) { $r.Add(('{0}: {1} строк, изменён {2}' -f $f, @(Get-ListLines $path).Count, (Get-Item $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))) }
    else { $r.Add("$($f): НЕТ ФАЙЛА") }
}
Add-File 'Найдено сканером (ipset-user.txt)' (Join-Path $Script:Lists 'ipset-user.txt')
# сайты из автосписка и его журнал - это кусок истории браузера: в отчёт только с согласия
Add-Section ('Автосписок сайтов: ' + (Get-AutolistText $s))
$sites = $false
if (-not $NoPrompt -and @(Get-AutolistDomains).Count) {
    Write-Color 'В автосписке и его журнале видно, какие сайты вы открывали (те, что не открылись с первого раза).' Yellow
    $sites = Read-YesNo 'Добавить их в отчёт? Без них тоже можно разобраться в большинстве проблем'
}
if ($sites) {
    foreach ($d in @(Get-AutolistDomains)) { $r.Add($d) }
    Add-File 'Журнал автосписка (последние строки)' (Join-Path $Script:Runtime 'autohostlist-debug.log') 60
} else { $r.Add('(список сайтов не добавлен)') }

Add-File 'Параметры winws2 (последний запуск)' (Join-Path $Script:Runtime 'args-active.txt')
Add-File 'Последний сбой запуска обхода' (Join-Path $Script:Runtime 'start-error.txt')
Add-Section ('Падения обхода за {0} дней' -f $Script:CrashDays)
$crashes = @(Get-BypassCrashes (Get-Date).AddDays(-$Script:CrashDays))
$r.Add($(if ($crashes.Count) { Format-BypassCrashes $crashes } else { '(не было)' }))
Add-Section 'Telegram'
$r.Add('Мост Telegram: ' + $(if ($s.telegram -eq 'on') { if (Test-TgBridgeRunning) { 'включён, работает' } else { 'включён, но не запущен' } } else { 'выключен' }))
Add-File 'Журнал моста Telegram (последние строки)' (Join-Path $Script:Runtime 'tgbridge.log') 40
Add-File 'Последний автоподбор' (Join-Path $Script:Runtime 'test-last.txt') -StopAt 'Подробно'
Add-File 'Журнал автонастройки' (Join-Path $Script:Runtime 'autotune.log') 30
Add-File 'Последний сканер' (Join-Path $Script:Runtime 'scan-last.txt')
Add-File 'Последний трекер' (Join-Path $Script:Runtime 'track-last.txt') 300

$dbg = Join-Path $Script:Runtime 'debug.log'
if ((Test-Path $dbg) -and -not $NoPrompt) {
    Write-Color 'Есть подробный лог winws2 (runtime\debug.log). В нём видны адреса сайтов и серверов, к которым вы подключались.' Yellow
    if (Read-YesNo 'Добавить в отчёт его последние 600 строк?') { Add-File 'Подробный лог winws2 (debug.log)' $dbg 600 }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$file = Join-Path $Script:Runtime ('report-' + $stamp + '.txt')
Write-TextNoBom $file (Protect-ReportText (($r -join "`r`n") + "`r`n") $(if ($info) { [string]$info.Ip }))
Write-Color ('Отчёт готов: ' + $file) Green
Write-Color 'Имя пользователя Windows и ваш внешний IP в нём скрыты.' Gray
Write-Color 'Перешлите этот файл тому, кто помогает с настройкой, или приложите к issue на GitHub.' Green
if (-not $NoOpen) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $file + '"') } catch { } }
