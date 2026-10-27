# zapret: общие функции. Подключается из menu.ps1, test.ps1, scan.ps1, report.ps1.
# Совместимо с Windows PowerShell 5.1.

Set-StrictMode -Version 2

$Script:Root        = Split-Path -Parent $PSScriptRoot
$Script:Bin         = Join-Path $Script:Root 'bin'
$Script:Exe         = Join-Path $Script:Bin 'winws2.exe'
$Script:Runtime     = Join-Path $Script:Root 'runtime'
$Script:Lists       = Join-Path $Script:Root 'lists'
$Script:StratDir    = Join-Path $Script:Root 'strategies'
$Script:ServiceName = 'zapret2-bypass'
$Script:ServiceDisplayName = 'zapret - обход DPI'
$Script:Version     = '1.2'
$Script:Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

# Порты Discord как у Flowseal: TCP для discord.media, UDP для голоса
$Script:DiscordTcpPorts = '2053,2083,2087,2096,8443'
$Script:DiscordUdpPorts = '19294-19344,50000-50100'
# Основные стратегии: быстрый автоподбор и круг автосмены, пока автоподбор не запускали. Порядок: сначала ALT Flowseal,
# с которыми игра работала в наших проверках, затем стратегии bol-van из документации zapret2 (другие техники: MD5-опция,
# сдвиг seq, обратный порядок частей). 31, 32 - мягкие ALT11/ALT12 без ложного начала для сайтов: щадят серверы Akamai.
# Остальные стратегии Flowseal (1-9, 40-48) проверяет полный автоподбор; в круг они попадают только по его рейтингу.
$Script:RotationPref = @('12', '11', '32', '31', '13', '10', '21', '22', '23')
$Script:AutolistFile = 'lists/autohostlist.txt'
$Script:AutolistHeader = "# Автосписок: сюда zapret2 сам дописывает сайты вне списков, которые 3 раза подряд не открылись" +
    " (замерзание, сброс от DPI). Очистить - Настройки -> 5 в меню.`r`n"
# Секции, которые обязаны быть в каждом файле стратегии. Необязательная [ipset_tcp] - стратегия для сетей ipset-all,
# если у Flowseal она другая, чем для общего списка (ALT7 и др.); без неё сети ipset-all получают [general].
$Script:Sections = @('quic', 'discord_udp', 'discord_media', 'google', 'general', 'game_tcp', 'game_udp')
# Клиенты прокси/VPN: их серверы исключаются из обработки, чтобы обход не трогал туннель
$Script:ProxyProcessNames = @('v2rayN', 'nekoray', 'nekobox', 'Throne', 'clash*', 'mihomo*', 'sing-box*', 'xray*', 'Hiddify*', 'AmneziaVPN*', 'happ*', 'Outline*')

if (-not (Test-Path $Script:Runtime)) { New-Item -ItemType Directory -Path $Script:Runtime -Force | Out-Null }

function Write-TextNoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Script:Utf8NoBom)
}

function Write-Color([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}

# Цвета не из 16 стандартных (светло-розовая строка в шапке меню) - через escape-последовательности консоли.
# Windows Terminal понимает их сразу, старой консоли (conhost) их включаем. Не вышло (или вывод не в консоль) -
# вместо них ближайший стандартный цвет.
$Script:ConsoleVt = $null
function Enable-ConsoleColors {
    if ($null -ne $Script:ConsoleVt) { return $Script:ConsoleVt }
    $Script:ConsoleVt = $false
    if ($env:WT_SESSION) { $Script:ConsoleVt = $true; return $true }
    try {
        if (-not ('NbaVt.NbaConsole' -as [type])) {
            Add-Type -Namespace NbaVt -Name NbaConsole -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
'@
        }
        $h = [NbaVt.NbaConsole]::GetStdHandle(-11)
        $m = [uint32]0
        # 4 - ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if ([NbaVt.NbaConsole]::GetConsoleMode($h, [ref]$m) -and (($m -band 4) -or [NbaVt.NbaConsole]::SetConsoleMode($h, ($m -bor 4)))) { $Script:ConsoleVt = $true }
    } catch { }
    return $Script:ConsoleVt
}

function Write-Rgb([string]$Text, [int[]]$Rgb, [string]$Fallback = 'Magenta', [switch]$NoNewline) {
    if (Enable-ConsoleColors) {
        $e = [char]27
        Write-Host ($e + '[38;2;' + $Rgb[0] + ';' + $Rgb[1] + ';' + $Rgb[2] + 'm' + $Text + $e + '[0m') -NoNewline:$NoNewline
    } else { Write-Host $Text -ForegroundColor $Fallback -NoNewline:$NoNewline }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-YesNo([string]$Question) {
    $ans = Read-Host ($Question + ' (y/n)')
    return ($ans -match '^[yYдД]')
}

# ---------- настройки ----------

function Get-Settings {
    $s = @{ alt = '12'; auto = 'on'; game = 'all'; ipset = 'loaded'; gametcp = '1024-65535'; gameudp = '1024-65535'; autolist = 'on' }
    $f = Join-Path $Script:Runtime 'settings.ini'
    if (Test-Path $f) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match '^\s*([a-z]+)\s*=\s*(.*?)\s*$') { $s[$matches[1]] = $matches[2] }
        }
    }
    if (@('all', 'tcp', 'udp', 'off') -notcontains $s.game) { $s.game = 'all' }
    if (@('loaded', 'any', 'none') -notcontains $s.ipset) { $s.ipset = 'loaded' }
    if (@('on', 'off') -notcontains $s.autolist) { $s.autolist = 'on' }
    if (-not (Test-PortList $s.gametcp)) { $s.gametcp = '1024-65535' }
    if (-not (Test-PortList $s.gameudp)) { $s.gameudp = '1024-65535' }
    return $s
}

function Save-Settings([hashtable]$Settings) {
    $lines = @($Settings.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Settings[$_] })
    Write-TextNoBom (Join-Path $Script:Runtime 'settings.ini') (($lines -join "`r`n") + "`r`n")
}

# '1024-65535' или '1024-2000,3000' и т.п.
function Test-PortList([string]$Text) {
    if (-not $Text) { return $false }
    foreach ($x in ($Text -split ',')) {
        if ($x -notmatch '^(\d{1,5})(-(\d{1,5}))?$') { return $false }
        $a = [int]$matches[1]
        $b = if ($matches[3]) { [int]$matches[3] } else { $a }
        if ($a -lt 1 -or $b -gt 65535 -or $a -gt $b) { return $false }
    }
    return $true
}

function Get-GameText([hashtable]$Settings) {
    switch ($Settings.game) {
        'all' { return ('TCP и UDP (TCP {0}, UDP {1})' -f $Settings.gametcp, $Settings.gameudp) }
        'tcp' { return ('только TCP {0}' -f $Settings.gametcp) }
        'udp' { return ('только UDP {0}' -f $Settings.gameudp) }
        default { return 'выключен' }
    }
}

function Get-IpsetText([string]$Mode) {
    switch ($Mode) {
        'loaded' { return 'loaded (сети из lists\ipset-all.txt, как у Flowseal)' }
        'any'    { return 'any (все адреса, кроме исключений и серверов 2K)' }
        default  { return 'none (только домены Discord/YouTube и найденное сканером)' }
    }
}

# ---------- стратегии ----------
# Файл strategies\altNN.txt: заголовок "# name:", "# desc:", затем секции [quic], [discord_udp] ... с параметрами winws2.

function Get-Strategies {
    $result = @()
    foreach ($file in (Get-ChildItem -Path $Script:StratDir -Filter 'alt*.txt' | Sort-Object { [int]($_.BaseName -replace '\D', '') })) {
        if ($file.BaseName -notmatch '^alt(\d+)$') { continue }
        $id = $matches[1]
        $name = 'ALT' + $id
        $desc = ''
        $sec = @{}
        $cur = $null
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            $t = $line.Trim()
            if ($t -match '^#\s*name:\s*(.+)$') { $name = $matches[1]; continue }
            if ($t -match '^#\s*desc:\s*(.+)$') { $desc = $matches[1]; continue }
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            if ($t -match '^\[([a-z_]+)\]$') { $cur = $matches[1]; $sec[$cur] = @(); continue }
            if ($cur) { $sec[$cur] += $t }
        }
        $missing = @($Script:Sections | Where-Object { -not $sec.ContainsKey($_) })
        $result += New-Object PSObject -Property @{
            Id = $id; Name = $name; Desc = $desc; File = $file.FullName; Sections = $sec; Missing = $missing
        }
    }
    return $result
}

function Get-Strategy([string]$Id) {
    foreach ($s in (Get-Strategies)) { if ($s.Id -eq $Id) { return $s } }
    return $null
}

# Все целые стратегии в порядке RotationPref, затем любые свои (alt14.txt и т.д.) - для автоподбора
function Get-AllStrategiesOrdered {
    $all = @(Get-Strategies | Where-Object { $_.Missing.Count -eq 0 })
    $order = @()
    foreach ($id in $Script:RotationPref) { $order += @($all | Where-Object { $_.Id -eq $id }) }
    $order += @($all | Where-Object { $Script:RotationPref -notcontains $_.Id })
    return $order
}

# ---------- рейтинг стратегий по последнему автоподбору (runtime\test-rank.txt) ----------
# Строки: "id score ok total harm freeze ГРУППА=ok/total ...", score = пробито - вред;
# строка "base ok total ГРУППА=ok/total ..." - прогон без обхода.
# У каждого профиля обхода свой круг автосмены, по своим группам теста (SectionGroups):
# YouTube - по группе YouTube, Discord - по Discord, игровой TCP - по хостингам, 2K и EAC,
# сайты - по общему "пробито минус вред". В круг попадают только стратегии, которые дают хотя бы
# RankMinShare прироста лучшей относительно прогона без обхода. Слабые остаются в strategies\ и в автоподборе.
$Script:RankFile = 'runtime/test-rank.txt'
$Script:RankMinShare = 0.6
# В группах на 3-4 адреса почти все стратегии набирают максимум; дальше пятой по кругу всё равно не уйдёт
$Script:RingMax = 5
$Script:SectionGroups = @{ google = @('YouTube'); discord_media = @('Discord'); game_tcp = @('DPI', 'NBA2K', 'EAC') }
$Script:SectionTitles = [ordered]@{ general = 'сайты'; google = 'YouTube'; discord_media = 'Discord'; game_tcp = 'игра' }

# Баллы автоподбора бывают дробными: адрес, открывшийся только со второй попытки, даёт полбалла.
# В файл рейтинга и отчёты - всегда с точкой, независимо от языка Windows.
function Format-Points([double]$X) { return $X.ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) }
function ConvertFrom-Points([string]$Text) { return [double]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture) }

function Read-RankGroups([string]$Text) {
    $g = @{}
    foreach ($m in [regex]::Matches($Text, '(\w+)=(\d+(?:\.\d+)?)/(\d+)')) { $g[$m.Groups[1].Value] = ConvertFrom-Points $m.Groups[2].Value }
    return $g
}

function Get-TestRank {
    $f = Get-PkgPath $Script:RankFile
    if (-not (Test-Path $f)) { return $null }
    $rows = @(); $baseOk = $null; $baseGroups = @{}; $date = $null
    $n = '(-?\d+(?:\.\d+)?)'
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        if ($line -match '^#\s*date:\s*(.+)$') { $date = $matches[1].Trim(); continue }
        if ($line -match ('^base\s+' + $n + '\s+(\d+)(.*)$')) { $baseOk = ConvertFrom-Points $matches[1]; $baseGroups = Read-RankGroups $matches[3]; continue }
        if ($line -match ('^(\d+)\s+' + $n + '\s+' + $n + '\s+(\d+)\s+(\d+)\s+(\d+)(.*)$')) {
            $rows += New-Object PSObject -Property @{ Id = $matches[1]; Score = (ConvertFrom-Points $matches[2]); Ok = (ConvertFrom-Points $matches[3])
                Total = [int]$matches[4]; Harm = [int]$matches[5]; Freeze = [int]$matches[6]; Groups = (Read-RankGroups $matches[7]) }
        }
    }
    if ($null -eq $baseOk -or $rows.Count -eq 0) { return $null }
    return New-Object PSObject -Property @{ Date = $date; BaseOk = $baseOk; BaseGroups = $baseGroups; Rows = $rows }
}

# Стратегии, достаточно сильные для профиля, от лучшей к худшей (Id). $null - по этому профилю различать нечего
# (группа у провайдера не блокируется или рейтинг старого формата): тогда берётся круг сайтов.
function Get-SectionRank($Rank, [string]$Section) {
    $groups = $Script:SectionGroups[$Section]
    $score = @{}
    if ($groups) {
        foreach ($g in $groups) { if (-not $Rank.BaseGroups.ContainsKey($g)) { return $null } }
        $base = 0; foreach ($g in $groups) { $base += $Rank.BaseGroups[$g] }
        foreach ($r in $Rank.Rows) { $s = 0.0; foreach ($g in $groups) { if ($r.Groups.ContainsKey($g)) { $s += $r.Groups[$g] } }; $score[$r.Id] = $s - $base }
    } else {
        foreach ($r in $Rank.Rows) { $score[$r.Id] = $r.Score - $Rank.BaseOk }
    }
    $bestGain = ($score.Values | Measure-Object -Maximum).Maximum
    if ($bestGain -le 0) { return $null }
    $q = @($Rank.Rows | Where-Object { $score[$_.Id] -ge $Script:RankMinShare * $bestGain } |
        Sort-Object @{ Expression = { $score[$_.Id] }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Freeze } } |
        Select-Object -First $Script:RingMax)
    return @($q | ForEach-Object { $_.Id })
}

# $Base и $Alts - итоги автоподбора (Get-RunSummary): Ok, Total, Score, Harm, Freeze и Groups (группа -> Ok/Total)
function Save-TestRank($Base, $Alts) {
    function Format-Groups($S) { return (@($S.Groups.Keys | ForEach-Object { '{0}={1}/{2}' -f $_, (Format-Points $S.Groups[$_].Ok), $S.Groups[$_].Total }) -join ' ') }
    $lines = @('# Рейтинг стратегий по автоподбору: порядок и состав кругов автосмены. Удалите файл - вернётся стандартный порядок.',
        ('# date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        '# id score(пробито-вред) ok total harm freeze группы; .5 - адрес открылся только со второй попытки',
        ('base {0} {1} {2}' -f (Format-Points $Base.Ok), $Base.Total, (Format-Groups $Base)))
    foreach ($r in $Alts) {
        $lines += ('{0} {1} {2} {3} {4} {5} {6}' -f $r.Id, (Format-Points $r.Score), (Format-Points $r.Ok), $r.Total, $r.Harm, $r.Freeze, (Format-Groups $r))
    }
    Write-TextNoBom (Get-PkgPath $Script:RankFile) (($lines -join "`r`n") + "`r`n")
}

# Круг автосмены профиля $Section (general - сайты, google - YouTube, discord_media, game_tcp).
# С рейтингом: основная первой, если она достаточно сильная для этого профиля, дальше остальные сильные.
# Без рейтинга (автоподбор ещё не запускали) - основная и основные стратегии в порядке RotationPref.
function Get-RotationOrder([string]$PrimaryId, [string]$Section = 'general') {
    $all = @(Get-Strategies | Where-Object { $_.Missing.Count -eq 0 })
    $primary = @($all | Where-Object { $_.Id -eq $PrimaryId })
    $rank = Get-TestRank
    if ($rank) {
        $ids = Get-SectionRank $rank $Section
        if ($null -eq $ids) { $ids = Get-SectionRank $rank 'general' }
        if ($null -ne $ids) {
            $order = @()
            if ($ids -contains $PrimaryId) { $order += $primary }
            foreach ($id in $ids) { $order += @($all | Where-Object { $_.Id -eq $id -and $_.Id -ne $PrimaryId }) }
            if ($order.Count) { return $order }
        }
    }
    $order = $primary
    foreach ($id in $Script:RotationPref) { $order += @($all | Where-Object { $_.Id -eq $id -and $_.Id -ne $PrimaryId }) }
    return $order
}

# Что проверяет автоподбор. Полный - все стратегии. Быстрый - основные (RotationPref), основная и все, кто сейчас
# в кругах автосмены: так стратегия, найденная полным автоподбором, не выпадает из круга после быстрого.
function Get-TestStrategies([switch]$Full) {
    $all = @(Get-AllStrategiesOrdered)
    if ($Full) { return $all }
    $s = Get-Settings
    $keep = @($Script:RotationPref) + @($s.alt)
    foreach ($sec in $Script:SectionTitles.Keys) { $keep += @(Get-RotationOrder $s.alt $sec | ForEach-Object { $_.Id }) }
    return @($all | Where-Object { $keep -contains $_.Id })
}

# Круги профилей, которые отличаются от круга сайтов: "YouTube: A > B" и т.д.
function Get-RingsText([hashtable]$Settings) {
    if ($Settings.auto -ne 'on' -or -not (Get-TestRank)) { return @() }
    $general = (@(Get-RotationOrder $Settings.alt 'general' | ForEach-Object { $_.Id })) -join ','
    $out = @()
    foreach ($sec in @('google', 'discord_media', 'game_tcp')) {
        $ring = @(Get-RotationOrder $Settings.alt $sec)
        if ((@($ring | ForEach-Object { $_.Id }) -join ',') -ne $general) {
            $out += ('{0}: {1}' -f $Script:SectionTitles[$sec], (($ring | ForEach-Object { $_.Name }) -join ' > '))
        }
    }
    return $out
}

# ---------- списки ----------

function Get-ListLines([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    # List, а не массив с +=: в ipset-all.txt 33 тыс. строк
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $i = $line.IndexOfAny([char[]]'#;')
        $t = if ($i -ge 0) { $line.Substring(0, $i).Trim() } else { $line.Trim() }
        if ($t) { $out.Add($t) }
    }
    return $out.ToArray()
}

function Test-PublicIp([string]$Ip) {
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$a)) { return $false }
    if ([System.Net.IPAddress]::IsLoopback($a)) { return $false }
    $b = $a.GetAddressBytes()
    if (@($b | Where-Object { $_ -ne 0 }).Count -eq 0) { return $false }   # 0.0.0.0 и ::
    if ($b.Count -eq 4) {
        if ($b[0] -eq 10 -or $b[0] -eq 0 -or $b[0] -ge 224) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
        if ($b[0] -eq 198 -and ($b[1] -eq 18 -or $b[1] -eq 19)) { return $false }
        return $true
    }
    if ($a.IsIPv6LinkLocal -or $a.IsIPv6SiteLocal -or $a.IsIPv6Multicast) { return $false }
    if (($b[0] -band 0xFE) -eq 0xFC) { return $false }
    return $true
}

# Служебный список в runtime\ для режима IPSet any.
# Серверы прокси автоматически не исключаются: ядро прокси (xray, sing-box) само ходит напрямую к сайтам
# по правилам "direct", и такие адреса не отличить от сервера прокси. Свой сервер можно вписать в ipset-exclude-user.txt.
function Update-RuntimeLists {
    Write-TextNoBom (Join-Path $Script:Runtime 'ipset-any.txt') "0.0.0.0/0`r`n::/0`r`n"
    $auto = Get-PkgPath $Script:AutolistFile
    if (-not (Test-Path $auto)) { Write-TextNoBom $auto $Script:AutolistHeader }
    Remove-AutolistIps | Out-Null
    # журнал автосписка (почему сайт попал в список) не даём разрастись больше 1 МБ
    $dbg = Join-Path $Script:Runtime 'autohostlist-debug.log'
    if ((Test-Path $dbg) -and (Get-Item $dbg).Length -gt 1MB) { Move-Item $dbg ($dbg + '.old') -Force }
}

# Домены, которые zapret2 сам добавил в автосписок
function Get-AutolistDomains {
    return @(Get-ListLines (Get-PkgPath $Script:AutolistFile))
}

# Автосписок задуман для сайтов. IP-адрес попадает туда, только когда программа ходит по HTTP на адрес без имени
# и соединения рвутся по другой причине: так через ExitLag туда попали серверы Telegram, после чего его запасной
# HTTP-канал получал фейки и разрезку и Telegram переставал подключаться. Такие строки убираем перед каждым запуском.
function Get-AutolistIps {
    return @(Get-AutolistDomains | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -or $_.Contains(':') })
}

function Remove-AutolistIps {
    $ips = @(Get-AutolistIps)
    if (-not $ips.Count) { return @() }
    $f = Get-PkgPath $Script:AutolistFile
    $keep = @([System.IO.File]::ReadAllLines($f) | Where-Object { $ips -notcontains $_.Trim() })
    Write-TextNoBom $f (($keep -join "`r`n") + "`r`n")
    return $ips
}

function Get-AutolistText([hashtable]$Settings) {
    if ($Settings.autolist -ne 'on') { return 'выключен' }
    return ('включён, сайтов в нём: {0}' -f @(Get-AutolistDomains).Count)
}

# ---------- сборка параметров winws2 ----------
# Параметры передаются прямо в командной строке, как у Flowseal: файл @config в Windows-сборке winws2
# разбирается через bash, которого в Windows нет. Все пути абсолютные: у службы рабочая папка System32.

function Get-PkgPath([string]$Rel) {
    $sep = if ($Script:Root -match '^[A-Za-z]:\\') { '\' } else { '/' }
    return $Script:Root.TrimEnd('\', '/') + $sep + ($Rel -replace '[\\/]', $sep)
}

# Профили повторяют general (ALT10-13).bat Flowseal в том же порядке, с Game Filter и IPSet.
# Отличия от Flowseal:
#  - на TCP-профилях работает circular (zapret-auto.lua): при 3 неудачах подряд к одному серверу
#    (повторные отправки = замерзание 16-20 КБ, RST от DPI) этот сервер переводится на следующую ALT;
#  - из UDP 443 в драйвер попадают только пакеты QUIC Initial, а не весь QUIC-трафик YouTube;
#  - сети Take-Two (собственные серверы 2K) исключены везде: они не заблокированы, а фейки и разрезка
#    в их протоколе ломают проверку Easy Anti-Cheat (fee12ea9). У Flowseal их нет в ipset-all;
#  - серверы Valve (Steam, ретрансляторы Dota 2 и CS2) исключены везде по той же причине: часть ретрансляторов
#    стоит у хостингов из ipset-all, и фейки ломали матчи в Доте;
#  - фейки с устаревшим timestamp к серверу без TCP timestamps портятся иначе (lua\fooling.lua), а не уходят целыми.
function New-BypassArgList {
    param(
        [Parameter(Mandatory = $true)] [hashtable] $Settings,
        [string] $Alt,          # ALT вместо сохранённой (автоподбор)
        [switch] $NoAuto,       # без circular, ровно одна ALT
        [string] $IpsetMode,    # loaded / any / none вместо сохранённого
        [switch] $DryRun,
        [string] $DebugFile
    )
    $altId = if ($Alt) { $Alt } else { $Settings.alt }
    $primary = Get-Strategy $altId
    if (-not $primary) { throw "Стратегия ALT$altId не найдена в strategies\" }
    if ($primary.Missing.Count -gt 0) { throw ("В {0} нет секций: {1}" -f $primary.File, ($primary.Missing -join ', ')) }
    # с автосменой у каждого профиля свой круг (Get-RotationOrder по секции), без неё - ровно основная, как у Flowseal
    $auto = ($Settings.auto -eq 'on') -and -not $NoAuto
    $ipMode = if ($IpsetMode) { $IpsetMode } else { $Settings.ipset }
    $gameTcp = @('all', 'tcp') -contains $Settings.game
    $gameUdp = @('all', 'udp') -contains $Settings.game

    $a = New-Object System.Collections.Generic.List[string]
    if ($DryRun) { $a.Add('--dry-run') }
    if ($DebugFile) { $a.Add('--debug=@' + $DebugFile) }
    $autolist = ($Settings.autolist -eq 'on')
    if ($autolist) { $a.Add('--hostlist-auto-debug=' + (Get-PkgPath 'runtime/autohostlist-debug.log')) }

    # Драйвер перехватывает только исходящее; входящие SYN+ACK/FIN/RST winws2 добавляет сам (нужны circular).
    $tcpPorts = '80,443,' + $Script:DiscordTcpPorts
    if ($gameTcp) { $tcpPorts += ',' + $Settings.gametcp }
    $udpPorts = $Script:DiscordUdpPorts
    if ($gameUdp) { $udpPorts += ',' + $Settings.gameudp }
    $a.Add("--wf-tcp-out=$tcpPorts")
    $a.Add("--wf-udp-out=$udpPorts")
    $a.Add('--wf-raw-part=@' + (Get-PkgPath 'windivert/quic_initial_ietf.txt'))

    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-lib.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-antidpi.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-auto.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/fooling.lua'))
    $a.Add('--blob=quic_google:@' + (Get-PkgPath 'fake/quic_initial_www_google_com.bin'))
    $a.Add('--blob=quic_4pda:@' + (Get-PkgPath 'fake/quic_initial_4pda_to.bin'))
    $a.Add('--blob=stun_fs:@' + (Get-PkgPath 'fake/stun.bin'))
    $a.Add('--blob=stun2:@' + (Get-PkgPath 'fake/stun2.bin'))
    $a.Add('--blob=tls_google:@' + (Get-PkgPath 'fake/tls_clienthello_www_google_com.bin'))
    $a.Add('--blob=tls_4pda:@' + (Get-PkgPath 'fake/tls_clienthello_4pda_to.bin'))
    $a.Add('--blob=tls_sferum:@' + (Get-PkgPath 'fake/tls_clienthello_www_sferum_ru.bin'))
    $a.Add('--blob=tls_sochi:@' + (Get-PkgPath 'fake/tls_clienthello_sochi_park.bin'))
    $a.Add('--blob=discord_udp:@' + (Get-PkgPath 'fake/ACTIVE_DISCORD_UDP.bin'))
    $a.Add('--blob=game_udp:@' + (Get-PkgPath 'fake/ACTIVE_GAME_UDP.bin'))

    $hostlists = @(
        ('--hostlist=' + (Get-PkgPath 'lists/list-general.txt')),
        ('--hostlist=' + (Get-PkgPath 'lists/list-general-user.txt')))
    $hostEx = @(
        ('--hostlist-exclude=' + (Get-PkgPath 'lists/list-exclude.txt')),
        ('--hostlist-exclude=' + (Get-PkgPath 'lists/list-exclude-user.txt')))
    # серверы игр, которые не заблокированы (2K и Valve), исключены во всех профилях, даже в IPSet any
    $ipGames = @(('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-taketwo.txt')), ('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-valve.txt')))
    $ipEx = @(
        ('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-exclude.txt')),
        ('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-exclude-user.txt'))) + $ipGames
    $ips = @()
    if ($ipMode -eq 'loaded') { $ips += '--ipset=' + (Get-PkgPath 'lists/ipset-all.txt') }
    elseif ($ipMode -eq 'any') { $ips += '--ipset=' + (Get-PkgPath 'runtime/ipset-any.txt') }
    $ips += '--ipset=' + (Get-PkgPath 'lists/ipset-user.txt')

    $script:firstProfile = $true
    function Add-Profile([string]$Name, [string[]]$Filters) {
        if ($script:firstProfile) { $a.Add("--name=$Name"); $script:firstProfile = $false }
        else { $a.Add("--new=$Name") }
        foreach ($f in $Filters) { $a.Add($f) }
    }
    # Секция стратегии. С circular - секции стратегий круга этого профиля по очереди, каждая со своим номером strategy=N.
    # Если в круге профиля одна стратегия (например, на этом провайдере YouTube пробивает только она) - она без circular.
    # $Fallback - секция, которую берём у стратегии, если нужной у неё нет (ipset_tcp -> general).
    function Get-SectionLines($St, [string]$Name, [string]$Fallback) {
        if ($St.Sections.ContainsKey($Name)) { return $St.Sections[$Name] }
        return $St.Sections[$Fallback]
    }
    function Add-Section([string]$Name, [switch]$Circular, [string]$CircularArgs = '', [string]$Fallback = '') {
        $ring = @(if ($Circular -and $auto) { Get-RotationOrder $altId $Name } else { $primary })
        if ($ring.Count -ge 2) {
            $a.Add('--payload=all')
            $a.Add('--out-range=-s34228')
            $a.Add('--in-range=-s5556')
            $a.Add('--lua-desync=circular:fails=3:time=60:nld=2' + $CircularArgs)
            $a.Add('--in-range=x')
            $n = 0
            foreach ($st in $ring) {
                $n++
                foreach ($l in (Get-SectionLines $st $Name $Fallback)) {
                    if ($l.StartsWith('--lua-desync=')) { $a.Add($l + ':strategy=' + $n) } else { $a.Add($l) }
                }
            }
        } else {
            foreach ($l in (Get-SectionLines $ring[0] $Name $Fallback)) { $a.Add($l) }
        }
    }

    # Стратегия "общего списка" нужна в трёх профилях (general, tcp_ipset, autolist). С автосменой это все стратегии
    # круга, и три копии раздували командную строку к пределу Windows (32767). Поэтому - шаблон zapret2 и --import.
    $a.Add('--template=tpl_general')
    Add-Section 'general' -Circular -CircularArgs ':reset'
    $a.Add('--new')

    Add-Profile 'quic_list' (@('--filter-udp=443', '--filter-l7=quic') + $hostlists + $hostEx + $ipEx)
    Add-Section 'quic'
    Add-Profile 'discord_voice' (@("--filter-udp=$($Script:DiscordUdpPorts)", '--filter-l7=discord,stun') + $ipGames)
    Add-Section 'discord_udp'
    Add-Profile 'discord_media' (@("--filter-tcp=$($Script:DiscordTcpPorts)", '--hostlist-domains=discord.media') + $ipGames)
    Add-Section 'discord_media' -Circular -CircularArgs ':reset'
    Add-Profile 'google' (@('--filter-tcp=443', ('--hostlist=' + (Get-PkgPath 'lists/list-google.txt'))) + $ipGames)
    Add-Section 'google' -Circular -CircularArgs ':reset'
    Add-Profile 'general' (@('--filter-tcp=80,443') + $hostlists + $hostEx + $ipEx + @('--import=tpl_general'))
    Add-Profile 'quic_ipset' (@('--filter-udp=443', '--filter-l7=quic') + $ips + $hostEx + $ipEx)
    Add-Section 'quic'
    # У кого-то в круге своя стратегия для сетей ipset-all - тогда профиль собирается отдельно, иначе берёт шаблон
    $ipsetRing = @(if ($auto) { Get-RotationOrder $altId 'ipset_tcp' } else { $primary })
    if (@($ipsetRing | Where-Object { $_.Sections.ContainsKey('ipset_tcp') }).Count) {
        Add-Profile 'tcp_ipset' (@('--filter-tcp=80,443,8443') + $ips + $hostEx + $ipEx)
        Add-Section 'ipset_tcp' -Circular -CircularArgs ':reset' -Fallback 'general'
    } else {
        Add-Profile 'tcp_ipset' (@('--filter-tcp=80,443,8443') + $ips + $hostEx + $ipEx + @('--import=tpl_general'))
    }
    # Автосписок (--hostlist-auto): сайты на 80/443, которые не попали ни в один профиль выше. Пока сайта нет
    # в списке, обход его не трогает и только считает неудачи; после 3 неудач подряд за минуту сайт дописывается
    # в lists\autohostlist.txt и дальше получает ту же стратегию, что и общий список. Исключения действуют и здесь.
    # Профиль стоит после всех остальных TCP 80/443: профиль с автосписком забирает любое соединение с именем сайта.
    if ($autolist) {
        Add-Profile 'autolist' (@('--filter-tcp=80,443', '--filter-l7=tls,http', ('--hostlist-auto=' + (Get-PkgPath $Script:AutolistFile))) + $hostEx + $ipEx + @('--import=tpl_general'))
    }
    # Игровые профили: RST в игру не шлём, пусть игра сама переподключается
    if ($gameTcp) {
        Add-Profile 'game_tcp' (@("--filter-tcp=$($Settings.gametcp)") + $ips + $ipEx)
        Add-Section 'game_tcp' -Circular
    }
    if ($gameUdp) {
        Add-Profile 'game_udp' (@("--filter-udp=$($Settings.gameudp)") + $ips + $ipEx)
        Add-Section 'game_udp'
    }

    return ,($a.ToArray())
}

# Один аргумент для командной строки Windows: всегда в двойных кавычках
# (так cygwin не раскрывает * и не трогает < > в аргументах вроде --out-range=<n4).
function ConvertTo-WinArg([string]$Arg) {
    $e = [regex]::Replace($Arg, '(\\*)"', '$1$1\"')
    $e = [regex]::Replace($e, '(\\+)$', '$1$1')
    return '"' + $e + '"'
}

function ConvertTo-WinCmdLine([string[]]$ArgList) {
    return (@($ArgList | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ')
}

# Командная строка winws2. Копия по одному параметру в строке кладётся в runtime\args-<Name>.txt для диагностики.
function Get-BypassCmdLine {
    param([hashtable]$Settings, [string]$Name = 'active', [string]$Alt, [switch]$NoAuto, [string]$IpsetMode, [switch]$DryRun, [string]$DebugFile)
    $list = New-BypassArgList -Settings $Settings -Alt $Alt -NoAuto:$NoAuto -IpsetMode $IpsetMode -DryRun:$DryRun -DebugFile $DebugFile
    Write-TextNoBom (Join-Path $Script:Runtime ('args-' + $Name + '.txt')) (($list -join "`r`n") + "`r`n")
    $cmd = ConvertTo-WinCmdLine $list
    # предел командной строки Windows - 32767 символов; пути к файлам повторяются в каждом профиле
    if ($cmd.Length -gt 32000) {
        throw ("Командная строка winws2 слишком длинная ({0} символов, предел Windows 32767). Перенесите папку в короткий путь, например C:\zapret" -f $cmd.Length)
    }
    return $cmd
}

# ---------- процесс и служба ----------

function Get-OurProcesses {
    return @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $Script:Exe } catch { $false }
    })
}

function Get-OurService {
    return Get-Service -Name $Script:ServiceName -ErrorAction SilentlyContinue
}

function Set-HighPriority {
    foreach ($p in (Get-OurProcesses)) {
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch { }
    }
}

function Enable-TcpTimestamps {
    # фейки с устаревшим timestamp (fooling ts у Flowseal) требуют TCP timestamps Windows
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null
}

function Stop-Bypass([switch]$Unload) {
    $svc = Get-OurService
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $Script:ServiceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
    }
    foreach ($p in (Get-OurProcesses)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Milliseconds 500
    if ($Unload) { return (Remove-WinDivertDriver) }
}

# ---------- драйвер WinDivert ----------
# После остановки winws2 драйвер остаётся загруженным и держит WinDivert64.sys (папку не удалить).
# Выгружаем его, только если им не пользуется другой обход. Следующий запуск winws2 установит его заново.
function Remove-WinDivertDriver {
    if (@(Get-ForeignBypass).Count -gt 0) { return $false }
    foreach ($n in @('WinDivert', 'WinDivert14')) {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) {
            & sc.exe stop $n 2>&1 | Out-Null
            & sc.exe delete $n 2>&1 | Out-Null
        }
    }
    return $true
}

# Если служба драйвера осталась от удалённой/перенесённой копии (файла .sys нет), WinDivert не загрузится.
function Repair-WinDivertService {
    foreach ($n in @('WinDivert', 'WinDivert14')) {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $n
        $img = $null
        try { $img = (Get-ItemProperty -Path $key -ErrorAction Stop).ImagePath } catch { continue }
        if (-not $img) { continue }
        $path = ($img -replace '^\\\?\?\\', '' -replace '^"|"$', '')
        if (-not (Test-Path -LiteralPath $path) -and @(Get-ForeignBypass).Count -eq 0) {
            & sc.exe stop $n 2>&1 | Out-Null
            & sc.exe delete $n 2>&1 | Out-Null
        }
    }
}

# Запуск внешней программы с перехватом stdout+stderr
function Invoke-Native([string]$File, [string]$Arguments, [string]$WorkDir, [int]$TimeoutSec = 30) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # curl отдаёт UTF-8 (города и провайдеры по-русски), winws2 - ASCII
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { return New-Object PSObject -Property @{ ExitCode = -1; Output = ('не удалось запустить ' + $File + ': ' + $_.Exception.Message); TimedOut = $false } }
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    # TimedOut - процесс работал до конца срока и был остановлен (для winws2 это значит "запустился и работает")
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $p.Kill() } catch { } }
    $p.WaitForExit()
    return New-Object PSObject -Property @{ ExitCode = $p.ExitCode; Output = ($so.Result + $se.Result).Trim(); TimedOut = $timedOut }
}

# Проверка параметров без перехвата трафика (--dry-run)
function Test-ConfigDry([hashtable]$Settings, [string]$Alt, [switch]$NoAuto, [string]$IpsetMode) {
    try { $cmd = Get-BypassCmdLine -Settings $Settings -Name 'check' -Alt $Alt -NoAuto:$NoAuto -IpsetMode $IpsetMode -DryRun }
    catch { return New-Object PSObject -Property @{ Ok = $false; Output = $_.Exception.Message } }
    $r = Invoke-Native $Script:Exe $cmd $Script:Bin 60
    # изредка процесс cygwin падает при старте без единого слова - это не ошибка параметров, пробуем ещё раз
    if ($r.ExitCode -ne 0 -and -not $r.Output) {
        Start-Sleep -Milliseconds 500
        $r = Invoke-Native $Script:Exe $cmd $Script:Bin 60
    }
    $out = if ($r.Output) { $r.Output } else { 'winws2 завершился с кодом {0} без сообщений' -f $r.ExitCode }
    return New-Object PSObject -Property @{ Ok = ($r.ExitCode -eq 0); Output = $out }
}

function Get-ServiceBinPath([string]$CmdLine) {
    return '"' + $Script:Exe + '" ' + $CmdLine
}

# Запускает обход с текущими настройками. Возвращает $true, если winws2 жив через 3 секунды.
function Start-Bypass([switch]$Quiet) {
    $bad = @(Test-PackageIntegrity)
    if ($bad.Count) { Write-IntegrityError $bad; return $false }
    $settings = Get-Settings
    Stop-Bypass
    Repair-WinDivertService
    Enable-TcpTimestamps
    Update-RuntimeLists

    $dry = Test-ConfigDry $settings
    if (-not $dry.Ok) {
        Write-Color 'winws2 отклонил параметры:' Red
        Write-Host $dry.Output
        return $false
    }

    $cmd = Get-BypassCmdLine -Settings $settings
    $svc = Get-OurService
    $since = Get-Date
    $err = ''
    if ($svc) {
        # параметры службы живут в её командной строке: обновляем под текущие настройки
        Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Script:ServiceName) -Name ImagePath -Value (Get-ServiceBinPath $cmd)
        $err = Start-OurService
    } else {
        # без окна: ошибки запуска видны через Инструменты -> 5 (диагностика)
        Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden | Out-Null
    }
    Start-Sleep -Seconds 3
    $alive = @(Get-OurProcesses).Count -gt 0
    if (-not $alive -and -not $svc) {
        # winws2 (cygwin) изредка падает при старте без причины - ещё одна попытка (у службы есть свой перезапуск)
        Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 3
        $alive = @(Get-OurProcesses).Count -gt 0
    }
    if (-not $alive) {
        Write-Color $(if ($svc) { 'Служба обхода не запустилась.' } else { 'winws2 завершился сразу после запуска.' }) Red
        $alive = Show-StartFailure $err $since
    }
    if ($alive) {
        Set-HighPriority
        if (-not $Quiet) {
            Write-Color ('Обход запущен: ' + (Get-AltText $settings)) Green
            foreach ($x in @(Get-RingsText $settings)) { Write-Color ('  свой круг - ' + $x) Gray }
            Write-Color ('Game Filter: ' + (Get-GameText $settings) + '. IPSet: ' + $settings.ipset) Gray
            if (@(Get-ProxyWarnings).Count) { Write-Color 'Запущен прокси/VPN: трафик через него обход не видит. Для игры выйдите из клиента полностью.' Yellow }
            foreach ($b in @(Get-GameBoosters)) { Write-Color ('Запущен игровой ускоритель ' + $b + ': он ' + $Script:BoosterHint + '.') Yellow }
        }
    }
    return $alive
}

# Start-Service, но вместо исключения - текст ошибки Windows ('' - служба запустилась)
function Start-OurService {
    try { Start-Service -Name $Script:ServiceName -ErrorAction Stop; return '' }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return $e.Message
    }
}

# Ошибки службы в журнале Windows "Система" с момента $Since (новые сверху, не больше трёх)
function Get-ServiceEvents([datetime]$Since) {
    $ev = @()
    # записей нет - Get-WinEvent тоже бросает исключение
    try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Level = 1, 2, 3; StartTime = $Since } -ErrorAction Stop) } catch { }
    return @($ev | Where-Object { $_.Message -and ($_.Message.Contains($Script:ServiceDisplayName) -or $_.Message.Contains($Script:ServiceName)) } |
        Select-Object -First 3 | ForEach-Object { ($_.Message -replace '\s+', ' ').Trim() })
}

# Подсказки по тексту ошибки: самые частые причины на чужих ПК
function Get-StartFailureHints([string]$Text) {
    $h = @()
    if ($Text -match 'already running') { $h += 'Уже работает другой winws2 с теми же фильтрами: остановите его (пункт 2) или закройте Flowseal.' }
    if ($Text -match '(?i)\b577\b|signature|подпис') { $h += 'Windows не приняла подпись драйвера WinDivert: установите все обновления Windows.' }
    if ($Text -match '(?i)\b1275\b|blocked|заблокирова') {
        $h += 'Загрузку драйвера WinDivert заблокировали: антивирус или "Безопасность Windows -> Безопасность устройства -> Изоляция ядра -> Целостность памяти". Добавьте папку в исключения антивируса; не поможет - выключите "Целостность памяти" и перезагрузите ПК.'
    }
    if ($Text -match '(?i)access is denied|отказано в доступе') { $h += 'Отказано в доступе: антивирус блокирует winws2.exe или WinDivert64.sys - добавьте папку в исключения антивируса.' }
    if ($Text -match '(?i)\b1053\b|timely|своевременно') { $h += 'Служба не ответила Windows вовремя: обычно её держит проверка антивирусом. Добавьте папку в исключения антивируса.' }
    if ($Text -match '(?i)cannot find the file|не удается найти указанный файл') { $h += 'Не найден файл: антивирус удалил winws2.exe или WinDivert64.sys. Добавьте папку в исключения и распакуйте архив заново.' }
    return $h
}

# Почему обход не запустился. Сначала то, что видно сразу: ошибка Windows при запуске службы, код, с которым служба
# завершилась, и записи журнала "Система". Затем winws2 запускается обычным процессом на 5 секунд с выводом в меню:
# если он падает и так, его последние строки и есть причина; если работает - сбой только у службы, и обход остаётся
# работать без неё. Всё это пишется в runtime\start-error.txt и попадает в отчёт (Инструменты -> 4).
# -RemoveService - служба только что поставлена и не запустилась: она удаляется, а не остаётся сбоить при каждом старте.
# Возвращает $true, если обход в итоге запущен без службы.
function Show-StartFailure([string]$StartError, [datetime]$Since, [switch]$RemoveService) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($StartError) { $lines.Add('Windows: ' + $StartError) }
    $svc = $null
    try { $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $Script:ServiceName + "'") -ErrorAction Stop } catch { }
    # 1077 - службу с загрузки ещё не запускали
    if ($svc -and @(0, 1077) -notcontains [int]$svc.ExitCode) {
        $code = if ([int]$svc.ExitCode -eq 1066) { 'winws2 вернул код ' + $svc.ServiceSpecificExitCode }
        else { '{0} - {1}' -f $svc.ExitCode, (New-Object System.ComponentModel.Win32Exception([int]$svc.ExitCode)).Message }
        $lines.Add('служба завершилась: ' + $code)
    }
    foreach ($e in @(Get-ServiceEvents $Since)) { $lines.Add('журнал Windows: ' + $e) }

    # пока winws2 проверяется отдельно, Windows не должна перезапустить службу: у неё автоперезапуск при сбое
    Stop-Bypass
    if ($svc) {
        if ($RemoveService) { & sc.exe delete $Script:ServiceName | Out-Null }
        else { & sc.exe config $Script:ServiceName start= disabled | Out-Null }
    }
    $cmd = Get-BypassCmdLine -Settings (Get-Settings)
    $r = Invoke-Native $Script:Exe $cmd $Script:Bin 5
    if ($svc -and -not $RemoveService) { & sc.exe config $Script:ServiceName start= auto | Out-Null }
    $fallback = $false
    if ($r.TimedOut) {
        $lines.Add('winws2 без службы запускается и работает: сбой только у службы Windows')
        Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 2
        $fallback = @(Get-OurProcesses).Count -gt 0
    } else {
        $tail = @(($r.Output -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 4)
        $lines.Add(('winws2 и без службы завершился сразу (код {0})' -f $r.ExitCode) + $(if ($tail.Count) { ':' } else { ', ничего не написав' }))
        foreach ($t in $tail) { $lines.Add('  ' + $t.Trim()) }
    }
    $hints = @(Get-StartFailureHints ($lines -join "`n"))

    Write-Color 'Почему не запустилось:' Yellow
    foreach ($l in $lines) { Write-Color ('  ' + $l) Gray }
    foreach ($x in $hints) { Write-Color ('  ' + $x) Yellow }
    if (-not $hints.Count) { Write-Color '  Пришлите отчёт (Инструменты -> 4): причина записана и туда. Инструменты -> 5 покажет winws2 в окне.' Yellow }
    if ($fallback) { Write-Color 'Обход запущен без службы: он работает до перезагрузки ПК.' Green }
    $os = '' + [Environment]::OSVersion.Version
    $save = @(('Обход не запустился {0}, Windows {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $os)) + @($lines) + @($hints)
    Write-TextNoBom (Join-Path $Script:Runtime 'start-error.txt') (($save -join "`r`n") + "`r`n")
    return $fallback
}

function Get-AltText([hashtable]$Settings) {
    $st = Get-Strategy $Settings.alt
    $name = if ($st) { $st.Name } else { 'ALT' + $Settings.alt + ' (нет файла!)' }
    if ($Settings.auto -eq 'on') {
        $ring = @(Get-RotationOrder $Settings.alt 'general' | ForEach-Object { $_.Name })
        $rank = Get-TestRank
        $how = if ($rank) { ' (по автоподбору от ' + $rank.Date + ')' } else { '' }
        if ($ring.Count -ge 2) { return ($name + ', круг для сайтов: ' + ($ring -join ' > ') + $how) }
        if ($rank) { return ($name + ', для сайтов других сильных стратегий нет' + $how) }
    }
    return ($name + ', без автосмены')
}

function Install-BypassService {
    $bad = @(Test-PackageIntegrity)
    if ($bad.Count) { Write-IntegrityError $bad; return $false }
    $settings = Get-Settings
    Stop-Bypass
    if (Get-OurService) { & sc.exe delete $Script:ServiceName | Out-Null; Start-Sleep -Seconds 1 }

    Enable-TcpTimestamps
    Update-RuntimeLists | Out-Null
    $dry = Test-ConfigDry $settings
    if (-not $dry.Ok) { Write-Color 'winws2 отклонил параметры:' Red; Write-Host $dry.Output; return $false }

    $binPath = Get-ServiceBinPath (Get-BypassCmdLine -Settings $settings)
    $since = Get-Date
    New-Service -Name $Script:ServiceName -BinaryPathName $binPath -DisplayName $Script:ServiceDisplayName `
        -Description 'Обход DPI для NBA 2K27, Discord и YouTube (zapret2 / winws2)' -StartupType Automatic | Out-Null
    & sc.exe failure $Script:ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
    $err = Start-OurService
    Start-Sleep -Seconds 3
    if (@(Get-OurProcesses).Count -gt 0) { Set-HighPriority; return $true }
    Write-Color 'Служба не запустилась и удалена.' Red
    Show-StartFailure $err $since -RemoveService | Out-Null
    return $false
}

# Сборка называлась NBA2K27-zapret2: служба и задача автонастройки прежних версий переносятся под новые имена
# при запуске меню (нужны права администратора). Новое имя службы не "zapret": так зовётся служба Flowseal.
$Script:LegacyServiceName = 'nba2k27-zapret2'
$Script:LegacyAutotuneTask = 'NBA2K27-zapret2 autotune'

function Update-LegacyNames {
    $old = Get-Service -Name $Script:LegacyServiceName -ErrorAction SilentlyContinue
    if ($old) {
        Write-Color ('Сборка переименована в zapret: служба автозапуска ' + $Script:LegacyServiceName + ' переносится под новым именем...') Gray
        if ($old.Status -ne 'Stopped') {
            Stop-Service -Name $Script:LegacyServiceName -Force -ErrorAction SilentlyContinue
            try { $old.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
        }
        & sc.exe delete $Script:LegacyServiceName | Out-Null
        if (-not (Get-OurService)) {
            if (Install-BypassService) { Write-Color 'Служба автозапуска перенесена: "zapret - обход DPI".' Green }
            else { Write-Color 'Новую службу поставить не вышло - включите автозапуск заново: Настройки -> 6.' Yellow }
        }
    }
    $oldTask = $null
    try { $oldTask = Get-ScheduledTask -TaskName $Script:LegacyAutotuneTask -ErrorAction Stop } catch { }
    if ($oldTask) {
        try { Unregister-ScheduledTask -TaskName $Script:LegacyAutotuneTask -Confirm:$false -ErrorAction Stop } catch { }
        if (-not (Get-AutotuneTask)) {
            if (Install-AutotuneTask) { Write-Color 'Автонастройка перенесена под новое имя задачи.' Green }
            else { Write-Color 'Автонастройку перенести не вышло - включите заново: Настройки -> 7.' Yellow }
        }
    }
}

function Remove-BypassService {
    Stop-Bypass
    if (Get-OurService) { & sc.exe delete $Script:ServiceName | Out-Null }
    Remove-WinDivertDriver | Out-Null
}

# ---------- другие обходы ----------

function Get-FlowsealService {
    return Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
}

function Get-ForeignBypass {
    # другие обходы на WinDivert, которые будут обрабатывать те же соединения
    $list = @()
    foreach ($n in @('winws', 'goodbyedpi')) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) { $list += $p.Name }
    }
    foreach ($p in @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = $p.Path } catch { }
        if ($path -ne $Script:Exe) { $list += 'winws2 (другая копия)' }
    }
    return @($list | Select-Object -Unique)
}

# Предлагает остановить Flowseal / другой обход. Возвращает $true, если посторонних обходов не осталось.
function Resolve-ForeignBypass([switch]$NoPrompt) {
    $foreign = @(Get-ForeignBypass)
    if ($foreign.Count -eq 0) { return $true }
    Write-Color ('Запущен другой обход: ' + ($foreign -join ', ') + '.') Yellow
    Write-Color 'Два обхода сразу обрабатывают одни и те же соединения и ломают их. Discord и YouTube в этой сборке уже есть.' Yellow
    if ($NoPrompt) { return $false }
    if (-not (Read-YesNo 'Остановить его?')) { return $false }
    $fs = Get-FlowsealService
    if ($fs -and $fs.Status -ne 'Stopped') {
        Stop-Service -Name 'zapret' -Force -ErrorAction SilentlyContinue
        try { $fs.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
    }
    foreach ($n in @('winws', 'goodbyedpi')) { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
    $fs = Get-FlowsealService
    if ($fs -and $fs.StartType -eq 'Automatic') {
        Write-Color 'У Flowseal стоит служба автозапуска (zapret): после перезагрузки он снова запустится.' Yellow
        if (Read-YesNo 'Отключить автозапуск Flowseal? (сам Flowseal не удаляется, включить можно его service.bat)') {
            & sc.exe config zapret start= demand | Out-Null
            Write-Color 'Автозапуск Flowseal отключён.' Green
        }
    }
    $left = @(Get-ForeignBypass)
    if ($left.Count) { Write-Color ('Не удалось остановить: ' + ($left -join ', ')) Red; return $false }
    Write-Color 'Другой обход остановлен.' Green
    return $true
}

# ---------- прокси, VPN и прямое подключение ----------

# Прокси и VPN: трафик через них zapret не видит, и пинг через них выше.
function Get-ProxyWarnings {
    $w = @()
    try {
        $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if (($is.PSObject.Properties.Name -contains 'ProxyEnable') -and $is.ProxyEnable -eq 1) {
            $srv = if ($is.PSObject.Properties.Name -contains 'ProxyServer') { $is.ProxyServer } else { '?' }
            $w += "системный прокси Windows: $srv"
        }
        if (($is.PSObject.Properties.Name -contains 'AutoConfigURL') -and $is.AutoConfigURL) { $w += "PAC-скрипт прокси: $($is.AutoConfigURL)" }
    } catch { }
    foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $w += "переменная $v = $val" }
    }
    foreach ($a in @(Get-TunAdapters)) { $w += "VPN/TUN-адаптер: $($a.Name) ($($a.InterfaceDescription))" }
    foreach ($p in @(Get-Process -Name $Script:ProxyProcessNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)) {
        $w += "запущен клиент прокси/VPN: $p"
    }
    return @($w | Select-Object -Unique)
}

function Get-TunAdapters {
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'Wintun|TAP-Windows|WireGuard|sing-box|Clash|Mihomo|Meta Tunnel|Hiddify|Happ|AmneziaWG|OpenVPN|Xray' -or $_.Name -match 'tun|wg') })
    } catch { return @() }
}

# Игровые ускорители: сами перехватывают трафик игр и Discord и ведут его через свои серверы. Вместе с обходом пакеты
# перехватывают две программы сразу: с ExitLag голос Discord пропадал (пакеты уходили, ответов не было). Ищем и процессы, и работающие службы: у некоторых служба остаётся и при закрытом окне.
$Script:GameBoosters = [ordered]@{
    'ExitLag'        = @('ExitLag*')
    'NoPing'         = @('NoPing*')
    'WTFast'         = @('WTFast*')
    'Mudfish'        = @('mudfish*', 'mudrun*')
    'GearUP Booster' = @('GearUP*')
    'LagoFast'       = @('LagoFast*')
    'Haste'          = @('Haste', 'HasteSvc*', 'Haste Service*')
    'Outfox'         = @('Outfox*')
    'Speedify'       = @('speedify*')
    'Xunyou'         = @('xunyou*')
}
$Script:BoosterHint = 'перехватывает трафик игр и Discord вместе с обходом - голос Discord пропадает, игра может вылетать. Закройте его полностью (и в трее)'

# Запущенные ускорители: "ExitLag" или "ExitLag (служба ExitLagSvc)", если окна нет, а служба работает
function Get-GameBoosters {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $svcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    $found = @()
    foreach ($name in $Script:GameBoosters.Keys) {
        $pats = $Script:GameBoosters[$name]
        $p = @($procs | Where-Object { $n = $_; @($pats | Where-Object { $n -like $_ }).Count })
        if ($p.Count) { $found += $name; continue }
        $s = @($svcs | Where-Object { $sv = $_; @($pats | Where-Object { $sv.Name -like $_ -or $sv.DisplayName -like $_ }).Count })
        if ($s.Count) { $found += ('{0} (служба {1})' -f $name, $s[0].Name) }
    }
    return $found
}

# Страна, город, провайдер и координаты IP-адресов (пустая строка - свой внешний IP). Только HTTPS: провайдер не видит,
# какие адреса проверяются, и не может подменить ответ. ipwho.is (по-русски), не ответил - ipinfo.io; по HTTP - никогда.
# Запросы параллельно, мимо системного прокси. Возвращает ip -> Ip, Country, CountryCode, City, Isp, Org, As, Lat, Lon.
function Get-IpInfo([string[]]$Ips, [int]$TimeoutSec = 8) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    function Start-Curl([string]$Url) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $curl
        $psi.Arguments = '-s --noproxy "*" --max-time ' + $TimeoutSec + ' "' + $Url + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        return New-Object PSObject -Property @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync() }
    }
    function Read-Json($Job) {
        if (-not $Job.P.WaitForExit(($TimeoutSec + 4) * 1000)) { try { $Job.P.Kill() } catch { } ; return $null }
        try { return ($Job.Out.Result | ConvertFrom-Json) } catch { return $null }
    }
    # поля в ответах бывают не все (у адресов anycast нет города), а strict mode на отсутствующее поле падает
    function Get-Field($O, [string]$Name) {
        if ($null -ne $O -and $O.PSObject.Properties.Name -contains $Name) { return $O.$Name }
        return $null
    }
    # адреса берём только похожие на IP: они попадают в URL
    $list = @($Ips | Where-Object { $_ -eq '' -or $_ -match '^[0-9a-fA-F:.]+$' } | Select-Object -Unique)
    $res = @{}
    $jobs = @{}
    foreach ($ip in $list) { $jobs[$ip] = Start-Curl ('https://ipwho.is/' + $ip + '?lang=ru') }
    foreach ($ip in $list) {
        $j = Read-Json $jobs[$ip]
        if (-not (Get-Field $j 'success')) { continue }
        $c = Get-Field $j 'connection'
        $org = [string](Get-Field $c 'org')
        $res[$ip] = New-Object PSObject -Property @{ Ip = (Get-Field $j 'ip'); Country = (Get-Field $j 'country'); CountryCode = (Get-Field $j 'country_code')
            City = (Get-Field $j 'city'); Isp = (Get-Field $c 'isp'); Org = $org; As = ('AS' + (Get-Field $c 'asn') + ' ' + $org)
            Lat = [double](Get-Field $j 'latitude'); Lon = [double](Get-Field $j 'longitude') }
    }
    $rest = @($list | Where-Object { -not $res.ContainsKey($_) })
    $jobs = @{}
    foreach ($ip in $rest) { $jobs[$ip] = Start-Curl ('https://ipinfo.io/' + $(if ($ip) { $ip + '/' }) + 'json') }
    foreach ($ip in $rest) {
        $j = Read-Json $jobs[$ip]
        $cc = Get-Field $j 'country'
        if (-not $cc) { continue }
        $org = [string](Get-Field $j 'org')
        $loc = @(([string](Get-Field $j 'loc')) -split ',')
        $res[$ip] = New-Object PSObject -Property @{ Ip = (Get-Field $j 'ip'); Country = $cc; CountryCode = $cc; City = (Get-Field $j 'city')
            Isp = ($org -replace '^AS\d+\s+', ''); Org = ($org -replace '^AS\d+\s+', ''); As = $org
            Lat = $(if ($loc.Count -eq 2) { [double]$loc[0] } else { 0.0 }); Lon = $(if ($loc.Count -eq 2) { [double]$loc[1] } else { 0.0 }) }
    }
    return $res
}

# Внешний IP и провайдер, как их видит интернет. Запрос идёт мимо системного прокси (--noproxy),
# но если включён VPN в режиме TUN, ответ покажет адрес VPN - это и есть признак, что трафик идёт не напрямую.
function Get-DirectConnectionInfo {
    $i = (Get-IpInfo @(''))['']
    if (-not $i) { return $null }
    return New-Object PSObject -Property @{
        Ip = $i.Ip; CountryCode = $i.CountryCode; Country = $i.Country; City = $i.City
        Isp = $i.Isp; As = $i.As; Lat = $i.Lat; Lon = $i.Lon
        IsRussia = ($i.CountryCode -eq 'RU')
    }
}

# Отчёты пересылают и прикладывают к issue: имя пользователя Windows (оно в путях к папке) и свой внешний IP
# в них заменяются на заглушки, где бы они ни встретились.
function Protect-ReportText([string]$Text, [string]$SelfIp) {
    if ($env:USERPROFILE) { $Text = [regex]::Replace($Text, [regex]::Escape($env:USERPROFILE), '%USERPROFILE%', 'IgnoreCase') }
    if ($env:USERNAME) { $Text = [regex]::Replace($Text, '(?i)(\\Users\\)' + [regex]::Escape($env:USERNAME) + '(?=\\|\s|$)', '${1}%USERNAME%') }
    if ($SelfIp) { $Text = $Text.Replace($SelfIp, (Get-MaskedIp $SelfIp)) }
    return $Text
}

# IP для отчётов, которые пересылают: последний октет (у IPv6 - всё после третьей группы) скрыт
function Get-MaskedIp([string]$Ip) {
    if ($Ip -match '^(\d+\.\d+\.\d+)\.\d+$') { return $matches[1] + '.x' }
    if ($Ip -match ':') { return ((($Ip -split ':') | Select-Object -First 3) -join ':') + ':...' }
    return $Ip
}

# Печатает проверку подключения. Возвращает $true, если похоже на прямое подключение из России без VPN.
function Show-ConnectionCheck {
    $ok = $true
    $proxy = @(Get-ProxyWarnings)
    $tun = @(Get-TunAdapters)
    $info = Get-DirectConnectionInfo
    if ($info) {
        Write-Color ('  Внешний IP: {0}  ({1}, {2})' -f $info.Ip, $info.Country, $info.City) White
        Write-Color ('  Провайдер:  {0}  [{1}]' -f $info.Isp, $info.As) White
        if (-not $info.IsRussia) {
            Write-Color '  ! Интернет видит не российский адрес: трафик идёт через VPN/прокси. Обход и тест в таком режиме бессмысленны.' Red
            $ok = $false
        } else {
            Write-Color '  Прямое подключение через провайдера: OK' Green
        }
    } else {
        Write-Color '  Не удалось узнать внешний IP (ipwho.is и ipinfo.io не ответили).' Yellow
    }
    if ($tun.Count) {
        Write-Color '  ! Включён VPN в режиме TUN: игра пойдёт через него, а не напрямую. Выйдите из VPN-клиента полностью.' Red
        $ok = $false
    }
    foreach ($x in $proxy) { Write-Color ('  ! ' + $x) Yellow }
    foreach ($b in @(Get-GameBoosters)) { Write-Color ('  ! Игровой ускоритель ' + $b + ': ' + $Script:BoosterHint + '.') Yellow }
    return $ok
}

# ---------- IPv6 ----------
# Сайты на разных CDN, у которых есть и IPv4, и IPv6. У некоторых провайдеров часть сетей IPv6 не отвечает совсем (Fastly, с которого
# качает Steam, Wikimedia), хотя по IPv4 те же сайты открываются. Windows по умолчанию сначала идёт по IPv6, и программы
# без быстрого перехода на IPv4 (Steam) ждут по 20 секунд. Это маршрутизация провайдера, обход тут ни при чём.
$Script:Ipv6Hosts = [ordered]@{
    'Steam CDN (Fastly)' = 'fastly.cdn.steampipe.steamcontent.com'
    'Steam CDN (Valve)'  = 'cache1-fra1.steamcontent.com'
    'Fastly'             = 'pypi.org'
    'Akamai'             = 'www.akamai.com'
    'Microsoft'          = 'www.microsoft.com'
    'Google'             = 'www.google.com'
    'Cloudflare'         = 'www.cloudflare.com'
    'Amazon CloudFront'  = 'd1.awsstatic.com'
    'GitHub'             = 'github.githubassets.com'
    'Wikipedia'          = 'www.wikipedia.org'
}

# Глобальные IPv6-адреса ПК (2000::/3, без адаптеров VPN). Локальные fe80::/fd00:: в интернет не ведут.
function Get-Ipv6Addresses {
    $tun = @(Get-TunAdapters | ForEach-Object { $_.ifIndex })
    try {
        return @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop | Where-Object {
            $_.IPAddress -match '^[23][0-9a-fA-F]{3}:' -and $_.AddressState -eq 'Preferred' -and $tun -notcontains $_.InterfaceIndex })
    } catch { return @() }
}

# "Предпочитать IPv4": в таблице политик адресов Windows (RFC 6724) IPv4 (::ffff:0:0/96) стоит выше IPv6 (::/0).
# Сайты только с IPv6 по-прежнему открываются по IPv6. Стандарт Windows: ::/0 - 40, ::ffff:0:0/96 - 35.
function Get-PreferIpv4 {
    try {
        $pol = @(Get-NetPrefixPolicy -ErrorAction Stop)
        $v4 = @($pol | Where-Object { $_.Prefix -eq '::ffff:0:0/96' })
        $any = @($pol | Where-Object { $_.Prefix -eq '::/0' })
        return [bool]($v4.Count -and $any.Count -and $v4[0].Precedence -gt $any[0].Precedence)
    } catch { return $false }
}

# Меняет одну строку таблицы политик (netsh, сохраняется после перезагрузки) и сразу действует для новых соединений.
function Set-PreferIpv4([bool]$On) {
    $prec = if ($On) { 45 } else { 35 }
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    Invoke-Native $netsh ('interface ipv6 set prefixpolicy prefix=::ffff:0:0/96 precedence={0} label=4' -f $prec) $env:SystemRoot 15 | Out-Null
    return ((Get-PreferIpv4) -eq $On)
}

# TLS до $Script:Ipv6Hosts по IPv4 и по IPv6 напрямую (мимо прокси), все запросы параллельно - около $TimeoutSec секунд.
# Verdict: ok; broken - по IPv4 открылся, по IPv6 нет; slow - по IPv6 заметно медленнее; none - у сайта нет IPv6;
# down - не открылся ни так, ни так.
function Test-Ipv6Paths([int]$TimeoutSec = 6) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $jobs = @{}
    foreach ($name in $Script:Ipv6Hosts.Keys) {
        foreach ($v in @('4', '6')) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = '-' + $v + ' -s -o NUL --noproxy "*" --ssl-no-revoke --max-time ' + $TimeoutSec + ' --connect-timeout ' + ($TimeoutSec - 1) +
                ' -w "%{http_code} %{time_appconnect}" "https://' + $Script:Ipv6Hosts[$name] + '/"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $jobs[$name + '|' + $v] = New-Object PSObject -Property @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync() }
        }
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rows = @()
    foreach ($name in $Script:Ipv6Hosts.Keys) {
        $r = @{}
        foreach ($v in @('4', '6')) {
            $j = $jobs[$name + '|' + $v]
            if (-not $j.P.WaitForExit(($TimeoutSec + 5) * 1000)) { try { $j.P.Kill() } catch { } ; $j.P.WaitForExit() }
            $parts = @($j.Out.Result.Trim() -split '\s+')
            $ms = 0
            if ($parts.Count -ge 2) { try { $ms = [math]::Round([double]::Parse($parts[1], $inv) * 1000) } catch { } }
            $r[$v] = New-Object PSObject -Property @{ Ok = ($j.P.ExitCode -eq 0 -and $parts[0] -ne '000'); Ms = $ms; Exit = $j.P.ExitCode }
        }
        $verdict = if ($r['6'].Exit -eq 6) { 'none' }
            elseif (-not $r['6'].Ok -and -not $r['4'].Ok) { 'down' }
            elseif (-not $r['6'].Ok) { 'broken' }
            elseif ($r['4'].Ok -and $r['6'].Ms -gt 2 * $r['4'].Ms + 300) { 'slow' }
            else { 'ok' }
        $rows += New-Object PSObject -Property @{ Name = $name; Host = $Script:Ipv6Hosts[$name]; V4 = $r['4']; V6 = $r['6']; Verdict = $verdict }
    }
    return $rows
}

# Итог проверки IPv6 одной строкой для отчётов (Text) и подробно (Rows).
function Get-Ipv6Report {
    $prefer = Get-PreferIpv4
    $mode = if ($prefer) { 'Windows сначала пробует IPv4 (включено "предпочитать IPv4")' } else { 'Windows сначала пробует IPv6' }
    if (-not @(Get-Ipv6Addresses).Count) {
        return New-Object PSObject -Property @{ Has = $false; PreferV4 = $prefer; Rows = @(); Broken = @(); Slow = @()
            Text = 'IPv6: у ПК нет IPv6-адреса в интернете, всё идёт по IPv4 - проверять нечего' }
    }
    $rows = @(Test-Ipv6Paths)
    $broken = @($rows | Where-Object { $_.Verdict -eq 'broken' } | ForEach-Object { $_.Name })
    $slow = @($rows | Where-Object { $_.Verdict -eq 'slow' } | ForEach-Object { $_.Name })
    $tested = @($rows | Where-Object { @('ok', 'broken', 'slow') -contains $_.Verdict }).Count
    if (-not $tested) {
        # "0 из 0": сравнивать нечего
        $why = if (@($rows | Where-Object { $_.Verdict -eq 'none' }).Count -eq $rows.Count) {
            'DNS не отдаёт сайтам IPv6-адресов (так делают некоторые VPN и прокси-клиенты), всё идёт по IPv4'
        } else { 'сайты не открылись и по IPv4 (нет интернета?)' }
        return New-Object PSObject -Property @{ Has = $true; PreferV4 = $prefer; Rows = $rows; Broken = @(); Slow = @()
            Text = ('IPv6: адрес у ПК есть, но проверить не вышло - ' + $why) }
    }
    $text = 'IPv6: открылось {0} из {1}' -f ($tested - $broken.Count - $slow.Count), $tested
    if ($broken.Count) { $text += '; не отвечают по IPv6 (по IPv4 открываются): ' + ($broken -join ', ') }
    if ($slow.Count) { $text += '; по IPv6 заметно медленнее: ' + ($slow -join ', ') }
    $text += '; ' + $mode
    return New-Object PSObject -Property @{ Has = $true; PreferV4 = $prefer; Rows = $rows; Broken = $broken; Slow = $slow; Text = $text }
}

# ---------- hosts Flowseal ----------
# Flowseal держит в .service/hosts закреплённые адреса GitHub, Telegram и Discord - в обход DNS провайдера, если тот
# отдаёт заблокированный адрес. Но закреплённый адрес не всегда лучше: бывает, что DNS провайдера честный, а Telegram
# по его адресу не открывается (по адресу Flowseal - да), а GitHub по адресу Flowseal в 8 раз медленнее. Поэтому проверка обходов сначала
# проверяет каждую службу по обоим адресам и ставит в системный hosts только то, что помогает.
$Script:HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Script:HostsRef = 'lists/hosts-flowseal.txt'   # копия .service/hosts Flowseal, обновляется вместе со списками
$Script:HostsGroups = [ordered]@{
    GitHub   = @{ Match = '(^|\.)(github\.com|githubusercontent\.com)$'; Probe = 'raw.githubusercontent.com'
                  Path = '/Flowseal/zapret-discord-youtube/refs/heads/main/.service/version.txt' }
    Telegram = @{ Match = '(^|\.)(telegram\.org|telegram\.me|telegram\.dog|telegram\.space|t\.me|telesco\.pe|tg\.dev)$'; Probe = 'telegram.org'; Path = '/' }
    Discord  = @{ Match = '(^|\.)discord\.com$'; Probe = 'discord.com'; Path = '/api/v9/gateway' }
}
$Script:HostsBegin = '# zapret: hosts Flowseal - начало (меню: Проверка обходов)'
$Script:HostsEnd = '# zapret: hosts Flowseal - конец'
# метки, которыми блок помечали прежние версии: такой блок тоже узнаётся и заменяется
$Script:HostsLegacyBegin = @('# NBA2K27-zapret2: hosts Flowseal - начало (пункт H меню)', '# zapret: hosts Flowseal - начало (меню, пункт 4)')
$Script:HostsLegacyEnd = @('# NBA2K27-zapret2: hosts Flowseal - конец')

# Записи hosts: адрес и имя (строка "IP имя1 имя2" даёт несколько записей)
function Read-HostsEntries([string]$Path) {
    $out = @()
    if (-not (Test-Path $Path)) { return $out }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = ($line -replace '#.*', '').Trim()
        if (-not $t) { continue }
        $p = @($t -split '\s+')
        for ($i = 1; $i -lt $p.Count; $i++) { $out += New-Object PSObject -Property @{ Ip = $p[0]; Host = $p[$i].ToLower() } }
    }
    return $out
}

function Get-HostsGroup([string]$Name) {
    foreach ($g in $Script:HostsGroups.Keys) { if ($Name -match $Script:HostsGroups[$g].Match) { return $g } }
    return $null
}

# По службам: есть ли записи в системном hosts, сколько из них не совпадает с актуальными у Flowseal, сколько повторов.
# Без сети - по копии lists\hosts-flowseal.txt.
function Get-HostsStatus {
    $ref = @(Read-HostsEntries (Get-PkgPath $Script:HostsRef))
    $sys = @(Read-HostsEntries $Script:HostsFile)
    $res = [ordered]@{}
    foreach ($g in $Script:HostsGroups.Keys) {
        $refPairs = @($ref | Where-Object { (Get-HostsGroup $_.Host) -eq $g } | ForEach-Object { $_.Ip + ' ' + $_.Host })
        $sysPairs = @($sys | Where-Object { (Get-HostsGroup $_.Host) -eq $g } | ForEach-Object { $_.Ip + ' ' + $_.Host })
        $res[$g] = New-Object PSObject -Property @{
            Present = ($sysPairs.Count -gt 0)
            Stale = @($sysPairs | Where-Object { $refPairs -notcontains $_ } | Select-Object -Unique).Count
            Missing = @($refPairs | Where-Object { $sysPairs -notcontains $_ }).Count
            Dups = $sysPairs.Count - @($sysPairs | Select-Object -Unique).Count
        }
    }
    return $res
}

# Записи YouTube в hosts (от старых "разблокировщиков") ломают YouTube - Flowseal тоже о них предупреждает
function Get-HostsYoutube {
    return @(Read-HostsEntries $Script:HostsFile | Where-Object { $_.Host -match '(^|\.)(youtube\.com|youtu\.be|googlevideo\.com|ytimg\.com)$' } | ForEach-Object { $_.Host } | Select-Object -Unique)
}

# Открывается ли служба по адресу из DNS провайдера (мимо hosts) и по адресу Flowseal: TLS напрямую, мимо прокси.
# Verdict: helps - по DNS не открывается, по адресу Flowseal да; worse - по адресу Flowseal не открывается или
# заметно медленнее; same - разницы нет; down - не открывается никак.
# Сайты Telegram даже по рабочему адресу открываются не каждый раз, поэтому сбой и "медленнее" перепроверяются
# второй попыткой, в зачёт - лучшая.
function Test-HostsPins([int]$TimeoutSec = 6) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    # все пробы пачки - параллельно; у каждой проставляет Ok и лучшее Ms
    function Invoke-Probes($Items) {
        $run = @()
        foreach ($it in $Items) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = '-s -o NUL --noproxy "*" --ssl-no-revoke --max-time ' + $TimeoutSec + ' --resolve "' + $it.Probe + ':443:' + $it.Ip +
                '" -w "%{http_code} %{time_appconnect}" "https://' + $it.Probe + $it.Path + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $run += New-Object PSObject -Property @{ It = $it; P = $p; Out = $p.StandardOutput.ReadToEndAsync() }
        }
        foreach ($j in $run) {
            if (-not $j.P.WaitForExit(($TimeoutSec + 5) * 1000)) { try { $j.P.Kill() } catch { } ; $j.P.WaitForExit() }
            $parts = @($j.Out.Result.Trim() -split '\s+')
            if ($j.P.ExitCode -ne 0 -or $parts[0] -eq '000' -or $parts.Count -lt 2) { continue }
            $ms = 0
            try { $ms = [math]::Round([double]::Parse($parts[1], $inv) * 1000) } catch { }
            if (-not $j.It.Ok -or $ms -lt $j.It.Ms) { $j.It.Ms = $ms }
            $j.It.Ok = $true
        }
    }
    $ref = @(Read-HostsEntries (Get-PkgPath $Script:HostsRef))
    $items = @()
    foreach ($g in $Script:HostsGroups.Keys) {
        $probe = $Script:HostsGroups[$g].Probe
        $pin = @($ref | Where-Object { $_.Host -eq $probe -and $_.Ip -notmatch ':' } | ForEach-Object { $_.Ip }) | Select-Object -First 1
        $dns = $null
        try { $dns = @(Resolve-DnsName $probe -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) | Select-Object -First 1 } catch { }
        foreach ($k in @('Dns', 'Pin')) {
            $items += New-Object PSObject -Property @{ Group = $g; Kind = $k; Ip = $(if ($k -eq 'Dns') { $dns } else { $pin })
                Probe = $probe; Path = $Script:HostsGroups[$g].Path; Ok = $false; Ms = 0 }
        }
    }
    $withIp = @($items | Where-Object { $_.Ip })
    Invoke-Probes $withIp
    $again = @($withIp | Where-Object { -not $_.Ok })
    foreach ($g in $Script:HostsGroups.Keys) {
        $d = $items | Where-Object { $_.Group -eq $g -and $_.Kind -eq 'Dns' }
        $p = $items | Where-Object { $_.Group -eq $g -and $_.Kind -eq 'Pin' }
        if ($d.Ok -and $p.Ok -and $p.Ms -gt $d.Ms + 300) { $again += @($d, $p) }
    }
    if ($again.Count) { Invoke-Probes $again }
    $rows = @()
    foreach ($g in $Script:HostsGroups.Keys) {
        $r = @{}
        foreach ($it in @($items | Where-Object { $_.Group -eq $g })) { $r[$it.Kind] = $it }
        $verdict = if (-not $r['Pin'].Ip) { 'none' }
            elseif (-not $r['Dns'].Ok -and $r['Pin'].Ok) { 'helps' }
            elseif (-not $r['Dns'].Ok) { 'down' }
            elseif (-not $r['Pin'].Ok -or $r['Pin'].Ms -gt $r['Dns'].Ms + 300) { 'worse' }
            else { 'same' }
        $rows += New-Object PSObject -Property @{ Group = $g; Dns = $r['Dns']; Pin = $r['Pin']; Verdict = $verdict }
    }
    return $rows
}

# Какие службы держать в hosts: где адрес Flowseal помогает; где разницы нет или проверить не вышло - как сейчас
function Get-HostsAdvice($Rows, $Status) {
    return @($Rows | Where-Object { $_.Verdict -eq 'helps' -or (@('same', 'down', 'none') -contains $_.Verdict -and $Status[$_.Group].Present) } | ForEach-Object { $_.Group })
}

# Ставит в системный hosts записи Flowseal только для служб $Groups одним блоком между метками, остальные записи этих
# служб (в том числе вставленные вручную и повторы) убирает. Чужие записи не трогает. Копия старого hosts - в runtime.
function Set-HostsFlowseal([string[]]$Groups) {
    $bytes = [System.IO.File]::ReadAllBytes($Script:HostsFile)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    Copy-Item $Script:HostsFile (Join-Path $Script:Runtime ('hosts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')) -Force
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in ($text.TrimStart([char]0xFEFF) -split "`r?`n")) {
        if ($line -eq $Script:HostsBegin -or $Script:HostsLegacyBegin -contains $line) { $inBlock = $true; continue }
        if ($line -eq $Script:HostsEnd -or $Script:HostsLegacyEnd -contains $line) { $inBlock = $false; continue }
        if ($inBlock) { continue }
        $t = ($line -replace '#.*', '').Trim()
        if ($t) {
            $names = @($t -split '\s+' | Select-Object -Skip 1)
            if ($names.Count -and @($names | Where-Object { Get-HostsGroup $_ }).Count -eq $names.Count) { continue }
        }
        $out.Add($line)
    }
    while ($out.Count -and -not $out[$out.Count - 1].Trim()) { $out.RemoveAt($out.Count - 1) }
    $add = @(Read-HostsEntries (Get-PkgPath $Script:HostsRef) | Where-Object { $Groups -contains (Get-HostsGroup $_.Host) })
    if ($add.Count) {
        $out.Add('')
        $out.Add($Script:HostsBegin)
        foreach ($e in $add) { $out.Add($e.Ip + ' ' + $e.Host) }
        $out.Add($Script:HostsEnd)
    }
    $enc = New-Object System.Text.UTF8Encoding($bom)
    try { [System.IO.File]::WriteAllText($Script:HostsFile, (($out -join $nl) + $nl), $enc) }
    catch { return $false }
    & ipconfig.exe /flushdns | Out-Null
    return $true
}

# Что сейчас в hosts по службам - коротко, без сети (шапка меню, отчёт R)
function Get-HostsStatusText($Status) {
    $parts = @()
    foreach ($g in $Status.Keys) {
        $st = $Status[$g]
        if (-not $st.Present) { continue }
        $t = $g
        if ($st.Stale) { $t += (' (устаревших: ' + $st.Stale + ')') }
        if ($st.Dups) { $t += (' (повторов: ' + $st.Dups + ')') }
        $parts += $t
    }
    if (-not $parts.Count) { return 'записей Flowseal нет' }
    return ('записи Flowseal: ' + ($parts -join ', '))
}

# Одна строка для отчётов автоподбора и проверки провайдера
function Get-HostsReportText($Rows, $Status) {
    $parts = @()
    foreach ($x in $Rows) {
        $now = if ($Status[$x.Group].Present) { 'в hosts есть' } else { 'в hosts нет' }
        $how = switch ($x.Verdict) {
            'helps' { 'по DNS не открывается, по адресу Flowseal открывается' }
            'worse' { 'по DNS лучше, чем по адресу Flowseal' }
            'down'  { 'не открывается ни так, ни так' }
            'none'  { 'адреса Flowseal нет' }
            default { 'разницы нет' }
        }
        $parts += ('{0}: {1}, {2}' -f $x.Group, $how, $now)
    }
    return ('hosts Flowseal: ' + ($parts -join '; '))
}

# ---------- списки Flowseal, новые версии и автонастройка по расписанию ----------

$Script:FlowsealRaw = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/'
# Списки Flowseal, которые пакет берёт как есть (свои добавления - только в *-user.txt): файл в lists\ -> путь в репозитории.
# ipset-all - тот, что Flowseal ставит при IPSet "loaded".
$Script:FlowsealLists = [ordered]@{
    'ipset-all.txt'     = '.service/ipset-service.txt'
    'ipset-exclude.txt' = 'lists/ipset-exclude.txt'
    'list-general.txt'  = 'lists/list-general.txt'
    'list-google.txt'   = 'lists/list-google.txt'
    'list-exclude.txt'  = 'lists/list-exclude.txt'
    # не список обхода, а копия для проверки обходов: системный hosts меняет только он, по вашему выбору
    'hosts-flowseal.txt' = '.service/hosts'
}

# Скачивает один список Flowseal (старый - в .bak). Битый или обрезанный файл не ставится: строки должны быть сетями
# или доменами, и их не меньше половины прежнего. Ok, Changed и Text для меню и журнала.
function Update-FlowsealList([string]$Name) {
    $dst = Join-Path $Script:Lists $Name
    $tmp = Join-Path $Script:Runtime ($Name + '.download')
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $r = Invoke-Native $curl ('-s -L -f --ssl-no-revoke --max-time 60 -o "' + $tmp + '" "' + $Script:FlowsealRaw + $Script:FlowsealLists[$Name] + '"') $Script:Runtime 90
    function Result([bool]$Ok, [bool]$Changed, [string]$Text) {
        return New-Object PSObject -Property @{ Name = $Name; Ok = $Ok; Changed = $Changed; Text = ($Name + ': ' + $Text) }
    }
    if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp)) { return (Result $false $false ('не скачалось (curl код ' + $r.ExitCode + ')')) }
    $lines = @(Get-ListLines $tmp)
    $isIp = $Name.StartsWith('ipset')
    # ^ в начале домена - синтаксис zapret "только сам домен, без поддоменов"; в hosts - "адрес имя"
    $pattern = if ($isIp) { '^[0-9a-fA-F:.]+(/\d{1,3})?$' }
        elseif ($Name.StartsWith('hosts')) { '^[0-9a-fA-F:.]+\s+[0-9A-Za-z_.-]+$' }
        else { '^\^?[0-9A-Za-z_.-]+$' }
    $bad = @($lines | Where-Object { $_ -notmatch $pattern })
    $old = @(Get-ListLines $dst)
    $min = if ($Name -eq 'ipset-all.txt') { 1000 } else { [math]::Max(1, [math]::Floor($old.Count / 2)) }
    if ($lines.Count -lt $min -or $bad.Count -gt 0) {
        Remove-Item $tmp -Force
        return (Result $false $false ('не похож на список (строк: {0}, мусорных: {1}), оставлен старый' -f $lines.Count, $bad.Count))
    }
    # сравниваем строки, а не файлы: переводы строк в архиве Flowseal и на GitHub бывают разные
    if ((Test-Path $dst) -and (($lines -join "`n") -ceq ($old -join "`n"))) {
        Remove-Item $tmp -Force
        # время файла - дата последней проверки: по нему автонастройка решает, пора ли качать снова
        (Get-Item $dst).LastWriteTime = Get-Date
        return (Result $true $false ('без изменений, строк: {0}' -f $lines.Count))
    }
    if (Test-Path $dst) { Copy-Item $dst ($dst + '.bak') -Force }
    Move-Item $tmp $dst -Force
    $what = if ($isIp) { 'сетей' } elseif ($Name.StartsWith('hosts')) { 'записей' } else { 'доменов' }
    # у ipset-all 33 тыс. строк: построчное сравнение слишком долгое, хватает количества
    if ($lines.Count -gt 2000) { return (Result $true $true ('{2}: было {0}, стало {1}' -f $old.Count, $lines.Count, $what)) }
    $added = @($lines | Where-Object { $old -notcontains $_ }).Count
    $removed = @($old | Where-Object { $lines -notcontains $_ }).Count
    return (Result $true $true ('{3}: было {0}, стало {1} (+{2} -{4})' -f $old.Count, $lines.Count, $added, $what, $removed))
}

function Update-FlowsealLists {
    # вместе со списками Flowseal - адреса серверов Valve (Update-ValveList)
    return @(@($Script:FlowsealLists.Keys | ForEach-Object { Update-FlowsealList $_ }) + @(Update-ValveList))
}

# Серверы Valve (Steam, ретрансляторы Dota 2 и CS2) не заблокированы, а фейки ломают игру: часть ретрансляторов стоит
# у хостинга Datapacket, чьи сети есть в ipset-all Flowseal (в Доте не нажималась "Играть" и не пускало в матч).
# lists\ipset-valve.txt исключён во всех профилях: сети Valve (AS32590, по данным RIPE на 2026-10-27) и адреса
# ретрансляторов из официального конфига Steam Datagram Relay, который обновляется вместе со списками Flowseal.
$Script:ValveNets = @('45.121.184.0/24', '103.10.124.0/23', '103.28.54.0/24', '146.66.152.0/24', '146.66.155.0/24', '155.133.224.0/21', '155.133.236.0/22', '155.133.240.0/23', '155.133.244.0/24', '155.133.246.0/24', '155.133.248.0/22', '155.133.252.0/24', '155.133.254.0/23', '162.254.192.0/21', '185.25.180.0/24', '185.25.182.0/23', '192.69.96.0/22', '205.196.6.0/24', '208.64.200.0/22', '208.78.164.0/22', '2404:3fc0::/46', '2404:3fc0:8::/47', '2404:3fc0:a::/48', '2602:801:f000::/46', '2602:801:f005::/48', '2602:801:f006::/47', '2602:801:f008::/46', '2602:801:f00d::/48', '2602:801:f00e::/48', '2a01:bc80::/45', '2a01:bc80:8::/46', '2a01:bc80:c::/48')
$Script:ValveSdrApps = @('570', '730')
$Script:ValveListHead = @(
    '# Серверы Valve: Steam, ретрансляторы Dota 2 и CS2 (Steam Datagram Relay). Они НЕ заблокированы, поэтому исключены',
    '# из обработки во всех профилях: часть ретрансляторов стоит у хостингов из ipset-all (Datapacket), и фейки ломали Доту.',
    '# Обновляется вместе со списками (Настройки -> 8): сети Valve + адреса ретрансляторов из GetSDRConfig Steam.',
    '# сети Valve (AS32590)')

# Скачивает адреса ретрансляторов Valve (Dota 2, CS2) и пересобирает lists\ipset-valve.txt (старый - в .bak).
# Меньше 50 адресов или чужой ответ - оставляем старый: пустой список исключений zapret2 понял бы как "все адреса".
function Update-ValveList {
    $name = 'ipset-valve.txt'
    $dst = Join-Path $Script:Lists $name
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    function Result([bool]$Ok, [bool]$Changed, [string]$Text) {
        return New-Object PSObject -Property @{ Name = $name; Ok = $Ok; Changed = $Changed; Text = ($name + ': ' + $Text) }
    }
    function Get-Prop($O, [string]$Prop) {
        if ($null -ne $O -and $O.PSObject.Properties.Name -contains $Prop) { return $O.$Prop }
        return $null
    }
    $relays = New-Object System.Collections.Generic.List[string]
    foreach ($app in $Script:ValveSdrApps) {
        $tmp = Join-Path $Script:Runtime ('sdr-' + $app + '.json')
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        $r = Invoke-Native $curl ('-s -f --ssl-no-revoke --max-time 30 -o "' + $tmp + '" "https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=' + $app + '"') $Script:Runtime 40
        if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp)) { return (Result $false $false ('не скачалось (curl код ' + $r.ExitCode + ')')) }
        $j = $null
        try { $j = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json } catch { }
        Remove-Item $tmp -Force
        $pops = Get-Prop $j 'pops'
        if (-not $pops) { return (Result $false $false 'ответ Steam не похож на конфиг, оставлен старый') }
        foreach ($p in $pops.PSObject.Properties) {
            foreach ($x in @(Get-Prop $p.Value 'relays')) {
                $ip = '' + (Get-Prop $x 'ipv4')
                if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and -not $relays.Contains($ip)) { $relays.Add($ip) }
            }
        }
    }
    if ($relays.Count -lt 50) { return (Result $false $false ('ретрансляторов всего {0}: не похоже на конфиг, оставлен старый' -f $relays.Count)) }
    $relayLines = @($relays | Sort-Object { [version]$_ } | ForEach-Object { $_ + '/32' })
    $lines = @($Script:ValveNets) + $relayLines
    $old = @(Get-ListLines $dst)
    if ((Test-Path $dst) -and (($lines -join "`n") -ceq ($old -join "`n"))) {
        # время файла - дата последней проверки, как у списков Flowseal
        (Get-Item $dst).LastWriteTime = Get-Date
        return (Result $true $false ('без изменений, сетей и адресов: {0}' -f $lines.Count))
    }
    $text = @($Script:ValveListHead) + @($Script:ValveNets) + @('# ретрансляторы Steam Datagram Relay (Dota 2, CS2), ' + (Get-Date -Format 'yyyy-MM-dd')) + $relayLines
    if (Test-Path $dst) { Copy-Item $dst ($dst + '.bak') -Force }
    Write-TextNoBom $dst (($text -join "`r`n") + "`r`n")
    $added = @($lines | Where-Object { $old -notcontains $_ }).Count
    $removed = @($old | Where-Object { $lines -notcontains $_ }).Count
    return (Result $true $true ('сетей и адресов: было {0}, стало {1} (+{2} -{3})' -f $old.Count, $lines.Count, $added, $removed))
}

# Основа сборки: с какими версиями zapret2 и Flowseal она собрана. Выход новых проверяется раз в несколько дней.
$Script:Upstream = [ordered]@{
    'zapret2'  = @{ Repo = 'bol-van/zapret2'; Base = 'v1.0.6' }
    'Flowseal' = @{ Repo = 'Flowseal/zapret-discord-youtube'; Base = '1.10.4' }
}
$Script:UpdatesFile = 'runtime/updates.txt'
# Сама сборка: о её новой версии меню сообщает в шапке
$Script:SelfRepo = 'chepi1/zapret'

# Последний релиз на GitHub без API (у API лимит запросов): /releases/latest перенаправляет на страницу тега
function Get-LatestRelease([string]$Repo) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $r = Invoke-Native $curl ('-s -o NUL --ssl-no-revoke --max-time 5 -w "%{redirect_url}" "https://github.com/' + $Repo + '/releases/latest"') $Script:Runtime 8
    if ($r.ExitCode -eq 0 -and $r.Output -match '/releases/tag/([^/\s]+)$') { return [uri]::UnescapeDataString($matches[1]) }
    return $null
}

# Узнаёт последние версии (не чаще раза в $Days дней, -Force - сейчас) и запоминает в runtime\updates.txt.
# Возвращает $true, если проверка была.
function Update-UpstreamCheck([int]$Days = 7, [switch]$Force) {
    $f = Get-PkgPath $Script:UpdatesFile
    if (-not $Force -and (Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalDays -lt $Days) { return $false }
    $lines = @()
    foreach ($k in $Script:Upstream.Keys) {
        $tag = Get-LatestRelease $Script:Upstream[$k].Repo
        if (-not $tag) {
            # GitHub не ответил: прежний результат оставляем, а время проверки обновляем - иначе меню ждало бы
            # ответа при каждом запуске
            if (Test-Path $f) { (Get-Item $f).LastWriteTime = Get-Date } else { Write-TextNoBom $f "`r`n" }
            return $false
        }
        $lines += ('{0}={1}' -f $k, $tag)
    }
    # своя версия - не обязательна: если её не узнали, основа всё равно запоминается
    $self = Get-LatestRelease $Script:SelfRepo
    if ($self) { $lines += ('zapret={0}' -f $self) }
    Write-TextNoBom $f (($lines -join "`r`n") + "`r`n")
    return $true
}

# Новее ли тег релиза, чем версия в сборке. По числам: 1.10.4 новее 1.9, v1.0 и 1.0 - одно и то же.
function Test-NewerVersion([string]$Tag, [string]$Base) {
    $t = $Tag -replace '^[vV]', ''
    $b = $Base -replace '^[vV]', ''
    if ($t -notmatch '\.') { $t += '.0' }
    if ($b -notmatch '\.') { $b += '.0' }
    $vt = $null; $vb = $null
    if ([version]::TryParse($t, [ref]$vt) -and [version]::TryParse($b, [ref]$vb)) { return ($vt -gt $vb) }
    return ($Tag -ne $Base)
}

# Что вышло новее основы сборки - по сохранённой проверке, без запросов в сеть (для шапки меню и отчётов)
function Get-UpstreamNews {
    $f = Get-PkgPath $Script:UpdatesFile
    if (-not (Test-Path $f)) { return @() }
    $out = @()
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        if ($line -notmatch '^(\w+)=(\S+)$' -or -not $Script:Upstream.Contains($matches[1])) { continue }
        $k = $matches[1]; $tag = $matches[2]
        if (Test-NewerVersion $tag $Script:Upstream[$k].Base) { $out += ('{0} {1} (в сборке {2})' -f $k, $tag, $Script:Upstream[$k].Base) }
    }
    return $out
}

# Новая версия самой сборки по сохранённой проверке: тег вида v1.2 или $null
function Get-ZapretUpdate {
    $f = Get-PkgPath $Script:UpdatesFile
    if (-not (Test-Path $f)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        if ($line -notmatch '^zapret=(\S+)$') { continue }
        $tag = $matches[1]
        if (Test-NewerVersion $tag $Script:Version) { return $tag }
    }
    return $null
}

# Все новые версии одним списком (журнал автонастройки, отчёт): сама сборка и её основа
function Get-AllNews {
    $out = @()
    $u = Get-ZapretUpdate
    if ($u) { $out += ('zapret {0} (у вас {1})' -f $u, $Script:Version) }
    return @($out + @(Get-UpstreamNews))
}

# Задача планировщика запускает tools\autotune.ps1 каждый день в 4:00 (или позже, если ПК был выключен), только когда
# ПК простаивает. Сам скрипт решает, пора ли: автоподбор - раз в $AutotuneDays дней (ручной тоже считается), ipset-all -
# раз в $IpsetDays дней. От SYSTEM, чтобы не мелькало окно и не нужен был вход пользователя.
$Script:AutotuneTask = 'zapret autotune'
$Script:AutotuneDays = 7
$Script:IpsetDays = 30
# Игры и античиты: пока они запущены, обход на время теста не выключаем
$Script:GameProcessNames = @('NBA2K*', 'dota2', 'cs2', 'csgo', 'EasyAntiCheat*', 'BEService*', 'FortniteClient*', 'r5apex*',
    'RocketLeague', 'GTA5*', 'TslGame*', 'VALORANT*', 'eldenring', 'FC2*', 'Overwatch', 'destiny2')

# Запрос к планировщику занимает ~0,3 с, а шапка меню перерисовывается после каждого пункта: ответ держим минуту.
# Install/Remove-AutotuneTask сбрасывают его сразу.
$Script:AutotuneTaskCache = $null
function Get-AutotuneTask {
    $c = $Script:AutotuneTaskCache
    if ($c -and ((Get-Date) - $c.Time).TotalSeconds -lt 60) { return $c.Task }
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $Script:AutotuneTask -ErrorAction Stop } catch { }
    $Script:AutotuneTaskCache = New-Object PSObject -Property @{ Time = Get-Date; Task = $task }
    return $task
}

function Get-AutotuneScript { return (Join-Path $Script:Root 'tools\autotune.ps1') }

function Install-AutotuneTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -WorkingDirectory $Script:Root `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Get-AutotuneScript) + '"')
    $trigger = New-ScheduledTaskTrigger -Daily -At '04:00'
    # тест сам выключает и включает обход, поэтому прерывать его нельзя: ни при выходе из простоя, ни при переходе на батарею
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfIdle -IdleDuration (New-TimeSpan -Minutes 10) `
        -IdleWaitTimeout (New-TimeSpan -Hours 6) -DontStopOnIdleEnd -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $Script:AutotuneTaskCache = $null
    try {
        Register-ScheduledTask -TaskName $Script:AutotuneTask -Action $action -Trigger $trigger -Settings $set -Principal $pr -Force `
            -Description 'zapret: полный автоподбор раз в неделю и списки Flowseal раз в месяц, когда ПК простаивает' -ErrorAction Stop | Out-Null
    } catch { Write-Color $_.Exception.Message Red; return $false }
    return [bool](Get-AutotuneTask)
}

function Remove-AutotuneTask {
    try { Unregister-ScheduledTask -TaskName $Script:AutotuneTask -Confirm:$false -ErrorAction Stop } catch { }
    $Script:AutotuneTaskCache = $null
}

function Get-AutotuneText {
    $task = Get-AutotuneTask
    if (-not $task) { return 'выключена' }
    $t = 'раз в неделю, когда ПК простаивает'
    $rank = Get-PkgPath $Script:RankFile
    if (Test-Path $rank) { $t += '; последний автоподбор ' + (Get-Item $rank).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
    $args0 = @($task.Actions | ForEach-Object { $_.Arguments }) -join ' '
    if ($args0 -notlike ('*' + (Get-AutotuneScript) + '*')) { $t += ' (! задача от другой папки - включите заново: Настройки -> 7)' }
    return $t
}

function Add-AutotuneLog([string]$Text) {
    $f = Join-Path $Script:Runtime 'autotune.log'
    $lines = @(if (Test-Path $f) { [System.IO.File]::ReadAllLines($f) })
    $lines = @($lines | Select-Object -Last 299) + @((Get-Date -Format 'yyyy-MM-dd HH:mm') + ' ' + $Text)
    Write-TextNoBom $f (($lines -join "`r`n") + "`r`n")
}

# Почему автоподбор сейчас нельзя запускать (пусто - можно)
function Get-AutotuneBlockers {
    $w = @()
    $games = @(Get-Process -Name $Script:GameProcessNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    if ($games.Count) { $w += ('запущена игра: ' + ($games -join ', ')) }
    $tun = @(Get-TunAdapters)
    if ($tun.Count) { $w += ('включён VPN: ' + (($tun | ForEach-Object { $_.Name }) -join ', ')) }
    $foreign = @(Get-ForeignBypass)
    if ($foreign.Count) { $w += ('работает другой обход: ' + ($foreign -join ', ')) }
    $boost = @(Get-GameBoosters)
    if ($boost.Count) { $w += ('запущен игровой ускоритель: ' + ($boost -join ', ')) }
    if (-not $w.Count) {
        # системный прокси (Happ и т.п.) тесту не мешает: curl идёт мимо него. Мешает только VPN на весь трафик.
        $info = Get-DirectConnectionInfo
        if (-not $info) { $w += 'нет интернета (ipwho.is и ipinfo.io не ответили)' }
        elseif (-not $info.IsRussia) { $w += ('трафик идёт не напрямую: внешний IP не российский (' + $info.CountryCode + ')') }
    }
    return $w
}

# Пока идёт автонастройка, ручной автоподбор ждёт: два теста выключали бы обход друг другу
function Test-AutotuneRunning {
    $f = Join-Path $Script:Runtime 'autotune.lock'
    if (-not (Test-Path $f)) { return $false }
    $id = 0
    if (-not [int]::TryParse(([System.IO.File]::ReadAllText($f)).Trim(), [ref]$id) -or $id -eq $PID) { return $false }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    return [bool]($p -and $p.ProcessName -eq 'powershell')
}

# ---------- проверка адресов по спискам (сканер, трекер) ----------
# 33 тыс. сетей ipset-all перебирать в PowerShell слишком долго, поэтому небольшой помощник на C#.
# Компилируется при первом обращении, чтобы не замедлять меню.
function Initialize-IpSetHelper {
    if ('NbaIpSet' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;

public class NbaIpSet
{
    private readonly List<uint[]> v4 = new List<uint[]>();
    private readonly List<KeyValuePair<byte[], int>> v6 = new List<KeyValuePair<byte[], int>>();
    private uint[] starts = new uint[0];
    private uint[] ends = new uint[0];

    public void Add(string line)
    {
        string t = line.Trim();
        if (t.Length == 0) return;
        string[] p = t.Split('/');
        IPAddress ip;
        if (!IPAddress.TryParse(p[0], out ip)) return;
        byte[] b = ip.GetAddressBytes();
        int len = b.Length * 8;
        if (p.Length > 1 && !int.TryParse(p[1], out len)) return;
        if (b.Length == 4)
        {
            if (len < 0 || len > 32) return;
            uint n = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
            uint mask = len == 0 ? 0u : 0xFFFFFFFFu << (32 - len);
            uint s = n & mask;
            v4.Add(new uint[] { s, s | ~mask });
        }
        else
        {
            if (len < 0 || len > 128) return;
            v6.Add(new KeyValuePair<byte[], int>(b, len));
        }
    }

    public void Finish()
    {
        v4.Sort((x, y) => x[0].CompareTo(y[0]));
        var s = new List<uint>(); var e = new List<uint>();
        foreach (var r in v4)
        {
            if (s.Count > 0 && r[0] <= e[e.Count - 1] + 1UL) { if (r[1] > e[e.Count - 1]) e[e.Count - 1] = r[1]; }
            else { s.Add(r[0]); e.Add(r[1]); }
        }
        starts = s.ToArray(); ends = e.ToArray();
    }

    public bool Contains(string text)
    {
        IPAddress ip;
        if (!IPAddress.TryParse(text, out ip)) return false;
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        byte[] b = ip.GetAddressBytes();
        if (b.Length == 4)
        {
            uint n = ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
            int lo = 0, hi = starts.Length - 1;
            while (lo <= hi)
            {
                int mid = (lo + hi) / 2;
                if (n < starts[mid]) hi = mid - 1;
                else if (n > ends[mid]) lo = mid + 1;
                else return true;
            }
            return false;
        }
        foreach (var kv in v6)
        {
            byte[] c = kv.Key; int len = kv.Value;
            if (c.Length != 16) continue;
            int full = len / 8, rest = len % 8;
            bool ok = true;
            for (int i = 0; i < full && ok; i++) if (b[i] != c[i]) ok = false;
            if (ok && rest > 0)
            {
                int m = (0xFF << (8 - rest)) & 0xFF;
                if ((b[full] & m) != (c[full] & m)) ok = false;
            }
            if (ok) return true;
        }
        return false;
    }
}
'@
}

function Load-IpSet([string]$File) {
    Initialize-IpSetHelper
    $set = New-Object NbaIpSet
    foreach ($l in (Get-ListLines (Join-Path $Script:Lists $File))) {
        if ($l -ne '203.0.113.113/32') { $set.Add($l) }
    }
    $set.Finish()
    return $set
}

# Списки, по которым подписываются адреса игры. Порядок важен: первый совпавший и есть "владелец".
function Get-OwnerSets {
    return [ordered]@{
        # Valve первым: часть его ретрансляторов есть и в ipset-all, но обход их не трогает
        'Valve'        = (Load-IpSet 'ipset-valve.txt')
        'ipset-all'    = (Load-IpSet 'ipset-all.txt')
        'Take-Two'     = (Load-IpSet 'ipset-taketwo.txt')
        'найден ранее' = (Load-IpSet 'ipset-user.txt')
        'AWS'          = (Load-IpSet 'ipset-aws.txt')
    }
}

function Get-Owner([string]$Ip, $Sets) {
    foreach ($name in $Sets.Keys) { if ($Sets[$name].Contains($Ip)) { return $name } }
    return ''
}

# ---------- журнал сети Windows (ETW Microsoft-Windows-Kernel-Network) ----------
# Порты в нём в сетевом порядке байт, IPv4 - число с байтами адреса в обратном порядке,
# IPv6 - 16 байт (в XML-виде события - 32 hex-символа без двоеточий).
function Swap16([int]$v) { return (($v -band 0xFF) -shl 8) -bor (($v -shr 8) -band 0xFF) }

function Convert-EtwAddr($v) {
    if ($v -is [byte[]]) { return ([System.Net.IPAddress]::new($v)).ToString() }
    $s = [string]$v
    if ($s -match '^\d+$') {
        $n = [uint64]$s
        return ('{0}.{1}.{2}.{3}' -f ($n -band 255), (($n -shr 8) -band 255), (($n -shr 16) -band 255), (($n -shr 24) -band 255))
    }
    if ($s -match '^[0-9A-Fa-f]{32}$') {
        $parts = for ($i = 0; $i -lt 32; $i += 4) { $s.Substring($i, 4) }
        return ([System.Net.IPAddress]::Parse(($parts -join ':'))).ToString()
    }
    return $s
}

# События Kernel-Network: TCP IPv4 10-18, TCP IPv6 26-34, UDP IPv4 42/43/49, UDP IPv6 58/59/65.
$Script:EtwUdpIds = @(42, 43, 49, 58, 59, 65)
$Script:EtwSendIds = @(10, 26, 42, 58)
$Script:EtwRecvIds = @(11, 27, 43, 59)

# Запуск и остановка записи журнала сети в файл
function Start-NetTrace([string]$Session, [string]$Etl) {
    & logman stop $Session -ets 2>&1 | Out-Null
    if (Test-Path $Etl) { Remove-Item $Etl -Force -ErrorAction SilentlyContinue }
    & logman start $Session -p 'Microsoft-Windows-Kernel-Network' '0xffffffffffffffff' '0xff' -o $Etl -bs 1024 -nb 64 256 -max 512 -ets 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Stop-NetTrace([string]$Session) {
    & logman stop $Session -ets 2>&1 | Out-Null
}

# ---------- защита от подмены ----------
# Код пакета выполняется с правами администратора (меню, обход) и SYSTEM (служба, автонастройка). Папка же по умолчанию
# наследует от C:\ право "Прошедшие проверку: изменение": любая программа без прав администратора могла бы подменить
# winws2.exe или скрипт и получить права SYSTEM. Поэтому:
#  - файлы zapret2 сверяются с SHA-256 официального релиза (как в CHECKSUMS.txt) перед каждым запуском;
#  - папки с кодом закрыты на запись для всех, кроме администраторов и SYSTEM, владелец - Администраторы
#    (иначе владелец-пользователь мог бы вернуть себе запись). lists\ и runtime\ - данные, их не трогаем.
# Копия для разработки (есть папка dev\) не закрывается: её правят без прав администратора.
$Script:UpstreamHashes = [ordered]@{
    'bin\winws2.exe'         = 'ba4ceccdea3576da0a0991a50d7893ea911de197281338132dbec02a5b2fcf58'
    'bin\cygwin1.dll'        = '103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b'
    'bin\WinDivert.dll'      = '16abd6a029e65557c6a309bea7b13bf81fff4e193567582e1cddbf6719f323e0'
    'bin\WinDivert64.sys'    = '8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2'
    'lua\zapret-lib.lua'     = '6bf528fef1f0fc3c65e189216fc8a06bb873f6e25d1c29d2bfa4695a09b73440'
    'lua\zapret-antidpi.lua' = '6d1fa9168e5de1682fef91fd174f68b58c50f6739ef00f42ca7db2b940b6246d'
    'lua\zapret-auto.lua'    = '23a9b99a776d868d92f4cc0ee5110f5c1f12fe746620d9c0337022dbc2f52df0'
}
$Script:ProtectedDirs = @('bin', 'lua', 'tools', 'strategies', 'fake', 'windivert')
$Script:ProtectedFiles = @('zapret.bat')

# Что не совпало с релизом zapret2 (пусто - всё в порядке)
function Test-PackageIntegrity {
    $bad = @()
    foreach ($rel in $Script:UpstreamHashes.Keys) {
        $p = Join-Path $Script:Root $rel
        if (-not (Test-Path $p)) { $bad += ($rel + ' - нет файла'); continue }
        if ((Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $Script:UpstreamHashes[$rel]) { $bad += ($rel + ' - изменён') }
    }
    return $bad
}

function Write-IntegrityError($Bad) {
    Write-Color ('Файлы zapret2 не совпадают с официальным релизом: ' + ($Bad -join ', ') + '.') Red
    Write-Color 'Обход не запущен: изменённый файл работал бы с правами администратора. Скачайте сборку заново' Yellow
    Write-Color '(часто это антивирус удалил или "вылечил" файл - тогда добавьте папку в исключения).' Yellow
}

function Test-DevCheckout { return (Test-Path (Join-Path $Script:Root 'dev')) }

function Test-PackageProtected {
    try { $acl = Get-Acl (Join-Path $Script:Root 'tools') -ErrorAction Stop } catch { return $false }
    return ($acl.AreAccessRulesProtected -and $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544')
}

# Закрывает папки с кодом на запись (нужны права администратора). На дисках без прав доступа (FAT32, exFAT) не выйдет -
# тогда просто ничего не меняется.
function Protect-Package {
    if ((Test-DevCheckout) -or (Test-PackageProtected)) { return }
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    # SYSTEM и Администраторы - полный доступ, Пользователи и Прошедшие проверку - только чтение и запуск
    $dirGrant = @('/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '*S-1-5-11:(OI)(CI)RX')
    $fileGrant = @('/grant:r', '*S-1-5-18:F', '*S-1-5-32-544:F', '*S-1-5-32-545:RX', '*S-1-5-11:RX')
    foreach ($d in $Script:ProtectedDirs) {
        $p = Join-Path $Script:Root $d
        if (-not (Test-Path $p)) { continue }
        & $icacls $p /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null
        & $icacls $p /inheritance:r @dirGrant /Q 2>&1 | Out-Null
        # содержимое - только унаследованные права от защищённой папки
        & $icacls (Join-Path $p '*') /reset /T /C /Q 2>&1 | Out-Null
    }
    foreach ($f in $Script:ProtectedFiles) {
        $p = Join-Path $Script:Root $f
        if (-not (Test-Path $p)) { continue }
        & $icacls $p /setowner '*S-1-5-32-544' /C /Q 2>&1 | Out-Null
        & $icacls $p /inheritance:r @fileGrant /Q 2>&1 | Out-Null
    }
}

# Обратно к обычным правам (перед удалением или заменой папки): всё снова наследуется от родительской папки
function Unprotect-Package {
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    foreach ($d in $Script:ProtectedDirs) {
        $p = Join-Path $Script:Root $d
        if (Test-Path $p) { & $icacls $p /reset /T /C /Q 2>&1 | Out-Null }
    }
    foreach ($f in $Script:ProtectedFiles) {
        $p = Join-Path $Script:Root $f
        if (Test-Path $p) { & $icacls $p /reset /C /Q 2>&1 | Out-Null }
    }
}

function Unblock-Package {
    Get-ChildItem -Path $Script:Root -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
}
