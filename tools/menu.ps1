# Меню zapret. Запускается из zapret.bat с правами администратора.
# Совместимо с Windows PowerShell 5.1.

. (Join-Path $PSScriptRoot 'lib.ps1')

try { $Host.UI.RawUI.WindowTitle = 'zapret' } catch { }

if (-not (Test-Admin)) {
    Write-Color 'Нужны права администратора. Запустите zapret.bat (он сам запросит права).' Red
    Read-Host 'Enter - выход' | Out-Null
    exit 1
}

# снимаем пометку "скачано из интернета" при каждом запуске: архив могли распаковать поверх старой версии
Unblock-Package
if (-not (Test-Path $Script:Exe) -or -not (Test-Path (Join-Path $Script:Bin 'WinDivert64.sys'))) {
    Write-Color 'Нет bin\winws2.exe или bin\WinDivert64.sys. Скорее всего их удалил антивирус: добавьте папку в исключения и распакуйте архив заново.' Red
    Read-Host 'Enter - выход' | Out-Null
    exit 1
}
# папки с кодом - только для администраторов: иначе программа без прав могла бы подменить скрипт (см. lib.ps1)
Protect-Package
# служба и задача версий до переименования (NBA2K27-zapret2) - под новые имена
Update-LegacyNames

function Pause-Menu { Read-Host 'Enter - назад в меню' | Out-Null }

# новые версии zapret, zapret2 и Flowseal - раз в 3 дня, свежие списки сайтов - раз в неделю; оба в фоне
Start-UpstreamCheck -Days 3
Start-ListsUpdate -Days $Script:IpsetDays

function Test-Running { return ((@(Get-OurProcesses).Count -gt 0) -or [bool](Get-OurService)) }

# ---------- табличка меню ----------
# Меню рисуется в двойной рамке: рамка белая, строки внутри дополняются пробелами до одной ширины, длинная строка
# переносится по словам. Ширина внутри рамки - 64 знака: влезает самое длинное имя стратегии в строке состояния.
function Get-BoxWidth { return 64 }

function Write-BoxLine([string]$Left, [string]$Fill, [string]$Right, [string]$Title = '') {
    $w = Get-BoxWidth
    $l = [math]::Floor(($w - $Title.Length) / 2)
    Write-Color ($Left + ($Fill * $l) + $Title + ($Fill * ($w - $Title.Length - $l)) + $Right) White
}
function Write-BoxTop([string]$Title = '') { Write-BoxLine '╔' '═' '╗' $Title }
function Write-BoxSep { Write-BoxLine '╠' '═' '╣' }
function Write-BoxBottom { Write-BoxLine '╚' '═' '╝' }

# Строка внутри рамки. $Rgb - свой цвет текста (светло-розовая строка состояния), иначе $Color.
function Write-BoxRow([string]$Text, [string]$Color = 'Gray', [int[]]$Rgb = @()) {
    $w = Get-BoxWidth
    $indent = ([regex]::Match($Text, '^\s*')).Value
    $rows = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($word in @($Text.Trim() -split '\s+')) {
        $next = if ($cur) { $cur + ' ' + $word } else { $indent + $word }
        if ($next.Length -gt $w - 1 -and $cur) { $rows.Add($cur); $next = $indent + '  ' + $word }
        $cur = $next
    }
    if ($cur -or -not $rows.Count) { $rows.Add($cur) }
    foreach ($r in $rows) {
        if ($r.Length -gt $w) { $r = $r.Substring(0, $w - 1) + '~' }
        Write-Host '║' -ForegroundColor White -NoNewline
        $pad = $r + (' ' * ($w - $r.Length))
        if ($Rgb.Count -eq 3) { Write-Rgb $pad $Rgb -NoNewline } else { Write-Host $pad -ForegroundColor $Color -NoNewline }
        Write-Host '║' -ForegroundColor White
    }
}

# Шапка: одна строка состояния и только то, что требует действия. Прокси и VPN - в проверке обходов (пункт 5): клиент
# прокси для браузера многие держат включённым постоянно, и строки о нём только мешали.
function Show-Header {
    Clear-Host
    $s = Get-Settings
    $st = Get-Strategy $s.alt
    $state = @($(if (@(Get-OurProcesses).Count) { 'Обход: РАБОТАЕТ' } else { 'Обход: остановлен' }),
        $(if ($st) { $st.Name } else { 'ALT' + $s.alt + ' (нет файла!)' }),
        $(if (Get-OurService) { 'автозапуск с Windows' }),
        $(if ($s.telegram -eq 'on') { if (Test-TgBridgeRunning) { 'Telegram' } else { 'Telegram: не запущен' } }))
    Write-BoxTop (' zapret v' + $Script:Version + ' ')
    Write-BoxRow ('  ' + (@($state | Where-Object { $_ }) -join ' · ')) -Rgb @(255, 200, 220)
    $bad = @(Test-PackageIntegrity -Cached)
    if ($bad.Count) { Write-BoxRow ('  ! Файлы zapret2 изменены (' + ($bad -join ', ') + '): обход не запустится. Скачайте сборку заново.') Red }
    if (Test-AutotuneRunning) { Write-BoxRow '  ! Идёт автонастройка по расписанию: обход включится сам через несколько минут.' Yellow }
    if ($Script:Root -match "[^\x21-\x7E]|'") { Write-BoxRow '  ! В пути к папке пробелы, апостроф или русские буквы - надёжнее перенести в C:\zapret' Yellow }
    $foreign = @(Get-ForeignBypass)
    if ($foreign.Count) { Write-BoxRow ('  ! Запущен другой обход: ' + ($foreign -join ', ') + '. Пункт 1 предложит его остановить.') Yellow }
    foreach ($b in @(Get-GameBoosters -Cached)) { Write-BoxRow ('  ! Игровой ускоритель ' + $b + ' мешает обходу: закройте его полностью.') Yellow }
    $conf = @(Get-SystemConflicts -Cached)
    if ($conf.Count) { Write-BoxRow ('  ! Мешает обходу: ' + (($conf | ForEach-Object { ($_.Text -split '[:(]')[0].Trim() }) -join ', ') + ' - подробно в пункте 5.') Yellow }
    $stuck = @(Get-ProxyStuckApps -Cached)
    if ($stuck.Count) { Write-BoxRow ('  ! ' + ($stuck -join ' и ') + ' ходит через выключенный прокси и сидит без сети (в Доте нет цен, не работает "Играть"). Перезапуск - пункт 5.') Yellow }
    $hs = Get-HostsStatus
    if (@($hs.Keys | Where-Object { $hs[$_].Present -and $hs[$_].Stale }).Count -or @(Get-HostsYoutube).Count) { Write-BoxRow '  ! В hosts есть что поправить - пункт 5.' Yellow }
    $upd = Get-ZapretUpdate
    if ($upd) { Write-BoxRow ('  ! Вышла новая версия zapret ' + $upd + ' - обновить: Настройки -> 9.') Yellow }
    # меню обновляет списки само раз в неделю: старше трёх недель - значит, GitHub не отвечает
    $age = Get-ListsAgeDays
    if ($age -ge 21) { Write-BoxRow ('  ! Списки сайтов не обновлялись ' + $age + ' дн.: новые блокировки в них не попали. Обновить: Настройки -> 8.') Yellow }
    $news = @(Get-UpstreamNews)
    if ($news.Count) { Write-BoxRow ('  ! Вышли новые версии основы: ' + ($news -join ', ') + ' - сборку стоит обновить.') Yellow }
    Write-BoxSep
}

# Главный экран - только то, что нужно каждый день. Остальное - в "Настройках" и "Инструментах". На каждом экране
# свои номера по порядку, 0 - назад (на главном - выход).
function Show-Main {
    Write-BoxRow '  1. Запустить / перезапустить обход'
    Write-BoxRow '  2. Остановить обход'
    Write-BoxRow '  3. Автоподбор стратегии'
    Write-BoxRow '  4. Выбрать стратегию вручную'
    Write-BoxRow '  5. Проверка обходов'
    Write-BoxSep
    Write-BoxRow '  6. Настройки'
    Write-BoxRow '  7. Инструменты: трекер, сканер, отчёты'
    Write-BoxRow '  0. Выход'
    Write-BoxBottom
}

function Show-SettingsMenu {
    while ($true) {
        Show-Header
        $s = Get-Settings
        $st = Get-Strategy $s.alt
        $svc = Get-OurService
        $game = switch ($s.game) { 'all' { 'TCP и UDP' } 'tcp' { 'только TCP' } 'udp' { 'только UDP' } default { 'выкл' } }
        if ($s.game -ne 'off' -and ($s.gametcp -ne '1024-65535' -or $s.gameudp -ne '1024-65535')) {
            $game += $(if ($s.gametcp -eq $Script:GamePortsPreset.tcp -and $s.gameudp -eq $Script:GamePortsPreset.udp) { ', только порты игр' } else { ', свои порты' })
        }
        $tune = if (-not (Get-AutotuneTask)) { 'выкл' } elseif ((Get-AutotuneText) -match 'другой папки') { '! задача от другой папки' } else { 'раз в неделю' }
        Write-BoxRow ' Настройки' Cyan
        Write-BoxRow ('  1. Стратегия: ' + $(if ($st) { $st.Name } else { 'ALT' + $s.alt + ' (нет файла!)' }))
        Write-BoxRow ('  2. Автосмена при сбое: ' + $(if ($s.auto -eq 'on') { 'вкл' } else { 'выкл' }))
        Write-BoxRow ('  3. Game Filter: ' + $game)
        Write-BoxRow ('  4. IPSet: ' + $s.ipset)
        Write-BoxRow ('  5. Автосписок сайтов: ' + $(if ($s.autolist -ne 'on') { 'выкл' } else { 'вкл, сайтов: ' + @(Get-AutolistDomains).Count }))
        Write-BoxRow ('  6. Автозапуск с Windows: ' + $(if (-not $svc) { 'нет' } elseif ($svc.Status -eq 'Running') { 'служба работает' } else { 'служба (' + $svc.Status + ')' }))
        Write-BoxRow ('  7. Автонастройка по расписанию: ' + $tune)
        Write-BoxRow '  8. Обновить списки'
        $upd = Get-ZapretUpdate
        Write-BoxRow ('  9. Обновить zapret: у вас ' + $Script:Version + $(if ($upd) { ', вышла ' + $upd } else { '' }))
        Write-BoxRow ('  10. Уведомления Windows: ' + $(if (Test-NotifyEnabled $s) { 'вкл' } else { 'выкл' }))
        Write-BoxSep
        Write-BoxRow '  0. Назад'
        Write-BoxBottom
        $c = (Read-Host 'Выбор').Trim().ToUpper()
        if (-not $c -or $c -eq '0') { return }
        $map = @{ '1' = 'strategy'; '2' = 'auto'; '3' = 'game'; '4' = 'ipset'; '5' = 'autolist'; '6' = 'service'; '7' = 'autotune'; '8' = 'lists'; '9' = 'update'; '10' = 'notify' }
        if ($map.ContainsKey($c)) { Invoke-MenuAction $map[$c] } elseif ($Script:LetterKeys.ContainsKey($c)) { Invoke-MenuAction $Script:LetterKeys[$c] }
    }
}

function Show-ToolsMenu {
    while ($true) {
        Show-Header
        Write-BoxRow ' Инструменты' Cyan
        Write-BoxRow '  1. Трекер: где сервер матча, пинг, голос Discord'
        Write-BoxRow '  2. Сканер адресов игры'
        Write-BoxRow '  3. Проверка провайдера (отчёт, чтобы переслать)'
        Write-BoxRow '  4. Отчёт: настройки и логи одним файлом'
        Write-BoxRow '  5. Диагностика: winws2 в видимом окне'
        Write-BoxRow '  6. Исключить игру из обхода (по последнему трекеру)'
        Write-BoxRow '  7. Правила "напрямую" для Happ (Steam, Discord, игры)'
        Write-BoxRow '  8. Telegram: встроенный мост (без VPN и программ)'
        Write-BoxRow '  9. Discord не запускается: очистить кэш'
        Write-BoxSep
        Write-BoxRow '  0. Назад'
        Write-BoxBottom
        $c = (Read-Host 'Выбор').Trim().ToUpper()
        if (-not $c -or $c -eq '0') { return }
        $map = @{ '1' = 'tracker'; '2' = 'scanner'; '3' = 'provider'; '4' = 'report'; '5' = 'diag'; '6' = 'exclude'; '7' = 'direct'; '8' = 'telegram'; '9' = 'discordcache' }
        if ($map.ContainsKey($c)) { Invoke-MenuAction $map[$c] } elseif ($Script:LetterKeys.ContainsKey($c)) { Invoke-MenuAction $Script:LetterKeys[$c] }
    }
}

function Start-WithChecks {
    if (Test-AutotuneRunning) { Write-Color 'Идёт автонастройка по расписанию: она сама включит обход через несколько минут.' Yellow; return }
    if (-not (Resolve-ForeignBypass)) {
        Write-Color 'Обход не запущен: сначала остановите другой обход.' Red
        return
    }
    Start-Bypass | Out-Null
    Start-TelegramWithBypass
}

# Telegram вместе с обходом: включён - запускаем tg-ws-proxy; ещё не выбирали, а Telegram Desktop есть - спрашиваем один раз
function Start-TelegramWithBypass {
    $s = Get-Settings
    if ($s.telegram -eq 'on') {
        if (Start-TgBridge) { Write-Color 'Telegram: мост работает.' Green } else { Write-Color 'Telegram: мост не запустился (Инструменты -> 8).' Yellow }
        return
    }
    if ($s.telegram -or -not (Test-TelegramDesktop)) { return }
    Write-Host ''
    Write-Color 'Telegram у нас режут по адресам его серверов: без VPN он тормозит или не грузит фото и видео.' Cyan
    Write-Color 'Обход это не лечит, а встроенный мост zapret - лечит: Telegram Desktop ходит через него, а мост - через' Cyan
    Write-Color 'веб-версию Telegram, которую не режут. Ничего не скачивается; мост работает с входа в Windows.' Cyan
    if (Read-YesNo 'Включить мост Telegram?') {
        if (Set-TelegramMode $true) { Write-Color 'Telegram: мост работает.' Green; Connect-TgDesktop }
        else { Write-Color 'Мост не запустился: Инструменты -> 8.' Yellow }
    } else {
        $s.telegram = 'off'
        Save-Settings $s
        Write-Color 'Хорошо. Включить можно позже: Инструменты -> 8.' Gray
    }
}

function Select-AltManual {
    $s = Get-Settings
    Write-Host ''
    # круги автосмены - здесь, рядом с выбором стратегии
    if ($s.auto -eq 'on') {
        $ring = @(Get-RotationOrder $s.alt 'general' | ForEach-Object { $_.Name })
        Write-Color ('Автосмена для сайтов: ' + ($ring -join ' > ')) Gray
        foreach ($x in @(Get-RingsText $s)) { Write-Color ('Автосмена, ' + $x) Gray }
    } else { Write-Color 'Автосмена выключена (Настройки -> 2): всё время работает основная стратегия.' Gray }
    Write-Host ''
    # одна строка на стратегию: номер, имя, суть (полное описание - в начале файла strategies\altNN.txt)
    $w = 0; try { $w = $Host.UI.RawUI.WindowSize.Width } catch { }
    if ($w -lt 60) { $w = 120 }
    foreach ($x in (Get-Strategies)) {
        $mark = if ($x.Id -eq $s.alt) { '*' } else { ' ' }
        $tail = if ($x.Missing.Count) { 'НЕ ХВАТАЕТ СЕКЦИЙ: ' + ($x.Missing -join ', ') } else { $x.Desc }
        $line = ' {0} {1,3}  {2,-19} {3}' -f $mark, $x.Id, $x.Name, $tail
        if ($line.Length -gt $w - 1) { $line = $line.Substring(0, $w - 2) + '~' }
        Write-Color $line $(if ($x.Id -eq $s.alt) { 'White' } else { 'Gray' })
    }
    $id = (Read-Host 'Номер в скобках или имя, например 12, 45 или EXP (Enter - не менять)').Trim()
    if (-not $id) { return }
    # имя как в списке (ALT, EXP, SIMPLE FAKE ALT, BV1...) - тоже подходит
    $byName = @(Get-Strategies | Where-Object { $_.Name -eq $id })
    if ($byName.Count) { $id = $byName[0].Id }
    $id = $id -replace '^(?i)alt\s*', ''
    if ($id -match '^(?i)bv(\d)$') { $id = [string](20 + [int]$matches[1]) }
    $st = Get-Strategy $id
    if (-not $st -or $st.Missing.Count) { Write-Color 'Нет такой стратегии.' Red; Pause-Menu; return }
    $s.alt = $id
    Save-Settings $s
    if (Test-Running) { Start-Bypass | Out-Null }
    else { Write-Color ("Основная стратегия: {0}. Запустите обход пунктом 1." -f $st.Name) Green }
    Pause-Menu
}

function Toggle-Auto {
    $s = Get-Settings
    $s.auto = if ($s.auto -eq 'on') { 'off' } else { 'on' }
    Save-Settings $s
    if ($s.auto -eq 'on') {
        Write-Color 'Автосмена включена: если к серверу 3 раза подряд не удалось достучаться (повторные отправки, сброс от DPI),' Green
        Write-Color 'этот сервер переводится на следующую ALT. Остальные соединения остаются на текущей.' Green
    } else {
        Write-Color 'Автосмена выключена: всё время работает одна выбранная ALT, ровно как у Flowseal.' Green
    }
    if (Test-Running) { Start-Bypass -Quiet | Out-Null }
    Pause-Menu
}

function Select-GameFilter {
    $s = Get-Settings
    Write-Host ''
    Write-Host '  1. TCP и UDP (как Game Filter all у Flowseal, рекомендуется)'
    Write-Host '  2. только TCP'
    Write-Host '  3. только UDP'
    Write-Host '  4. выключить'
    Write-Host ('  5. диапазон портов TCP (сейчас {0})' -f $s.gametcp)
    Write-Host ('  6. диапазон портов UDP (сейчас {0})' -f $s.gameudp)
    Write-Host ('  7. только порты игр: NBA 2K27 и игры Steam/Valve (TCP {0}, UDP {1}) - меньше чужого трафика через обход' -f $Script:GamePortsPreset.tcp, $Script:GamePortsPreset.udp)
    Write-Host '  8. все порты 1024-65535 (как у Flowseal)'
    $c = Read-Host 'Выбор (Enter - не менять)'
    switch ($c) {
        '1' { $s.game = 'all' }
        '2' { $s.game = 'tcp' }
        '3' { $s.game = 'udp' }
        '4' { $s.game = 'off' }
        '5' { $v = (Read-Host 'Порты TCP, например 1024-65535').Trim(); if (Test-PortList $v) { $s.gametcp = $v } else { Write-Color 'Неверный формат.' Red } }
        '6' { $v = (Read-Host 'Порты UDP, например 1024-65535').Trim(); if (Test-PortList $v) { $s.gameudp = $v } else { Write-Color 'Неверный формат.' Red } }
        '7' { $s.game = 'all'; $s.gametcp = $Script:GamePortsPreset.tcp; $s.gameudp = $Script:GamePortsPreset.udp }
        '8' { $s.gametcp = '1024-65535'; $s.gameudp = '1024-65535' }
        default { return }
    }
    Save-Settings $s
    Write-Color ('Game Filter: ' + (Get-GameText $s)) Green
    if ($s.game -eq 'off') { Write-Color 'Без Game Filter NBA 2K27 почти наверняка будет вылетать: игровые соединения к AWS режутся после 16-20 КБ.' Yellow }
    if (Test-Running) { Start-Bypass -Quiet | Out-Null }
    Pause-Menu
}

function Select-Ipset {
    $s = Get-Settings
    Write-Host ''
    Write-Host '  1. loaded - сети из ipset-all.txt (как у Flowseal "loaded", рекомендуется)'
    Write-Host '  2. any    - все адреса. Для проверки, если игра всё равно вылетает; на постоянку не стоит'
    Write-Host '  3. none   - без ipset-all, только домены, Take-Two, AWS и найденное сканером'
    $c = Read-Host 'Выбор (Enter - не менять)'
    switch ($c) {
        '1' { $s.ipset = 'loaded' }
        '2' { $s.ipset = 'any' }
        '3' { $s.ipset = 'none' }
        default { return }
    }
    Save-Settings $s
    Write-Color ('IPSet: ' + (Get-IpsetText $s.ipset)) Green
    if (Test-Running) { Start-Bypass -Quiet | Out-Null }
    Pause-Menu
}

function Show-Autolist {
    $s = Get-Settings
    $file = Get-PkgPath $Script:AutolistFile
    $doms = @(Get-AutolistDomains)
    Write-Host ''
    Write-Color ('Автосписок сайтов: ' + (Get-AutolistText $s)) Cyan
    Write-Color 'Сюда zapret2 сам дописывает сайты вне списков, которые 3 раза подряд за минуту не открылись' Gray
    Write-Color '(замерзание на 16-20 КБ, сброс от DPI). Дальше такие сайты идут через обход.' Gray
    Write-Color 'Если сюда попал сайт, который просто лежал, - не страшно, обход ему обычно не мешает. Лишнее можно удалить.' Gray
    if ($doms.Count) { foreach ($d in $doms) { Write-Host ('  ' + $d) } } else { Write-Color '  (пусто)' DarkGray }
    $why = Join-Path $Script:Runtime 'autohostlist-debug.log'
    if (Test-Path $why) {
        $added = @([System.IO.File]::ReadAllLines($why) | Where-Object { $_ -match 'adding to' } | Select-Object -Last 8)
        if ($added.Count) {
            Write-Color 'Последние добавления (сайт, адрес вашего ПК, протокол):' DarkGray
            foreach ($l in $added) { Write-Color ('  ' + $l) DarkGray }
        }
    }
    Write-Host ''
    Write-Host '  1. Очистить автосписок'
    Write-Host '  2. Удалить один сайт'
    Write-Host ('  3. ' + $(if ($s.autolist -eq 'on') { 'Выключить' } else { 'Включить' }) + ' автосписок')
    $c = Read-Host 'Выбор (Enter - назад)'
    switch ($c) {
        '1' {
            Write-TextNoBom $file $Script:AutolistHeader
            Write-Color 'Автосписок очищен. winws2 сам перечитает его.' Green
        }
        '2' {
            $d = (Read-Host 'Сайт (как в списке выше)').Trim().ToLower()
            if (-not $d) { return }
            $lines = @([System.IO.File]::ReadAllLines($file) | Where-Object { $_.Trim().ToLower() -ne $d })
            Write-TextNoBom $file (($lines -join "`r`n") + "`r`n")
            Write-Color ("Удалён: $d") Green
        }
        '3' {
            $s.autolist = if ($s.autolist -eq 'on') { 'off' } else { 'on' }
            Save-Settings $s
            Write-Color ('Автосписок сайтов: ' + (Get-AutolistText $s)) Green
            if (Test-Running) { Start-Bypass -Quiet | Out-Null }
        }
        default { return }
    }
    Pause-Menu
}

function Update-Lists {
    Write-Color ('Скачиваю свежие списки Flowseal (' + $Script:FlowsealRaw + '):') Cyan
    $res = @(Update-FlowsealLists)
    foreach ($u in $res) { Write-Color ('  ' + $u.Text) $(if (-not $u.Ok) { 'Red' } elseif ($u.Changed) { 'Green' } else { 'Gray' }) }
    if (@($res | Where-Object { $_.Changed }).Count) {
        Write-Color 'Старые версии сохранены рядом (.bak). winws2 сам перечитает списки, перезапуск не нужен.' Gray
    }
    Write-Color 'Проверяю новые версии zapret, zapret2 и Flowseal...' Cyan
    if (Update-UpstreamCheck -Force) {
        $upd = Get-ZapretUpdate
        $news = @(Get-UpstreamNews)
        if ($upd) { Write-Color ('  Вышла новая версия zapret ' + $upd + ' - скачать: https://github.com/' + $Script:SelfRepo + '/releases') Yellow }
        foreach ($x in $news) { Write-Color ('  Вышла новая версия основы: ' + $x) Yellow }
        if (-not $upd -and -not $news.Count) {
            Write-Color ('  Новых нет: zapret {0}, zapret2 {1}, Flowseal {2}.' -f $Script:Version, $Script:Upstream['zapret2'].Base, $Script:Upstream['Flowseal'].Base) Green
        }
    } else {
        Write-Color '  GitHub не ответил, проверю в другой раз.' Yellow
    }
    Pause-Menu
}

function Update-ZapretMenu {
    Write-Host ''
    if (Test-Path (Join-Path $Script:Root '.git')) { Write-Color 'Это папка с исходниками (есть .git): обновляйте её через git pull.' Yellow; Pause-Menu; return }
    Write-Color 'Узнаю последнюю версию на GitHub...' Cyan
    $rel = Get-ZapretRelease
    if (-not $rel) { Write-Color ('  GitHub не ответил. Скачать можно вручную: https://github.com/' + $Script:SelfRepo + '/releases') Yellow; Pause-Menu; return }
    if (-not (Test-NewerVersion $rel.Tag $Script:Version)) { Write-Color ('  У вас последняя версия: zapret ' + $Script:Version + '.') Green; Pause-Menu; return }
    Write-Color ('  Вышла zapret {0}, у вас {1}. Что нового: https://github.com/{2}/releases' -f $rel.Tag, $Script:Version, $Script:SelfRepo) White
    Write-Color '  Обход остановится на полминуты. Настройки, рейтинг, ваши списки и списки Flowseal останутся.' Gray
    if (-not (Read-YesNo 'Обновить?')) { return }
    if (Install-ZapretUpdate $rel) {
        Start-Process -FilePath (Join-Path $Script:Root 'zapret.bat') -WorkingDirectory $Script:Root
        exit 0
    }
    Pause-Menu
}

function Clear-DiscordMenu {
    Write-Host ''
    Write-Color 'Очистка кэша Discord (как у Flowseal): помогает, если Discord не запускается, висит на загрузке или на обновлении.' Cyan
    Write-Color 'Discord закроется. Вход, настройки и сообщения останутся - удаляются только папки кэша.' Gray
    if (-not (Read-YesNo 'Очистить?')) { return }
    $res = @(Clear-DiscordCache)
    if (-not $res.Count) { Write-Color 'Discord на этом ПК не найден.' Yellow; Pause-Menu; return }
    foreach ($r in $res) {
        $t = '{0}: очищено папок кэша - {1}' -f $r.Name, $r.Cleared
        if ($r.Failed.Count) { $t += ', не удалось: ' + ($r.Failed -join ', ') + ' (закройте Discord в трее и повторите)' }
        Write-Color ('  ' + $t) $(if ($r.Failed.Count) { 'Yellow' } else { 'Green' })
    }
    if (@($res | Where-Object { $_.Name -eq 'Discord' }).Count) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList 'discord://-/'
        Write-Color 'Discord запускается заново (первый запуск после очистки - чуть дольше).' Green
    }
    Pause-Menu
}

function Connect-TgDesktop {
    # tg://proxy открывает Telegram Desktop с вопросом "Подключиться к прокси?" - ответьте "Подключиться"
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Get-TgLink)
    Write-Color 'Открываю Telegram: на вопрос о прокси нажмите "Подключиться".' Green
    Write-Color 'Не открылся - Telegram: Настройки -> Продвинутые настройки -> Тип подключения -> Прокси: MTProto, 127.0.0.1, порт и secret - в runtime\telegram.txt (secret с dd впереди).' Gray
}

function Show-TelegramMenu {
    while ($true) {
        Show-Header
        $on = (Get-Settings).telegram -eq 'on'
        $state = if (-not $on) { 'выключен' } elseif (Test-TgBridgeRunning) { 'включён, работает' } else { 'включён, но не запущен' }
        Write-BoxRow ' Telegram: встроенный мост' Cyan
        Write-BoxRow '  Telegram Desktop ходит через мост на этом ПК, а мост - через веб-версию Telegram, которую не режут. Ничего не скачивается.' Gray
        Write-BoxRow ('  Сейчас: ' + $state) Gray
        Write-BoxRow ('  1. ' + $(if ($on) { 'Выключить' } else { 'Включить: работает с входа в Windows и сам поднимается, если закрылся' }))
        Write-BoxRow '  2. Подключить Telegram Desktop к мосту'
        Write-BoxSep
        Write-BoxRow '  0. Назад'
        Write-BoxBottom
        $c = (Read-Host 'Выбор').Trim()
        switch ($c) {
            '1' {
                Write-Host ''
                if ($on) {
                    Set-TelegramMode $false | Out-Null
                    Write-Color 'Мост выключен. В Telegram выключите прокси, иначе он останется без сети: Настройки -> Продвинутые настройки -> Тип подключения.' Yellow
                } elseif (Set-TelegramMode $true) {
                    Write-Color 'Мост работает: стартует с входом в Windows, а если его закрыть, поднимется сам.' Green
                    if (Read-YesNo 'Подключить Telegram Desktop к мосту (если ещё не подключали)?') { Connect-TgDesktop }
                } else {
                    $owner = Get-PortOwnerName (Get-TgConfig).Port
                    if ($owner) { Write-Color ('Мост не запустился: порт ' + (Get-TgConfig).Port + ' занят программой ' + $owner + '. Закройте её и включите снова.') Yellow }
                    else { Write-Color 'Мост не запустился. Подробности - в runtime\tgbridge.log; отчёт (Инструменты -> 4) тоже их покажет.' Yellow }
                }
                Pause-Menu
            }
            '2' {
                Write-Host ''
                if (-not $on) { Write-Color 'Сначала включите мост (пункт 1).' Yellow } else { Start-TgBridge | Out-Null; Connect-TgDesktop }
                Pause-Menu
            }
            default { return }
        }
    }
}

function Export-DirectRules {
    $text = @(Get-DirectRulesText)
    $file = Join-Path ([Environment]::GetFolderPath('Desktop')) 'zapret-direct-rules.txt'
    Write-TextNoBom $file (($text -join "`r`n") + "`r`n")
    $copied = $false
    try { Set-Clipboard -Value (@($text | Where-Object { $_ -like 'domain:*' }) -join "`r`n"); $copied = $true } catch { }
    Write-Host ''
    Write-Color 'Правила "напрямую" для Happ и других прокси: Steam, Discord и игры мимо прокси, их обрабатывает обход.' Cyan
    foreach ($g in $Script:DirectDomains.Keys) { Write-Color ('  ' + $g + ': ' + ($Script:DirectDomains[$g] -join ', ')) Gray }
    Write-Color ('Полный список (домены и сети серверов игр) - на рабочем столе: ' + (Split-Path -Leaf $file)) Green
    if ($copied) { Write-Color 'Домены с приставкой domain: уже скопированы - вставьте их в прямые (direct) домены маршрутизации Happ.' Green }
    Write-Color 'После правил перезапустите Steam и Discord: они запоминают прокси при запуске.' Gray
    Pause-Menu
}

function Toggle-Notify {
    Write-Host ''
    $s = Get-Settings
    if (Test-NotifyEnabled $s) {
        if (Read-YesNo 'Уведомления включены. Выключить?') { $s.notify = 'off'; Save-Settings $s; Sync-UserTask $s | Out-Null; Write-Color 'Уведомления выключены.' Green }
        Pause-Menu; return
    }
    Write-Color 'Уведомления Windows (раз в 5 минут, без окон, от имени вашей учётной записи):' Cyan
    Write-Color '  - служба обхода остановилась и не поднялась сама;' Gray
    Write-Color '  - Steam или Discord запущены при включённом прокси и после его выключения остались без сети;' Gray
    Write-Color '  - вышла новая версия zapret; автонастройка обновила круги или списки.' Gray
    if (Read-YesNo 'Включить?') {
        $s.notify = 'on'
        Save-Settings $s
        if (Sync-UserTask $s) {
            Write-Color 'Уведомления включены. Проверочное уведомление - сейчас.' Green
            if (-not (Show-Toast 'zapret' 'Уведомления включены.')) { Write-Color 'Показать уведомление не вышло: проверьте, что уведомления Windows не выключены.' Yellow }
        } else { Write-Color 'Не удалось создать задачу в планировщике.' Red }
    }
    Pause-Menu
}

function Toggle-Autotune {
    Write-Host ''
    $task = Get-AutotuneTask
    if ($task) {
        Write-Color ('Автонастройка: ' + (Get-AutotuneText)) Cyan
        $log = Join-Path $Script:Runtime 'autotune.log'
        if (Test-Path $log) {
            Write-Color 'Последние записи журнала (runtime\autotune.log):' DarkGray
            foreach ($l in @([System.IO.File]::ReadAllLines($log) | Select-Object -Last 8)) { Write-Color ('  ' + $l) DarkGray }
        }
        if (Read-YesNo 'Выключить автонастройку?') {
            Remove-AutotuneTask
            Write-Color 'Автонастройка выключена, задача удалена из планировщика.' Green
        } elseif ((Get-AutotuneText) -match 'папка') {
            if (Install-AutotuneTask) { Write-Color 'Задача обновлена под новую папку.' Green }
        }
        Pause-Menu; return
    }
    Write-Color 'Автонастройка по расписанию (планировщик заданий Windows):' Cyan
    Write-Color ('  - раз в неделю сама запускает полный автоподбор (все стратегии) и обновляет круги автосмены (основную не меняет);') Gray
    Write-Color ('  - раз в месяц скачивает свежие списки Flowseal (сети ipset-all и домены), раз в неделю узнаёт о новых версиях;') Gray
    Write-Color '  - только когда ПК простаивает (ночью или пока вас нет), обход выключается на ~10 минут теста и включается обратно;' Gray
    Write-Color '  - пропускает раз и пробует на следующий день, если запущена игра (или античит), включён VPN или другой обход.' Gray
    Write-Color '  Журнал: runtime\autotune.log. Если папку перенесёте - включите заново этим же пунктом.' Gray
    if (Read-YesNo 'Включить автонастройку?') {
        if (Install-AutotuneTask) { Write-Color 'Автонастройка включена.' Green }
        else { Write-Color 'Не удалось создать задачу в планировщике.' Red }
    }
    Pause-Menu
}

function Toggle-Service {
    if (Get-OurService) {
        Remove-BypassService
        Write-Color 'Служба удалена, обход остановлен.' Green
    } else {
        if (-not (Resolve-ForeignBypass)) { Write-Color 'Служба не установлена: сначала остановите другой обход.' Red; Pause-Menu; return }
        Write-Color 'Ставлю службу: обход будет включаться сам при старте Windows...' Cyan
        if (Install-BypassService) { Write-Color 'Служба установлена и запущена.' Green }
        else { Write-Color 'Автозапуск с Windows не включён.' Yellow }
    }
    Pause-Menu
}

# Исключить игру из обхода по последнему трекеру: для игр, которые с обходом работают хуже, чем без него
# (серверы игры стоят у хостингов из ipset-all - так было с Dota 2 и Easy Anti-Cheat у NBA 2K).
function Exclude-TrackedGame {
    $t = Get-TrackBypassedNets
    $file = Join-Path $Script:Lists 'ipset-exclude-user.txt'
    Write-Host ''
    if (-not $t.App) {
        Write-Color 'Трекера ещё не было. Запустите игру, затем Инструменты -> 1 (имя процесса игры), поиграйте пару минут и вернитесь сюда.' Yellow
        Pause-Menu; return
    }
    if (-not $t.Nets.Count) { Write-Color ('В последнем трекере ({0}, {1}) обход не трогал ни одного адреса - исключать нечего.' -f $t.App, $t.Started) Green; Pause-Menu; return }
    Write-Color ('По последнему трекеру ({0}, {1}) обход трогает сети:' -f $t.App, $t.Started) Cyan
    foreach ($n in $t.Nets) { Write-Host ('  ' + $n) }
    Write-Color 'Исключайте, только если игра с обходом работает хуже, чем без него: не находит матч, вылетает, ругается античит.' Gray
    if ($t.App -like 'NBA2K*') { Write-Color 'Для NBA 2K27 не стоит: её серверы на AWS без обхода замерзают на 16-20 КБ, и игра выкидывает из матча.' Yellow }
    $add = @($t.Nets | Where-Object { @(Get-ListLines $file) -notcontains $_ })
    if (-not $add.Count) { Write-Color 'Все эти сети уже исключены.' Green; Pause-Menu; return }
    if (-not (Read-YesNo 'Добавить их в lists\ipset-exclude-user.txt?')) { return }
    $text = if (Test-Path $file) { [System.IO.File]::ReadAllText($file) } else { '' }
    if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    $text += ('# ' + $t.App + ': исключено по трекеру ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`r`n") + (($add -join "`r`n") + "`r`n")
    Write-TextNoBom $file $text
    Write-Color ('Исключено сетей: {0}. winws2 сам перечитает список. Вернуть - удалите эти строки из lists\ipset-exclude-user.txt.' -f $add.Count) Green
    Pause-Menu
}

function Start-Diagnostics {
    Stop-Bypass
    Write-Color 'Подробный лог пишет каждый пакет и сам по себе поднимает пинг. Включайте его только для поиска ошибки.' Yellow
    $dbg = Read-YesNo 'Писать подробный лог в runtime\debug.log?'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'diag.ps1') + '"' + $(if ($dbg) { ' -DebugLog' } else { '' })
    Start-Process -FilePath $ps -ArgumentList $a -WorkingDirectory $Script:Root
    Write-Color 'Открыл окно winws2. Если в нём ошибка, по ней видно, что мешает (антивирус, другой обход, файлы).' Cyan
    Write-Color 'Для обычной работы закройте то окно и запустите обход пунктом 1.' Cyan
    Pause-Menu
}

# Одна проверка обходов вместо нескольких пунктов: подключение (VPN, прокси, ускорители, другой обход), IPv6,
# hosts Flowseal и автосписок. В конце - список того, что можно исправить, и выбор, что исправлять.
function Show-PcCheck {
    $fixes = New-Object System.Collections.Generic.List[object]
    # блоки исправлений выполняются здесь же, в конце функции, и видят её переменные ($want и т.п.)
    function Add-Fix([string]$Text, [scriptblock]$Do) { $fixes.Add((New-Object PSObject -Property @{ Text = $Text; Do = $Do })) }

    Write-Host ''
    Write-Color 'Проверка обходов' White
    # сетевые пробы IPv6 и hosts - сразу и одновременно, пока идут быстрые проверки (раньше ~6 + ~12 с подряд)
    $v6Jobs = if (@(Get-Ipv6Addresses).Count) { Start-Ipv6Probes } else { $null }
    $pinJobs = Start-HostsPinProbes
    Write-Color '1/4 Подключение' Cyan
    Show-ConnectionCheck | Out-Null
    $foreign = @(Get-ForeignBypass)
    if ($foreign.Count) {
        Write-Color ('  ! Запущен другой обход: ' + ($foreign -join ', ')) Yellow
        Add-Fix ('Остановить другой обход (' + ($foreign -join ', ') + ')') { Resolve-ForeignBypass }
    }
    foreach ($c in @(Get-SystemConflicts)) {
        Write-Color ('  ! ' + $c.Text) Yellow
        if ($c.Key -eq 'bfe') { Add-Fix 'Включить службу Base Filtering Engine: без неё WinDivert не работает' { Repair-Bfe } }
    }
    if (@(Get-OurProcesses).Count) { Write-Color '  Обход: работает' Green } else { Write-Color '  Обход: остановлен - включается пунктом 1' Yellow }
    $tgOn = (Get-Settings).telegram -eq 'on'
    if ($tgOn -and -not (Test-TgBridgeRunning)) {
        Write-Color '  ! Мост Telegram не запущен: Telegram без него без сети.' Yellow
        Add-Fix 'Запустить мост Telegram' { Start-TgBridge }
    } elseif (-not $tgOn -and (Test-TelegramWaitsForProxy)) {
        Write-Color '  ! Telegram настроен на прокси 127.0.0.1, а там никто не слушает: Telegram без сети.' Yellow
        Add-Fix 'Включить мост Telegram (или выключите прокси в настройках Telegram)' { Set-TelegramMode $true }
    }
    $stuck = @(Get-ProxyStuckApps)
    if ($stuck.Count) {
        Write-Color ('  ! ' + ($stuck -join ' и ') + ' запущен, когда был включён прокси, и шлёт запросы в выключенный прокси: без сети, хотя выглядит "в сети".') Yellow
        Add-Fix ('Перезапустить ' + ($stuck -join ' и ') + ': иначе у него не будет сети (в Доте - нет цен и не работает "Играть")') { Restart-ProxyApps $stuck }
    } else {
        $via = @(Get-ProxyAppsNow)
        if ($via.Count) { Write-Color ('  ' + ($via -join ' и ') + ' сейчас ходит через прокси. Выключите прокси - перезапустите ' + $(if ($via.Count -gt 1) { 'их' } else { 'его' }) + ', иначе останется без сети.') Gray }
    }

    Write-Color '2/4 IPv6 (~6 с)' Cyan
    $v6 = Get-Ipv6Report $v6Jobs
    $v6Bad = $v6.Broken.Count -and -not $v6.PreferV4
    Write-Color ('  ' + $v6.Text) $(if ($v6Bad) { 'Yellow' } else { 'Gray' })
    if ($v6Bad) { Add-Fix 'Включить "предпочитать IPv4": часть сетей IPv6 не отвечает, Steam и сайты ждут по 20 секунд' { Set-PreferIpv4 $true } }
    elseif ($v6.PreferV4 -and $v6.Has -and @($v6.Rows | Where-Object { $_.Verdict -eq 'ok' }).Count) {
        Add-Fix 'Вернуть стандартный порядок Windows (сначала IPv6): сейчас IPv6 везде отвечает, "предпочитать IPv4" не нужно' { Set-PreferIpv4 $false }
    }

    Write-Color '3/4 hosts Flowseal: GitHub, Telegram и Discord по адресу из DNS и по адресу Flowseal' Cyan
    $status = Get-HostsStatus
    $rows = @(Test-HostsPins -Pending $pinJobs)
    foreach ($x in $rows) {
        $dns = if ($x.Dns.Ok) { '{0} мс' -f $x.Dns.Ms } elseif ($x.Dns.Ip) { 'не открылся' } else { 'нет адреса' }
        $pin = if ($x.Pin.Ok) { '{0} мс' -f $x.Pin.Ms } elseif ($x.Pin.Ip) { 'не открылся' } else { '-' }
        $now = if ($status[$x.Group].Present) { 'в hosts есть' } else { 'в hosts нет' }
        $color = switch ($x.Verdict) { 'helps' { 'Green' } 'worse' { 'Yellow' } default { 'Gray' } }
        Write-Color ('  {0,-9} по DNS: {1,-11} по адресу Flowseal: {2,-11} {3}' -f $x.Group, $dns, $pin, $now) $color
    }
    $want = @(Get-HostsAdvice $rows $status)
    $have = @($status.Keys | Where-Object { $status[$_].Present })
    $dirty = @($want | Where-Object { $status[$_].Stale -or $status[$_].Dups -or $status[$_].Missing })
    if (((@($want | Sort-Object) -join ',') -ne (@($have | Sort-Object) -join ',')) -or $dirty.Count) {
        $plan = 'держать в hosts ' + $(if ($want.Count) { $want -join ', ' } else { 'ничего из Flowseal' })
        $drop = @($have | Where-Object { $want -notcontains $_ })
        if ($drop.Count) { $plan += '; убрать ' + ($drop -join ', ') + ' (по адресу из DNS не хуже)' }
        if ($dirty.Count) { $plan += '; заменить устаревшие и повторы' }
        Add-Fix ('hosts: ' + $plan) { Set-HostsFlowseal $want }
    }
    $yt = @(Get-HostsYoutube)
    if ($yt.Count) { Write-Color ('  ! В hosts есть записи YouTube (' + ($yt -join ', ') + '): они мешают YouTube. Удалите их из ' + $Script:HostsFile) Yellow }
    # серверы игр, часть адресов которых провайдер режет по IP (см. lib.ps1, GamePinHosts)
    $pinsOn = (Get-Settings).gamepins -eq 'on'
    foreach ($x in @(Get-GamePinsState)) {
        $tested = @($x.Good).Count + @($x.Bad).Count
        $now = if (@($x.Pinned).Count) { 'в hosts закреплено ' + @($x.Pinned).Count } else { 'в hosts нет' }
        $bad = if (@($x.Bad).Count) { ', не отвечают: ' + ($x.Bad -join ', ') } else { '' }
        Write-Color ('  Сервер игры {0}: отвечают {1} из {2} адресов{3}; {4}' -f $x.Host, @($x.Good).Count, $tested, $bad, $now) $(if (@($x.Bad).Count) { 'Yellow' } else { 'Gray' })
    }
    if (-not $pinsOn) {
        Add-Fix 'hosts: закрепить рабочие адреса серверов игр (api.quago.io - запись матча NBA 2K27). Часть их адресов провайдер режет по IP, и игра на них подвисает; адреса перепроверяются при каждом запуске обхода' {
            $s = Get-Settings; $s.gamepins = 'on'; Save-Settings $s
            $u = Update-GamePins; Write-Color ('  ' + (Get-GamePinsText $u)) Gray; $u.Ok
        }
    }

    Write-Color '4/4 Автосписок сайтов' Cyan
    $ips = @(Get-AutolistIps)
    Write-Color ('  ' + (Get-AutolistText (Get-Settings))) Gray
    if ($ips.Count) {
        Write-Color ('  ! В автосписке адреса вместо сайтов: ' + ($ips -join ', ')) Yellow
        Add-Fix 'Убрать адреса из автосписка: туда их добавил сбой через ускоритель или VPN, а обход на них ломает Telegram' { @(Remove-AutolistIps).Count -gt 0 }
    }

    Write-Host ''
    if (-not $fixes.Count) { Write-Color 'Исправлять нечего.' Green; Pause-Menu; return }
    Write-Color 'Что можно исправить:' White
    for ($i = 0; $i -lt $fixes.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $fixes[$i].Text) }
    $c = (Read-Host 'Номера через пробел, A - всё, Enter - ничего').Trim()
    if (-not $c) { return }
    $pick = if (@('a', 'A', 'ф', 'Ф') -contains $c) { 1..$fixes.Count } else { @($c -split '[\s,]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
    foreach ($n in $pick) {
        if ($n -lt 1 -or $n -gt $fixes.Count) { continue }
        $f = $fixes[$n - 1]
        $ok = & $f.Do
        if ($ok -ne $false) { Write-Color ('Готово: ' + $f.Text) Green } else { Write-Color ('Не получилось: ' + $f.Text) Red }
    }
    if (@($pick | Where-Object { $fixes[$_ - 1].Text -like 'hosts*' }).Count) { Write-Color 'Копия прежнего hosts - runtime\hosts-<дата>.bak. Браузер и Telegram лучше перезапустить.' Gray }
    if (@($pick | Where-Object { $fixes[$_ - 1].Text -like 'Убрать адреса*' }).Count -and @(Get-OurProcesses).Count) {
        Write-Color 'Автосписок winws2 перечитывает сам. Telegram лучше перезапустить.' Gray
    }
    Pause-Menu
}

# ---------------- действия и цикл меню ----------------
# Действия по имени: одно место для главного экрана и подменю
function Invoke-MenuAction([string]$Name) {
    switch ($Name) {
        'start' { Start-WithChecks; Pause-Menu }
        'stop' {
            # перед удалением или заменой папки - обычные права, чтобы Проводник не спрашивал разрешения на каждый файл
            Unprotect-Package
            Write-TextNoBom (Get-PkgPath $Script:ManualStopFile) (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            if (Stop-Bypass -Unload) { Write-Color 'Обход остановлен, драйвер WinDivert выгружен. Папку можно удалять или обновлять.' Green }
            else {
                Write-Color ('Обход остановлен. Драйвер WinDivert оставлен: им пользуется другой обход (' + (@(Get-ForeignBypass) -join ', ') + ').') Yellow
                Write-Color 'Чтобы удалить папку, сначала остановите тот обход и снова выберите пункт 2.' Yellow
            }
            if (Get-AutotuneTask) { Write-Color 'Автонастройка по расписанию включит обход после очередного теста, только если он работал. Перед удалением папки выключите её (Настройки -> 7).' Gray }
            if (Get-NotifyTask) { Write-Color 'Перед удалением папки выключите и уведомления (Настройки -> 10).' Gray }
            # перед удалением - вернуть то, что сборка меняла в Windows по проверке обходов
            $hostsSet = @((Get-HostsStatus).Values | Where-Object { $_.Present }).Count -gt 0
            $pinsSet = @(Read-HostsEntries $Script:HostsFile | Where-Object { $Script:GamePinHosts -contains $_.Host }).Count -gt 0
            if ($hostsSet -or $pinsSet -or (Get-PreferIpv4)) {
                $changed = @($(if ($hostsSet) { 'записи hosts Flowseal' }), $(if ($pinsSet) { 'адреса серверов игр в hosts' }), $(if (Get-PreferIpv4) { '"предпочитать IPv4"' }) | Where-Object { $_ })
                Write-Color ('Сборка (проверка обходов) меняла в Windows: ' + ($changed -join ', ') + '.') Gray
                if (Read-YesNo 'Если удаляете сборку - вернуть как было?') {
                    if ($hostsSet) { if (Set-HostsFlowseal @()) { Write-Color 'Записи hosts Flowseal убраны.' Green } }
                    if ($pinsSet) {
                        $s = Get-Settings; $s.gamepins = 'off'; Save-Settings $s
                        if (Set-GamePins @{}) { Write-Color 'Адреса серверов игр из hosts убраны.' Green }
                    }
                    if (Get-PreferIpv4) { if (Set-PreferIpv4 $false) { Write-Color 'Стандартный порядок IPv6/IPv4 возвращён.' Green } }
                }
            }
            Pause-Menu
        }
        'test' {
            Write-Host ''
            Write-Host '  1. Быстрый: 9 основных стратегий и те, что сейчас в кругах (~4 мин)'
            Write-Host ('  2. Полный: все {0} стратегий, включая остальные Flowseal (~8 мин). Его же раз в неделю делает автонастройка' -f @(Get-AllStrategiesOrdered).Count)
            $m = (Read-Host '  Выбор (Enter - быстрый)').Trim()
            & (Join-Path $PSScriptRoot 'test.ps1') -Full:(@('2', 'f', 'F', 'а', 'А') -contains $m)
            Pause-Menu
        }
        'check' { Show-PcCheck }
        'strategy' { Select-AltManual }
        'auto' { Toggle-Auto }
        'game' { Select-GameFilter }
        'ipset' { Select-Ipset }
        'autolist' { Show-Autolist }
        'service' { Toggle-Service }
        'autotune' { Toggle-Autotune }
        'lists' { Update-Lists }
        'update' { Update-ZapretMenu }
        'tracker' {
            Write-Host ''
            Write-Host '  За какой программой следить?'
            Write-Host '    1. NBA 2K27 (Enter)'
            Write-Host '    2. Discord (зайдите в голосовой канал)'
            Write-Host '    или имя процесса из диспетчера задач без .exe, например dota2'
            $pn = (Read-Host '  Выбор').Trim()
            if (-not $pn -or $pn -eq '1') { $pn = 'NBA2K*' } elseif (@('2', 'd', 'D', 'в', 'В') -contains $pn) { $pn = 'Discord' } else { $pn = $pn -replace '\.exe$', '' }
            & (Join-Path $PSScriptRoot 'track.ps1') -ProcessName $pn
            Pause-Menu
        }
        'scanner' { & (Join-Path $PSScriptRoot 'scan.ps1'); Pause-Menu }
        'provider' { & (Join-Path $PSScriptRoot 'provider-check.ps1') }
        'report' { & (Join-Path $PSScriptRoot 'report.ps1'); Pause-Menu }
        'diag' { Start-Diagnostics }
        'exclude' { Exclude-TrackedGame }
        'direct' { Export-DirectRules }
        'telegram' { Show-TelegramMenu }
        'discordcache' { Clear-DiscordMenu }
        'notify' { Toggle-Notify }
    }
}

# Буквы версий до zapret 1.0 (NBA2K27-zapret2) работают с любого экрана - для тех, кто к ним привык. Русская раскладка - та же клавиша.
$Script:LetterKeys = @{
    'C' = 'check'; 'С' = 'check'; 'H' = 'check'; 'Р' = 'check'; 'T' = 'tracker'; 'Е' = 'tracker'; 'S' = 'service'; 'Ы' = 'service'
    'U' = 'autotune'; 'Г' = 'autotune'; 'A' = 'autolist'; 'Ф' = 'autolist'; 'P' = 'provider'; 'З' = 'provider'
    'R' = 'report'; 'К' = 'report'; 'D' = 'diag'; 'В' = 'diag'
}

# после обновления (Настройки -> 9) - включить обход, если он работал до него
$updFlag = Join-Path $Script:Runtime 'update-restart.txt'
if (Test-Path $updFlag) {
    $wasOn = ([System.IO.File]::ReadAllText($updFlag).Trim() -eq 'start')
    Remove-Item $updFlag -Force
    Write-Color ('zapret обновлён до ' + $Script:Version + '.') Green
    if ($wasOn) { Start-WithChecks; Pause-Menu }
}

while ($true) {
    Show-Header
    Show-Main
    $c = (Read-Host 'Выбор').Trim().ToUpper()
    switch ($c) {
        '0' { exit 0 }
        '1' { Invoke-MenuAction 'start' }
        '2' { Invoke-MenuAction 'stop' }
        '3' { Invoke-MenuAction 'test' }
        '4' { Invoke-MenuAction 'strategy' }
        '5' { Invoke-MenuAction 'check' }
        '6' { Show-SettingsMenu }
        '7' { Show-ToolsMenu }
        default {
            if (@('N', 'Т') -contains $c) { Show-SettingsMenu }
            elseif (@('I', 'Ш') -contains $c) { Show-ToolsMenu }
            elseif ($Script:LetterKeys.ContainsKey($c)) { Invoke-MenuAction $Script:LetterKeys[$c] }
        }
    }
}
