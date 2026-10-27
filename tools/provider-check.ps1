# Проверка провайдера: для тех, кому прислали эту папку. Запускается из меню: Инструменты -> 3.
# Проверяет подключение, прогоняет автоподбор в режиме "только отчёт" и собирает один файл с результатом
# (название провайдера в имени файла) - его пересылают обратно. Обход сама не включает: спрашивает в конце.
# Совместимо с Windows PowerShell 5.1.

. (Join-Path $PSScriptRoot 'lib.ps1')

try { $Host.UI.RawUI.WindowTitle = 'Проверка провайдера - zapret' } catch { }

if (-not (Test-Admin)) {
    Write-Color 'Нужны права администратора. Запустите zapret.bat (он сам запросит права), затем Инструменты -> 3.' Red
    Read-Host 'Enter - выход' | Out-Null
    exit 1
}
Unblock-Package
Protect-Package
if (-not (Test-Path $Script:Exe) -or -not (Test-Path (Join-Path $Script:Bin 'WinDivert64.sys'))) {
    Write-Color 'Нет bin\winws2.exe или bin\WinDivert64.sys. Скорее всего их удалил антивирус: добавьте папку в исключения и распакуйте архив заново.' Red
    Read-Host 'Enter - выход' | Out-Null
    exit 1
}

Clear-Host
Write-Color '=============== Проверка провайдера ===============' Cyan
Write-Color 'Займёт около 10 минут. Проверяется:' White
Write-Color '  - что режет ваш провайдер: зарубежные хостинги (игры), Discord, YouTube, SoundCloud, 2K, EAC;' Gray
Write-Color '  - какая стратегия обхода у вас лучше всего пробивает блок;' Gray
Write-Color '  - не ломает ли она обычные сайты (Bing, Apple, Amazon и др.).' Gray
Write-Host ''
Write-Color 'Перед началом:' Yellow
Write-Color '  1. Полностью выйдите из VPN/прокси (Happ, v2rayN и т.п. - выход из программы, а не "отключить").' Yellow
Write-Color '  2. Остановите загрузки (Steam, торренты) - они мешают замерам.' Yellow
Write-Color '  3. Закройте игровые ускорители (ExitLag, NoPing, WTFast, GearUP и т.п.) - они перехватывают трафик.' Yellow
foreach ($b in @(Get-GameBoosters)) { Write-Color ('     Сейчас запущен: ' + $b) Red }
Write-Host ''
Read-Host 'Enter - начать' | Out-Null

$started = Get-Date
& (Join-Path $PSScriptRoot 'test.ps1') -ReportOnly -Full

$testFile = Join-Path $Script:Runtime 'test-last.txt'
$bestFile = Join-Path $Script:Runtime 'test-best.txt'
if (-not (Test-Path $testFile) -or (Get-Item $testFile).LastWriteTime -lt $started) {
    Write-Color 'Автоподбор не завершился - отчёта нет. Запустите проверку ещё раз.' Red
    Read-Host 'Enter - выход' | Out-Null
    exit 1
}

# ---------- один файл с результатом ----------
$info = Get-DirectConnectionInfo
$isp = if ($info -and $info.Isp) { $info.Isp } else { 'провайдер' }
$ispFile = (($isp -replace '[^\p{L}\p{Nd}]+', '-').Trim('-'))
if ($ispFile.Length -gt 40) { $ispFile = $ispFile.Substring(0, 40) }
$r = New-Object System.Collections.Generic.List[string]
$r.Add('zapret v' + $Script:Version + ' - проверка провайдера ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
if ($info) {
    $r.Add(('Провайдер: {0} [{1}]' -f $info.Isp, $info.As))
    $r.Add(('Где: {0}, {1}. IP: {2}' -f $info.City, $info.Country, (Get-MaskedIp ([string]$info.Ip))))
} else { $r.Add('Провайдер: не удалось определить (ipwho.is и ipinfo.io не ответили)') }
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $r.Add('Windows: ' + $os.Caption + ' ' + $os.Version) } catch { }
foreach ($x in @(Get-ProxyWarnings)) { $r.Add('Прокси/VPN во время проверки: ' + $x) }
foreach ($b in @(Get-GameBoosters)) { $r.Add('Игровой ускоритель во время проверки: ' + $b + ' - перехватывает трафик вместе с обходом') }
$r.Add('')
foreach ($l in [System.IO.File]::ReadAllLines($testFile)) { $r.Add($l) }

$name = 'zapret-proverka-' + $ispFile + '-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.txt'
$file = Join-Path $Script:Runtime $name
Write-TextNoBom $file (Protect-ReportText (($r -join "`r`n") + "`r`n") $(if ($info) { [string]$info.Ip }))
# копия на рабочий стол - чтобы проще найти и переслать
$desk = [Environment]::GetFolderPath('Desktop')
$deskFile = $null
if ($desk -and (Test-Path $desk)) {
    $deskFile = Join-Path $desk $name
    try { Copy-Item $file $deskFile -Force } catch { $deskFile = $null }
}

Write-Host ''
Write-Color '=============== Готово ===============' Green
Write-Color ('Файл с результатом: ' + $(if ($deskFile) { $deskFile } else { $file })) Green
Write-Color 'Перешлите его тому, кто дал вам эту папку (в Telegram, Discord - как удобно).' Green
try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $(if ($deskFile) { $deskFile } else { $file }) + '"') } catch { }

# ---------- включить обход? ----------
$bestId = if (Test-Path $bestFile) { ([System.IO.File]::ReadAllText($bestFile)).Trim() } else { '' }
$best = if ($bestId) { Get-Strategy $bestId } else { $null }
Write-Host ''
if ($best) {
    if (Read-YesNo ("Включить обход сейчас с лучшей для вас стратегией {0}?" -f $best.Name)) {
        $s = Get-Settings
        $s.alt = $best.Id
        Save-Settings $s
        if (Resolve-ForeignBypass) { Start-Bypass | Out-Null }
        Write-Color 'Дальше управлять обходом можно через zapret.bat (меню).' Gray
    } else {
        Write-Color 'Обход не включён. Включить можно позже через zapret.bat, пункт 1.' Gray
    }
}
Read-Host 'Enter - выход' | Out-Null
