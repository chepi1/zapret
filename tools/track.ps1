# Трекер подключений NBA 2K27 (или другой программы, -ProcessName Discord): пока идёт матч / голосовой канал,
# показывает, с какими серверами общаются программа и EAC,
# где они находятся, сколько идёт пакетов, пинг и трогает ли их обход. Всё пишется в runtime\track-*.txt.
# Источник - журнал сети Windows (ETW Kernel-Network), который пишется кусками по $Interval секунд.
# Совместимо с Windows PowerShell 5.1.
# -Replay <файл.etl> -ReplayPid <PID>: один проход по уже записанному журналу (например, runtime\scan.etl) без игры и logman.
param([int]$Interval = 5, [string]$ProcessName = 'NBA2K*', [string]$Replay, [int]$ReplayPid = 0)

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not $Replay -and -not (Test-Admin)) { Write-Color 'Нужны права администратора. Запускайте через zapret.bat.' Red; exit 1 }

$EacNames = @('EasyAntiCheat*', 'start_protected_game*')
$procName = @{}    # PID -> имя процесса (игра и EAC), запоминаем и после выхода процесса
function Update-Watched {
    foreach ($p in @(Get-Process -Name (@($ProcessName) + $EacNames) -ErrorAction SilentlyContinue)) { $procName[[int]$p.Id] = $p.ProcessName }
}

function Get-LocalAddrs {
    $h = @{}
    foreach ($a in @(Get-NetIPAddress -ErrorAction SilentlyContinue)) { $h[($a.IPAddress -replace '%.*$', '')] = $true }
    return $h
}

# ---------- журнал ----------

# События игры и EAC из одного куска журнала: направление, удалённый адрес и порт, размер.
function Read-TraceFile([string]$Etl, $Local) {
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $Etl)) { return $out }
    $pidFilter = (@($procName.Keys) | ForEach-Object { "Data[@Name='PID']=$_" }) -join ' or '
    $events = @()
    try { $events = @(Get-WinEvent -Path $Etl -Oldest -FilterXPath "*[EventData[$pidFilter]]" -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -notmatch 'No events|не найдено|не найдены') {
            # фильтр не сработал - читаем всё и фильтруем сами
            try { $events = @(Get-WinEvent -Path $Etl -Oldest -ErrorAction Stop | Where-Object { $procName.ContainsKey([int]$_.Properties[0].Value) }) } catch { }
        }
    }
    foreach ($e in $events) {
        if ($e.Properties.Count -lt 6) { continue }
        $evPid = [int]$e.Properties[0].Value
        if (-not $procName.ContainsKey($evPid)) { continue }
        $da = Convert-EtwAddr $e.Properties[2].Value
        $sa = Convert-EtwAddr $e.Properties[3].Value
        if ($Local.ContainsKey($sa) -and -not $Local.ContainsKey($da)) { $rip = $da; $rport = $e.Properties[4].Value }
        elseif ($Local.ContainsKey($da) -and -not $Local.ContainsKey($sa)) { $rip = $sa; $rport = $e.Properties[5].Value }
        else { $rip = $da; $rport = $e.Properties[4].Value }
        if (-not (Test-PublicIp $rip)) { continue }
        $dir = if ($Script:EtwSendIds -contains $e.Id) { 'out' } elseif ($Script:EtwRecvIds -contains $e.Id) { 'in' } elseif ($e.Id -eq 14 -or $e.Id -eq 30) { 'retx' } else { 'ctl' }
        $out.Add((New-Object PSObject -Property @{
            Proto = $(if ($Script:EtwUdpIds -contains $e.Id) { 'udp' } else { 'tcp' })
            Ip = $rip; Port = (Swap16 ([int]$rport)); Dir = $dir; Size = [int]$e.Properties[1].Value
            Proc = $procName[$evPid]; Time = $e.TimeCreated
        }))
    }
    return $out
}

# ---------- где находится сервер ----------

$geo = @{}         # ip -> сведения Get-IpInfo (или $false, если не узнали)
$self = $null

# где сервер - по HTTPS (Get-IpInfo), не больше 16 новых адресов за круг: остальные узнаются в следующих
function Update-Geo([string[]]$Ips) {
    $need = @($Ips | Where-Object { -not $geo.ContainsKey($_) } | Select-Object -Unique -First 16)
    if ($need.Count -eq 0) { return }
    $info = Get-IpInfo $need 6
    foreach ($ip in $need) { $geo[$ip] = $(if ($info.ContainsKey($ip)) { $info[$ip] } else { $false }) }
}

# Расстояние по прямой (км) от вас до сервера и нижняя граница пинга: свет в оптоволокне ~200 км/мс в одну сторону
function Get-DistanceKm($G) {
    if (-not $self -or -not $G) { return $null }
    $r = 6371.0
    $toRad = [math]::PI / 180
    $dLat = ([double]$G.lat - $self.Lat) * $toRad
    $dLon = ([double]$G.lon - $self.Lon) * $toRad
    $a = [math]::Sin($dLat / 2) * [math]::Sin($dLat / 2) + [math]::Cos($self.Lat * $toRad) * [math]::Cos([double]$G.lat * $toRad) * [math]::Sin($dLon / 2) * [math]::Sin($dLon / 2)
    return [math]::Round(2 * $r * [math]::Asin([math]::Sqrt($a)))
}

function Get-GeoText([string]$Ip, [int]$Width) {
    $g = $geo[$Ip]
    if ($null -eq $g) { return '...' }
    if (-not $g) { return '?' }
    $place = if ($g.city) { $g.city } else { $g.country }
    $net = if ($g.org) { $g.org } else { $g.isp }
    $t = '{0} {1}, {2}' -f $place, $g.countryCode, $net
    if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width - 1) + '~' }
    return $t
}

# ---------- пинг ----------
# ICMP ко всем активным адресам (асинхронно), а к TCP-серверам, которые не отвечают на ICMP, - время TCP-подключения.

$pingTask = @{}    # ip -> Task<PingReply>
$ping = @{}        # ip -> @{ Min; Last; Ok; Fail; Kind }
$tcpProbeAt = @{}  # "ip|port" -> время последней пробы

function Add-PingSample([string]$Ip, [double]$Ms, [string]$Kind) {
    if (-not $ping.ContainsKey($Ip)) { $ping[$Ip] = @{ Min = $null; Last = $null; Ok = 0; Fail = 0; Kind = $Kind } }
    $p = $ping[$Ip]
    $p.Last = $Ms; $p.Ok++; $p.Kind = $Kind
    if ($null -eq $p.Min -or $Ms -lt $p.Min) { $p.Min = $Ms }
}

function Update-Ping([string[]]$Ips) {
    foreach ($ip in @($pingTask.Keys)) {
        $t = $pingTask[$ip]
        if (-not $t.IsCompleted) { continue }
        $pingTask.Remove($ip)
        $ok = $false
        try { if ($t.Result.Status -eq 'Success') { Add-PingSample $ip ([double]$t.Result.RoundtripTime) 'icmp'; $ok = $true } } catch { }
        if (-not $ok) {
            if (-not $ping.ContainsKey($ip)) { $ping[$ip] = @{ Min = $null; Last = $null; Ok = 0; Fail = 0; Kind = 'icmp' } }
            $ping[$ip].Fail++
        }
    }
    foreach ($ip in ($Ips | Select-Object -First 12)) {
        if ($pingTask.ContainsKey($ip)) { continue }
        # кто трижды не ответил на ICMP и ни разу не ответил - больше не мучаем
        if ($ping.ContainsKey($ip) -and $ping[$ip].Kind -eq 'icmp' -and $ping[$ip].Ok -eq 0 -and $ping[$ip].Fail -ge 3) { continue }
        try { $pingTask[$ip] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip, 1000) } catch { }
    }
}

function Invoke-TcpProbe([string]$Ip, [int]$Port) {
    $key = "$Ip|$Port"
    if ($tcpProbeAt.ContainsKey($key) -and ((Get-Date) - $tcpProbeAt[$key]).TotalSeconds -lt 20) { return }
    $tcpProbeAt[$key] = Get-Date
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $t = $c.ConnectAsync($Ip, $Port)
        if ($t.Wait(1000) -and $c.Connected) { $sw.Stop(); Add-PingSample $Ip $sw.Elapsed.TotalMilliseconds 'tcp' }
    } catch { } finally { $c.Close() }
}

function Get-PingText([string]$Ip) {
    if (-not $ping.ContainsKey($Ip)) { return '...' }
    $p = $ping[$Ip]
    if ($p.Ok -eq 0) { return $(if ($p.Fail -ge 3) { 'молчит' } else { '...' }) }
    $suffix = if ($p.Kind -eq 'tcp') { 't' } else { '' }
    return ('{0:N0}{1}' -f $p.Min, $suffix)
}

# ---------- кто обрабатывается обходом ----------

$settings = Get-Settings
function Get-BypassText([string]$Owner, [string]$Proto, [int]$Port) {
    if ($Owner -eq 'Take-Two') { return 'нет (2K)' }
    if ($Owner -eq 'Valve') { return 'нет (Valve)' }
    # голос Discord: отдельный профиль по портам и распознаванию протокола, списки не нужны
    if ($Proto -eq 'udp' -and (($Port -ge 19294 -and $Port -le 19344) -or ($Port -ge 50000 -and $Port -le 50100))) { return 'да (голос)' }
    $gameOn = ($Proto -eq 'tcp' -and @('all', 'tcp') -contains $settings.game) -or ($Proto -eq 'udp' -and @('all', 'udp') -contains $settings.game)
    $portOk = ($Port -ge 1024 -and $gameOn) -or ($Proto -eq 'tcp' -and @(80, 443, 8443) -contains $Port) -or ($Proto -eq 'udp' -and $Port -eq 443)
    if (-not $portOk) { return 'нет (порт)' }
    if ($settings.ipset -eq 'any') { return 'да (any)' }
    if ($Owner -eq 'найден ранее') { return 'да (user)' }
    if ($Owner -eq 'ipset-all' -and $settings.ipset -eq 'loaded') { return 'да' }
    return 'нет (списки)'
}

function Format-Endpoint([string]$Ip, $Port, [int]$Width) {
    $t = if ($Ip -match ':') { "[$Ip]:$Port" } else { "$($Ip):$Port" }
    if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width - 1) + '~' }
    return $t
}

# ---------- старт ----------

$AppName = if ($ProcessName -like 'NBA2K*') { 'NBA 2K27' } else { $ProcessName.TrimEnd('*') }
try { $Host.UI.RawUI.WindowTitle = $AppName + ' - трекер подключений' } catch { }
Write-Color ('Трекер подключений: ' + $AppName) Cyan
Write-Color 'Готовлю списки и определяю ваше местоположение...' Gray
$sets = Get-OwnerSets
$self = Get-DirectConnectionInfo
$warn = @(Get-ProxyWarnings)
$tun = @(Get-TunAdapters)
# ExitLag и т.п.: перехватывают трафик игры и Discord вместе с обходом (с ExitLag голос Discord уходит без ответа)
$boosters = @(if (-not $Replay) { Get-GameBoosters })

if ($Replay) {
    $procName[$ReplayPid] = 'NBA2K27'
    $gamePids = @()
} else {
    Write-Color ('Запустите {0} (если ещё не запущен). Жду процесс...' -f $AppName) Cyan
    $procs = @()
    $waitUntil = (Get-Date).AddMinutes(15)
    while ($procs.Count -eq 0 -and (Get-Date) -lt $waitUntil) {
        $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { Start-Sleep -Seconds 2 }
    }
    if ($procs.Count -eq 0) { Write-Color ('{0} не найден за 15 минут. Выход.' -f $AppName) Red; exit 1 }
    $gamePids = @($procs | ForEach-Object { $_.Id })
    Update-Watched
}

$stamp = if ($Replay) { 'replay' } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
$logFile = Join-Path $Script:Runtime ('track-' + $stamp + '.txt')
if (Test-Path $logFile) { Remove-Item $logFile -Force }
$log = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$Line) {
    $log.Add($Line)
    [System.IO.File]::AppendAllText($logFile, $Line + "`r`n", $Script:Utf8NoBom)
}
Write-Log ('zapret v' + $Script:Version + ' - трекер (' + $AppName + '), начало ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Log ('Обход: ' + $(if (@(Get-OurProcesses).Count) { 'работает, ' + (Get-AltText $settings) } else { 'НЕ запущен' }) + '. Game Filter: ' + (Get-GameText $settings) + '. IPSet: ' + $settings.ipset)
foreach ($x in @(Get-RingsText $settings)) { Write-Log ('  свой круг - ' + $x) }
if ($self) { Write-Log ('Вы: {0}, {1} ({2})' -f $self.City, $self.CountryCode, $self.Isp) }
foreach ($w in $warn) { Write-Log ('Прокси/VPN: ' + $w) }
foreach ($a in $tun) { Write-Log ('VPN/TUN-адаптер: ' + $a.Name) }
foreach ($b in $boosters) { Write-Log ('Игровой ускоритель: ' + $b + ' - ' + $Script:BoosterHint) }
Write-Log ('Процессы: ' + (($procName.Keys | ForEach-Object { $procName[$_] + ' (PID ' + $_ + ')' }) -join ', '))
Write-Log 'Пинг: мс по ICMP; "t" - время TCP-подключения (сервер не отвечает на ICMP); "молчит" - не отвечает совсем.'
Write-Log ''

# Ходит ли программа через локальный прокси (Happ, v2rayN и т.п. в режиме системного прокси).
# Тогда её TCP идёт через прокси, а UDP (голос, игра) - напрямую мимо него: чат работает, голос - нет.
function Get-ProxyPorts {
    $ports = @{}
    foreach ($p in @(Get-Process -Name $Script:ProxyProcessNames -ErrorAction SilentlyContinue)) {
        foreach ($l in @(Get-NetTCPConnection -OwningProcess $p.Id -State Listen -ErrorAction SilentlyContinue)) { $ports[[int]$l.LocalPort] = $p.ProcessName }
    }
    return $ports
}
function Get-ProxyUse($ProxyPorts) {
    if (-not $ProxyPorts -or $ProxyPorts.Count -eq 0) { return @() }
    $hits = @()
    foreach ($c in @(Get-NetTCPConnection -OwningProcess @($procName.Keys) -State Established -ErrorAction SilentlyContinue)) {
        $ra = [string]$c.RemoteAddress
        if (($ra -eq '127.0.0.1' -or $ra -eq '::1') -and $ProxyPorts.ContainsKey([int]$c.RemotePort)) {
            $hits += ('{0}:{1} ({2})' -f $ra, $c.RemotePort, $ProxyPorts[[int]$c.RemotePort])
        }
    }
    return @($hits | Select-Object -Unique)
}
$proxyPorts = Get-ProxyPorts
$proxyUse = @()
$proxyLogged = $false

# UDP-серверы, которым программа шлёт, а в ответ не приходит ничего: провайдер режет или сервер молчит
function Get-UdpNoReply {
    return @($ep.Values | Where-Object { $_.Proto -eq 'udp' -and $_.Out -ge 20 -and $_.In -eq 0 } | Sort-Object Out -Descending)
}

$ep = @{}          # "proto|ip|port" -> статистика
$matchKey = $null
$matchHistory = New-Object System.Collections.Generic.List[string]
$matchStats = [ordered]@{}   # "ip|port" -> скорости по интервалам для итога

# Итог: серверы матча с их статистикой и все адреса. $Final = $false - промежуточный (трекер ещё работает).
function Get-SummaryLines([bool]$Final) {
    $s = New-Object System.Collections.Generic.List[string]
    $s.Add('')
    $head = if ($Final) { 'Итог ' } else { 'Итог на ' }
    $tail = if ($Final) { '' } else { ' (промежуточный: трекер ещё работает, итог обновляется раз в минуту)' }
    $s.Add($head + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', длительность ' + ('{0:hh\:mm\:ss}' -f ((Get-Date) - $startTime)) + $tail)
    if ($proxyUse.Count) {
        $s.Add(('ВНИМАНИЕ: {0} ходит через локальный прокси {1}. TCP идёт через прокси, а UDP (голос, игра) - напрямую мимо него.' -f $AppName, ($proxyUse -join ', ')))
    }
    if ($boosters.Count) {
        $s.Add(('ВНИМАНИЕ: работал игровой ускоритель {0}: он {1}.' -f ($boosters -join ', '), $Script:BoosterHint))
    }
    $noReply = @(Get-UdpNoReply)
    if ($noReply.Count) {
        $why = if ($boosters.Count) { 'скорее всего виноват ' + ($boosters -join ', ') } else { 'провайдер режет или сервер недоступен' }
        $s.Add('UDP без ответа (программа шлёт, сервер не отвечает - ' + $why + '):')
        foreach ($x in $noReply) { $s.Add(('  {0} | вых {1}, вх 0 | {2} | обход: {3}' -f (Format-Endpoint $x.Ip $x.Port 46), $x.Out, (Get-GeoText $x.Ip 50), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port)))) }
    }
    if ($matchStats.Count) {
        $s.Add('Главный UDP-сервер - матч / голос (скорость - пакетов в секунду по реальному времени интервалов):')
        foreach ($k in $matchStats.Keys) {
            $ms = $matchStats[$k]
            # первый и последний интервал матча неполные - в минимум и провалы их не берём
            $core = if ($ms.In.Count -gt 4) { $ms.In.GetRange(1, $ms.In.Count - 2) } else { $ms.In }
            $sorted = @($core | Sort-Object)
            $med = if ($sorted.Count) { $sorted[[int][math]::Floor($sorted.Count / 2)] } else { 0 }
            $dips = @($core | Where-Object { $_ -lt $med * 0.5 }).Count
            $s.Add(('  {0} | {1} | {2:HH:mm:ss}-{3:HH:mm:ss} ({4:hh\:mm\:ss}) | вых/вх в среднем {5:N1}/{6:N1}, вх: мин {7:N1} медиана {8:N1} макс {9:N1}, провалов ниже половины медианы: {10} | пинг {11}' -f
                (Format-Endpoint $ms.Ip $ms.Port 46), (Get-GeoText $ms.Ip 50), $ms.First, $ms.Last, ($ms.Last - $ms.First),
                ($ms.Out / [math]::Max($ms.Sec, 1)), ($ms.InTotal / [math]::Max($ms.Sec, 1)),
                $(if ($sorted.Count) { $sorted[0] } else { 0 }), $med, $(if ($sorted.Count) { $sorted[-1] } else { 0 }), $dips, (Get-PingText $ms.Ip)))
        }
    } else { $s.Add('Активный UDP-сервер (матч / голос) не обнаружен.') }
    $s.Add('Все адреса (пакетов всего вых/вх, повторных отправок TCP, мин. пинг, где, обход):')
    foreach ($x in ($ep.Values | Sort-Object @{ Expression = { $_.Out + $_.In }; Descending = $true })) {
        $dist = Get-DistanceKm $geo[$x.Ip]
        $s.Add(('  {0} {1,-46} {2,-10} {3,6}/{4,-6} retx {5,-3} пинг {6,-7} {7}{8} | обход: {9}' -f $x.Proto.ToUpper(), (Format-Endpoint $x.Ip $x.Port 46), $x.Proc,
            $x.Out, $x.In, $x.Retx, (Get-PingText $x.Ip), (Get-GeoText $x.Ip 60), $(if ($dist) { " | ~$dist км" } else { '' }), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port))))
    }
    return $s
}

# Лог целиком + итог. Пишется раз в минуту, поэтому при закрытии окна крестиком теряется не больше минуты.
function Save-Track([bool]$Final) {
    $all = @($log) + @(Get-SummaryLines $Final)
    [System.IO.File]::WriteAllText($logFile, (($all -join "`r`n") + "`r`n"), $Script:Utf8NoBom)
    if (-not $Replay) { Copy-Item $logFile (Join-Path $Script:Runtime 'track-last.txt') -Force }
}
$session = 'zapretTrack'
$etlFiles = @((Join-Path $Script:Runtime 'track-a.etl'), (Join-Path $Script:Runtime 'track-b.etl'))
$cur = 0
$local = Get-LocalAddrs
$startTime = Get-Date
$lastSave = Get-Date
$quit = $false

if (-not $Replay -and -not (Start-NetTrace $session $etlFiles[$cur])) {
    Write-Color 'Не удалось включить журнал сети Windows (logman). Без него трекер не работает.' Red
    exit 1
}
$chunkStart = Get-Date   # начало текущего куска журнала: скорость считаем по его реальной длительности

try {
    while (-not $quit) {
        if ($Replay) {
            $done = $Replay
            $quit = $true
            $gameAlive = $true
        } else {
            # ждём интервал, слушая клавиши
            $until = (Get-Date).AddSeconds($Interval)
            while ((Get-Date) -lt $until) {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if (@('Q', 'Enter', 'Escape') -contains [string]$k.Key -or $k.KeyChar -eq 'й' -or $k.KeyChar -eq 'Й') { $quit = $true; break }
                }
                Start-Sleep -Milliseconds 200
            }
            $gameAlive = @(Get-Process -Id $gamePids -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $gameAlive) { $quit = $true }

            # переключаем кусок журнала и разбираем предыдущий; длительность куска - реальная, а не $Interval:
            # на медленном ПК разбор журнала растягивает круг, и деление на 5 с завышало бы скорость
            $chunkSec = ((Get-Date) - $chunkStart).TotalSeconds
            Stop-NetTrace $session
            $done = $etlFiles[$cur]
            $cur = 1 - $cur
            if (-not $quit) { Start-NetTrace $session $etlFiles[$cur] | Out-Null; $chunkStart = Get-Date }
        }
        Update-Watched
        if ((((Get-Date) - $startTime).TotalSeconds % 60) -lt $Interval) { $local = Get-LocalAddrs }
        $recs = Read-TraceFile $done $local
        $now = Get-Date
        if ($Replay) {
            $times = @($recs | ForEach-Object { $_.Time } | Sort-Object)
            $chunkSec = if ($times.Count -gt 1) { ($times[-1] - $times[0]).TotalSeconds } else { $Interval }
        }
        if ($chunkSec -lt 1) { $chunkSec = 1 }

        foreach ($k in @($ep.Keys)) { $ep[$k].IOut = 0; $ep[$k].IIn = 0; $ep[$k].IBytes = 0; $ep[$k].IRetx = 0 }
        foreach ($r in $recs) {
            $key = "$($r.Proto)|$($r.Ip)|$($r.Port)"
            if (-not $ep.ContainsKey($key)) {
                $ep[$key] = @{ Proto = $r.Proto; Ip = $r.Ip; Port = $r.Port; Proc = $r.Proc; First = $now; Last = $now
                    Out = 0; In = 0; Bytes = 0; Retx = 0; IOut = 0; IIn = 0; IBytes = 0; IRetx = 0; Owner = (Get-Owner $r.Ip $sets); Logged = $false }
            }
            $x = $ep[$key]
            $x.Last = $now
            switch ($r.Dir) {
                'out'  { $x.Out++; $x.IOut++; $x.Bytes += $r.Size; $x.IBytes += $r.Size }
                'in'   { $x.In++; $x.IIn++; $x.Bytes += $r.Size; $x.IBytes += $r.Size }
                'retx' { $x.Retx++; $x.IRetx++ }
            }
        }

        $active = @($ep.Values | Where-Object { ($now - $_.Last).TotalSeconds -le 30 } |
            Sort-Object @{ Expression = { $_.IOut + $_.IIn }; Descending = $true }, @{ Expression = { $_.Out + $_.In }; Descending = $true })
        Update-Geo @($active | ForEach-Object { $_.Ip })
        Update-Ping @($active | ForEach-Object { $_.Ip } | Select-Object -Unique)
        # TCP-серверы, молчащие на ICMP: пробуем подключением (не больше трёх за круг)
        $probes = 0
        foreach ($x in ($active | Where-Object { $_.Proto -eq 'tcp' })) {
            if ($probes -ge 3) { break }
            $p = $ping[$x.Ip]
            if ($p -and $p.Kind -eq 'icmp' -and $p.Ok -eq 0 -and $p.Fail -ge 1) { Invoke-TcpProbe $x.Ip ([int]$x.Port); $probes++ }
        }

        # новые адреса - в лог
        foreach ($x in $ep.Values) {
            if ($x.Logged -or $null -eq $geo[$x.Ip]) { continue }
            $x.Logged = $true
            $g = $geo[$x.Ip]
            $dist = Get-DistanceKm $g
            Write-Log (('{0:HH:mm:ss} новый  {1} {2,-44} {3,-10} {4}{5} | обход: {6}' -f $x.First, $x.Proto.ToUpper(), (Format-Endpoint $x.Ip $x.Port 44), $x.Proc,
                (Get-GeoText $x.Ip 60), $(if ($dist) { " | ~$dist км" } else { '' }), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port))))
        }

        # повторные отправки TCP - в лог сразу (признак потерь или блока)
        foreach ($x in ($ep.Values | Where-Object { $_.IRetx -gt 0 })) {
            Write-Log ('{0:HH:mm:ss} retx   {1} {2,-44} x{3} | {4} | обход: {5}' -f $now, $x.Proto.ToUpper(), (Format-Endpoint $x.Ip $x.Port 44), $x.IRetx,
                (Get-GeoText $x.Ip 50), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port)))
        }

        # сервер матча: UDP с наибольшим числом пакетов за интервал (не меньше 5 пакетов в секунду)
        $m = $active | Where-Object { $_.Proto -eq 'udp' -and ($_.IOut + $_.IIn) -ge ($chunkSec * 5) } | Select-Object -First 1
        if ($m) {
            $mk = "$($m.Ip)|$($m.Port)"
            if ($mk -ne $matchKey) {
                $matchKey = $mk
                $line = '{0:HH:mm:ss} МАТЧ   {1} | {2}' -f $now, (Format-Endpoint $m.Ip $m.Port 44), (Get-GeoText $m.Ip 60)
                $matchHistory.Add($line)
                Write-Log $line
            }
            if (-not $matchStats.Contains($mk)) {
                $matchStats[$mk] = @{ Ip = $m.Ip; Port = $m.Port; First = $now; Last = $now; Sec = 0.0; Out = 0; InTotal = 0
                    In = (New-Object System.Collections.Generic.List[double]) }
            }
            $ms = $matchStats[$mk]
            $ms.Last = $now; $ms.Sec += $chunkSec; $ms.Out += $m.IOut; $ms.InTotal += $m.IIn
            $ms.In.Add([math]::Round($m.IIn / $chunkSec, 1))
            Write-Log ('{0:HH:mm:ss} матч   {1} пак/с {2:N1}/{3:N1} (вых/вх), {4:N0} кбит/с, интервал {5:N1} с, пинг {6}' -f $now, (Format-Endpoint $m.Ip $m.Port 44),
                ($m.IOut / $chunkSec), ($m.IIn / $chunkSec), ($m.IBytes * 8 / 1000 / $chunkSec), $chunkSec, (Get-PingText $m.Ip))
        }
        # программа ходит через локальный прокси? (проверяем каждый круг, порты прокси - раз в минуту)
        if (-not $Replay) {
            if ((((Get-Date) - $startTime).TotalSeconds % 60) -lt $Interval) {
                $proxyPorts = Get-ProxyPorts
                foreach ($b in @(Get-GameBoosters | Where-Object { $boosters -notcontains $_ })) {
                    $boosters = @($boosters) + $b
                    Write-Log ('{0:HH:mm:ss} запущен игровой ускоритель {1} - {2}' -f $now, $b, $Script:BoosterHint)
                }
            }
            $pu = @(Get-ProxyUse $proxyPorts)
            if ($pu.Count) { $proxyUse = @(@($proxyUse) + $pu | Select-Object -Unique) }
            if ($proxyUse.Count -and -not $proxyLogged) {
                $proxyLogged = $true
                Write-Log ('{0:HH:mm:ss} ВНИМАНИЕ: {1} ходит через локальный прокси {2}: TCP через прокси, UDP (голос, игра) - напрямую мимо него' -f $now, $AppName, ($proxyUse -join ', '))
            }
        }
        foreach ($x in @(Get-UdpNoReply | Where-Object { -not $_.NoReplyLogged })) {
            $x.NoReplyLogged = $true
            Write-Log ('{0:HH:mm:ss} нет ответа UDP {1} (вых {2}, вх 0) | {3} | обход: {4}' -f $now, (Format-Endpoint $x.Ip $x.Port 44), $x.Out, (Get-GeoText $x.Ip 50), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port)))
        }
        if (((Get-Date) - $lastSave).TotalSeconds -ge 60) { Save-Track $false; $lastSave = Get-Date }

        # ---------- экран ----------
        Clear-Host
        $el = $now - $startTime
        Write-Color ('=== Трекер: {3} === {0:HH:mm:ss}, идёт {1:hh\:mm\:ss}, интервал {2:N1} с. Q или Enter - выход (итог сохраняется и так раз в минуту).' -f $now, $el, $chunkSec, $AppName) Cyan
        $by = if (@(Get-OurProcesses).Count) { 'работает, ' + (Get-AltText $settings) } else { 'НЕ ЗАПУЩЕН' }
        Write-Color ('Обход: ' + $by) $(if (@(Get-OurProcesses).Count) { 'Gray' } else { 'Yellow' })
        if ($tun.Count) { Write-Color ('! VPN в режиме TUN: трафик идёт через него, а не напрямую.') Red }
        if ($boosters.Count) { Write-Color ('! Игровой ускоритель {0}: {1}.' -f ($boosters -join ', '), $Script:BoosterHint) Red }
        if ($proxyUse.Count) { Write-Color ('! {0} ходит через локальный прокси {1}: TCP через прокси, а UDP (голос, игра) напрямую мимо него. Выйдите из прокси-клиента полностью.' -f $AppName, ($proxyUse -join ', ')) Red }
        if ($m) {
            $g = $geo[$m.Ip]
            $dist = Get-DistanceKm $g
            Write-Color ('ГЛАВНЫЙ UDP - МАТЧ / ГОЛОС: {0}  {1}' -f (Format-Endpoint $m.Ip $m.Port 45), (Get-GeoText $m.Ip 60)) Green
            $pt = Get-PingText $m.Ip
            $min = if ($dist) { ' | по прямой ~{0} км, физический минимум пинга ~{1} мс' -f $dist, [math]::Round($dist / 100) } else { '' }
            Write-Color ('  пинг {0} мс{1} | обход: {2}' -f $pt, $min, (Get-BypassText $m.Owner 'udp' ([int]$m.Port))) Green
        } else {
            Write-Color 'Активного UDP пока нет: зайдите в матч / голосовой канал.' Yellow
        }
        $nr = @(Get-UdpNoReply)
        if ($nr.Count) { Write-Color ('UDP без ответа (' + $(if ($boosters.Count) { 'скорее всего из-за ' + ($boosters -join ', ') } else { 'провайдер режет или сервер молчит' }) + '): ' + (($nr | Select-Object -First 4 | ForEach-Object { (Format-Endpoint $_.Ip $_.Port 40) + ' вых ' + $_.Out }) -join ', ')) Red }
        Write-Host ''
        Write-Color ('{0,-4} {1,-32} {2,-9} {3,9} {4,6} {5,7} {6,-34} {7}' -f 'Прот', 'Адрес:порт', 'Процесс', 'вых/вх/с', 'кбит/с', 'пинг', 'Где, сеть', 'Обход') DarkCyan
        foreach ($x in ($active | Select-Object -First 16)) {
            $line = '{0,-4} {1,-32} {2,-9} {3,9} {4,6:N0} {5,7} {6,-34} {7}' -f $x.Proto.ToUpper(), (Format-Endpoint $x.Ip $x.Port 32),
                $(if ($x.Proc.Length -gt 9) { $x.Proc.Substring(0, 9) } else { $x.Proc }),
                ('{0:N0}/{1:N0}' -f ($x.IOut / $chunkSec), ($x.IIn / $chunkSec)), ($x.IBytes * 8 / 1000 / $chunkSec),
                (Get-PingText $x.Ip), (Get-GeoText $x.Ip 34), (Get-BypassText $x.Owner $x.Proto ([int]$x.Port))
            $col = if ($m -and $x.Ip -eq $m.Ip -and $x.Port -eq $m.Port) { 'Green' } elseif ($x.Retx) { 'Yellow' } else { 'Gray' }
            Write-Color $line $col
        }
        $retx = @($active | Where-Object { $_.Retx -gt 0 })
        if ($retx.Count) { Write-Color ('Повторные отправки TCP (признак потерь или блока): ' + (($retx | ForEach-Object { (Format-Endpoint $_.Ip $_.Port 40) + ' x' + $_.Retx }) -join ', ')) Yellow }
        Write-Host ''
        Write-Color ('Лог: ' + $logFile) DarkGray
        if (-not $gameAlive) { Write-Color ('{0} закрылся.' -f $AppName) Yellow }
    }
} finally {
    Stop-NetTrace $session
    foreach ($f in $etlFiles) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

# ---------- итог ----------
Save-Track $true
Write-Host ''
Write-Color ('Готово. Лог: ' + $logFile) Green
Write-Color 'Копия - runtime\track-last.txt: её можно переслать или приложить к issue на GitHub.' Gray
