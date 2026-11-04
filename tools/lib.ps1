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
$Script:Version     = '1.9'
. (Join-Path $PSScriptRoot 'netstate.ps1')
. (Join-Path $PSScriptRoot 'capture.ps1')
. (Join-Path $PSScriptRoot 'linkguard.ps1')
. (Join-Path $PSScriptRoot 'recovery.ps1')
. (Join-Path $PSScriptRoot 'selection.ps1')
. (Join-Path $PSScriptRoot 'processmetrics.ps1')
. (Join-Path $PSScriptRoot 'comparison.ps1')
$Script:RingNetworkKey = 'unknown-' + [guid]::NewGuid().ToString('N')
$Script:RingPersistAllowed = $true
$Script:RingCompositionKey = ''
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
    # telegram, notify: on / off / пусто (ещё не выбирали - см. Test-NotifyEnabled и первый запуск обхода)
    # gamepins: on - рабочие адреса серверов игр закреплены в hosts и перепроверяются при запуске (Update-GamePins)
    $s = @{ alt = '12'; auto = 'on'; game = 'all'; ipset = 'loaded'; gametcp = '1024-65535'; gameudp = '1024-65535'; autolist = 'on'; telegram = ''; notify = ''; gamepins = '' }
    $f = Join-Path $Script:Runtime 'settings.ini'
    if (Test-Path $f) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match '^\s*([a-z]+)\s*=\s*(.*?)\s*$') { $s[$matches[1]] = $matches[2] }
        }
    }
    if (@('all', 'tcp', 'udp', 'off') -notcontains $s.game) { $s.game = 'all' }
    if (@('loaded', 'any', 'none') -notcontains $s.ipset) { $s.ipset = 'loaded' }
    if (@('on', 'off') -notcontains $s.autolist) { $s.autolist = 'on' }
    if (@('on', 'off', '') -notcontains $s.telegram) { $s.telegram = '' }
    if (@('on', 'off', '') -notcontains $s.notify) { $s.notify = '' }
    if (@('on', 'off', '') -notcontains $s.gamepins) { $s.gamepins = '' }
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

# Входит ли порт в список вида '1024-2000,3000'
function Test-PortInList([int]$Port, [string]$List) {
    foreach ($x in ($List -split ',')) {
        if ($x -notmatch '^(\d{1,5})(-(\d{1,5}))?$') { continue }
        $a = [int]$matches[1]
        $b = if ($matches[3]) { [int]$matches[3] } else { $a }
        if ($Port -ge $a -and $Port -le $b) { return $true }
    }
    return $false
}

# Game Filter "только порты игр": вместо всех портов 1024-65535 через winws2 идут только порты, на которых ходят
# NBA 2K27 (TCP 20000-26000 к её серверам на Cloudflare, UDP 30000-30100 к серверам матча) и игры Steam и Valve
# (ретрансляторы UDP 27015-27200). Торренты, звонки и прочие программы на остальных портах обход больше не пропускает
# через себя. Другие игры с иными портами так не обходятся - для них все порты.
$Script:GamePortsPreset = @{ tcp = '20000-27200'; udp = '27000-27200,30000-30100' }

function Get-GameText([hashtable]$Settings) {
    $preset = $Settings.gametcp -eq $Script:GamePortsPreset.tcp -and $Settings.gameudp -eq $Script:GamePortsPreset.udp
    if ($preset -and $Settings.game -eq 'all') { return ('TCP и UDP, только порты игр (TCP {0}, UDP {1})' -f $Settings.gametcp, $Settings.gameudp) }
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
# Необязательный "# since: 1.6" - версия сборки, в которой стратегия появилась: быстрый автоподбор проверяет её, пока
# рейтинг сделан более старой версией (Get-TestStrategies).

# Разбор 27 файлов стратегий - заметная часть времени шапки меню и сборки командной строки (Get-RotationOrder
# зовёт его для каждого профиля), поэтому результат хранится, пока не изменился ни один файл strategies\alt*.txt.
$Script:StrategiesCache = $null
function Get-Strategies {
    $files = @(Get-ChildItem -Path $Script:StratDir -Filter 'alt*.txt' | Sort-Object { [int]($_.BaseName -replace '\D', '') })
    $sig = (@($files | ForEach-Object { $_.Name + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks }) -join '|')
    if ($Script:StrategiesCache -and $Script:StrategiesCache.Sig -eq $sig) { return $Script:StrategiesCache.Items }
    $result = @()
    foreach ($file in $files) {
        if ($file.BaseName -notmatch '^alt(\d+)$') { continue }
        $id = $matches[1]
        $name = 'ALT' + $id
        $desc = ''
        $since = ''
        $sec = @{}
        $matchL3 = @{}
        $invalid = @()
        $cur = $null
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            $t = $line.Trim()
            if ($t -match '^#\s*name:\s*(.+)$') { $name = $matches[1]; continue }
            if ($t -match '^#\s*desc:\s*(.+)$') { $desc = $matches[1]; continue }
            if ($t -match '^#\s*since:\s*(.+)$') { $since = $matches[1].Trim(); continue }
            if ($t -match '^#\s*match-l3:\s*(.*)$') {
                $family=$matches[1].Trim()
                if(-not $cur -or $family -notin @('ipv4','ipv6') -or $matchL3.ContainsKey($cur)){$invalid+='некорректный match-l3';continue}
                $matchL3[$cur]=$family;continue
            }
            if ($t -eq '' -or $t.StartsWith('#')) { continue }
            if ($t -match '^\[([a-z_]+)\]$') { $cur = $matches[1]; $sec[$cur] = @(); continue }
            if ($cur) { $sec[$cur] += $t }
        }
        $missing = @($Script:Sections | Where-Object { -not $sec.ContainsKey($_) }) + $invalid
        $result += New-Object PSObject -Property @{
            Id = $id; Name = $name; Desc = $desc; Since = $since; File = $file.FullName; Sections = $sec; MatchL3=$matchL3; Missing = $missing
        }
    }
    $Script:StrategiesCache = New-Object PSObject -Property @{ Sig = $sig; Items = $result }
    return $result
}

function Get-Strategy([string]$Id) {
    foreach ($s in (Get-Strategies)) { if ($s.Id -eq $Id) { return $s } }
    return $null
}
function Get-SectionMatchL3($Strategy,[string]$Section,[string]$Fallback='') {
    $actual=if($Strategy.Sections.ContainsKey($Section)){$Section}else{$Fallback}
    if($Strategy.PSObject.Properties.Name -contains 'MatchL3' -and $Strategy.MatchL3.ContainsKey($actual)){return $Strategy.MatchL3[$actual]}
    return 'any'
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
# YouTube - по группе YouTube, Discord - по Discord, сайты - по общему "пробито минус вред".
# В круг попадают только стратегии, которые дают хотя бы RankMinShare прироста лучшей относительно
# прогона без обхода. Слабые и вредные для обычных сайтов (seqovl ломает серверы Akamai) остаются
# в strategies\ и в автоподборе. Стандартный круг сайтов в 1.4 пускал по кругу ALT11/ALT12, и сайты Akamai
# (Bing, Adobe, Sony) висели на TLS.
# У игры (FixedRings) круг стандартный: автоподбор не проверяет игру в матче, 2K и EAC открываются почти со всеми
# стратегиями, и круг игры выбирался бы по сайтам.
$Script:RankFile = 'runtime/test-rank.txt'
$Script:RankMinShare = 0.6
# В группах на 3-4 адреса почти все стратегии набирают максимум; дальше пятой по кругу всё равно не уйдёт
$Script:RingMax = 5
$Script:SectionGroups = @{ google = @('YouTube'); discord_media = @('Discord') }
$Script:FixedRings = @('game_tcp')
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

# Рейтинг относится к сети и входным файлам. alt/auto — результат выбора, notify — только интерфейс.
# RunId связывает два файла одного измерения: незавершённая публикация не смешивает покрытие разных прогонов.
function Get-TestResultContext($Settings = $null, $NetworkObservation = $null) {
    try {
        if ($null -eq $Settings) { $Settings = Get-Settings }
        if ($null -eq $NetworkObservation) { $NetworkObservation = Get-NetworkObservation }
        if (-not $NetworkObservation.Known -or $NetworkObservation.Key -notmatch '^[A-Fa-f0-9]{64}$') { return $null }
        $settingsKey = @($Settings.Keys | Where-Object { $_ -notin @('alt','auto','notify') } | Sort-Object | ForEach-Object { $_+'='+[string]$Settings[$_] }) -join '|'
        $inputs = Get-ScoreInputsHash @([pscustomobject]@{Group='rank';Name='configuration';Url='local'}) @{Settings=$settingsKey}
        if (-not $inputs) { return $null }
        $parts = @('rank-context-v2', $inputs)
        foreach ($dir in @('strategies','bin','windivert')) {
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Script:Root $dir) -File -ErrorAction Stop | Sort-Object Name)) {
                $parts += $dir+'/'+$file.Name+'='+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            }
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','') } finally { $sha.Dispose() }
        return [pscustomobject]@{Schema=2;NetworkKey=$NetworkObservation.Key;InputsHash=$hash;RunId=[guid]::NewGuid().ToString('N')}
    } catch { return $null }
}
function Test-TestResultContext($Before, $After) {
    if ($null -eq $Before -or $null -eq $After) { return $false }
    foreach ($c in @($Before,$After)) {
        foreach ($key in @('Schema','NetworkKey','InputsHash','RunId')) { if (-not $c.PSObject.Properties[$key]) { return $false } }
        if ($c.Schema -ne 2 -or $c.NetworkKey -notmatch '^[A-Fa-f0-9]{64}$' -or $c.InputsHash -notmatch '^[A-Fa-f0-9]{64}$' -or $c.RunId -notmatch '^[a-f0-9]{32}$') { return $false }
    }
    return $Before.NetworkKey -ceq $After.NetworkKey -and $Before.InputsHash -ceq $After.InputsHash
}
function Get-TestResultHeader($Lines) {
    try {
        $headers = @($Lines | Where-Object { $_.StartsWith('# context: ') })
        if ($headers.Count -ne 1) { return $null }
        $c = $headers[0].Substring(11) | ConvertFrom-Json -ErrorAction Stop
        if (Test-TestResultContext $c $c) { return $c }
    } catch { }
    return $null
}
function Write-TestResultFile([string]$Path, $Lines, $Context) {
    if (-not (Test-TestResultContext $Context $Context)) { throw 'Неизвестный контекст сети: рейтинг не сохранён.' }
    if ((Test-Path -LiteralPath $Path) -and -not (Get-TestResultHeader ([IO.File]::ReadAllLines($Path)))) {
        $backup = $Path+'.v1.bak'
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop }
    }
    $temp = $Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        Write-TextNoBom $temp ((@('# context: '+($Context | ConvertTo-Json -Compress)) + @($Lines) -join "`r`n") + "`r`n")
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
$Script:TestResultPreview = $null
function New-TestResultPreview($Base, $Alts, $Table, $Context) {
    if (-not (Test-TestResultContext $Context $Context)) { throw 'Контекст итоговой проверки не подтверждён.' }
    $baseGroups = @{}; foreach ($key in $Base.Groups.Keys) { $baseGroups[$key] = [double]$Base.Groups[$key].Ok }
    $rows = @($Alts | ForEach-Object {
        $groups = @{}; foreach ($key in $_.Groups.Keys) { $groups[$key] = [double]$_.Groups[$key].Ok }
        [pscustomobject]@{Id=$_.Id;Score=$_.Score;Ok=$_.Ok;Total=$_.Total;Harm=$_.Harm;Freeze=$_.Freeze;Groups=$groups}
    })
    $cover = @{}; foreach ($id in $Table.Keys) { $cover[$id] = @($Table[$id] | Where-Object { $_.State -eq 'OK' } | ForEach-Object { $_.Group+'|'+$_.Name } | Sort-Object -Unique) }
    $rank = [pscustomobject]@{Date=(Get-Date -Format 'yyyy-MM-dd HH:mm');Version=$Script:Version;BaseOk=$Base.Ok;BaseGroups=$baseGroups;Rows=$rows;Context=$Context}
    return [pscustomobject]@{Rank=$rank;Cover=$cover;Context=$Context}
}
function Get-TestRank($Context = $null) {
    if ($null -ne $Script:TestResultPreview) {
        if ($null -eq $Context) { $Context = Get-TestResultContext }
        if (Test-TestResultContext $Script:TestResultPreview.Context $Context) { return $Script:TestResultPreview.Rank }
        return $null
    }
    $f = Get-PkgPath $Script:RankFile
    if (-not (Test-Path $f)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($f)
    $savedContext = Get-TestResultHeader $lines
    if (-not $savedContext) { return $null }
    if ($null -eq $Context) { $Context = Get-TestResultContext }
    if (-not (Test-TestResultContext $savedContext $Context)) { return $null }
    # рейтинг без строки version сделан версией до 1.6, где её ещё не писали
    $rows = @(); $baseOk = $null; $baseGroups = @{}; $date = $null; $ver = '1.5'
    $n = '(-?\d+(?:\.\d+)?)'
    # стратегии, убранной обновлением сборки, в файле ещё числится балл: иначе она занимала бы место в круге, а в работе её нет
    $exists = @(Get-Strategies | ForEach-Object { $_.Id })
    foreach ($line in $lines) {
        if ($line -match '^#\s*date:\s*(.+)$') { $date = $matches[1].Trim(); continue }
        if ($line -match '^#\s*version:\s*(.+)$') { $ver = $matches[1].Trim(); continue }
        if ($line -match ('^base\s+' + $n + '\s+(\d+)(.*)$')) { $baseOk = ConvertFrom-Points $matches[1]; $baseGroups = Read-RankGroups $matches[3]; continue }
        if ($line -match ('^(\d+)\s+' + $n + '\s+' + $n + '\s+(\d+)\s+(\d+)\s+(\d+)(.*)$')) {
            if ($exists -notcontains $matches[1]) { continue }
            $rows += New-Object PSObject -Property @{ Id = $matches[1]; Score = (ConvertFrom-Points $matches[2]); Ok = (ConvertFrom-Points $matches[3])
                Total = [int]$matches[4]; Harm = [int]$matches[5]; Freeze = [int]$matches[6]; Groups = (Read-RankGroups $matches[7]) }
        }
    }
    if ($null -eq $baseOk -or $rows.Count -eq 0) { return $null }
    return New-Object PSObject -Property @{ Date = $date; Version = $ver; BaseOk = $baseOk; BaseGroups = $baseGroups; Rows = $rows; Context = $savedContext }
}

# Какие адреса открыла каждая стратегия в последнем автоподборе (runtime\test-cover.txt, рядом с рейтингом).
# Строка: номер<таб>группа|адрес<таб>группа|адрес... Номер 0 - без обхода. $Table: номер -> строки результата
$Script:CoverFile = 'runtime/test-cover.txt'
$Script:RingCache = @{}
function Save-TestCover($Table, $Context = $null) {
    if ($null -eq $Context) { $Context = Get-TestResultContext }
    $lines = @('# Какие адреса открыла каждая стратегия в последнем автоподборе. Удалите файл - круги соберутся только по баллам')
    foreach ($id in $Table.Keys) {
        $lines += (@($id) + @($Table[$id] | Where-Object { $_.State -eq 'OK' } | ForEach-Object { $_.Group + '|' + $_.Name } | Sort-Object -Unique)) -join "`t"
    }
    Write-TestResultFile (Get-PkgPath $Script:CoverFile) $lines $Context
}
function Get-TestCover($Rank = $null, $Context = $null) {
    if ($null -eq $Context) { $Context = Get-TestResultContext }
    if ($null -eq $Rank) { $Rank = Get-TestRank $Context }
    if (-not $Rank -or -not $Rank.PSObject.Properties['Context'] -or -not (Test-TestResultContext $Rank.Context $Context)) { return $null }
    if ($null -ne $Script:TestResultPreview) {
        if ((Test-TestResultContext $Script:TestResultPreview.Context $Context) -and $Rank.Context.RunId -ceq $Script:TestResultPreview.Context.RunId) { return $Script:TestResultPreview.Cover }
        return $null
    }
    $f = Get-PkgPath $Script:CoverFile
    if (-not (Test-Path $f)) { return $null }
    $lines = [System.IO.File]::ReadAllLines($f)
    $savedContext = Get-TestResultHeader $lines
    if (-not (Test-TestResultContext $savedContext $Context) -or $savedContext.RunId -cne $Rank.Context.RunId) { return $null }
    $c = @{}
    foreach ($line in $lines) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $p = @($line -split "`t")
        # ? - метка версии 1.7: "стратегия тут ни при чём". Это была ошибка, такие адреса просто не открылись (см. Convert-CurlResult)
        $c[$p[0]] = @($p | Select-Object -Skip 1 | Where-Object { -not $_.StartsWith('?') })
    }
    return $c
}

# Стратегии с близким баллом обычно открывают одно и то же, и перебирать их при неудаче незачем. Поэтому сразу за первой в круг
# идут те, что открывают заблокированные адреса, которых не открыла ни одна стратегия выше; вред тут не помеха: на такую
# стратегию переходит только сервер, на котором первая не сработала. Дальше - сильные по баллу ($Ids), всего до $RingMax.
# Адреса YouTube и Discord считаются только для их кругов: у них свои стратегии
function Get-RingByCover($Ids, [string]$Section, [string]$PrimaryId, $Rank, $Context = $null) {
    # Проверяем контекст до кэша: сам файл не меняется при переключении Wi-Fi.
    $cover = Get-TestCover -Rank $Rank -Context $Context
    if (-not $cover -or -not $cover.ContainsKey('0')) { return @($Ids) }
    # шапка меню строит круги при каждой перерисовке: тот же ответ, пока файл не поменялся
    $f = Get-Item -LiteralPath (Get-PkgPath $Script:CoverFile) -ErrorAction SilentlyContinue
    $fileHash = if ($null -ne $Script:TestResultPreview) { 'preview' } elseif ($f) { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } else { return @($Ids) }
    $cacheKey = ($Section, $PrimaryId, $Rank.Context.RunId, $fileHash, (@($Ids) -join ',')) -join '|'
    if ($Script:RingCache.ContainsKey($cacheKey)) { return $Script:RingCache[$cacheKey] }
    $groups = $Script:SectionGroups[$Section]
    $others = @($Script:SectionGroups.Values | ForEach-Object { $_ })
    $mine = @{}
    foreach ($id in $cover.Keys) {
        $l = New-Object System.Collections.Generic.List[string]
        foreach ($k in $cover[$id]) {
            $g = $k.Substring(0, [math]::Max(0, $k.IndexOf('|')))
            if ($(if ($groups) { $groups -contains $g } else { $others -notcontains $g })) { $l.Add($k) }
        }
        $mine[$id] = $l
    }
    $first = if (@($Ids) -contains $PrimaryId) { $PrimaryId } else { @($Ids)[0] }
    $done = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in @($cover['0'])) { [void]$done.Add($k) }
    if ($cover.ContainsKey($first)) { foreach ($k in $cover[$first]) { [void]$done.Add($k) } }
    $ring = @($first)
    # кандидаты в порядке рейтинга: при равной пользе берём ту, у кого балл выше
    $cands = @($Rank.Rows | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Freeze } } | ForEach-Object { $_.Id })
    while ($ring.Count -lt $Script:RingMax) {
        $best = $null; $bestGain = 0
        foreach ($id in $cands) {
            if ($ring -contains $id -or -not $cover.ContainsKey($id)) { continue }
            $gain = 0
            foreach ($k in $mine[$id]) { if (-not $done.Contains($k)) { $gain++ } }
            if ($gain -gt $bestGain) { $best = $id; $bestGain = $gain }
        }
        if (-not $best) { break }
        $ring += $best
        foreach ($k in $mine[$best]) { [void]$done.Add($k) }
    }
    foreach ($id in @($Ids)) {
        if ($ring.Count -ge $Script:RingMax) { break }
        if ($ring -notcontains $id) { $ring += $id }
    }
    $Script:RingCache[$cacheKey] = $ring
    return $ring
}

# Стратегии, достаточно сильные для профиля, от лучшей к худшей (Id). $null - по этому профилю различать нечего
# (группа у провайдера не блокируется или рейтинг старого формата): тогда берётся круг сайтов.
function Get-SectionRank($Rank, [string]$Section, [string]$PrimaryId, $Context = $null) {
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
    return @(Get-RingByCover @($q | ForEach-Object { $_.Id }) $Section $PrimaryId $Rank $Context)
}

# $Base и $Alts - итоги автоподбора (Get-RunSummary): Ok, Total, Score, Harm, Freeze и Groups (группа -> Ok/Total)
function Save-TestRank($Base, $Alts, $Context = $null) {
    if ($null -eq $Context) { $Context = Get-TestResultContext }
    function Format-Groups($S) { return (@($S.Groups.Keys | ForEach-Object { '{0}={1}/{2}' -f $_, (Format-Points $S.Groups[$_].Ok), $S.Groups[$_].Total }) -join ' ') }
    $lines = @('# Рейтинг стратегий по автоподбору: порядок и состав кругов автосмены. Удалите файл - вернётся стандартный порядок.',
        ('# date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')),
        ('# version: ' + $Script:Version),
        '# id score(пробито-вред) ok total harm freeze группы; .5 - адрес открылся только со второй попытки',
        ('base {0} {1} {2}' -f (Format-Points $Base.Ok), $Base.Total, (Format-Groups $Base)))
    foreach ($r in $Alts) {
        $lines += ('{0} {1} {2} {3} {4} {5} {6}' -f $r.Id, (Format-Points $r.Score), (Format-Points $r.Ok), $r.Total, $r.Harm, $r.Freeze, (Format-Groups $r))
    }
    Write-TestResultFile (Get-PkgPath $Script:RankFile) $lines $Context
    # какие стратегии на этом ПК уже проверялись хоть раз (номер и имя: номер могли отдать другой стратегии)
    $tested = @(@(Get-ListLines (Get-PkgPath $Script:TestedFile)) + @($Alts | ForEach-Object { $_.Id + '|' + $_.Name }) | Select-Object -Unique)
    Write-TextNoBom (Get-PkgPath $Script:TestedFile) (($tested -join "`r`n") + "`r`n")
}

$Script:TestedFile = 'runtime/tested-strategies.txt'

# Проверялась ли стратегия на этом ПК. Пока файла нет (автоподбор был до 1.6) - смотрим номера в рейтинге
function Test-StrategyTested($St, $Rank) {
    $lines = @(Get-ListLines (Get-PkgPath $Script:TestedFile))
    if ($lines.Count) { return ($lines -contains ($St.Id + '|' + $St.Name)) }
    return [bool]($Rank -and @($Rank.Rows | Where-Object { $_.Id -eq $St.Id }).Count)
}

# Баллы автоподбора плавают от прогона к прогону: на одном ПК за вечер - до 3 баллов. Основную стратегию поэтому сравниваем
# по среднему совместимых прогонов. Формат v2: дата|номер|имя|балл|контекст|SHA256 стратегии.
$Script:ScoreHistoryFile = 'runtime/test-scores.txt'
$Script:ScoreRuns = 3       # сколько последних прогонов каждой стратегии усредняем
$Script:ScoreMaxDays = 30   # прогоны старше забываем: за это время у провайдера всё могло поменяться
$Script:ScoreMargin = 2     # меньшая разница средних - случайность, основная не меняется

function Get-StrategyFingerprint([string]$Id) {
    if ($Id -notmatch '^\d+$') { return '' }
    try { return (Get-FileHash -LiteralPath (Join-Path $Script:StratDir ('alt' + $Id + '.txt')) -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' }
}
function Get-ScoreInputsHash($Targets, [hashtable]$Parameters = @{}) {
    try {
        if (-not @($Targets).Count) { return '' }
        $parts = @('score-inputs-v2', $Script:Version)
        $parts += @($Targets | ForEach-Object { @($_.Group,$_.Name,$_.Url) | ConvertTo-Json -Compress } | Sort-Object)
        foreach ($key in @($Parameters.Keys | Sort-Object)) { $parts += ($key + '=' + [string]$Parameters[$key]) }
        $files = @('tools/test.ps1','tools/lib.ps1','tools/netstate.ps1','tools/netwatch.ps1','tools/capture.ps1','tools/linkguard.ps1','tools/recovery.ps1','tools/selection.ps1','tools/comparison.ps1','tools/processmetrics.ps1','CHECKSUMS.txt') + @(Get-ChildItem -LiteralPath (Join-Path $Script:Root 'lua') -Filter '*.lua' -ErrorAction Stop | Sort-Object Name | ForEach-Object { 'lua/' + $_.Name })
        foreach ($dir in @('lists','fake')) {
            $files += @(Get-ChildItem -LiteralPath (Join-Path $Script:Root $dir) -File -ErrorAction Stop | Where-Object { $_.Name -ne 'autohostlist.txt' -and $_.Extension -ne '.bak' } | Sort-Object Name | ForEach-Object { $dir+'/'+$_.Name })
        }
        foreach ($file in $files) {
            $parts += (Get-FileHash -LiteralPath (Join-Path $Script:Root $file) -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','') } finally { $sha.Dispose() }
    } catch { return '' }
}
function Get-ScoreContext($Connection, $Targets, [hashtable]$Parameters = @{}) {
    try {
        $asn = [regex]::Match([string]$Connection.As, '(?i)^\s*AS\d+\b').Value.Trim().ToUpperInvariant()
        $country = ([string]$Connection.CountryCode).ToUpperInvariant()
        $inputs = Get-ScoreInputsHash $Targets $Parameters
        if (-not $asn -or $country -notmatch '^[A-Z]{2}$' -or -not $inputs) { return '' }
        # Публичный IP не сохраняется, дополнительных запросов к провайдерским сервисам нет.
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($asn + '|' + $country + '|' + $inputs)))).Replace('-','') } finally { $sha.Dispose() }
    } catch { return '' }
}
function Test-ScoreInputs([string]$Before, $Targets, [hashtable]$Parameters, [hashtable]$Fingerprints, $NetworkBefore = $null) {
    if ($null -ne $NetworkBefore -and -not (Test-NetworkObservation $NetworkBefore (Get-NetworkObservation))) { return $false }
    if (-not $Before -or $Before -cne (Get-ScoreInputsHash $Targets $Parameters)) { return $false }
    foreach ($id in $Fingerprints.Keys) {
        if (-not $Fingerprints[$id] -or $Fingerprints[$id] -cne (Get-StrategyFingerprint $id)) { return $false }
    }
    return $true
}
function Get-ScoreHistory {
    $min = (Get-Date).AddDays(-$Script:ScoreMaxDays)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rows = @()
    foreach ($l in @(Get-ListLines (Get-PkgPath $Script:ScoreHistoryFile))) {
        $p = $l -split '[|]'
        $d = [datetime]::MinValue; $x = 0.0
        if (@(4,6) -notcontains $p.Count) { continue }
        if (-not [datetime]::TryParseExact($p[0], 'yyyy-MM-dd HH:mm', $inv, [Globalization.DateTimeStyles]::None, [ref]$d) -or $d -lt $min -or $d -gt (Get-Date).AddMinutes(1)) { continue }
        if (-not [double]::TryParse($p[3], [Globalization.NumberStyles]::Float, $inv, [ref]$x) -or [double]::IsNaN($x) -or [double]::IsInfinity($x)) { continue }
        $context = ''; $fingerprint = ''
        if ($p.Count -eq 6) {
            if ($p[4] -notmatch '^[A-Za-z0-9_-]{1,64}$' -or $p[5] -notmatch '^[A-Fa-f0-9]{64}$') { continue }
            $context = $p[4]; $fingerprint = $p[5]
        }
        $rows += New-Object PSObject -Property @{ Date=$p[0]; Id=$p[1]; Name=$p[2]; Score=$x; Context=$context; Fingerprint=$fingerprint }
    }
    return $rows
}
function Add-ScoreHistory($Alts, [string]$Context = '', [hashtable]$Expected = @{}) {
    if ($Context -notmatch '^[A-Za-z0-9_-]{1,64}$') { return $false }
    try {
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $added = @()
        foreach ($a in $Alts) {
            $fingerprint = Get-StrategyFingerprint $a.Id
            if (-not $fingerprint) { return $false }
            if ($Expected.Count -and (-not $Expected.ContainsKey($a.Id) -or $Expected[$a.Id] -cne $fingerprint)) { return $false }
            $added += New-Object PSObject -Property @{ Date=$now; Id=$a.Id; Name=$a.Name; Score=$a.Score; Context=$Context; Fingerprint=$fingerprint }
        }
        $path = Get-PkgPath $Script:ScoreHistoryFile
        if ((Test-Path $path) -and -not (Test-Path ($path + '.v1.bak'))) {
            $legacy = @([IO.File]::ReadAllLines($path) | Where-Object { -not $_.StartsWith('#') -and ($_ -split '[|]').Count -eq 4 })
            if ($legacy.Count) { [IO.File]::Copy($path, ($path + '.v1.bak'), $false) }
        }
        $rows = @(Get-ScoreHistory) + $added
        $keep = @($rows | Group-Object { $_.Id + '|' + $_.Name + '|' + $_.Context + '|' + $_.Fingerprint } | ForEach-Object { $_.Group | Select-Object -Last $Script:ScoreRuns })
        $lines = @('# История: дата|номер|имя|балл|контекст|SHA256 стратегии; записи v1 сохранены, но не усредняются с v2')
        foreach ($row in $keep) {
            $line = '{0}|{1}|{2}|{3}' -f $row.Date,$row.Id,$row.Name,(Format-Points $row.Score)
            if ($row.Context) { $line += '|' + $row.Context + '|' + $row.Fingerprint }
            $lines += $line
        }
        Write-TextNoBom $path (($lines -join "`r`n") + "`r`n")
        return $true
    } catch { return $false }
}
function Get-AverageScores($Alts, [string]$Context = '') {
    $hist = @()
    if ($Context) { try { $hist = @(Get-ScoreHistory) } catch { } }
    $avg = @{}
    foreach ($a in $Alts) {
        $fingerprint = Get-StrategyFingerprint $a.Id
        $vals = @()
        if ($Context -and $fingerprint) {
            $vals = @($hist | Where-Object { $_.Id -eq $a.Id -and $_.Name -eq $a.Name -and $_.Context -ceq $Context -and $_.Fingerprint -eq $fingerprint } | ForEach-Object { $_.Score } | Select-Object -Last $Script:ScoreRuns)
        }
        if (-not $vals.Count) { $vals = @($a.Score) }
        $avg[$a.Id] = New-Object PSObject -Property @{ Avg=($vals | Measure-Object -Average).Average; Runs=$vals.Count }
    }
    return $avg
}

# Кого предлагать основной. Top - лучший средний (при равенстве основная, потом реже замерзает, потом основные стратегии);
# Noise - Top впереди основной меньше чем на $ScoreMargin: менять незачем
function Get-PrimaryChoice($Alts, [hashtable]$Avg, [string]$CurrentId, $OrderIds) {
    $top = @($Alts | Sort-Object @{ Expression = { $Avg[$_.Id].Avg }; Descending = $true }, @{ Expression = { $_.Id -ne $CurrentId } }, @{ Expression = { $_.Freeze } }, @{ Expression = { [array]::IndexOf(@($OrderIds), $_.Id) } })[0]
    $cur = @($Alts | Where-Object { $_.Id -eq $CurrentId }) | Select-Object -First 1
    $noise = $false
    if ($cur -and $top.Id -ne $cur.Id) { $noise = ($Avg[$top.Id].Avg - $Avg[$cur.Id].Avg) -lt $Script:ScoreMargin }
    return New-Object PSObject -Property @{ Top = $top; Current = $cur; Noise = $noise }
}

# Память автосмены (lua\autoring.lua): какие сайты и подсети работают не с первой стратегией круга
$Script:RingDir = 'runtime/ring'
# Каталог создаём сами. Если его создаст winws2 (mkdir в cygwin), в его правах будет запрет записи для Authenticated Users:
# служба работает от SYSTEM, входит в эту группу и не сможет записать файл. Такие права исправляем на обычные
function Initialize-RingDir {
    $d = Get-PkgPath $Script:RingDir
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null; return }
    $deny = @((Get-Acl $d).Access | Where-Object { $_.AccessControlType -eq 'Deny' })
    if ($deny.Count) { & (Join-Path $env:SystemRoot 'System32\icacls.exe') $d /reset /T /C /Q 2>&1 | Out-Null }
}
function Get-RingStateName([string]$Section, $Ring) {
    if($Script:RingCompositionKey -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Состав памяти автосмены не подтверждён.'}
    # Ключ сети добавляет Lua по свежему heartbeat; сохранённая ImagePath не фиксирует прежнюю сеть.
    $sig = $Script:RingCompositionKey + '|' + (@($Ring | ForEach-Object { $_.Id + ':' + $_.Name + ':' + (Get-StrategyFingerprint $_.Id) }) -join ',')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hex = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 24).ToLower() }
    finally { $sha.Dispose() }
    return ('ring-{0}-{1}-{2}.txt' -f $Section, $Script:RingCompositionKey.Substring(0,24).ToLowerInvariant(), $hex)
}
function Get-RingCompositionKey([hashtable]$Settings) {
    $settingsKey=@($Settings.Keys | Sort-Object | ForEach-Object { $_+'='+[string]$Settings[$_] }) -join '|'
    $target=[pscustomobject]@{Group='ring';Name='composition';Url='local'}
    return Get-ScoreInputsHash @($target) @{Settings=$settingsKey}
}
# Круг поменялся (новый автоподбор) - появляется новый файл. Старые оставляем на случай возврата, но не больше 8
function Remove-OldRingMemory {
    $d = Get-PkgPath $Script:RingDir
    if (-not (Test-Path $d)) { return }
    Get-ChildItem $d -Filter 'ring-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 8 |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# Круг автосмены профиля $Section (general - сайты, ipset_tcp, google - YouTube, discord_media, game_tcp).
# С рейтингом: основная первой, если она достаточно сильная для этого профиля, дальше остальные сильные.
# Без рейтинга (автоподбор ещё не запускали) и у игры (FixedRings) - основная и основные стратегии в порядке RotationPref.
function Get-RotationOrder([string]$PrimaryId, [string]$Section = 'general', $Context = $null) {
    $all = @(Get-Strategies | Where-Object { $_.Missing.Count -eq 0 })
    $primary = @($all | Where-Object { $_.Id -eq $PrimaryId })
    $rank = if ($Script:FixedRings -contains $Section) { $null } else { Get-TestRank $Context }
    if ($rank) {
        if ($null -eq $Context) { $Context = $rank.Context }
        $ids = Get-SectionRank $rank $Section $PrimaryId $Context
        if ($null -eq $ids) { $ids = Get-SectionRank $rank 'general' $PrimaryId $Context }
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
# Плюс новые стратегии (с "# since:"), которые на этом ПК ещё не проверялись: пришедшие с обновлением сборки
# проверяются первым же быстрым автоподбором, а дальше остаются в нём, только если попали в круги.
# QuickExtra (EXP, SIMPLE FAKE): фейк-приветствие без STUN впереди. Часть серверов отвечает только так, а STUN первым стоит почти во
# всех основных (за 10 автоподборов: net4u.de и adwin.fr - ALT11 0 из 10, ALT13 10 из 10); без них кругу не из чего выбирать
$Script:QuickExtra = @('41', '42')
function Get-TestStrategies([switch]$Full) {
    $all = @(Get-AllStrategiesOrdered)
    if ($Full) { return $all }
    $s = Get-Settings
    $rank = Get-TestRank
    $resultContext = if ($rank) { $rank.Context } else { $null }
    $keep = @($Script:RotationPref) + $Script:QuickExtra + @($s.alt)
    foreach ($sec in $Script:SectionTitles.Keys) { $keep += @(Get-RotationOrder $s.alt $sec $resultContext | ForEach-Object { $_.Id }) }
    $keep += @($all | Where-Object { $_.Since -and (-not $rank -or -not (Test-StrategyTested $_ $rank)) } | ForEach-Object { $_.Id })
    return @($all | Where-Object { $keep -contains $_.Id })
}

# Круги профилей, которые отличаются от круга сайтов: "YouTube: A > B" и т.д.
function Get-RingsText([hashtable]$Settings) {
    if ($Settings.auto -ne 'on') { return @() }
    $rank = Get-TestRank (Get-TestResultContext $Settings)
    if (-not $rank) { return @() }
    $general = (@(Get-RotationOrder $Settings.alt 'general' $rank.Context | ForEach-Object { $_.Id })) -join ','
    $out = @()
    foreach ($sec in @('google', 'discord_media', 'game_tcp')) {
        $ring = @(Get-RotationOrder $Settings.alt $sec $rank.Context)
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
# разбирается через bash, которого в Windows нет. Обычно пути абсолютные; длинные команды используют --chdir и относительные пути пакета.

function Get-PkgPath([string]$Rel) {
    $sep = if ($Script:Root -match '^[A-Za-z]:\\') { '\' } else { '/' }
    return $Script:Root.TrimEnd('\', '/') + $sep + ($Rel -replace '[\\/]', $sep)
}

# Профили повторяют general (ALT10-13).bat Flowseal в том же порядке, с Game Filter и IPSet.
# Отличия от Flowseal:
#  - на TCP-профилях работает circular (zapret-auto.lua) с детекторами lua\autoring.lua: при неудаче к одному серверу
#    (непроверенная на нём стратегия - с первой, проверенная - с третьей подряд)
#    (повторные отправки = замерзание 16-20 КБ, RST от DPI) этот сервер переводится на следующую ALT;
#  - из UDP 443 в драйвер попадают только пакеты QUIC Initial, а не весь QUIC-трафик YouTube;
#  - сети Take-Two (собственные серверы 2K) исключены везде: они не заблокированы, а фейки и разрезка
#    в их протоколе ломают проверку Easy Anti-Cheat (fee12ea9). У Flowseal их нет в ipset-all;
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
    $resultContext = if ($auto -and (Test-Path -LiteralPath (Get-PkgPath $Script:RankFile))) { Get-TestResultContext $Settings } else { $null }
    if ($auto) {
        $compositionSettings=$Settings.Clone()
        $compositionSettings.alt=$altId
        if($IpsetMode){$compositionSettings.ipset=$IpsetMode}
        $Script:RingCompositionKey = Get-RingCompositionKey $compositionSettings
        if (-not $Script:RingCompositionKey) { throw 'Не удалось подтвердить состав конфигурации для памяти автосмены.' }
    }
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
    # Take-Two уже исключены во всех профилях: TCP в обе стороны и исходящий UDP
    # не отправляем в userspace. У входящего TCP проверяется удалённый SrcAddr.
    # Небольшой IPv4 список фиксируется одинаково
    # в kernel filter и native профилях: редактирование файла не рассинхронизирует текущий запуск.
    $takeTwoFile=Get-PkgPath 'lists/ipset-taketwo.txt'
    $captureExclusion=$null
    try{if((Get-Item -LiteralPath $takeTwoFile -ErrorAction Stop).Length -le 8192){$captureExclusion=Get-CaptureExclusion ([IO.File]::ReadAllLines($takeTwoFile))}}catch{}
    if($captureExclusion){$a.Add('--wf-raw-filter='+$captureExclusion.Filter)}

    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-lib.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-antidpi.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/zapret-auto.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/host-cache.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/fooling.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/ring-store.lua'))
    $a.Add('--lua-init=@' + (Get-PkgPath 'lua/autoring.lua'))
    # память автосмены (lua\autoring.lua): файл можно писать только в этот каталог
    if ($auto) { Initialize-RingDir; $a.Add('--writable=' + (Get-PkgPath $Script:RingDir)) }
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
    # серверы 2K (Take-Two) исключены во всех профилях, даже в IPSet any. Серверы Valve - нет: NBA 2K27 ходит через
    # ретрансляторы Steam у хостингов из ipset-all, и без обхода их режут (в 1.2-1.3 их исключение давало статтеры в игре)
    $ipGames = @(if($captureExclusion){$captureExclusion.IpArgument}else{'--ipset-exclude='+$takeTwoFile})
    $ipEx = @(
        ('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-exclude.txt')),
        ('--ipset-exclude=' + (Get-PkgPath 'lists/ipset-exclude-user.txt'))) + $ipGames
    $ips = @()
    if ($ipMode -eq 'loaded') { $ips += '--ipset=' + (Get-PkgPath 'lists/ipset-all.txt') }
    elseif ($ipMode -eq 'any') { $ips += '--ipset=' + (Get-PkgPath 'runtime/ipset-any.txt') }
    $ips += '--ipset=' + (Get-PkgPath 'lists/ipset-user.txt')

    $script:firstProfile = $true
    $profileInfo=@{Current=$null}
    $generalTemplates=@{}
    function Add-ProfileRaw([string]$Name, [string[]]$Filters) {
        $profileInfo.Current=@{Name=$Name;Filters=$Filters;Start=$a.Count;First=$script:firstProfile}
        if ($script:firstProfile) { $a.Add("--name=$Name"); $script:firstProfile = $false }
        else { $a.Add("--new=$Name") }
        foreach ($f in $Filters) { $a.Add($f) }
    }
    function Add-Profile([string]$Name, [string[]]$Filters) {
        if($generalTemplates.Count -gt 0 -and $Filters -contains '--import=tpl_general'){
            foreach($family in @('ipv4','ipv6')){
                if(-not $generalTemplates.ContainsKey($family)){continue}
                $filtered=@($Filters|Where-Object{$_ -ne '--import=tpl_general'})+@(('--filter-l3='+$family),('--import='+$generalTemplates[$family]))
                Add-ProfileRaw ($Name+'_'+$family) $filtered
            }
            $profileInfo.Current=$null
        }else{Add-ProfileRaw $Name $Filters}
    }
    # Секция стратегии. С circular - секции стратегий круга этого профиля по очереди, каждая со своим номером strategy=N.
    # Если в круге профиля одна стратегия (например, на этом провайдере YouTube пробивает только она) - она без circular.
    # $Fallback - секция, которую берём у стратегии, если нужной у неё нет (ipset_tcp -> general).
    function Get-SectionLines($St, [string]$Name, [string]$Fallback) {
        if ($St.Sections.ContainsKey($Name)) { return $St.Sections[$Name] }
        return $St.Sections[$Fallback]
    }
    function Add-Section([string]$Name, [switch]$Circular, [string]$CircularArgs = '', [string]$Fallback = '', [switch]$Learn,[string]$Family='') {
        $ring = @(if ($Circular -and $auto) { Get-RotationOrder $altId $Name $resultContext } else { $primary })
        if($Family){$ring=@($ring|Where-Object{(Get-SectionMatchL3 $_ $Name $Fallback) -in @('any',$Family)})}
        elseif(@($ring|Where-Object{(Get-SectionMatchL3 $_ $Name $Fallback) -ne 'any'}).Count -and $null -ne $profileInfo.Current){
            $profile=$profileInfo.Current
            $a.RemoveRange($profile.Start,$a.Count-$profile.Start)
            $script:firstProfile=$profile.First
            foreach($version in @('ipv4','ipv6')){
                if(-not @($ring|Where-Object{(Get-SectionMatchL3 $_ $Name $Fallback) -in @('any',$version)}).Count){continue}
                Add-ProfileRaw ($profile.Name+'_'+$version) (@($profile.Filters)+@('--filter-l3='+$version))
                Add-Section $Name -Circular:$Circular -CircularArgs $CircularArgs -Fallback $Fallback -Learn:$Learn -Family $version
            }
            return
        }
        if(-not $ring.Count){return}
        # поддельные сбросы фильтра выбрасываются (lua\autoring.lua). Игру не трогаем. Входящие SYN+ACK, FIN и RST драйвер
        # и так передаёт winws2, поэтому лишней нагрузки нет
        if ($Learn) { foreach ($l in '--payload=all', '--out-range=x', '--in-range=a', '--lua-desync=rst_guard', '--in-range=x', '--out-range=a') { $a.Add($l) } }
        if ($ring.Count -ge 2) {
            $a.Add('--payload=all')
            $a.Add('--out-range=-s34228')
            $a.Add('--in-range=-s5556')
            # имя файла памяти - по составу круга: номера стратегий значат своё только в этом составе. Игра - без памяти
            # и с обычными детекторами: сервер матча не должен застрять на стратегии, случайно выбранной раньше
            $memoryName=if($Family){$Name+'_'+$Family}else{$Name}
            $stateArg = if ($Learn -and $Script:RingPersistAllowed) { ':context=network-context.txt:state=' + (Get-RingStateName $memoryName $ring) } else { '' }
            $memArgs = if ($Learn) { ':key=' + $memoryName + $stateArg + ':hostcache=bounded:link_guard=link-guard.txt:success_detector=ring_success:failure_detector=ring_failure' } else { '' }
            $a.Add('--lua-desync=circular:fails=3:time=60:nld=2' + $CircularArgs + $memArgs)
            $a.Add('--in-range=x')
            $n = 0
            foreach ($st in $ring) {
                $n++
                foreach ($l in (Get-SectionLines $st $Name $Fallback)) {
                    if ($l.StartsWith('--lua-desync=')) { $a.Add($l + ':strategy=' + $n) } else { $a.Add($l) }
                }
                if ($Learn) { foreach ($l in '--payload=all', '--out-range=-d10', ('--lua-desync=rst_mark:strategy=' + $n)) { $a.Add($l) } }
            }
        } else {
            foreach ($l in (Get-SectionLines $ring[0] $Name $Fallback)) { $a.Add($l) }
            if ($Learn) { foreach ($l in '--payload=all', '--out-range=-d10', '--lua-desync=rst_mark') { $a.Add($l) } }
        }
    }

    # Стратегия "общего списка" нужна в трёх профилях (general, tcp_ipset, autolist). С автосменой это все стратегии
    # круга, и три копии раздували командную строку к пределу Windows (32767). Поэтому - шаблон zapret2 и --import.
    $generalRing=@(if($auto){Get-RotationOrder $altId 'general' $resultContext}else{$primary})
    if(@($generalRing|Where-Object{(Get-SectionMatchL3 $_ 'general') -ne 'any'}).Count){
        foreach($family in @('ipv4','ipv6')){
            if(-not @($generalRing|Where-Object{(Get-SectionMatchL3 $_ 'general') -in @('any',$family)}).Count){continue}
            $generalTemplates[$family]='tpl_general_'+$family
            $a.Add('--template='+$generalTemplates[$family])
            Add-Section 'general' -Circular -CircularArgs ':reset' -Learn -Family $family
            $a.Add('--new')
        }
    }else{
        $a.Add('--template=tpl_general')
        Add-Section 'general' -Circular -CircularArgs ':reset' -Learn
        $a.Add('--new')
    }

    Add-Profile 'quic_list' (@('--filter-udp=443', '--filter-l7=quic') + $hostlists + $hostEx + $ipEx)
    Add-Section 'quic'
    Add-Profile 'discord_voice' (@("--filter-udp=$($Script:DiscordUdpPorts)", '--filter-l7=discord,stun') + $ipGames)
    Add-Section 'discord_udp'
    Add-Profile 'discord_media' (@("--filter-tcp=$($Script:DiscordTcpPorts)", '--hostlist-domains=discord.media') + $ipGames)
    Add-Section 'discord_media' -Circular -CircularArgs ':reset' -Learn
    Add-Profile 'google' (@('--filter-tcp=443', ('--hostlist=' + (Get-PkgPath 'lists/list-google.txt'))) + $ipGames)
    Add-Section 'google' -Circular -CircularArgs ':reset' -Learn
    Add-Profile 'general' (@('--filter-tcp=80,443') + $hostlists + $hostEx + $ipEx + @('--import=tpl_general'))
    Add-Profile 'quic_ipset' (@('--filter-udp=443', '--filter-l7=quic') + $ips + $hostEx + $ipEx)
    Add-Section 'quic'
    # У кого-то в круге своя стратегия для сетей ipset-all - тогда профиль собирается отдельно, иначе берёт шаблон
    $ipsetRing = @(if ($auto) { Get-RotationOrder $altId 'ipset_tcp' $resultContext } else { $primary })
    if (@($ipsetRing | Where-Object { $_.Sections.ContainsKey('ipset_tcp') }).Count) {
        Add-Profile 'tcp_ipset' (@('--filter-tcp=80,443,8443') + $ips + $hostEx + $ipEx)
        Add-Section 'ipset_tcp' -Circular -CircularArgs ':reset' -Fallback 'general' -Learn
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

function ConvertTo-CompactBypassArguments([string[]]$Arguments) {
    $rootPrefix=$Script:Root.TrimEnd('\','/')+'\'
    $result=New-Object 'System.Collections.Generic.List[string]'
    $result.Add('--chdir='+$Script:Root)
    foreach($arg in $Arguments){
        # Только файловые параметры внутри пакета; Lua-код, внешние пути и --writable не переписываются.
        if($arg -match '^(--(?:lua-init=@|blob=[A-Za-z_][A-Za-z_0-9]*:@|hostlist(?:-exclude|-auto|-auto-debug)?=|ipset(?:-exclude)?=|debug=@))(.+)$'){
            $option=$matches[1];$path=$matches[2]
            if($path.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){
                $arg=$option+($path.Substring($rootPrefix.Length).Replace('\','/'))
            }
        }
        $result.Add($arg)
    }
    return ,($result.ToArray())
}

# Командная строка winws2. Копия по одному параметру в строке кладётся в runtime\args-<Name>.txt для диагностики.
function Get-BypassCmdLine {
    param([hashtable]$Settings, [string]$Name = 'active', [string]$Alt, [switch]$NoAuto, [string]$IpsetMode, [switch]$DryRun, [string]$DebugFile)
    $previousPersistence = $Script:RingPersistAllowed
    try {
        if ($Name -in @('test','final-check','diag')) { $Script:RingPersistAllowed = $false }
        $list = New-BypassArgList -Settings $Settings -Alt $Alt -NoAuto:$NoAuto -IpsetMode $IpsetMode -DryRun:$DryRun -DebugFile $DebugFile
    } finally { $Script:RingPersistAllowed = $previousPersistence }
    $cmd = ConvertTo-WinCmdLine $list
    if($cmd.Length -gt 30000){
        $list=ConvertTo-CompactBypassArguments $list
        $cmd=ConvertTo-WinCmdLine $list
    }
    Write-TextNoBom (Join-Path $Script:Runtime ('args-' + $Name + '.txt')) (($list -join "`r`n") + "`r`n")
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
    Set-BypassPriorityPolicy $true
}

# При загрузке Windows и после сбоя службу запускает Windows, без меню, и приоритет был бы обычным. Настройка Windows для winws2.exe
# (CpuPriorityClass: 3 - высокий) действует при любом запуске. Убирает её пункт "Удалить zapret из Windows"
$Script:PriorityKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\winws2.exe'
function Set-BypassPriorityPolicy([bool]$On) {
    $k = $Script:PriorityKey
    $perf = $k + '\PerfOptions'
    $savedName = 'ZapretPreviousCpuPriorityClass'
    try {
        if (-not $On) {
            if (Test-Path -LiteralPath $perf) {
                $key = Get-Item -LiteralPath $perf -ErrorAction Stop
                $saved = $key.GetValue($savedName, $null)
                if ($null -ne $saved) {
                    if ((Get-BypassPriorityPolicy) -eq 3) {
                        if ($saved -eq 'absent') { Remove-ItemProperty -LiteralPath $perf -Name 'CpuPriorityClass' -ErrorAction Stop }
                        else { New-ItemProperty -LiteralPath $perf -Name 'CpuPriorityClass' -Value ([int]$saved) -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
                    }
                    Remove-ItemProperty -LiteralPath $perf -Name $savedName -ErrorAction Stop
                }
            }
            foreach ($path in @($perf, $k)) {
                if (Test-Path -LiteralPath $path) {
                    $key = Get-Item -LiteralPath $path -ErrorAction Stop
                    if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                }
            }
        } elseif ((Get-BypassPriorityPolicy) -ne 3) {
            if (-not (Test-Path -LiteralPath $perf)) { New-Item -Path $perf -Force -ErrorAction Stop | Out-Null }
            $key = Get-Item -LiteralPath $perf -ErrorAction Stop
            if ($null -eq $key.GetValue($savedName, $null)) {
                $before = $key.GetValue('CpuPriorityClass', $null)
                $saved = if ($null -eq $before) { 'absent' } else { [string]$before }
                New-ItemProperty -LiteralPath $perf -Name $savedName -Value $saved -PropertyType String -Force -ErrorAction Stop | Out-Null
            }
            New-ItemProperty -LiteralPath $perf -Name 'CpuPriorityClass' -Value 3 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
    } catch { }
}
function Get-BypassPriorityPolicy {
    $v = Get-ItemProperty -Path ($Script:PriorityKey + '\PerfOptions') -Name 'CpuPriorityClass' -ErrorAction SilentlyContinue
    if ($v) { return $v.CpuPriorityClass }
    return 0
}

function Enable-TcpTimestamps {
    # фейки с устаревшим timestamp (fooling ts у Flowseal) требуют TCP timestamps Windows
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null
}


# Один владелец управления общей службой/драйвером на ПК и дополнительная lease конкретной папки.
if (-not (Get-Variable ControlDepth -Scope Script -ErrorAction SilentlyContinue)) {
    $Script:ControlDepth = 0
    $Script:ControlHandle = $null
    $Script:ControlMutex = $null
}
if (-not (Get-Variable ControlMutexName -Scope Script -ErrorAction SilentlyContinue)) { $Script:ControlMutexName = 'Global\chepi1.zapret2.control.v2' }
if (-not (Get-Variable GameControlApproved -Scope Script -ErrorAction SilentlyContinue)) { $Script:GameControlApproved = $false }
function Enter-BypassControl([string]$Action) {
    if ($Script:ControlDepth -gt 0) { $Script:ControlDepth++; return $true }
    $handle = $null
    $mutex = $null; $ownsMutex = $false
    try {
        $mutex = New-ControlMutex $Script:ControlMutexName
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { $mutex.Dispose(); return $false }
        $handle = [IO.File]::Open((Join-Path $Script:Runtime 'control.lock'), 'OpenOrCreate', 'ReadWrite', 'Read')
        $bytes = [Text.Encoding]::UTF8.GetBytes(('{0} {1} {2}' -f $PID, (Get-Date -Format s), $Action))
        $handle.SetLength(0); $handle.Write($bytes, 0, $bytes.Length); $handle.Flush()
        $Script:ControlHandle = $handle; $Script:ControlDepth = 1
        $Script:ControlMutex = $mutex
        return $true
    } catch {
        if ($handle) { $handle.Dispose() }
        if ($mutex) { if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
        return $false
    }
}
function Exit-BypassControl {
    if ($Script:ControlDepth -le 0) { return }
    $Script:ControlDepth--
    if ($Script:ControlDepth -eq 0) {
        try { $Script:ControlHandle.Dispose(); $Script:ControlHandle = $null }
        finally { $Script:ControlMutex.ReleaseMutex(); $Script:ControlMutex.Dispose(); $Script:ControlMutex = $null }
    }
}
function Assert-BypassControlAllowed([switch]$AllowPendingUpdate) {
    if (-not $AllowPendingUpdate -and (Test-PendingUpdate $Script:Root)) { throw 'Обновление прервано. Запустите zapret.bat для восстановления файлов перед управлением обходом.' }
    $games = @(Get-RunningGames)
    if ($games.Count -and -not $Script:GameControlApproved) {
        throw ('Действие отложено: запущена игра (' + ($games -join ', ') + '). Закройте игру и повторите запуск.')
    }
}
function Add-BypassAction([string]$Action, [string]$Result) {
    try {
        $path = Join-Path $Script:Runtime 'control-actions.log'
        $old = @(if (Test-Path $path) { [IO.File]::ReadAllLines($path) | Select-Object -Last 79 })
        $line = '{0} pid={1} {2}: {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Action, ($Result -replace '[\r\n]+', ' ')
        Write-TextNoBom $path ((@($old) + @($line)) -join "`r`n")
    } catch { } # Неудача журнала не должна ломать управление обходом.
}
function Get-StartFailureKind([string]$Text) {
    if ($Text -match '(?i)referenced by other objects|0x8032000A|ссылаются другие объекты') { return 'FilterBusy' }
    if ($Text -match '(?i)\b577\b|\b1275\b|signature|подпис') { return 'DriverBlocked' }
    if ($Text -match '(?i)access is denied|отказано в доступе') { return 'AccessDenied' }
    return 'Unknown'
}
function Get-BypassDiagnosis([bool]$Running, [string]$StartError, [string[]]$Games, [string[]]$Proxy) {
    if ($Running) {
        'Обход: процесс работает.'
        (Get-ServiceHealthSummary @(Get-OurProcesses)).Text
    }
    else {
        'Обход: процесс не работает.'
        if ($StartError) {
            if ((Get-StartFailureKind $StartError) -eq 'FilterBusy') { 'Последняя ошибка: 0x8032000A — сетевой объект занят; причина удержания не установлена.' }
            else { 'Последняя записанная ошибка запуска: см. раздел ниже.' }
        } else { 'Ошибки запуска не записаны: обход мог быть остановлен вручную.' }
    }
    if ($Games.Count) { 'Открыты игры/античиты: ' + ($Games -join ', ') }
    if ($Proxy.Count) { 'Признаки прокси/VPN (не доказательство активного туннеля): ' + ($Proxy -join '; ') }
}
function Start-Bypass([switch]$Quiet) {
    if (-not (Enter-BypassControl 'start')) { Write-Color 'Запуск отложен: другая операция управляет обходом. Повторите после её завершения.' Yellow; return $false }
    try {
        Assert-BypassControlAllowed
        Add-BypassAction 'start' 'начало'
        $ok = Start-BypassCore -Quiet:$Quiet
        Add-BypassAction 'start' $(if ($ok) { 'запущен' } else { 'не запущен; проверьте последний сбой' })
        return $ok
    } catch {
        Add-BypassAction 'start' $_.Exception.Message
        Write-Color $_.Exception.Message Yellow
        return $false
    } finally { Exit-BypassControl }
}
function Stop-Bypass([switch]$Unload) {
    if (-not (Enter-BypassControl 'stop')) { throw 'Другая операция управляет обходом; остановка отменена.' }
    try {
        Assert-BypassControlAllowed
        Add-BypassAction 'stop' 'начало'
        $result = Stop-BypassCore -Unload:$Unload
        Add-BypassAction 'stop' 'завершено'
        return $result
    } catch {
        Add-BypassAction 'stop' $_.Exception.Message
        throw
    } finally { Exit-BypassControl }
}

function Stop-BypassCore([switch]$Unload) {
    $svc = Get-OurService
    $svcUp = $svc -and $svc.Status -ne 'Stopped'
    $since = Get-Date
    if ($svcUp) {
        Stop-Service -Name $Script:ServiceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
        # служба отчиталась об остановке - процесс завершается сам за доли секунды; добиваем только зависший
        for ($i = 0; $i -lt 15 -and @(Get-OurProcesses).Count; $i++) { Start-Sleep -Milliseconds 100 }
    }
    $crashed = $false
    foreach ($p in (Get-OurProcesses)) {
        if ($svc) { $svc.Refresh(); if ($svc.Status -ne 'Stopped') { $crashed = $true } }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    # ждём, пока процессы действительно завершатся (обычно сразу), а не фиксированные полсекунды
    for ($i = 0; $i -lt 30 -and @(Get-OurProcesses).Count; $i++) { Start-Sleep -Milliseconds 100 }
    # winws2 службы завершился, не сообщив Windows об остановке (упал или его добили) - для Windows это сбой, и через
    # 5 секунд она сама запустит службу снова (автоперезапуск при сбое). Автоподбор тогда упирался в "A copy of
    # winws2 is already running with the same filter". Дожидаемся перезапуска и останавливаем ещё раз
    if ($svcUp -and ($crashed -or @(Get-BypassCrashes $since).Count)) {
        for ($i = 0; $i -lt 70; $i++) {
            Start-Sleep -Milliseconds 100
            $svc.Refresh()
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $Script:ServiceName -Force -ErrorAction SilentlyContinue
                try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } catch { }
                foreach ($p in (Get-OurProcesses)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
                break
            }
        }
    }
    # Ошибка остановки не разрешает выгрузку драйвера или запуск второго экземпляра.
    $remaining = @(Get-OurProcesses)
    if ($svc) { $svc.Refresh() }
    if ($remaining.Count -or ($svc -and $svc.Status -ne 'Stopped')) {
        throw 'Предыдущий обход не удалось остановить. Новый экземпляр не запущен; проверьте права и журнал Windows.'
    }
    if ($Unload) { return (Remove-WinDivertDriver) }
}

# Когда служба обхода неожиданно завершалась после $Since, от ранних к поздним (журнал Windows, события 7031 и 7034).
# Записи нет - Get-WinEvent бросает исключение. Причину журнал не называет: winws2 в роли службы ничего не пишет
function Get-BypassCrashes([datetime]$Since) {
    $ev = @()
    try { $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034; StartTime = $Since } -ErrorAction Stop) } catch { }
    return @($ev | Where-Object { $_.Message -and ($_.Message.Contains($Script:ServiceDisplayName) -or $_.Message.Contains($Script:ServiceName)) } |
        ForEach-Object { $_.TimeCreated } | Sort-Object)
}
function Format-BypassCrashes($Times) { return (@($Times | ForEach-Object { $_.ToString('dd.MM HH:mm') }) -join ', ') }
$Script:CrashDays = 7   # за сколько дней проверка обходов и отчёт показывают падения

# winws2 (cygwin) изредка падает сразу после старта, а с ошибкой WinDivert выходит за доли секунды. Запуск удачный,
# когда процесс проработал $AliveMs подряд; раньше ждали фиксированные 3 секунды при каждом запуске.
function Wait-BypassAlive([int]$TimeoutMs = 4000, [int]$AliveMs = 1200) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $since = -1
    $identity = ''
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $processes = @(Get-OurProcesses)
        if ($processes.Count -eq 1) {
            $next = [string]$processes[0].Id
            if ($identity -ne $next) { $identity = $next; $since = $sw.ElapsedMilliseconds }
            elseif ($sw.ElapsedMilliseconds - $since -ge $AliveMs) { return $true }
        } else { $identity = ''; $since = -1 }
        Start-Sleep -Milliseconds 150
    }
    return $false
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
# $CmdLine - уже собранная командная строка запуска (Start-Bypass): к ней только добавляется --dry-run,
# а не собирается заново
function Test-ConfigDry([hashtable]$Settings, [string]$Alt, [switch]$NoAuto, [string]$IpsetMode, [string]$CmdLine) {
    if ($CmdLine) { $cmd = (ConvertTo-WinArg '--dry-run') + ' ' + $CmdLine }
    else {
        try { $cmd = Get-BypassCmdLine -Settings $Settings -Name 'check' -Alt $Alt -NoAuto:$NoAuto -IpsetMode $IpsetMode -DryRun }
        catch { return New-Object PSObject -Property @{ Ok = $false; Output = $_.Exception.Message } }
    }
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
function Start-BypassCore([switch]$Quiet) {
    Set-RingNetworkContext (Get-NetworkObservation)
    # обход снова включают - уведомление "обход не работает" опять имеет смысл (см. пункт 2 меню)
    Remove-Item (Get-PkgPath $Script:ManualStopFile) -Force -ErrorAction SilentlyContinue
    $bad = @(Test-PackageIntegrity)
    if ($bad.Count) { Write-IntegrityError $bad; return $false }
    $settings = Get-Settings
    Update-RuntimeLists | Out-Null
    try { $cmd = Get-BypassCmdLine -Settings $settings }
    catch { Write-Color $_.Exception.Message Red; return $false }
    $dry = Test-ConfigDry $settings -CmdLine $cmd
    if (-not $dry.Ok) {
        Write-Color 'winws2 отклонил параметры:' Red
        Write-Host $dry.Output
        return $false
    }

    Assert-BypassControlAllowed
    Stop-Bypass
    Repair-WinDivertService
    Enable-TcpTimestamps

    $svc = Get-OurService
    $since = Get-Date
    $err = ''
    if ($svc) {
        # параметры службы живут в её командной строке: обновляем под текущие настройки
        Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Script:ServiceName) -Name ImagePath -Value (Get-ServiceBinPath $cmd)
        $err = Start-OurService
    } else {
        # без окна: ошибки запуска видны через Инструменты -> 5 (диагностика)
        Assert-BypassControlAllowed
        Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden | Out-Null
    }
    $alive = Wait-BypassAlive
    if (-not $alive -and -not $svc -and @(Get-OurProcesses).Count -eq 0) {
        # winws2 (cygwin) изредка падает при старте без причины - ещё одна попытка (у службы есть свой перезапуск)
        Assert-BypassControlAllowed
        Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden | Out-Null
        $alive = Wait-BypassAlive
    }
    if (-not $alive) {
        Write-Color $(if ($svc) { 'Не удалось подтвердить стабильную работу службы обхода.' } else { 'Не удалось подтвердить стабильный запуск winws2.' }) Red
        $alive = Show-StartFailure $err $since
    }
    if ($alive) {
        if (-not (Start-NetworkWatcher)) { Add-BypassAction 'network-watch' 'Не запущен; память остаётся только в RAM до свежего heartbeat.' }
        Remove-Item (Join-Path $Script:Runtime 'start-error.txt') -Force -ErrorAction SilentlyContinue
        Set-HighPriority
        Remove-OldRingMemory
        # адреса серверов игр - уже через обход, как их увидит игра
        $gp = if ($settings.gamepins -eq 'on') { Update-GamePins } else { $null }
        if (-not $Quiet) {
            if ($gp) { Write-Color ('Серверы игр в hosts: ' + (Get-GamePinsText $gp)) Gray }
            Write-Color ('Обход запущен: ' + (Get-AltText $settings)) Green
            foreach ($x in @(Get-RingsText $settings)) { Write-Color ('  свой круг - ' + $x) Gray }
            Write-Color ('Game Filter: ' + (Get-GameText $settings) + '. IPSet: ' + $settings.ipset) Gray
            foreach ($warning in @(Get-ProxyWarnings)) { Write-Color ('Прокси/VPN: ' + $warning) Yellow }
            foreach ($b in @(Get-GameBoosters)) { Write-Color ('Запущен игровой ускоритель ' + $b + ': он ' + $Script:BoosterHint + '.') Yellow }
            if (@(Get-RunningGames).Count -eq 0) {
                Update-ServiceHealth | Out-Null
                $health = Get-ServiceHealthSummary @(Get-OurProcesses)
                Write-Color $health.Text $(if ($health.State -eq 'Partial') { 'Yellow' } else { 'Gray' })
            }
        }
    }
    return $alive
}

# Start-Service, но вместо исключения - текст ошибки Windows ('' - служба запустилась)
function Start-OurService {
    try { Assert-BypassControlAllowed; Start-Service -Name $Script:ServiceName -ErrorAction Stop; return '' }
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
    # FWP_E_IN_USE (0x8032000A): у Windows остались фильтры прошлого запуска. Было при перезапуске обхода посреди игры с античитом
    if ($Text -match '(?i)referenced by other objects|0x8032000A|ссылаются другие объекты') {
        $games = @(Get-RunningGames)
        $msg = 'Драйвер WinDivert не смог поставить фильтры: сетевой объект занят (0x8032000A). Причина удержания по этому коду не определяется.'
        if ($games.Count) { $msg += ' Так бывает, если перезапускать обход при открытой игре с античитом, а сейчас открыто: ' + ($games -join ', ') + '. Закройте игру, запустите обход (пункт 1), потом игру. Не поможет - перезагрузите ПК.' }
        else { $msg += ' Перезагрузите ПК и запускайте обход до игры.' }
        $h += $msg
    }
    return $h
}

# Почему обход не запустился. Сначала то, что видно сразу: ошибка Windows при запуске службы, код, с которым служба
# завершилась, и записи журнала "Система". Затем winws2 запускается обычным процессом на 5 секунд с выводом в меню:
# если он падает и так, его последние строки и есть причина; если работает - сбой только у службы, и обход остаётся
# работать без неё. Всё это пишется в runtime\start-error.txt и попадает в отчёт (Инструменты -> 4).
# -RemoveService - служба только что поставлена и не запустилась: она удаляется, а не остаётся сбоить при каждом старте.
# Возвращает $true, если обход в итоге запущен без службы.
function Show-StartFailure([string]$StartError, [datetime]$Since, [switch]$RemoveService) {
    if (-not (Enter-BypassControl 'Show-StartFailure')) { throw 'Другая операция управляет обходом; действие отложено.' }
    try {
        Assert-BypassControlAllowed

    $lines = New-Object System.Collections.Generic.List[string]
    if ($StartError) { $lines.Add('Windows: ' + $StartError) }
    $svc = $null
    try { $svc = Get-CimInstance Win32_Service -Filter ("Name='" + $Script:ServiceName + "'") -ErrorAction Stop } catch { }
    # 1077 - службу с загрузки ещё не запускали. Коды WFP (0x8032....) больше Int32: в Win32Exception - как отрицательное число
    $ec = if ($svc) { [int64]$svc.ExitCode } else { 0 }
    if ($svc -and @(0, 1077) -notcontains $ec) {
        $code = if ($ec -eq 1066) { 'winws2 вернул код ' + $svc.ServiceSpecificExitCode }
        else {
            $num = if ($ec -gt 0xFFFF) { '0x{0:X8}' -f $ec } else { [string]$ec }
            '{0} - {1}' -f $num, (New-Object System.ComponentModel.Win32Exception([BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$ec), 0))).Message
        }
        $lines.Add('служба завершилась: ' + $code)
    }
    foreach ($e in @(Get-ServiceEvents $Since)) { $lines.Add('журнал Windows: ' + $e) }

    # пока winws2 проверяется отдельно, Windows не должна перезапустить службу: у неё автоперезапуск при сбое
    Stop-Bypass
    if ($svc) {
        if ($RemoveService) { & sc.exe delete $Script:ServiceName | Out-Null }
        else { & sc.exe config $Script:ServiceName start= disabled | Out-Null }
    }
    $restoreMode = if ($svc) { switch ($svc.StartMode) { 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { 'auto' } } } else { '' }
    try {
        $cmd = Get-BypassCmdLine -Settings (Get-Settings)
        $kind = Get-StartFailureKind ($lines -join "`n")
        if ($kind -eq 'Unknown') { Assert-BypassControlAllowed; $r = Invoke-Native $Script:Exe $cmd $Script:Bin 5 }
        else { $r = $null }
    } finally {
        if ($svc -and -not $RemoveService) { & sc.exe config $Script:ServiceName start= $restoreMode | Out-Null }
    }
    $fallback = $false
    if ($kind -ne 'Unknown') {
        $lines.Add('Отдельный запуск без службы не выполнялся: ошибка уже определена (' + $kind + ').')
    } elseif ($r.TimedOut) {
        $lines.Add('winws2 без службы запускается и работает: сбой только у службы Windows')
        Assert-BypassControlAllowed
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

    } finally { Exit-BypassControl }
}

function Get-AltText([hashtable]$Settings) {
    $st = Get-Strategy $Settings.alt
    $name = if ($st) { $st.Name } else { 'ALT' + $Settings.alt + ' (нет файла!)' }
    if ($Settings.auto -eq 'on') {
        $resultContext = Get-TestResultContext $Settings
        $ring = @(Get-RotationOrder $Settings.alt 'general' $resultContext | ForEach-Object { $_.Name })
        $rank = Get-TestRank $resultContext
        $how = if ($rank) { ' (по автоподбору от ' + $rank.Date + ')' } else { '' }
        if ($ring.Count -ge 2) { return ($name + ', круг для сайтов: ' + ($ring -join ' > ') + $how) }
        if ($rank) { return ($name + ', для сайтов других сильных стратегий нет' + $how) }
    }
    return ($name + ', без автосмены')
}

function Install-BypassService {
    if (-not (Enter-BypassControl 'Install-BypassService')) { throw 'Другая операция управляет обходом; действие отложено.' }
    try {
        Assert-BypassControlAllowed

    Remove-Item (Get-PkgPath $Script:ManualStopFile) -Force -ErrorAction SilentlyContinue
    $bad = @(Test-PackageIntegrity)
    if ($bad.Count) { Write-IntegrityError $bad; return $false }
    $settings = Get-Settings
    Update-RuntimeLists | Out-Null
    try { $cmd = Get-BypassCmdLine -Settings $settings }
    catch { Write-Color $_.Exception.Message Red; return $false }
    $dry = Test-ConfigDry $settings -CmdLine $cmd
    if (-not $dry.Ok) { Write-Color 'winws2 отклонил параметры:' Red; Write-Host $dry.Output; return $false }

    Stop-Bypass
    if (Get-OurService) { & sc.exe delete $Script:ServiceName | Out-Null; Start-Sleep -Seconds 1 }
    Enable-TcpTimestamps
    $binPath = Get-ServiceBinPath $cmd
    $since = Get-Date
    New-Service -Name $Script:ServiceName -BinaryPathName $binPath -DisplayName $Script:ServiceDisplayName `
        -Description 'Обход DPI для NBA 2K27, Discord и YouTube (zapret2 / winws2)' -StartupType Automatic | Out-Null
    & sc.exe failure $Script:ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
    $err = Start-OurService
    if (Wait-BypassAlive) {
        Set-HighPriority
        if (-not (Install-NetworkWatchTask)) { Write-Color 'Наблюдатель сети не добавлен в автозапуск; до свежего heartbeat память будет только в RAM.' Yellow }
        Start-NetworkWatcher | Out-Null
        return $true
    }
    Write-Color 'Служба не запустилась и удалена.' Red
    Show-StartFailure $err $since -RemoveService | Out-Null
    return $false

    } finally { Exit-BypassControl }
}

# Сборка называлась NBA2K27-zapret2: служба и задача автонастройки прежних версий переносятся под новые имена
# при запуске меню (нужны права администратора). Новое имя службы не "zapret": так зовётся служба Flowseal.
$Script:LegacyServiceName = 'nba2k27-zapret2'
$Script:LegacyAutotuneTask = 'NBA2K27-zapret2 autotune'

function Update-LegacyNames {
    $old = Get-Service -Name $Script:LegacyServiceName -ErrorAction SilentlyContinue
    $oldTask = $null
    if ((Test-TaskExists $Script:LegacyAutotuneTask) -ne $false) {
        try { $oldTask = Get-ScheduledTask -TaskName $Script:LegacyAutotuneTask -ErrorAction Stop } catch { }
    }
    if (-not $old -and -not $oldTask) { return }
    if (@(Get-RunningGames).Count) { Write-Color 'Перенос прежней службы отложен до закрытия игры.' Yellow; return }
    if (-not (Enter-BypassControl 'Update-LegacyNames')) { Write-Color 'Перенос прежней службы отложен: другая операция управляет обходом.' Yellow; return }
    try {
        Assert-BypassControlAllowed

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
    if ($oldTask) {
        try { Unregister-ScheduledTask -TaskName $Script:LegacyAutotuneTask -Confirm:$false -ErrorAction Stop } catch { }
        if (-not (Get-AutotuneTask)) {
            if (Install-AutotuneTask) { Write-Color 'Автонастройка перенесена под новое имя задачи.' Green }
            else { Write-Color 'Автонастройку перенести не вышло - включите заново: Настройки -> 7.' Yellow }
        }
    }

    } catch { Write-Color $_.Exception.Message Yellow } finally { Exit-BypassControl }
}

function Remove-BypassService {
    if (-not (Enter-BypassControl 'Remove-BypassService')) { throw 'Другая операция управляет обходом; действие отложено.' }
    try {
        Assert-BypassControlAllowed

    Stop-Bypass
    if (Get-OurService) { & sc.exe delete $Script:ServiceName | Out-Null }
    Remove-NetworkWatchTask
    Remove-WinDivertDriver | Out-Null

    } finally { Exit-BypassControl }
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

# Текущее состояние Windows, а не оставшиеся ProxyServer/AutoConfigURL в реестре.
# API только читает настройки; PAC не загружается и не исполняется.
function Get-WindowsProxySettings {
    try {
        if (-not ('ZapretProxy.Reader' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ZapretProxy {
    public static class Reader {
        [StructLayout(LayoutKind.Sequential)]
        private struct Config {
            [MarshalAs(UnmanagedType.Bool)] public bool AutoDetect;
            public IntPtr Pac, Proxy, Bypass;
        }
        [DllImport("winhttp.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WinHttpGetIEProxyConfigForCurrentUser(out Config config);
        [DllImport("kernel32.dll")] private static extern IntPtr GlobalFree(IntPtr value);
        public static string[] Read() {
            Config c = new Config();
            try {
                if (!WinHttpGetIEProxyConfigForCurrentUser(out c)) return null;
                return new string[] { c.AutoDetect ? "1" : "0",
                    Marshal.PtrToStringUni(c.Pac) ?? "", Marshal.PtrToStringUni(c.Proxy) ?? "" };
            } finally {
                if (c.Pac != IntPtr.Zero) GlobalFree(c.Pac);
                if (c.Proxy != IntPtr.Zero) GlobalFree(c.Proxy);
                if (c.Bypass != IntPtr.Zero) GlobalFree(c.Bypass);
            }
        }
    }
}
'@ -ErrorAction Stop
        }
        $values = [ZapretProxy.Reader]::Read()
        if ($null -ne $values) {
            return [pscustomobject]@{ Known = $true; AutoDetect = ($values[0] -eq '1'); Pac = $values[1]; Proxy = $values[2] }
        }
    } catch { }
    return [pscustomobject]@{ Known = $false; AutoDetect = $false; Pac = ''; Proxy = '' }
}

function Get-ProxyListeners {
    try { return ,@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) }
    catch { return $null }
}

function Get-ProxyEnvironment {
    foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        if ([Environment]::GetEnvironmentVariable($v)) { $v }
    }
}

# Только loopback-адреса: не делаем сетевых запросов к удалённым прокси и не выводим пароли/URL.
function Get-ProxyLoopbackEndpoints([string]$Proxy) {
    foreach ($entry in @($Proxy -split '[;\s]+')) {
        $address = $entry -replace '^\w+=', ''
        if ($address -notmatch '^\w+://') { $address = 'http://' + $address }
        $uri = $null
        if (-not [uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri)) { continue }
        $hostName = $uri.DnsSafeHost.Trim('[', ']')
        $ip = $null
        if ($hostName -eq 'localhost' -or ([Net.IPAddress]::TryParse($hostName, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))) {
            if ($uri.Port -gt 0) { [pscustomobject]@{ Host = $hostName; Port = $uri.Port } }
        }
    }
}

# Подтверждение отсутствующего в таблице порта: только loopback, без HTTP/SOCKS-запроса и DNS.
function Get-ProxyEndpointState($Endpoint) {
    $addresses = @()
    if ($Endpoint.Host -eq 'localhost') { $addresses = @([Net.IPAddress]::Loopback, [Net.IPAddress]::IPv6Loopback) }
    else {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($Endpoint.Host, [ref]$ip) -or -not [Net.IPAddress]::IsLoopback($ip)) { return 'Unknown' }
        $addresses = @($ip)
    }
    $unknown = $false
    foreach ($address in $addresses) {
        $client = $null
        try {
            $client = New-Object Net.Sockets.TcpClient($address.AddressFamily)
            $task = $client.ConnectAsync($address, $Endpoint.Port)
            if ($task.Wait(200) -and $client.Connected) { return 'Open' }
            $unknown = $true
        } catch {
            $errorCause = $_.Exception.GetBaseException()
            if ($errorCause -isnot [Net.Sockets.SocketException] -or $errorCause.SocketErrorCode -ne [Net.Sockets.SocketError]::ConnectionRefused) { $unknown = $true }
        } finally { if ($client) { $client.Dispose() } }
    }
    if ($unknown) { return 'Unknown' }
    return 'Closed'
}

# Общий снимок локального порта для предупреждений, Telegram и проверки застрявших приложений.
# Unknown сохраняется отдельно: отсутствие доказательства доступности не означает закрытый порт.
function Get-LoopbackPortObservation($Endpoint, $Listeners = $null) {
    if (-not $PSBoundParameters.ContainsKey('Listeners')) { $Listeners = Get-ProxyListeners }
    $found = @($Listeners | Where-Object { $null -ne $_ } | Where-Object {
        if ($_.Port -ne $Endpoint.Port) { return $false }
        $ip = $_.Address
        if ($Endpoint.Host -eq 'localhost') { return ([Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any)) }
        $expected = $null
        if (-not [Net.IPAddress]::TryParse($Endpoint.Host, [ref]$expected) -or -not [Net.IPAddress]::IsLoopback($expected)) { return $false }
        return ($ip.Equals($expected) -or ($ip.AddressFamily -eq $expected.AddressFamily -and ($ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any))))
    }).Count -gt 0
    $state = if ($found) { 'Open' } else { Get-ProxyEndpointState $Endpoint }
    return [pscustomobject]@{ State=$state; Host=$Endpoint.Host; Port=$Endpoint.Port; ObservedUtc=[datetime]::UtcNow.ToString('o'); Evidence=$(if($found){'ListenerTable'}else{'LoopbackConnect'}) }
}

# Процесс клиента, настройки прокси и маршруты TUN — отдельные наблюдения, а не доказательство пути каждой игры.
function Get-ProxyWarnings {
    $w = @()
    $settings = Get-WindowsProxySettings
    if (-not $settings.Known) { $w += 'не удалось прочитать текущие настройки прокси Windows' }
    if ($settings.Proxy) {
        $w += 'системный прокси Windows включён; используется приложениями, которые учитывают эту настройку'
        $endpoints = @(Get-ProxyLoopbackEndpoints $settings.Proxy)
        if ($endpoints.Count) {
            $listeners = Get-ProxyListeners
                foreach ($endpoint in $endpoints) {
                    $observation = Get-LoopbackPortObservation $endpoint -Listeners $listeners
                    $state = switch ($observation.State) {
                        'Open' { 'слушает (доступность сервера не проверялась)' }
                        'Closed' { 'не слушает: локальное соединение отклонено; включённый прокси может мешать приложениям' }
                        default { 'не удалось проверить локальный порт прокси' }
                    }
                    $w += ('локальный прокси {0}:{1} — {2}' -f $endpoint.Host, $endpoint.Port, $state)
                }
        }
    }
    if ($settings.Pac) { $w += 'PAC-скрипт Windows включён; использование прокси зависит от правил скрипта и приложения' }
    if ($settings.AutoDetect) { $w += 'автоопределение прокси Windows включено; наличие прокси не подтверждено' }
    foreach ($v in @(Get-ProxyEnvironment)) { $w += "задана переменная $v; её используют только поддерживающие прокси приложения" }
    foreach ($a in @(Get-TunAdapters)) { $w += "VPN/TUN-адаптер с маршрутами (или маршруты недоступны): $($a.Name); путь конкретной игры зависит от маршрутизации" }
    foreach ($p in @(Get-Process -Name $Script:ProxyProcessNames -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)) {
        $w += "запущен клиент $p; подключение по одному процессу не подтверждено"
    }
    return @($w | Select-Object -Unique)
}

function Get-TunAdapters {
    try {
        $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'Wintun|TAP-Windows|WireGuard|sing-box|Clash|Mihomo|Meta Tunnel|Hiddify|Happ|AmneziaWG|OpenVPN|Xray' -or $_.Name -match '(^|[-_ ])(tun|wg)(\d|[-_ ]|$)') })
        if (-not $adapters.Count) { return @() }
        # Ошибка чтения маршрутов не должна разрешать опасный автоподбор под возможным TUN.
        try { $routes = @(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop) } catch { return $adapters }
        return @($adapters | Where-Object {
            $index = $_.ifIndex
            @($routes | Where-Object { $_.InterfaceIndex -eq $index -and $_.DestinationPrefix -notmatch '^(fe[89ab]|ff|127\.|169\.254\.|224\.|255\.|::1/)' }).Count -gt 0
        })
    } catch { return @() }
}

# ---------- программы и службы, которые мешают обходу (как в диагностике Flowseal) ----------
# Проверяем только работающие службы и процессы. Key - для исправления (bfe), Text - что найдено и чем мешает.
$Script:ConflictsCache = $null
function New-Conflict([string]$Key, [string]$Text) { return New-Object PSObject -Property @{ Key = $Key; Text = $Text } }

# -Cached - для шапки меню (раз в минуту); проверка обходов смотрит сразу, чтобы исправленное не мерещилось
function Get-SystemConflicts([switch]$Cached) {
    if ($Cached -and $Script:ConflictsCache -and ((Get-Date) - $Script:ConflictsCache.Time).TotalSeconds -lt 60) { return $Script:ConflictsCache.Items }
    $found = @()
    $bfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
    if (-not $bfe -or $bfe.Status -ne 'Running') { $found += New-Conflict 'bfe' 'не работает служба Base Filtering Engine (BFE): без неё WinDivert не запустится' }
    $svc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    $has = { param($re) @($svc | Where-Object { $_.Name -match $re -or $_.DisplayName -match $re }).Count -gt 0 }
    if (@(Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue).Count) { $found += New-Conflict 'adguard' 'AdGuard: известно, что мешает Discord. Выключите в нём фильтрацию Discord или закройте его' }
    if (& $has 'Killer') { $found += New-Conflict 'killer' 'службы Killer (сетевая программа на ноутбуках Dell, MSI и др.): конфликтуют с обходом - удалите Killer Control Center или выключите его службы' }
    if (& $has 'Intel.*Connectivity.*Network') { $found += New-Conflict 'intel' 'Intel Connectivity Network Service: конфликтует с обходом - выключите её в services.msc' }
    if (& $has 'TracSrvWrapper|EPWD') { $found += New-Conflict 'checkpoint' 'Check Point (VPN или защита): конфликтует с обходом - удалите его' }
    if (& $has 'SmartByte') { $found += New-Conflict 'smartbyte' 'SmartByte (Dell): конфликтует с обходом - выключите его службу в services.msc' }
    if ($env:OneDrive -and $Script:Root.StartsWith($env:OneDrive.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $found += New-Conflict 'onedrive' 'папка сборки лежит в OneDrive: синхронизация мешает файлам обхода - перенесите её, например в C:\zapret'
    }
    $Script:ConflictsCache = New-Object PSObject -Property @{ Time = Get-Date; Items = $found }
    return $found
}

# Российские корневые сертификаты (Минцифры, "Russian Trusted Root CA" и выпущенные ими): их просят поставить для
# госсайтов, а с ними в системе HTTPS-соединения можно подменять незаметно. Сборка их не ставит - только предупреждает.
function Get-RussianRootCerts {
    $res = @()
    foreach ($store in 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\CA', 'Cert:\CurrentUser\Root', 'Cert:\CurrentUser\CA') {
        foreach ($c in @(Get-ChildItem $store -ErrorAction SilentlyContinue)) {
            if (($c.Subject + ' ' + $c.Issuer) -match '(?i)Russian Trusted|Минцифр|Mincifr|Ministry of Digital Development') {
                $res += New-Object PSObject -Property @{ Store = $store; Subject = $c.Subject; Thumbprint = $c.Thumbprint }
            }
        }
    }
    return $res
}

function Repair-Bfe {
    try { Set-Service -Name 'BFE' -StartupType Automatic -ErrorAction Stop; Start-Service -Name 'BFE' -ErrorAction Stop } catch { return $false }
    $Script:ConflictsCache = $null
    return $true
}

# ---------- кэш Discord ----------
# Как у Flowseal: Discord закрывается, удаляются только папки кэша (вход, настройки и сообщения остаются). Помогает,
# когда Discord не запускается, висит на загрузке или на обновлении.
$Script:DiscordBuilds = [ordered]@{ 'Discord' = 'discord'; 'DiscordPTB' = 'discordptb'; 'DiscordCanary' = 'discordcanary'; 'DiscordDevelopment' = 'discorddevelopment' }

function Clear-DiscordCache {
    $res = @()
    foreach ($proc in $Script:DiscordBuilds.Keys) {
        $dir = Join-Path $env:APPDATA $Script:DiscordBuilds[$proc]
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $was = @(Get-Process -Name $proc -ErrorAction SilentlyContinue).Count -gt 0
        Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue
        if ($was) { Start-Sleep -Seconds 1 }
        $cleared = 0; $failed = @()
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
            $p = Join-Path $dir $sub
            if (-not (Test-Path -LiteralPath $p)) { continue }
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; $cleared++ } catch { $failed += $sub }
        }
        $res += New-Object PSObject -Property @{ Name = $proc; Cleared = $cleared; Failed = $failed; WasRunning = $was }
    }
    return $res
}

# ---------- Telegram: встроенный мост (tools\tgbridge.cs) ----------
# Обход сам Telegram не лечит: у нас режут адреса его дата-центров. Мост - перенос основной логики tg-ws-proxy от Flowseal
# (MIT): Telegram Desktop подключается к нему как к MTProto-прокси 127.0.0.1:1443, а мост гонит трафик через WebSocket
# веб-версии Telegram, которую не режут. Ничего не скачивается: C# из tools\tgbridge.cs компилирует сама Windows.
# Мост работает задачей "zapret telegram" от имени пользователя, без окна: с входа в Windows, а если упал или его
# закрыли - Windows запускает его снова (задача повторяется раз в 5 минут; второй экземпляр не запускается).
$Script:TgTask = 'zapret telegram'
$Script:TgConfigFile = 'runtime/telegram.txt'
$Script:TgPidFile = 'runtime/tgbridge.pid'
# папка tg-ws-proxy от Flowseal, который ставила zapret 1.2: из неё берём secret, потом удаляем
$Script:TgDir = 'runtime/tg-ws-proxy'
$Script:TgRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# Порт и secret моста (runtime\telegram.txt). Первый раз - из настроек tg-ws-proxy, если он стоял: тогда Telegram,
# уже настроенный на него, перенастраивать не нужно. Иначе - порт 1443 и новый случайный secret.
# $File и $Import - для проверок (dev\tests): чужие пути вместо runtime и настроек tg-ws-proxy
function Get-TgConfig([string]$File = '', [string[]]$Import = @()) {
    $f = if ($File) { $File } else { Get-PkgPath $Script:TgConfigFile }
    if (-not $Import.Count) { $Import = @((Join-Path (Get-PkgPath $Script:TgDir) 'TgWsProxy_data\config.json'), (Join-Path $env:APPDATA 'TgWsProxy\config.json')) }
    $port = 0; $secret = ''
    if (Test-Path $f) {
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            if ($l -match '^port=(\d+)$') { $port = [int]$matches[1] } elseif ($l -match '^secret=([0-9a-f]{32})$') { $secret = $matches[1] }
        }
    }
    if ($port -and $secret) { return New-Object PSObject -Property @{ Port = $port; Secret = $secret } }
    foreach ($cfg in $Import) {
        if ($secret -or -not (Test-Path -LiteralPath $cfg)) { continue }
        try {
            $j = [System.IO.File]::ReadAllText($cfg) | ConvertFrom-Json
            $names = @($j.PSObject.Properties.Name)
            if ($names -contains 'secret' -and ('' + $j.secret) -match '^[0-9a-fA-F]{32}$') { $secret = ('' + $j.secret).ToLower() }
            if ($secret -and $names -contains 'port' -and ('' + $j.port) -match '^\d+$') { $port = [int]$j.port }
        } catch { }
    }
    if (-not $secret) {
        $b = New-Object byte[] 16
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
        $secret = -join @($b | ForEach-Object { '{0:x2}' -f $_ })
    }
    if (-not $port) { $port = 1443 }
    Write-TextNoBom $f ("port=$port`r`nsecret=$secret`r`n")
    return New-Object PSObject -Property @{ Port = $port; Secret = $secret }
}

# Ссылка, по которой Telegram Desktop сам добавляет прокси ("dd" - протокол со случайной длиной пакетов)
function Get-TgLink {
    $c = Get-TgConfig
    return ('tg://proxy?server=127.0.0.1&port={0}&secret=dd{1}' -f $c.Port, $c.Secret)
}

# Процесс моста - по PID и времени запуска из runtime\tgbridge.pid (PID мог достаться другому процессу)
function Get-TgBridgeProcess {
    $f = Get-PkgPath $Script:TgPidFile
    if (-not (Test-Path $f)) { return $null }
    $x = @([System.IO.File]::ReadAllText($f).Trim() -split '\|')
    if ($x.Count -ne 2 -or $x[0] -notmatch '^\d+$' -or $x[1] -notmatch '^\d+$') { return $null }
    $p = Get-Process -Id ([int]$x[0]) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { if ($p.StartTime.Ticks -ne [long]$x[1]) { return $null } } catch { return $null }
    return $p
}

function Get-TgBridgeState {
    if (-not (Get-TgBridgeProcess)) { return 'Stopped' }
    return (Get-LoopbackPortObservation ([pscustomobject]@{Host='127.0.0.1';Port=(Get-TgConfig).Port})).State
}
function Test-TgBridgeRunning {
    return (Get-TgBridgeState) -eq 'Open'
}

# Чей процесс слушает порт на 127.0.0.1 (если порт моста занят чужой программой) - имя или ''
function Get-PortOwnerName([int]$Port) {
    foreach ($l in @(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p TCP 2>$null)) {
        if ($l -match ('^\s*TCP\s+(127\.0\.0\.1|0\.0\.0\.0):' + $Port + '\s+\S+\s+\S+\s+(\d+)\s*$')) {
            $p = Get-Process -Id ([int]$matches[2]) -ErrorAction SilentlyContinue
            if ($p) { return $p.ProcessName }
        }
    }
    return ''
}

function Get-TgTask {
    if ((Test-TaskExists $Script:TgTask) -eq $false) { return $null }
    try { return Get-ScheduledTask -TaskName $Script:TgTask -ErrorAction Stop } catch { return $null }
}

function Install-TgTask {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # conhost --headless: без окна PowerShell
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -WorkingDirectory $Script:Root `
        -Argument ('--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'tgbridge.ps1') + '"')
    $user = $env:USERDOMAIN + '\' + $env:USERNAME
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    # раз в 5 минут: если мост закрыли или он упал - запустится снова; пока работает, второй не запускается (IgnoreNew)
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    # от имени пользователя и без прав администратора: мосту они не нужны
    $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $Script:TgTask -Action $action -Trigger @($logon, $every) -Settings $set -Principal $pr -Force `
            -Description 'zapret: мост Telegram (127.0.0.1, MTProto через WebSocket веб-версии Telegram)' -ErrorAction Stop | Out-Null
    } catch { Write-Color $_.Exception.Message Red; return $false }
    return $true
}

# Запуск моста задачей - от имени пользователя, даже из меню с правами администратора. $true - мост слушает порт.
function Start-TgBridge {
    if (Test-TgBridgeRunning) { return $true }
    if (-not (Get-TgTask) -and -not (Install-TgTask)) { return $false }
    try { Start-ScheduledTask -TaskName $Script:TgTask -ErrorAction Stop } catch { }
    # первый запуск - компиляция C# (секунда-две)
    for ($i = 0; $i -lt 40 -and -not (Test-TgBridgeRunning); $i++) { Start-Sleep -Milliseconds 500 }
    return (Test-TgBridgeRunning)
}

function Stop-TgBridge {
    try { Stop-ScheduledTask -TaskName $Script:TgTask -ErrorAction Stop } catch { }
    $p = Get-TgBridgeProcess
    if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
}

# tg-ws-proxy от Flowseal больше не нужен: мост его заменяет и занимает тот же порт. Закрываем его, убираем
# его автозапуск и копию, которую ставила zapret 1.2 (runtime\tg-ws-proxy). Возвращает $true, если он был.
function Remove-FlowsealTg {
    $was = $false
    foreach ($p in @(Get-Process -Name 'TgWsProxy*' -ErrorAction SilentlyContinue)) { $was = $true; try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
    try {
        $run = Get-ItemProperty -Path $Script:TgRunKey -ErrorAction Stop
        if ($run.PSObject.Properties.Name -contains 'TgWsProxy') { $was = $true; Remove-ItemProperty -Path $Script:TgRunKey -Name 'TgWsProxy' -ErrorAction SilentlyContinue }
    } catch { }
    $d = Get-PkgPath $Script:TgDir
    if (Test-Path $d) { $was = $true; Start-Sleep -Milliseconds 500; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    return $was
}

# Включить или выключить мост Telegram. Возвращает $true, если всё получилось (при включении - мост слушает порт).
function Set-TelegramMode([bool]$On) {
    $s = Get-Settings
    if ($On) {
        # secret - пока настройки tg-ws-proxy ещё на месте
        Get-TgConfig | Out-Null
        if (Remove-FlowsealTg) { Write-Color 'tg-ws-proxy от Flowseal закрыт и убран из автозапуска: его заменяет встроенный мост (тот же порт и secret).' Gray }
        $s.telegram = 'on'
        Save-Settings $s
        if (-not (Install-TgTask)) { return $false }
        return (Start-TgBridge)
    }
    $s.telegram = 'off'
    Save-Settings $s
    Stop-TgBridge
    try { Unregister-ScheduledTask -TaskName $Script:TgTask -Confirm:$false -ErrorAction Stop } catch { }
    return $true
}

# Есть ли на ПК Telegram Desktop (тогда при первом запуске обхода предлагаем мост)
function Test-TelegramDesktop {
    return (@(Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue).Count -gt 0) -or (Test-Path (Join-Path $env:APPDATA 'Telegram Desktop'))
}

# Telegram настроен на прокси 127.0.0.1:<порт моста> (стучится в него), а там никто не слушает - Telegram без сети
function Test-TelegramWaitsForProxy {
    $port = (Get-TgConfig).Port
    if ((Get-LoopbackPortObservation ([pscustomobject]@{Host='127.0.0.1';Port=$port})).State -ne 'Closed') { return $false }
    $tg = @(Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if (-not $tg.Count) { return $false }
    return (@(Get-ProxyClientPids @($port) | Where-Object { $tg -contains $_ }).Count -gt 0)
}

# Уведомления включены? Пустое значение - настройки из 1.2, где их состояние хранила сама задача
function Test-NotifyEnabled($S) {
    if ($S.notify -eq 'on') { return $true }
    if ($S.notify -eq 'off') { return $false }
    return [bool](Get-NotifyTask)
}

# Ставит или убирает задачу уведомлений под настройку notify
function Sync-UserTask($S) {
    $need = Test-NotifyEnabled $S
    $task = Get-NotifyTask
    if ($need -and -not $task) { return (Install-NotifyTask) }
    if (-not $need -and $task) { Remove-NotifyTask }
    return $true
}

# ---------- программы, застрявшие на прокси ----------
# Steam и Discord запоминают системный прокси при запуске. Включили Happ, чтобы что-то открыть, выключили - а Steam так
# и шлёт веб-запросы на 127.0.0.1:10809, где уже никто не слушает. К своим серверам он при этом подключён (по UDP),
# поэтому выглядит "в сети", но в Доте нет цен на предметы и не работает "Играть". Лечится только перезапуском программы.
$Script:ProxyAppNames = [ordered]@{ 'Steam' = @('steam'); 'Discord' = @('Discord') }
$Script:ProxyAppsFile = 'runtime/proxy-apps.txt'
$Script:ProxyStuckCache = $null

# Локальные порты системного прокси - из настроек Windows, даже если прокси сейчас выключен
function Get-LocalProxyPorts {
    $srv = ''
    try {
        $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ($is.PSObject.Properties.Name -contains 'ProxyServer') { $srv = '' + $is.ProxyServer }
    } catch { }
    $ports = @(foreach ($m in [regex]::Matches($srv, '(?:127\.0\.0\.1|localhost|\[::1\]):(\d+)')) { [int]$m.Groups[1].Value })
    return @($ports | Select-Object -Unique)
}

# Совместимая bool-оболочка: положительный результат подтверждён; для вывода о закрытии нужен State=Closed.
function Test-PortListening([int]$Port) {
    return (Get-LoopbackPortObservation ([pscustomobject]@{Host='localhost';Port=$Port})).State -eq 'Open'
}

# PID программ с TCP-соединениями к 127.0.0.1:<порт прокси>. netstat в разы быстрее Get-NetTCPConnection; состояние
# соединения не разбираем (оно бывает переведено на язык Windows) - только адрес и PID в последнем столбце.
function Get-ProxyClientPids([int[]]$Ports) {
    if (-not $Ports.Count) { return @() }
    $ids = @()
    foreach ($l in @(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p TCP 2>$null)) {
        if ($l -match '^\s*TCP\s+\S+\s+127\.0\.0\.1:(\d+)\s+\S+\s+(\d+)\s*$' -and $Ports -contains [int]$matches[1]) { $ids += [int]$matches[2] }
    }
    return @($ids | Select-Object -Unique)
}

# Steam сам пишет в журнал подключений, через какой адрес ходит: "(127.0.0.1:10809, WebSocket)", проверка IPv6 через прокси.
# Смотрим только строки после запуска этого Steam. $LogPath и $Since - для проверок.
function Test-SteamProxyLog([int[]]$Ports, [string]$LogPath = '', [datetime]$Since = [datetime]::MinValue) {
    if (-not $Ports.Count) { return $false }
    if (-not $LogPath) {
        $steam = @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)
        if (-not $steam.Count) { return $false }
        try { $Since = $steam[0].StartTime } catch { return $false }
        try {
            $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
            if ($reg.PSObject.Properties.Name -contains 'SteamPath') { $LogPath = Join-Path $reg.SteamPath 'logs\connection_log.txt' }
        } catch { }
    }
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $false }
    $pattern = '127\.0\.0\.1:(' + ($Ports -join '|') + ')\b'
    foreach ($line in @(Get-Content -LiteralPath $LogPath -Tail 400 -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]') { continue }
        $t = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($t -ge $Since.AddSeconds(-5) -and $line -match $pattern) { return $true }
    }
    return $false
}

# Какие программы застряли на выключенном прокси. Пока прокси работает - запоминаем, кто ходит через него
# (runtime\proxy-apps.txt: программа, PID, время запуска). Когда прокси выключен - те же процессы, если ещё живы,
# и есть застрявшие; Steam ещё и сам пишет это в журнал. Возвращает имена программ (Steam, Discord).
# -Cached - для шапки меню (раз в 20 секунд); проверка обходов и уведомления смотрят сразу
function Get-ProxyStuckApps([switch]$Cached) {
    if ($Cached -and $Script:ProxyStuckCache -and ((Get-Date) - $Script:ProxyStuckCache.Time).TotalSeconds -lt 20) { return $Script:ProxyStuckCache.Apps }
    $stuck = @()
    $ports = @(Get-LocalProxyPorts)
    $file = Get-PkgPath $Script:ProxyAppsFile
    $known = @()
    if (Test-Path $file) {
        foreach ($l in [System.IO.File]::ReadAllLines($file)) {
            $f = $l -split '\|'
            if ($f.Count -ne 3 -or $f[1] -notmatch '^\d+$' -or $f[2] -notmatch '^\d+$') { continue }
            $p = Get-Process -Id ([int]$f[1]) -ErrorAction SilentlyContinue
            # PID могли отдать другому процессу - сверяем и время запуска
            $same = $false
            if ($p) { try { $same = ($p.StartTime.Ticks -eq [long]$f[2]) } catch { } }
            if ($same) { $known += New-Object PSObject -Property @{ App = $f[0]; Line = $l } }
        }
    }
    $observations = @($ports | ForEach-Object { Get-LoopbackPortObservation ([pscustomobject]@{Host='localhost';Port=$_}) })
    $alive = @($observations | Where-Object { $_.State -eq 'Open' } | ForEach-Object { $_.Port })
    if ($alive.Count) {
        $ids = @(Get-ProxyClientPids $alive)
        $lines = @($known | ForEach-Object { $_.Line })
        foreach ($app in $Script:ProxyAppNames.Keys) {
            foreach ($p in @(Get-Process -Name $Script:ProxyAppNames[$app] -ErrorAction SilentlyContinue)) {
                if ($ids -notcontains $p.Id) { continue }
                try { $line = '{0}|{1}|{2}' -f $app, $p.Id, $p.StartTime.Ticks } catch { continue }
                if ($lines -notcontains $line) { $lines += $line }
            }
        }
        if ($lines.Count -or (Test-Path $file)) { Write-TextNoBom $file (($lines -join "`r`n") + "`r`n") }
    } elseif ($ports.Count -and @($observations | Where-Object { $_.State -ne 'Closed' }).Count -eq 0) {
        $stuck = @($known | ForEach-Object { $_.App } | Select-Object -Unique)
        if ($stuck -notcontains 'Steam' -and (Test-SteamProxyLog $ports)) { $stuck += 'Steam' }
    }
    $Script:ProxyStuckCache = New-Object PSObject -Property @{ Time = Get-Date; Apps = $stuck }
    return $stuck
}

# Кто сейчас ходит через работающий локальный прокси (для проверки обходов: "если выключите прокси - перезапустите")
function Get-ProxyAppsNow {
    $alive = @(Get-LocalProxyPorts | Where-Object { Test-PortListening $_ })
    if (-not $alive.Count) { return @() }
    $ids = @(Get-ProxyClientPids $alive)
    return @($Script:ProxyAppNames.Keys | Where-Object { @(Get-Process -Name $Script:ProxyAppNames[$_] -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.Id }).Count })
}

# ---------- правила "напрямую" для прокси-клиентов ----------
# Steam, Discord и игры лучше пускать мимо прокси (Happ, v2rayN...): обход обрабатывает их сам, а через прокси Steam
# получает обрывы (в Доте нет цен, не работает "Играть"), Discord - голос мимо прокси. steamcommunity.com сюда
# не входит: он заблокирован, обход его не трогает (так у Flowseal), и без прокси он не откроется.
$Script:DirectDomains = [ordered]@{
    'Steam и Dota 2' = @('steampowered.com', 'steamserver.net', 'steamstatic.com', 'steamcontent.com', 'steam-chat.com', 'valvesoftware.com', 'dota2.com')
    'Discord'        = @('discord.com', 'discord.gg', 'discordapp.com', 'discordapp.net', 'discord.media', 'discordcdn.com')
    'NBA 2K и EAC'   = @('2k.com', 'take2games.com', 'easyanticheat.net')
}

# Текст правил: домены (как есть и в виде domain: для xray/Happ) и сети серверов игр (для режима TUN)
function Get-DirectRulesText {
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('# zapret ' + $Script:Version + ': что пускать мимо прокси (правила "напрямую" / direct). Обход обрабатывает это сам.')
    $t.Add('# Happ и другие клиенты на xray: вставьте строки из блока "domain:" в прямые домены, сети - в прямые IP.')
    $t.Add('')
    $t.Add('# --- домены, для xray / Happ ---')
    foreach ($g in $Script:DirectDomains.Keys) { $t.Add('# ' + $g); foreach ($d in $Script:DirectDomains[$g]) { $t.Add('domain:' + $d) } }
    $t.Add('')
    $t.Add('# --- те же домены без приставки (для клиентов, которые её не понимают) ---')
    foreach ($g in $Script:DirectDomains.Keys) { foreach ($d in $Script:DirectDomains[$g]) { $t.Add($d) } }
    $t.Add('')
    $t.Add('# --- сети серверов игр: Valve и Take-Two (нужны, если прокси в режиме TUN) ---')
    foreach ($n in @(Get-ListLines (Join-Path $Script:Lists 'ipset-taketwo.txt')) + @($Script:ValveNets)) { $t.Add($n) }
    return @($t)
}

# ---------- уведомления Windows ----------
# Задача "zapret notify" раз в 5 минут от имени пользователя запускает tools\notify.ps1: он показывает уведомление,
# если служба обхода не работает, Steam или Discord застряли на выключенном прокси, вышла новая версия zapret
# или автонастройка что-то сделала. Об одном и том же - один раз (runtime\notify-state.txt).
$Script:NotifyTask = 'zapret notify'
# обход остановлен пунктом 2 - это не сбой, уведомлять не нужно
$Script:ManualStopFile = 'runtime/manual-stop.txt'

$Script:NotifyTaskCache = $null
function Get-NotifyTask {
    $c = $Script:NotifyTaskCache
    if ($c -and ((Get-Date) - $c.Time).TotalSeconds -lt 60) { return $c.Task }
    $task = $null
    if ((Test-TaskExists $Script:NotifyTask) -ne $false) {
        try { $task = Get-ScheduledTask -TaskName $Script:NotifyTask -ErrorAction Stop } catch { }
    }
    $Script:NotifyTaskCache = New-Object PSObject -Property @{ Time = Get-Date; Task = $task }
    return $task
}

function Install-NotifyTask {
    # conhost --headless: без мелькающего окна PowerShell при каждом запуске
    $script = Join-Path $PSScriptRoot 'notify.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -WorkingDirectory $Script:Root `
        -Argument ('--headless "' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"')
    $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User ($env:USERDOMAIN + '\' + $env:USERNAME)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    # от имени пользователя и без прав администратора: уведомления показываются только в его сеансе
    $pr = New-ScheduledTaskPrincipal -UserId ($env:USERDOMAIN + '\' + $env:USERNAME) -LogonType Interactive -RunLevel Limited
    $Script:NotifyTaskCache = $null
    try {
        Register-ScheduledTask -TaskName $Script:NotifyTask -Action $action -Trigger @($every, $logon) -Settings $set -Principal $pr -Force `
            -Description 'zapret: уведомления (обход не работает, Steam без сети после прокси, новая версия)' -ErrorAction Stop | Out-Null
    } catch { Write-Color $_.Exception.Message Red; return $false }
    return [bool](Get-NotifyTask)
}

function Remove-NotifyTask {
    try { Unregister-ScheduledTask -TaskName $Script:NotifyTask -Confirm:$false -ErrorAction Stop } catch { }
    $Script:NotifyTaskCache = $null
}

# Уведомление Windows от имени PowerShell (своё имя приложения требует ярлыка в меню "Пуск" - не стоит того)
function Show-Toast([string]$Title, [string]$Text) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml(("<toast><visual><binding template='ToastGeneric'><text>{0}</text><text>{1}</text></binding></visual></toast>" -f (& $esc $Title), (& $esc $Text)))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
        return $true
    } catch { return $false }
}

# Перезапуск Steam и Discord. Меню работает от администратора, и запущенные из него программы получили бы те же права,
# поэтому закрываем и открываем их через Проводник (steam://, discord://) - от имени пользователя.
function Restart-ProxyApps([string[]]$Apps) {
    $ok = $true
    foreach ($app in $Apps) {
        if ($app -eq 'Steam') {
            Start-Process -FilePath 'explorer.exe' -ArgumentList 'steam://exit'
            for ($i = 0; $i -lt 30 -and @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count; $i++) { Start-Sleep -Seconds 1 }
            if (@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue).Count) {
                Write-Color '  Steam не закрылся за 30 секунд (идёт загрузка?) - закройте его сами: меню Steam -> Выход.' Yellow
                $ok = $false; continue
            }
            Start-Process -FilePath 'explorer.exe' -ArgumentList 'steam://open/main'
        } elseif ($app -eq 'Discord') {
            Stop-Process -Name 'Discord' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Process -FilePath 'explorer.exe' -ArgumentList 'discord://-/'
        }
    }
    $Script:ProxyStuckCache = $null
    return $ok
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
# -Cached - для шапки меню (она перерисовывается на каждом экране): не чаще раза в 15 секунд. Проверки, автоподбор
# и автонастройка смотрят процессы сразу - закрытый ускоритель не должен им мерещиться.
$Script:BoostersCache = $null
function Get-GameBoosters([switch]$Cached) {
    if ($Cached -and $Script:BoostersCache -and ((Get-Date) - $Script:BoostersCache.Time).TotalSeconds -lt 15) { return $Script:BoostersCache.Items }
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
    $svcs = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    $found = @()
    # обычные циклы вместо вложенных Where-Object: сотни процессов на десяток шаблонов - было ~80 мс на каждый вызов
    foreach ($name in $Script:GameBoosters.Keys) {
        $pats = @($Script:GameBoosters[$name] | ForEach-Object { New-Object System.Management.Automation.WildcardPattern($_, 'IgnoreCase') })
        $hit = $false
        foreach ($n in $procs) { foreach ($w in $pats) { if ($w.IsMatch($n)) { $hit = $true; break } }; if ($hit) { break } }
        if ($hit) { $found += $name; continue }
        $svc = $null
        foreach ($sv in $svcs) { foreach ($w in $pats) { if ($w.IsMatch($sv.Name) -or $w.IsMatch($sv.DisplayName)) { $svc = $sv; break } }; if ($svc) { break } }
        if ($svc) { $found += ('{0} (служба {1})' -f $name, $svc.Name) }
    }
    $Script:BoostersCache = New-Object PSObject -Property @{ Time = Get-Date; Items = $found }
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
        $psi.Arguments = '-q -s --noproxy "*" --max-time ' + $TimeoutSec + ' "' + $Url + '"'
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
            Write-Color '  ! Внешний IP не российский. Проверьте VPN и маршруты перед подбором обхода; страна IP сама по себе не доказывает наличие VPN.' Red
            $ok = $false
        } else {
            Write-Color '  Внешний IP относится к России; это не исключает прокси или VPN.' Gray
        }
    } else {
        Write-Color '  Не удалось узнать внешний IP (ipwho.is и ipinfo.io не ответили).' Yellow
    }
    if ($tun.Count) {
        Write-Color '  ! Найден активный VPN/TUN-адаптер с маршрутами либо маршруты недоступны. Перед подбором проверьте режим TUN; путь игры зависит от правил VPN.' Yellow
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
# Пробы IPv6 запускаются отдельно от разбора: проверка обходов стартует их сразу, вместе с пробами hosts,
# а результаты собирает потом - так обе проверки идут одновременно (было ~6 + ~12 с подряд)
function Start-Ipv6Probes([int]$TimeoutSec = 6) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $jobs = @{}
    foreach ($name in $Script:Ipv6Hosts.Keys) {
        foreach ($v in @('4', '6')) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = '-q -' + $v + ' -s -o NUL --noproxy "*" --ssl-no-revoke --max-time ' + $TimeoutSec + ' --connect-timeout ' + ($TimeoutSec - 1) +
                ' -w "%{http_code} %{time_appconnect}" "https://' + $Script:Ipv6Hosts[$name] + '/"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $jobs[$name + '|' + $v] = New-Object PSObject -Property @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync() }
        }
    }
    return $jobs
}

function Test-Ipv6Paths([int]$TimeoutSec = 6, $Jobs = $null) {
    $jobs = if ($Jobs) { $Jobs } else { Start-Ipv6Probes $TimeoutSec }
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
function Get-Ipv6Report($Jobs = $null) {
    $prefer = Get-PreferIpv4
    $mode = if ($prefer) { 'Windows сначала пробует IPv4 (включено "предпочитать IPv4")' } else { 'Windows сначала пробует IPv6' }
    if (-not @(Get-Ipv6Addresses).Count) {
        return New-Object PSObject -Property @{ Has = $false; PreferV4 = $prefer; Rows = @(); Broken = @(); Slow = @()
            Text = 'IPv6: у ПК нет IPv6-адреса в интернете, всё идёт по IPv4 - проверять нечего' }
    }
    $rows = @(Test-Ipv6Paths -Jobs $Jobs)
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
# Сайты Telegram даже по рабочему адресу открываются не каждый раз, поэтому каждый адрес пробуется $Tries раз
# одновременно, в зачёт - лучшая попытка (раньше повтор шёл вторым кругом и добавлял ещё 6 с).
# Start-HostsPinProbes запускает пробы и сразу возвращается: проверка обходов стартует их вместе с пробами IPv6.
function Start-HostsPinProbes([int]$TimeoutSec = 6, [int]$Tries = 2) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
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
    $run = @()
    foreach ($it in @($items | Where-Object { $_.Ip })) {
        for ($t = 0; $t -lt $Tries; $t++) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = '-q -s -o NUL --noproxy "*" --ssl-no-revoke --max-time ' + $TimeoutSec + ' --resolve "' + $it.Probe + ':443:' + $it.Ip +
                '" -w "%{http_code} %{time_appconnect}" "https://' + $it.Probe + $it.Path + '"'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $run += New-Object PSObject -Property @{ It = $it; P = $p; Out = $p.StandardOutput.ReadToEndAsync() }
        }
    }
    return New-Object PSObject -Property @{ Items = $items; Run = $run; TimeoutSec = $TimeoutSec }
}

function Test-HostsPins([int]$TimeoutSec = 6, $Pending = $null) {
    $pd = if ($Pending) { $Pending } else { Start-HostsPinProbes $TimeoutSec }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    # у каждого адреса - Ok и лучшее Ms из его попыток
    foreach ($j in $pd.Run) {
        if (-not $j.P.WaitForExit(($pd.TimeoutSec + 5) * 1000)) { try { $j.P.Kill() } catch { } ; $j.P.WaitForExit() }
        $parts = @($j.Out.Result.Trim() -split '\s+')
        if ($j.P.ExitCode -ne 0 -or $parts[0] -eq '000' -or $parts.Count -lt 2) { continue }
        $ms = 0
        try { $ms = [math]::Round([double]::Parse($parts[1], $inv) * 1000) } catch { }
        if (-not $j.It.Ok -or $ms -lt $j.It.Ms) { $j.It.Ms = $ms }
        $j.It.Ok = $true
    }
    $items = $pd.Items
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

# ---------- TCP-подключение к справочным сервисам ----------
# Публичные API и сайты не являются текущим сервером матча. Минимум нескольких подключений
# показывает лучший результат этих TCP-проб, включая работу локального ПК. Все цели параллельно.
$Script:GamePingTargets = [ordered]@{
    'Amazon API: eu-central-1'                    = 'ec2.eu-central-1.amazonaws.com'
    'Quago: сервис api.quago.io'                  = 'api.quago.io'
    'Epic: вход и сервисы'                       = 'api.epicgames.dev'
    'Amazon API: eu-north-1'                      = 'ec2.eu-north-1.amazonaws.com'
    'Amazon API: eu-west-2'                       = 'ec2.eu-west-2.amazonaws.com'
    'Steam (магазин и загрузки)'                    = 'store.steampowered.com'
    'Discord'                                       = 'discord.com'
}

# Имя -> минимальное время TCP-подключения в мс из $Tries попыток (-1 - не подключилось ни разу)
function Measure-TcpRtt([string[]]$Hosts, [int]$Tries = 4, [int]$TimeoutMs = 2000) {
    $ips = @{}
    foreach ($h in $Hosts) {
        try { $ips[$h] = @([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0] } catch { $ips[$h] = $null }
    }
    $best = @{}
    foreach ($h in $Hosts) { $best[$h] = -1 }
    for ($t = 0; $t -lt $Tries; $t++) {
        $jobs = @(foreach ($h in $Hosts) {
            if (-not $ips[$h]) { continue }
            $tc = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $task = $null
            try { $task = $tc.ConnectAsync($ips[$h], 443) } catch { }
            New-Object PSObject -Property @{ Host = $h; Tc = $tc; Task = $task; Sw = $sw }
        })
        # время каждого подключения - в момент, когда оно завершилось, а не когда до него дошла очередь ожидания
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $pending = @($jobs | Where-Object { $_.Task })
        while ($pending.Count -and $clock.ElapsedMilliseconds -lt $TimeoutMs) {
            foreach ($j in $pending) {
                if (-not $j.Task.IsCompleted) { continue }
                if ($j.Task.Status -eq 'RanToCompletion') {
                    $ms = [math]::Round($j.Sw.Elapsed.TotalMilliseconds)
                    if ($best[$j.Host] -lt 0 -or $ms -lt $best[$j.Host]) { $best[$j.Host] = $ms }
                }
            }
            $pending = @($pending | Where-Object { -not $_.Task.IsCompleted })
            if ($pending.Count) { Start-Sleep -Milliseconds 2 }
        }
        foreach ($j in $jobs) { try { $j.Tc.Close() } catch { } }
    }
    return $best
}

# ---------- Wi-Fi и задержка до роутера ----------
# Обход маршрут не меняет: пинг до сервера задают провайдер и расстояние. Что можно поправить на ПК - участок до
# роутера: по Wi-Fi адаптер раз в минуту-две уходит искать другие сети (агрессивность роуминга), и пакеты игры ждут
# по 50-300 мс. Это видно по всплескам пинга до роутера.

# Адаптер маршрута по умолчанию: Wi-Fi ли он, скорость, агрессивность роуминга (текущая и самая низкая из допустимых)
function Get-WifiInfo {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { return $null }
    $a = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $a) { return $null }
    $wifi = $a.NdisPhysicalMedium -eq 9 -or $a.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan'
    $roam = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)roaming aggressiveness|агрессивность роуминга' } | Select-Object -First 1
    # порядок значений у драйверов разный ("5.Highest ... 1.Lowest" у Qualcomm): ищем самое низкое по названию
    $lowest = $null
    if ($roam -and $roam.ValidDisplayValues) {
        $vals = @($roam.ValidDisplayValues)
        $lowest = @($vals | Where-Object { $_ -match '(?i)lowest|миним|самая низк|^\s*1\s*\.' }) | Select-Object -First 1
    }
    return New-Object PSObject -Property @{ Name = $a.Name; Gateway = $route.NextHop; Wifi = $wifi; Speed = $a.LinkSpeed
        Roam = $(if ($roam) { $roam.DisplayValue } else { $null }); RoamName = $(if ($roam) { $roam.DisplayName } else { $null }); RoamLowest = $lowest }
}

# Пинг до роутера раз в 50 мс в течение $Seconds: медиана, 99%, максимум, всплески от 30 мс, потери
function Measure-GatewayJitter([string]$Gateway, [int]$Seconds = 15) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $all = New-Object System.Collections.Generic.List[int]
    $lost = 0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        try { $x = $p.Send($Gateway, 1000); if ($x.Status -eq 'Success') { $all.Add([int]$x.RoundtripTime) } else { $lost++ } } catch { $lost++ }
        Start-Sleep -Milliseconds 50
    }
    $s = @($all | Sort-Object)
    if (-not $s.Count) { return New-Object PSObject -Property @{ Median = -1; P99 = -1; Max = -1; Spikes = 0; Lost = $lost; Count = 0 } }
    return New-Object PSObject -Property @{ Median = $s[[int]($s.Count / 2)]; P99 = $s[[int][math]::Min($s.Count - 1, [math]::Floor($s.Count * 0.99))]
        Max = $s[-1]; Spikes = @($s | Where-Object { $_ -ge 30 }).Count; Lost = $lost; Count = $s.Count }
}

# ---------- работают ли сервисы прямо сейчас ----------
# Главный вопрос проверки обходов: открывается ли то, ради чего стоит обход. Запрос - как у браузера и игр: напрямую,
# мимо прокси, через обход, если он запущен. Любой HTTP-ответ, даже 404, - сервис доступен: TLS прошёл, данные пришли.
$Script:ServiceProbes = [ordered]@{
    'YouTube'                 = 'https://www.youtube.com/generate_204'
    'видео YouTube'           = 'https://redirector.googlevideo.com/report_mapping'
    'Discord'                 = 'https://discord.com/api/v9/gateway'
    'Steam'                   = 'https://store.steampowered.com/'
    'GitHub'                  = 'https://github.com/'
    'NBA 2K27: вход (Epic)'   = 'https://api.epicgames.dev/'
    'NBA 2K27: запись матча'  = 'https://api.quago.io/'
}

function Get-BypassIdentity($Processes) {
    if (@($Processes).Count -ne 1) { return '' }
    try { return ('{0}:{1}' -f $Processes[0].Id, $Processes[0].StartTime.ToUniversalTime().Ticks) } catch { return '' }
}
function Test-ServiceHealthRows($Rows) {
    if (@($Rows).Count -ne $Script:ServiceProbes.Count) { return $false }
    $names = @{}
    foreach ($row in $Rows) {
        if (-not $Script:ServiceProbes.Contains([string]$row.Name) -or $names.ContainsKey([string]$row.Name) -or $row.Ok -isnot [bool]) { return $false }
        $names[[string]$row.Name] = $true
    }
    return $true
}
function Save-ServiceHealth($Rows, [string]$Identity, $NetworkBefore = $null) {
    try {
        if (-not $Identity -or $Identity -cne (Get-BypassIdentity @(Get-OurProcesses)) -or -not (Test-ServiceHealthRows $Rows)) { return $false }
        $network = Get-NetworkObservation -Machine
        if (-not $network.Known -or $network.Key -notmatch '^[A-Fa-f0-9]{64}$') { return $false }
        if ($null -ne $NetworkBefore -and -not(Test-NetworkObservation $NetworkBefore $network)) { return $false }
        $data = New-Object PSObject -Property @{ Identity=$Identity; NetworkKey=$network.Key; CheckedUtc=[datetime]::UtcNow.ToString('o'); Rows=@($Rows) }
        Write-TextNoBom (Join-Path $Script:Runtime 'service-health.json') ($data | ConvertTo-Json -Depth 4)
        return $true
    } catch { return $false }
}
function Get-ServiceHealthSummary($Processes) {
    $unknown = New-Object PSObject -Property @{ State='Unknown'; Text='HTTPS: для текущего запуска и подключения нет свежей проверки. Проверить — пункт 5.' }
    try {
        $identity = Get-BypassIdentity $Processes
        $path = Join-Path $Script:Runtime 'service-health.json'
        if (-not $identity -or -not (Test-Path $path) -or (Get-Item $path).Length -gt 16384) { return $unknown }
        $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($data.Identity -cne $identity -or -not (Test-ServiceHealthRows $data.Rows)) { return $unknown }
        $checked = [DateTimeOffset]::Parse([string]$data.CheckedUtc, [Globalization.CultureInfo]::InvariantCulture)
        $age = ([datetime]::UtcNow - $checked.UtcDateTime).TotalSeconds
        if ($age -lt 0 -or $age -gt 600) { return $unknown }
        $network = Get-NetworkObservation -Machine
        if (-not $network.Known -or $data.NetworkKey -cne $network.Key) { return $unknown }
        $bad = @($data.Rows | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
        $text = 'HTTPS: последняя проверка {0}, ответили {1}/{2}' -f $checked.ToLocalTime().ToString('HH:mm'), ($data.Rows.Count - $bad.Count), $data.Rows.Count
        if ($bad.Count) { $text += '; без ответа: ' + ($bad -join ', ') }
        return (New-Object PSObject -Property @{ State=$(if ($bad.Count) { 'Partial' } else { 'Good' }); Text=$text })
    } catch { return $unknown }
}
function Update-ServiceHealth {
    try {
        $identity = Get-BypassIdentity @(Get-OurProcesses)
        if (-not $identity) { return $false }
        $networkBefore = Get-NetworkObservation -Machine
        $jobs = Start-ServiceProbes -TimeoutSec 3
        $rows = @(Get-ServiceProbeResults $jobs)
        return (Save-ServiceHealth $rows $identity -NetworkBefore $networkBefore)
    } catch { return $false }
}
function Start-ServiceProbes([int]$TimeoutSec = 8) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $run = @()
    foreach ($name in $Script:ServiceProbes.Keys) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $curl
        $psi.Arguments = '-q -s -o NUL --noproxy "*" --ssl-no-revoke --max-time ' + $TimeoutSec + ' -w "%{http_code} %{time_appconnect}" "' + $Script:ServiceProbes[$name] + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $run += New-Object PSObject -Property @{ Name = $name; P = $p; Out = $p.StandardOutput.ReadToEndAsync(); TimeoutSec = $TimeoutSec }
    }
    return $run
}

# Name, Ok, Ms (время установки TLS)
function Get-ServiceProbeResults($Run) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $rows = @()
    foreach ($j in @($Run)) {
        if (-not $j.P.WaitForExit(($j.TimeoutSec + 5) * 1000)) { try { $j.P.Kill() } catch { } ; $j.P.WaitForExit() }
        $parts = @($j.Out.Result.Trim() -split '\s+')
        $ok = $j.P.ExitCode -eq 0 -and $parts.Count -ge 2 -and $parts[0] -ne '000'
        $ms = 0
        if ($ok) { try { $ms = [math]::Round([double]::Parse($parts[1], $inv) * 1000) } catch { } }
        $rows += New-Object PSObject -Property @{ Name = $j.Name; Ok = $ok; Ms = $ms }
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

# ---------- серверы игр в hosts ----------
# Часть адресов серверов игр провайдер режет по IP, а это обход не снимает. NBA 2K27 во время матча шлёт запись
# поведения игрока на api.quago.io (Quago, Amazon): DNS отдаёт то рабочие его адреса, то заблокированные
# (3.216.81.164 отвечает как api.quago.io только через VPN), и на заблокированном игра ждёт подключения - похоже,
# отсюда рывки посреди матча. Закрепляем в hosts только адреса, которые отвечают с сертификатом этого имени,
# и перепроверяем их при каждом запуске обхода: адреса Amazon со временем меняются.
$Script:GamePinHosts = @('api.quago.io')
$Script:GamePinsBegin = '# zapret: серверы игр - начало (меню: Проверка обходов)'
$Script:GamePinsEnd = '# zapret: серверы игр - конец'
$Script:GamePinsMax = 6
# свои имена: те, что трекер увидел недоступными, а проверка обходов предложила закрепить
$Script:GamePinsUserFile = 'runtime/gamepins-user.txt'
# серверы, к которым программа под трекером не подключилась (имя, адрес, когда): их разбирает проверка обходов
$Script:BlockedHostsFile = 'runtime/blocked-hosts.txt'

function Get-GamePinHosts {
    $user = @(Get-ListLines (Get-PkgPath $Script:GamePinsUserFile) | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -match '^[a-z0-9][a-z0-9\.\-]+$' })
    return @(@($Script:GamePinHosts) + $user | Select-Object -Unique)
}

function Add-GamePinHost([string]$Name) {
    $f = Get-PkgPath $Script:GamePinsUserFile
    $have = @(Get-ListLines $f)
    if ($have -contains $Name.ToLower()) { return }
    Write-TextNoBom $f ((@($have) + $Name.ToLower() | ForEach-Object { $_ + "`r`n" }) -join '')
}

# Записи трекера о серверах без ответа: имя -> адреса. Пустые имена и уже закреплённые - пропускаются
function Get-BlockedHosts {
    $res = [ordered]@{}
    $pinned = @(Get-GamePinHosts)
    foreach ($l in @(Get-ListLines (Get-PkgPath $Script:BlockedHostsFile))) {
        $p = @($l -split '\s+')
        if ($p.Count -lt 2 -or $pinned -contains $p[0]) { continue }
        if (-not $res.Contains($p[0])) { $res[$p[0]] = @() }
        if ($res[$p[0]] -notcontains $p[1]) { $res[$p[0]] += $p[1] }
    }
    return $res
}

# TLS к имени $Name по каждому адресу, все адреса параллельно, с проверкой сертификата этого имени
function Test-TlsIps([string]$Name, [string[]]$Ips, [int]$TimeoutMs = 2000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $jobs = @(foreach ($ip in $Ips) {
        $tc = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
        $conn = $null
        try { $conn = $tc.ConnectAsync([System.Net.IPAddress]::Parse($ip), 443) } catch { }
        New-Object PSObject -Property @{ Ip = $ip; Tc = $tc; Conn = $conn; Tls = $null }
    })
    foreach ($j in $jobs) { if ($j.Conn) { try { [void]$j.Conn.Wait([math]::Max(0, $TimeoutMs - $sw.ElapsedMilliseconds)) } catch { } } }
    foreach ($j in $jobs) {
        if ($j.Conn -and $j.Conn.Status -eq 'RanToCompletion') {
            try { $j.Tls = (New-Object System.Net.Security.SslStream($j.Tc.GetStream(), $false)).AuthenticateAsClientAsync($Name) } catch { }
        }
    }
    $res = @()
    foreach ($j in $jobs) {
        $ok = $false
        if ($j.Tls) { try { $ok = $j.Tls.Wait([math]::Max(0, 2 * $TimeoutMs - $sw.ElapsedMilliseconds)) -and $j.Tls.Status -eq 'RanToCompletion' } catch { } }
        $res += New-Object PSObject -Property @{ Ip = $j.Ip; Ok = $ok }
        try { $j.Tc.Close() } catch { }
    }
    return $res
}

# ---------- подмена DNS ----------
# Провайдер или роутер может отвечать на запросы о заблокированных сайтах чужим адресом: соединение идёт не туда, и обход бессилен.
# Сравниваем системный DNS с DoH. Частный адрес или доступность только адреса DoH - повод для предупреждения, но не доказательство
# подмены: CDN, маршрутизация и тайм-ауты тоже влияют на TLS. Неполную проверку явно отличаем от отсутствия подозрительных ответов.
$Script:DnsProbeNames = @('discord.com', 'x.com', 'rutracker.org')
function Test-PrivateIp([string]$Ip) {
    return $Ip -match '^(0\.|10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)'
}
# Адреса A из DoH. Пусто - DoH недоступен или адреса нет: тогда и вывода нет
function Get-DohAddresses([string]$Name) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    foreach ($u in @('https://1.1.1.1/dns-query?name=', 'https://8.8.8.8/resolve?name=')) {
        $r = Invoke-Native $curl ('-q -s --noproxy "*" --ssl-no-revoke --max-time 2 -H "accept: application/dns-json" "' + $u + $Name + '&type=A"') $Script:Runtime 4
        if ($r.ExitCode -ne 0) { continue }
        try {
            $ips = @((ConvertFrom-Json $r.Output).Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data })
            if ($ips.Count) { return $ips }
        } catch { }
    }
    return @()
}
# Возможная проблема DNS/маршрута. $SysOk, $DohOk - прошёл ли TLS по адресам системного DNS и DoH.
function Test-DnsAnswerForged($Sys, $Doh, [bool]$SysOk, [bool]$DohOk) {
    if (-not @($Sys).Count -or -not @($Doh).Count) { return $false }
    if (@($Sys | Where-Object { @($Doh) -contains $_ }).Count) { return $false }
    if (-not @($Sys | Where-Object { -not (Test-PrivateIp $_) }).Count) { return $true }
    return ((-not $SysOk) -and $DohOk)
}
# Подозрительные имена и число адресов, для которых удалось сделать сравнение.
function Get-DnsCheck {
    $res = @()
    $checked = 0
    $bypassOn = @(Get-OurProcesses).Count -gt 0
    foreach ($n in $Script:DnsProbeNames) {
        $doh = @(Get-DohAddresses $n)
        # DoH недоступен: сравнивать не с чем, и ждать его у каждого имени незачем
        if (-not $doh.Count) { break }
        $sys = @()
        try { $sys = @(Resolve-DnsName $n -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) } catch { }
        if (-not $sys.Count) { continue }
        if (@($sys | Where-Object { $doh -contains $_ }).Count) { $checked++; continue }
        if (-not @($sys | Where-Object { -not (Test-PrivateIp $_) }).Count) { $res += $n; $checked++; continue }
        if (-not $bypassOn) { continue }
        $sysOk = $false; $dohOk = $false
        # Одинаковый ответ - обычный случай, TLS проверять незачем. Без обхода заблокированный сайт не откроется ни по какому адресу
        if ($bypassOn -and $sys.Count -and -not @($sys | Where-Object { $doh -contains $_ }).Count) {
            $sysOk = @(Test-TlsIps $n $sys 1500 | Where-Object { $_.Ok }).Count -gt 0
            $dohOk = @(Test-TlsIps $n $doh 1500 | Where-Object { $_.Ok }).Count -gt 0
        }
        if (-not $sysOk -and -not $dohOk) { continue }
        $checked++
        if (Test-DnsAnswerForged $sys $doh $sysOk $dohOk) { $res += $n }
    }
    return New-Object PSObject -Property @{ Suspect = @($res); Checked = $checked; Total = @($Script:DnsProbeNames).Count }
}
function Get-DnsCheckText($Result) {
    if (-not $Result.Checked) { return 'DNS: проверить не удалось, нет данных для сравнения.' }
    $coverage = ' Проверено имён: {0}/{1}.' -f $Result.Checked, $Result.Total
    if ($Result.Suspect.Count) {
        return ('DNS: возможная подмена или недоступный адрес: ' + ($Result.Suspect -join ', ') + '. Разные ответы CDN и сбои маршрута тоже могут быть причиной.' + $coverage)
    }
    return ('DNS: подозрительных ответов среди проверенных не обнаружено.' + $coverage)
}

# По каждому имени: адреса из DNS (мимо hosts), закреплённые сейчас, и какие из них отвечают
function Get-GamePinsState {
    $hosts = @(Read-HostsEntries $Script:HostsFile)
    $res = @()
    foreach ($h in @(Get-GamePinHosts)) {
        $dns = @()
        try { $dns = @(Resolve-DnsName $h -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) } catch { }
        $pinned = @($hosts | Where-Object { $_.Host -eq $h } | ForEach-Object { $_.Ip })
        $t = @(Test-TlsIps $h @(@($dns) + @($pinned) | Select-Object -Unique))
        $res += New-Object PSObject -Property @{ Host = $h; Dns = $dns; Pinned = $pinned
            Good = @($t | Where-Object { $_.Ok } | ForEach-Object { $_.Ip }); Bad = @($t | Where-Object { -not $_.Ok } | ForEach-Object { $_.Ip }) }
    }
    return $res
}

# Блок закреплённых адресов в hosts. $Pins - имя -> адреса; пустой - блок убирается. Записи этих имён вне блока
# тоже убираются, остальные строки hosts (и блок Flowseal) остаются. Файл переписывается, только если что-то изменилось.
function Set-GamePins($Pins) {
    $bytes = [System.IO.File]::ReadAllBytes($Script:HostsFile)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $ours = @(Get-GamePinHosts)
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -eq $Script:GamePinsBegin) { $inBlock = $true; continue }
        if ($line -eq $Script:GamePinsEnd) { $inBlock = $false; continue }
        if ($inBlock) { continue }
        $t = ($line -replace '#.*', '').Trim()
        if ($t) {
            $names = @($t -split '\s+' | Select-Object -Skip 1)
            if ($names.Count -and @($names | Where-Object { $ours -contains $_.ToLower() }).Count -eq $names.Count) { continue }
        }
        $out.Add($line)
    }
    while ($out.Count -and -not $out[$out.Count - 1].Trim()) { $out.RemoveAt($out.Count - 1) }
    $add = @(foreach ($h in @($Pins.Keys)) { foreach ($ip in @($Pins[$h])) { $ip + ' ' + $h } })
    if ($add.Count) {
        $out.Add('')
        $out.Add($Script:GamePinsBegin)
        foreach ($l in $add) { $out.Add($l) }
        $out.Add($Script:GamePinsEnd)
    }
    $new = ($out -join $nl) + $nl
    if ($new -eq $text) { return $true }
    Copy-Item $Script:HostsFile (Join-Path $Script:Runtime ('hosts-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak')) -Force
    try { [System.IO.File]::WriteAllText($Script:HostsFile, $new, (New-Object System.Text.UTF8Encoding($bom))) }
    catch { return $false }
    & ipconfig.exe /flushdns | Out-Null
    return $true
}

# Перепроверить адреса и записать в hosts рабочие (при запуске обхода, если закрепление включено).
# Имя, у которого не ответил ни один адрес, не закрепляется: пусть идёт по DNS.
function Update-GamePins {
    # При VPN в режиме туннеля TLS проходит на любом адресе: клиент соединяется по имени из запроса, а не по адресу.
    # Такая проверка закрепила бы и заблокированные адреса, поэтому закреплённое не трогаем
    if (@(Get-TunAdapters).Count) { return New-Object PSObject -Property @{ Ok = $true; State = @(); Pins = [ordered]@{}; Skipped = $true } }
    $state = @(Get-GamePinsState)
    $pins = [ordered]@{}
    foreach ($s in $state) { if ($s.Good.Count) { $pins[$s.Host] = @($s.Good | Select-Object -First $Script:GamePinsMax) } }
    $ok = Set-GamePins $pins
    return New-Object PSObject -Property @{ Ok = $ok; State = $state; Pins = $pins; Skipped = $false }
}

function Get-GamePinsText($Update) {
    if ($Update.Skipped) { return 'включён VPN, проверить адреса нельзя - закрепление не менялось' }
    return (@(foreach ($s in $Update.State) {
        $n = if ($Update.Pins.Contains($s.Host)) { @($Update.Pins[$s.Host]).Count } else { 0 }
        $bad = if ($s.Bad.Count) { ', не отвечают: ' + ($s.Bad -join ', ') } else { '' }
        '{0} - закреплено адресов: {1}{2}' -f $s.Host, $n, $bad
    }) -join '; ')
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
    $args0 = '-s -L -f --ssl-no-revoke --max-time 60 -o "' + $tmp + '" "' + $Script:FlowsealRaw + $Script:FlowsealLists[$Name] + '"'
    $r = Invoke-Native $curl $args0 $Script:Runtime 90
    # GitHub изредка отвечает ошибкой или не отвечает вовсе - вторая попытка через секунду
    if ($r.ExitCode -ne 0) { Start-Sleep -Seconds 1; $r = Invoke-Native $curl $args0 $Script:Runtime 90 }
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
    return @($Script:FlowsealLists.Keys | ForEach-Object { Update-FlowsealList $_ })
}

# Сети Valve (AS32590, по данным RIPE на 2026-10-27) - для правил "напрямую" прокси-клиентов (Инструменты -> 7)
$Script:ValveNets = @('45.121.184.0/24', '103.10.124.0/23', '103.28.54.0/24', '146.66.152.0/24', '146.66.155.0/24', '155.133.224.0/21', '155.133.236.0/22', '155.133.240.0/23', '155.133.244.0/24', '155.133.246.0/24', '155.133.248.0/22', '155.133.252.0/24', '155.133.254.0/23', '162.254.192.0/21', '185.25.180.0/24', '185.25.182.0/23', '192.69.96.0/22', '205.196.6.0/24', '208.64.200.0/22', '208.78.164.0/22', '2404:3fc0::/46', '2404:3fc0:8::/47', '2404:3fc0:a::/48', '2602:801:f000::/46', '2602:801:f005::/48', '2602:801:f006::/47', '2602:801:f008::/46', '2602:801:f00d::/48', '2602:801:f00e::/48', '2a01:bc80::/45', '2a01:bc80:8::/46', '2a01:bc80:c::/48')

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
    # TLS с GitHub изредка занимает 4-5 секунд, а то и не проходит - до 10 секунд и вторая попытка (проверка идёт
    # в фоне, меню её не ждёт)
    for ($try = 0; $try -lt 2; $try++) {
        $r = Invoke-Native $curl ('-s -o NUL --ssl-no-revoke --max-time 10 -w "%{redirect_url}" "https://github.com/' + $Repo + '/releases/latest"') $Script:Runtime 14
        if ($r.ExitCode -eq 0 -and $r.Output -match '/releases/tag/([^/\s]+)$') { return [uri]::UnescapeDataString($matches[1]) }
    }
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

# Раздел CHANGELOG.md про версию $Version - без заголовка и разметки (меню показывает его после обновления)
function Get-ChangelogSection([string]$Version) {
    $f = Join-Path $Script:Root 'CHANGELOG.md'
    if (-not (Test-Path $f)) { return @() }
    $out = @(); $in = $false
    foreach ($l in [System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8)) {
        if ($l -match '^## ') { if ($in) { break }; $in = ($l -eq '## zapret ' + $Version); continue }
        if ($in -and $l.Trim()) { $out += ($l -replace '^#+\s*', '' -replace '\*\*', '' -replace '`', '') }
    }
    return $out
}

# Сколько дней не обновлялись списки Flowseal: по времени ipset-all (оно меняется и когда списки не изменились)
function Get-ListsAgeDays {
    $f = Join-Path $Script:Lists 'ipset-all.txt'
    if (-not (Test-Path $f)) { return 999 }
    return [int][math]::Floor(((Get-Date) - (Get-Item $f).LastWriteTime).TotalDays)
}

# Свежие списки Flowseal - в фоне при открытии меню, если им $Days дней и больше: без автонастройки по расписанию
# они не обновлялись бы вовсе. Новые адреса провайдер блокирует постоянно, а winws2 перечитывает изменённые списки сам.
function Start-ListsUpdate([int]$Days = 7) {
    # в рабочей копии разработки списки лежат в git - их обновляют вручную (Настройки -> 8), а не фоном
    if ((Test-DevCheckout) -or (Get-ListsAgeDays) -lt $Days) { return }
    $cmd = ". '" + (Join-Path $Script:Root 'tools\lib.ps1').Replace("'", "''") + "'; Update-FlowsealLists | Out-Null"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc) | Out-Null
    } catch { }
}

# То же в фоне, отдельным скрытым процессом: до четырёх запросов к GitHub по 5 с задерживали открытие меню.
# Новости появятся в шапке при следующей перерисовке. Процесс запускается, только когда проверка уже нужна.
function Start-UpstreamCheck([int]$Days = 7) {
    $f = Get-PkgPath $Script:UpdatesFile
    if ((Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalDays -lt $Days) { return }
    $cmd = ". '" + (Join-Path $Script:Root 'tools\lib.ps1').Replace("'", "''") + "'; Update-UpstreamCheck -Days $Days | Out-Null"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    try {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $enc) | Out-Null
    } catch { }
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

# ---------- обновление самой сборки ----------
# Последний релиз с GitHub (Настройки -> 9). Архив сверяется по SHA-256, которую GitHub сам считает для каждого файла
# релиза, и только потом раскладывается поверх папки. Не трогаются runtime\ (настройки, рейтинг, логи), ваши списки
# lists\*-user.txt, автосписок и списки Flowseal (они обновляются сами и в папке обычно новее, чем в архиве).
function Get-ZapretRelease {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $tmp = Join-Path $Script:Runtime 'release.json'
    $r = Invoke-Native $curl ('-s -f --ssl-no-revoke --max-time 20 -H "Accept: application/vnd.github+json" -o "' + $tmp + '" "https://api.github.com/repos/' + $Script:SelfRepo + '/releases/latest"') $Script:Runtime 30
    if ($r.ExitCode -ne 0 -or -not (Test-Path $tmp)) { return $null }
    $j = $null
    try { $j = [System.IO.File]::ReadAllText($tmp) | ConvertFrom-Json } catch { }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (-not $j -or -not ($j.PSObject.Properties.Name -contains 'assets')) { return $null }
    $prefix = 'https://github.com/' + $Script:SelfRepo + '/releases/download/'
    $asset = @($j.assets | Where-Object { $_.name -match '^zapret-v[\d.]+\.zip$' -and ('' + $_.browser_download_url).StartsWith($prefix) }) | Select-Object -First 1
    if (-not $asset) { return $null }
    $digest = if ($asset.PSObject.Properties.Name -contains 'digest') { '' + $asset.digest } else { '' }
    return New-Object PSObject -Property @{ Tag = '' + $j.tag_name; Url = '' + $asset.browser_download_url; Name = '' + $asset.name; Sha256 = ($digest -replace '^sha256:', '').ToLower() }
}

# Какие файлы нового архива ($Src - папка zapret из архива) класть в папку $Dst. Одинаковые не трогаем.
function Get-UpdatePlan([string]$Src, [string]$Dst) {
    $keep = @($Script:FlowsealLists.Keys) + @('autohostlist.txt')
    $plan = @()
    # полный путь: в $Src может быть короткое имя (C:\Users\RUNNER~1\...), а FullName у файлов - всегда длинное
    $base = (Get-Item -LiteralPath $Src).FullName.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File)) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\')
        if ($rel -like 'runtime\*') { continue }
        $target = Join-Path $Dst $rel
        $exists = Test-Path -LiteralPath $target
        if ($rel -like 'lists\*' -and $exists) {
            $name = Split-Path -Leaf $rel
            if ($name -like '*-user.txt' -or $keep -contains $name) { continue }
        }
        if ($exists -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) { continue }
        $plan += $rel
    }
    return $plan
}

# Удаляем только явно отозванные файлы сборки, а не любые пользовательские стратегии.
function Get-RetiredStrategies([string]$Src, [string]$Dst) {
    $manifest = Join-Path $Src 'strategies\retired.txt'
    if (-not (Test-Path -LiteralPath $manifest)) { return @() }
    foreach ($name in Get-ListLines $manifest) {
        if ($name -notmatch '^alt\d+\.txt$') { continue }
        $rel = 'strategies\' + $name
        if (-not (Test-Path -LiteralPath (Join-Path $Src $rel)) -and (Test-Path -LiteralPath (Join-Path $Dst $rel))) { $rel }
    }
}

# Если выбранная стратегия отозвана, готовим замену настройки внутри той же файловой транзакции.
function Prepare-UpdateSettings([string]$Src, [string]$Dst, $Remove) {
    $file = Join-Path $Dst 'runtime\settings.ini'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $text = [IO.File]::ReadAllText($file)
    $match = [regex]::Match($text, '(?m)^[ \t]*alt[ \t]*=[ \t]*(\d+)[ \t]*\r?$')
    if (-not $match.Success -or @($Remove) -notcontains ('strategies\alt' + $match.Groups[1].Value + '.txt')) { return @() }
    $replacement = '12'
    if (-not (Test-Path -LiteralPath (Join-Path $Src 'strategies\alt12.txt'))) { throw 'В обновлении нет запасной стратегии ALT12.' }
    $text = [regex]::Replace($text, '(?m)^([ \t]*alt[ \t]*=[ \t]*)\d+([ \t]*\r?)$', ('${1}' + $replacement + '${2}'))
    $staged = Join-Path $Src 'runtime\settings.ini'
    New-Item -ItemType Directory (Split-Path -Parent $staged) -Force -ErrorAction Stop | Out-Null
    Write-TextNoBom $staged $text
    Write-Color ('Выбранная стратегия отозвана в обновлении. После установки основной станет ALT' + $replacement + '.') Yellow
    return 'runtime\settings.ini'
}

# Сначала резервные копии всех исходных файлов, затем замена/удаление. Даже частично записанный файл включён в откат.
function Install-UpdateFiles([string]$Src, [string]$Dst, [string]$Backup, $Plan, $Remove, [bool]$WasRunning = $false, [scriptblock]$BeforeApply = $null) {
    $root = [IO.Path]::GetFullPath($Dst).TrimEnd('\')
    $journalPath = $null
    try {
        if (Test-PendingUpdate $root) { throw 'Сначала восстановите незавершённое обновление.' }
        $dir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Backup))
        $id = [IO.Path]::GetFileName($dir)
        $expected = Resolve-UpdateFilePath $root ('runtime/update/'+$id+'/backup')
        if ($id -notmatch '^[a-f0-9]{32}$' -or $Backup -ine $expected -or (Test-Path -LiteralPath $Backup) -or (Test-Path -LiteralPath (Join-Path $dir 'journal.json'))) { throw 'Недопустимый или уже использованный каталог транзакции.' }
        Initialize-UpdateStore $root | Out-Null
        if (Test-Path -LiteralPath $dir) { if (-not (Test-UpdateTrustedPath $dir)) { throw 'Недоверенный каталог транзакции.' } }
        else { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null; Protect-UpdatePath $dir }
        New-Item -ItemType Directory -Path $Backup -ErrorAction Stop | Out-Null; Protect-UpdatePath $Backup
        $entries = @(); $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @(@($Plan) + @($Remove))) {
            $relative = ([string]$item).Replace('/','\')
            if (-not $seen.Add($relative)) { throw 'Повторный путь в обновлении.' }
            $target = Resolve-UpdateFilePath $root $relative
            if ($relative -match '^(?i:runtime)\\' -and $relative -ine 'runtime\settings.ini') { throw 'Недопустимый файл runtime в обновлении.' }
            $existed = Test-Path -LiteralPath $target
            if ($existed -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Обновление не заменяет каталоги.' }
            $oldHash = ''; $newHash = ''; $isRemove = @($Remove) -contains $item
            if (-not $isRemove) { $newHash = (Get-FileHash -LiteralPath (Resolve-UpdateFilePath $Src $relative) -Algorithm SHA256 -ErrorAction Stop).Hash }
            if ($existed) {
                $oldHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
                $b = Join-Path $Backup $item
                New-Item -ItemType Directory (Split-Path -Parent $b) -Force -ErrorAction Stop | Out-Null
                Copy-Item -LiteralPath $target -Destination $b -Force -ErrorAction Stop
                $cursor = $b
                while ($cursor.StartsWith($Backup,[StringComparison]::OrdinalIgnoreCase)) { Protect-UpdatePath $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor) }
                if ((Get-FileHash -LiteralPath $b -Algorithm SHA256 -ErrorAction Stop).Hash -cne $oldHash) { throw 'Исходный файл изменился при создании копии.' }
                $file = [IO.File]::Open($b,'Open','ReadWrite','None'); try { $file.Flush($true) } finally { $file.Dispose() }
            }
            $entries += [pscustomobject]@{Relative=$relative;Existed=$existed;OldHash=$oldHash;NewHash=$newHash;Remove=$isRemove}
        }
        if ($entries.Count -gt 500) { throw 'Слишком много файлов в транзакции обновления.' }
        $journal = [pscustomobject]@{Schema=1;Id=$id;Root=$root;State='Prepared';WasRunning=$WasRunning;Entries=$entries}
        $journalPath = Join-Path $dir 'journal.json'
        Write-UpdateJournal $journalPath $journal
        if ($null -ne $BeforeApply) { & $BeforeApply | Out-Null }
        $journal.State = 'Applying'; Write-UpdateJournal $journalPath $journal
        foreach ($entry in $entries) {
            $target = Resolve-UpdateFilePath $root $entry.Relative
            if ($entry.Existed -and (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -cne $entry.OldHash) { throw 'Исходный файл изменён после создания копии.' }
            if ($entry.Remove) { if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop } }
            else { Copy-UpdateFile (Resolve-UpdateFilePath $Src $entry.Relative) $target $entry.NewHash }
        }
        Write-UpdateRestartIntent $root $WasRunning
        $journal.State = 'Committed'; Write-UpdateJournal $journalPath $journal
        return $true
    } catch {
        Write-Color ('Обновление прервано: ' + $_.Exception.Message + '. Возвращаю прежние файлы.') Red
        if ($journalPath -and (Test-Path -LiteralPath $journalPath)) {
            try { Restore-UpdateJournalFiles $root $journalPath }
            catch { Write-Color ('Автоматический откат остановлен. Копии: '+$Backup+'. '+$_.Exception.Message) Red }
        }
        return $false
    }
}

# Скачивает, проверяет и ставит релиз $Rel (из Get-ZapretRelease). Перед заменой старые файлы копируются
# в runtime\update\<номер>\backup и при сбое возвращаются. Возвращает $true, если обновлено.
function Install-ZapretUpdate($Rel) {
    if (-not (Enter-BypassControl 'Install-ZapretUpdate')) { throw 'Другая операция управляет обходом; действие отложено.' }
    try {
        Assert-BypassControlAllowed

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $dir = New-UpdateTransactionDirectory $Script:Root
    $zip = Join-Path $dir $Rel.Name
    Write-Color ('Скачиваю ' + $Rel.Name + '...') Cyan
    $r = Invoke-Native $curl ('-s -L -f --ssl-no-revoke --max-time 300 -o "' + $zip + '" "' + $Rel.Url + '"') $dir 320
    if ($r.ExitCode -ne 0 -or -not (Test-Path $zip)) { Write-Color ('Не скачалось (curl код ' + $r.ExitCode + ').') Red; return $false }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if (-not $Rel.Sha256 -or $hash -ne $Rel.Sha256) {
        Write-Color 'Контрольная сумма архива не совпала с GitHub - архив повреждён или подменён, не ставлю.' Red
        Remove-Item -LiteralPath $zip -Force
        return $false
    }
    $x = Join-Path $dir 'x'
    New-Item -ItemType Directory $x | Out-Null
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -x -f $zip -C $x 2>&1 | Out-Null
    $src = Join-Path $x 'zapret'
    $ver = ''
    if (Test-Path (Join-Path $src 'tools\lib.ps1')) { $ver = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $src 'tools\lib.ps1')), "Script:Version\s*=\s*'([^']+)'").Groups[1].Value }
    if (-not (Test-Path (Join-Path $src 'zapret.bat')) -or -not (Test-Path (Join-Path $src 'bin\winws2.exe')) -or ('v' + $ver) -ne $Rel.Tag) {
        Write-Color ('В архиве не то, что ожидалось (версия "' + $ver + '", релиз ' + $Rel.Tag + ') - не ставлю.') Red
        return $false
    }
    $plan = @(Get-UpdatePlan $src $Script:Root)
    $remove = @(Get-RetiredStrategies $src $Script:Root)
    $plan += @(Prepare-UpdateSettings $src $Script:Root $remove)
    # Сначала durable backup+intent, затем остановка: hard kill не должен забыть, что обход работал.
    $was = @(Get-OurProcesses).Count -gt 0
    $backup = Join-Path $dir 'backup'
    if (-not (Install-UpdateFiles $src $Script:Root $backup $plan $remove -WasRunning:$was -BeforeApply {
        Assert-BypassControlAllowed -AllowPendingUpdate
        Add-BypassAction 'update-stop' 'начало'
        Stop-BypassCore -Unload | Out-Null
        Add-BypassAction 'update-stop' 'завершено'
    })) {
        if ($was -and @(Get-OurProcesses).Count -eq 0) { Start-Bypass -Quiet | Out-Null }
        return $false
    }
    # новое меню само включит обход, если он работал (runtime\update-restart.txt)
    # Намерение перезапуска уже сохранено журналом до commit.
    $cleanup = [IO.Path]::GetFullPath($x)
    if ([IO.Path]::GetDirectoryName($cleanup) -eq [IO.Path]::GetFullPath($dir)) { Remove-Item -LiteralPath $cleanup -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Color ('Обновлено до zapret {0}: файлов заменено {1}, старых стратегий убрано {2}. Меню откроется заново.' -f $Rel.Tag, $plan.Count, $remove.Count) Green
    return $true

    } finally { Exit-BypassControl }
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
$Script:IpsetDays = 7
# Игры и античиты: пока они запущены, обход на время теста не выключаем
$Script:GameProcessNames = @('NBA2K*', 'dota2', 'cs2', 'csgo', 'EasyAntiCheat*', 'BEService*', 'FortniteClient*', 'r5apex*',
    'RocketLeague', 'GTA5*', 'TslGame*', 'VALORANT*', 'eldenring', 'FC2*', 'Overwatch', 'destiny2')
function Get-RunningGames {
    return @(Get-Process -Name $Script:GameProcessNames -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
}

# Запрос к планировщику занимает ~0,3 с, а шапка меню перерисовывается после каждого пункта: ответ держим минуту.
# Install/Remove-AutotuneTask сбрасывают его сразу.
$Script:AutotuneTaskCache = $null
function Get-AutotuneTask {
    $c = $Script:AutotuneTaskCache
    if ($c -and ((Get-Date) - $c.Time).TotalSeconds -lt 60) { return $c.Task }
    $task = $null
    if ((Test-TaskExists $Script:AutotuneTask) -ne $false) {
        try { $task = Get-ScheduledTask -TaskName $Script:AutotuneTask -ErrorAction Stop } catch { }
    }
    $Script:AutotuneTaskCache = New-Object PSObject -Property @{ Time = Get-Date; Task = $task }
    return $task
}

# Есть ли задача планировщика - по его ключу в реестре, без модуля ScheduledTasks: первая загрузка модуля стоит ~0,4 с,
# а задач часто нет вовсе. Без прав администратора ключ закрыт - тогда $null, и спрашиваем планировщик как обычно.
function Test-TaskExists([string]$Name) {
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\' + $Name)
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { return $null }
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
    $games = @(Get-RunningGames)
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
        if (-not $info) { $w += 'не удалось определить провайдера; автоподбор отложен, доступность интернета этим не установлена' }
        elseif (-not $info.IsRussia) { $w += ('страна внешнего IP: ' + $info.CountryCode + '; проверьте маршрут перед автоподбором, геолокация сама по себе не доказывает VPN') }
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
        # исключённое вами - первым: эти адреса бывают и в ipset-all, но обход их не трогает
        'исключено'    = (Load-IpSet 'ipset-exclude-user.txt')
        'ipset-all'    = (Load-IpSet 'ipset-all.txt')
        'Take-Two'     = (Load-IpSet 'ipset-taketwo.txt')
        'найден ранее' = (Load-IpSet 'ipset-user.txt')
        'AWS'          = (Load-IpSet 'ipset-aws.txt')
    }
}

# Сети, которые обход трогал у программы, по журналу трекера (runtime\track-last.txt) - чтобы исключить игру из обхода,
# если с ним она работает хуже, чем без него. Голос Discord не берём: он идёт отдельным профилем по портам.
# Возвращает App, Started и Nets (IPv4 - /24, IPv6 - /64, как у сканера).
function Get-TrackBypassedNets([string]$Path = (Join-Path $Script:Runtime 'track-last.txt')) {
    $res = New-Object PSObject -Property @{ App = ''; Started = ''; Nets = @() }
    if (-not (Test-Path $Path)) { return $res }
    $nets = New-Object System.Collections.Generic.List[string]
    $inAll = $false
    foreach ($l in [System.IO.File]::ReadAllLines($Path)) {
        if (-not $res.App -and $l -match 'трекер \((.+)\), начало (.+)$') { $res.App = $matches[1]; $res.Started = $matches[2]; continue }
        if ($l.StartsWith('Все адреса')) { $inAll = $true; continue }
        if (-not $inAll) { continue }
        if ($l -notmatch '^\s+(TCP|UDP) \[?([0-9a-fA-F:.]+?)\]?:(\d+)\s.*\| обход: да(?: \((?:any|user)\))?\s*$') { continue }
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($matches[2], [ref]$ip)) { continue }
        $b = $ip.GetAddressBytes()
        $net = if ($ip.AddressFamily -eq 'InterNetwork') { '{0}.{1}.{2}.0/24' -f $b[0], $b[1], $b[2] }
        else { ([System.Net.IPAddress]::new([byte[]]($b[0..7] + @(0, 0, 0, 0, 0, 0, 0, 0)))).ToString() + '/64' }
        if (-not $nets.Contains($net)) { $nets.Add($net) }
    }
    $res.Nets = @($nets)
    return $res
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

# Что не совпало с релизом zapret2 (пусто - всё в порядке).
# -Cached - для шапки меню: хеши пересчитываются, только если у файлов изменились размер или время. Перед запуском обхода,
# службы, теста и диагностики сверка всегда полная.
$Script:IntegrityCache = $null
function Test-PackageIntegrity([switch]$Cached) {
    $sig = ''
    if ($Cached) {
        $sig = (@($Script:UpstreamHashes.Keys | ForEach-Object {
            $i = Get-Item -LiteralPath (Join-Path $Script:Root $_) -ErrorAction SilentlyContinue
            if ($i) { $_ + ':' + $i.Length + ':' + $i.LastWriteTimeUtc.Ticks } else { $_ + ':-' } }) -join '|')
        if ($Script:IntegrityCache -and $Script:IntegrityCache.Sig -eq $sig) { return $Script:IntegrityCache.Bad }
    }
    $bad = @()
    foreach ($rel in $Script:UpstreamHashes.Keys) {
        $p = Join-Path $Script:Root $rel
        if (-not (Test-Path $p)) { $bad += ($rel + ' - нет файла'); continue }
        if ((Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $Script:UpstreamHashes[$rel]) { $bad += ($rel + ' - изменён') }
    }
    if ($Cached) { $Script:IntegrityCache = New-Object PSObject -Property @{ Sig = $sig; Bad = $bad } }
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
        Remove-ForeignAces $p
        # содержимое - только унаследованные права от защищённой папки
        & $icacls (Join-Path $p '*') /reset /T /C /Q 2>&1 | Out-Null
    }
    foreach ($f in $Script:ProtectedFiles) {
        $p = Join-Path $Script:Root $f
        if (-not (Test-Path $p)) { continue }
        & $icacls $p /setowner '*S-1-5-32-544' /C /Q 2>&1 | Out-Null
        & $icacls $p /inheritance:r @fileGrant /Q 2>&1 | Out-Null
        Remove-ForeignAces $p
    }
}

# Явные права других учётных записей (бывают у папок в профиле пользователя: "Загрузки", рабочий стол) /inheritance:r
# не убирает - а с ними программа без прав администратора могла бы подменить скрипт. Оставляем только наши четыре.
function Remove-ForeignAces([string]$Path) {
    $keep = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545', 'S-1-5-11')
    $sids = @()
    try { $sids = @((Get-Acl -LiteralPath $Path -ErrorAction Stop).Access | ForEach-Object { try { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { } } | Select-Object -Unique) } catch { }
    foreach ($sid in $sids) {
        if ($sid -and $keep -notcontains $sid) { & (Join-Path $env:SystemRoot 'System32\icacls.exe') $Path /remove:g ('*' + $sid) /Q 2>&1 | Out-Null }
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
