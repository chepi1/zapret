# Сканер адресов NBA 2K27: смотрит, с какими серверами и портами общается игра (TCP и UDP),
# и добавляет адреса, которых нет ни в одном списке, в lists\ipset-user.txt.
# UDP-адреса берутся из системного журнала событий сети (ETW Microsoft-Windows-Kernel-Network).
# Совместимо с Windows PowerShell 5.1.
param([int]$Seconds = 180, [string]$ProcessName = 'NBA2K*')

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not (Test-Admin)) { Write-Color 'Нужны права администратора. Запускайте через zapret.bat.' Red; exit 1 }

# ---------- 1. ждём игру ----------

# Кроме самой игры следим за Easy Anti-Cheat: его служба ходит в сеть отдельным процессом.
$EacNames = @('EasyAntiCheat*', 'start_protected_game*')
$procName = @{}    # PID -> имя процесса (запоминаем, чтобы подписать адреса и после выхода процесса)
function Update-Watched {
    foreach ($p in @(Get-Process -Name (@($ProcessName) + $EacNames) -ErrorAction SilentlyContinue)) { $procName[[int]$p.Id] = $p.ProcessName }
}

Write-Color 'Запустите NBA 2K27 (если ещё не запущена). Жду процесс игры...' Cyan
Write-Color 'Обход лучше держать включённым (пункт 1), иначе игра может не дойти до онлайна.' Gray
$procs = @()
$waitUntil = (Get-Date).AddMinutes(15)
while ($procs.Count -eq 0 -and (Get-Date) -lt $waitUntil) {
    $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Start-Sleep -Seconds 2 }
}
if ($procs.Count -eq 0) { Write-Color 'Игра не найдена за 15 минут. Выход.' Red; exit 1 }
$gamePids = @($procs | ForEach-Object { $_.Id })
Update-Watched
Write-Color ('Слежу за: ' + (($procName.Keys | ForEach-Object { $procName[$_] + '.exe (PID ' + $_ + ')' }) -join ', ')) Green
Write-Color ("Сейчас зайдите в онлайн: Город / Парк / Рек / Play Now Online. Слежу {0} сек, Enter - закончить раньше." -f $Seconds) Yellow

# ---------- 2. запись ----------

$session = 'zapretScan'
$etl = Join-Path $Script:Runtime 'scan.etl'
$etwOk = Start-NetTrace $session $etl
if (-not $etwOk) { Write-Color 'Не удалось включить журнал сети ETW: будут найдены только TCP-адреса.' Yellow }

$tcpSeen = @{}     # "ip|port" -> имя процесса
$start = Get-Date
# запись журнала сети останавливаем и при Ctrl+C: иначе она шла бы до перезагрузки
try {
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        Update-Watched
        foreach ($c in @(Get-NetTCPConnection -OwningProcess @($procName.Keys) -ErrorAction SilentlyContinue)) {
            $ra = ([string]$c.RemoteAddress) -replace '^::ffff:', ''
            if ((Test-PublicIp $ra) -and $c.RemotePort -ne 0) { $tcpSeen["$ra|$($c.RemotePort)"] = $procName[[int]$c.OwningProcess] }
        }
        $left = [int]($Seconds - ((Get-Date) - $start).TotalSeconds)
        Write-Host -NoNewline ("`r  осталось {0,3} сек, TCP-соединений найдено: {1}   " -f $left, $tcpSeen.Count)
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { break }
        }
        if (@(Get-Process -Id $gamePids -ErrorAction SilentlyContinue).Count -eq 0) { Write-Host ''; Write-Color 'Игра закрылась.' Yellow; break }
        Start-Sleep -Seconds 2
    }
} finally {
    if ($etwOk) { Stop-NetTrace $session }
}
Write-Host ''

# ---------- 3. разбор журнала ----------

$endpoints = @{}   # "proto|ip|port" -> имя процесса
foreach ($k in $tcpSeen.Keys) { $p = $k.Split('|'); $endpoints["tcp|$($p[0])|$($p[1])"] = $tcpSeen[$k] }

if ($etwOk -and (Test-Path $etl)) {
    Write-Color 'Разбираю журнал сети...' Cyan
    $local = @{}
    foreach ($a in @(Get-NetIPAddress -ErrorAction SilentlyContinue)) { $local[($a.IPAddress -replace '%.*$', '')] = $true }
    $raw = @{}      # proto|remoteIp|remotePortRaw -> имя процесса
    $n = 0
    try {
        Get-WinEvent -Path $etl -Oldest -ErrorAction Stop | ForEach-Object {
            $n++
            if (($n % 20000) -eq 0) { Write-Host -NoNewline "`r  событий: $n   " }
            $e = $_
            if ($e.Properties.Count -lt 6) { return }
            $evPid = [int]$e.Properties[0].Value
            if (-not $procName.ContainsKey($evPid)) { return }
            $proto = if ($Script:EtwUdpIds -contains $e.Id) { 'udp' } else { 'tcp' }
            [xml]$x = $e.ToXml()
            $d = @{}
            foreach ($node in @($x.Event.EventData.Data)) { if ($node -and $node.Name) { $d[$node.Name] = [string]$node.InnerText } }
            if (-not ($d.ContainsKey('daddr') -and $d.ContainsKey('saddr') -and $d.ContainsKey('dport') -and $d.ContainsKey('sport'))) { return }
            $da = Convert-EtwAddr $d.daddr
            $sa = Convert-EtwAddr $d.saddr
            # удалённая сторона = та, что не является адресом этого компьютера
            if ($local.ContainsKey($sa) -and -not $local.ContainsKey($da)) { $rip = $da; $rport = $d.dport }
            elseif ($local.ContainsKey($da) -and -not $local.ContainsKey($sa)) { $rip = $sa; $rport = $d.sport }
            else { $rip = $da; $rport = $d.dport }
            if (-not (Test-PublicIp $rip)) { return }
            $raw["$proto|$rip|$rport"] = $procName[$evPid]
        }
    } catch {
        Write-Color ('Журнал не прочитан: ' + $_.Exception.Message) Yellow
    }
    Write-Host ''

    # Порты в журнале обычно в сетевом порядке байт. Сверяемся с TCP-портами, известными точно; без сверки - переворачиваем.
    $direct = 0; $swapped = 0
    foreach ($k in $raw.Keys) {
        $p = $k.Split('|')
        if ($p[0] -ne 'tcp' -or $p[2] -notmatch '^\d+$') { continue }
        if ($tcpSeen.ContainsKey("$($p[1])|$($p[2])")) { $direct++ }
        if ($tcpSeen.ContainsKey("$($p[1])|$(Swap16 ([int]$p[2]))")) { $swapped++ }
    }
    $needSwap = -not ($direct -gt $swapped)
    foreach ($k in $raw.Keys) {
        $p = $k.Split('|')
        $port = $p[2]
        if ($port -match '^\d+$' -and $needSwap) { $port = [string](Swap16 ([int]$port)) }
        if ($port -eq '0') { continue }
        $key = "$($p[0])|$($p[1])|$port"
        if (-not $endpoints.ContainsKey($key)) { $endpoints[$key] = $raw[$k] }
    }
}

# ---------- 4. отчёт ----------

Write-Color 'Сверяю адреса со списками...' Cyan
$sets = Get-OwnerSets
$ownerText = @{
    'ipset-all'    = 'ipset-all (обход работает)'
    'Take-Two'     = 'сервер 2K (не трогаем: не заблокирован, нужен EAC)'
    'исключено'    = 'исключено вами (ipset-exclude-user.txt)'
    'найден ранее' = 'ipset-user (обход работает)'
    'AWS'          = 'AWS, но НЕТ в ipset-all (обход не трогает)'
    ''             = 'НЕ В СПИСКАХ (обход не трогает)'
}
$rows = @()
foreach ($k in $endpoints.Keys) {
    $p = $k.Split('|')
    $rows += New-Object PSObject -Property @{ Proto = $p[0]; Ip = $p[1]; Port = $p[2]; Proc = $endpoints[$k]; Owner = (Get-Owner $p[1] $sets) }
}
if ($rows.Count -eq 0) {
    Write-Color 'Ничего не найдено. Убедитесь, что во время записи вы были в онлайн-режиме.' Yellow
    Write-Color 'Ручной способ: Монитор ресурсов (resmon) -> Сеть -> отметьте NBA2K27.exe -> "Сетевая активность".' Yellow
    exit 0
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add('zapret v' + $Script:Version + ' - сканер ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ', процессы: ' + (@($procName.Values | Select-Object -Unique) -join ', '))
Write-Color 'Адреса, с которыми общались игра и EAC:' Cyan
foreach ($r in ($rows | Sort-Object Proto, Owner, Ip, Port)) {
    $col = switch ($r.Owner) { 'ipset-all' { 'Gray' } 'найден ранее' { 'Gray' } 'Take-Two' { 'DarkCyan' } default { 'Yellow' } }
    $line = '  {0}  {1,-40} порт {2,-5}  {3,-22} {4}' -f $r.Proto.ToUpper(), $r.Ip, $r.Port, $r.Proc, $ownerText[$r.Owner]
    Write-Color $line $col
    $report.Add($line)
}

$s = Get-Settings
# порт из журнала, который не удалось разобрать, бывает не числом - такие пропускаем
$lowUdp = @($rows | Where-Object { $_.Proto -eq 'udp' -and $_.Port -match '^\d+$' -and [int]$_.Port -lt 1024 -and @('53', '443') -notcontains $_.Port -and $_.Owner -ne 'Take-Two' })
$lowTcp = @($rows | Where-Object { $_.Proto -eq 'tcp' -and $_.Port -match '^\d+$' -and [int]$_.Port -lt 1024 -and @('80', '443') -notcontains $_.Port -and $_.Owner -ne 'Take-Two' })
if ($lowUdp.Count) {
    $line = 'Внимание: игра использует UDP-порты ниже 1024 (' + (($lowUdp | ForEach-Object { $_.Port } | Select-Object -Unique) -join ', ') + '), Game Filter их не покрывает.'
    Write-Color $line Yellow; $report.Add($line)
}
if ($lowTcp.Count) {
    $line = 'Внимание: игра использует TCP-порты ниже 1024 (' + (($lowTcp | ForEach-Object { $_.Port } | Select-Object -Unique) -join ', ') + '), Game Filter их не покрывает.'
    Write-Color $line Yellow; $report.Add($line)
}
if ($s.game -ne 'all') {
    $line = 'Game Filter сейчас: ' + (Get-GameText $s) + '. Для NBA 2K27 нужен режим TCP и UDP (Настройки -> 3).'
    Write-Color $line Yellow; $report.Add($line)
}

# ---------- 5. что добавить ----------
# Предлагаем только адреса вне всех списков и AWS вне ipset-all. Серверы 2K не предлагаем никогда.

$newNets = @()
foreach ($r in ($rows | Where-Object { -not $_.Owner -or $_.Owner -eq 'AWS' })) {
    $a = [System.Net.IPAddress]::Parse($r.Ip)
    $b = $a.GetAddressBytes()
    if ($a.AddressFamily -eq 'InterNetwork') { $newNets += ('{0}.{1}.{2}.0/24' -f $b[0], $b[1], $b[2]) }
    else { $newNets += (([System.Net.IPAddress]::new([byte[]]($b[0..7] + @(0, 0, 0, 0, 0, 0, 0, 0)))).ToString() + '/64') }
}
$newNets = @($newNets | Select-Object -Unique)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$repFile = Join-Path $Script:Runtime ('scan-' + $stamp + '.txt')
if ($newNets.Count) { $report.Add('Не покрыто обходом: ' + ($newNets -join ', ')) } else { $report.Add('Все нужные адреса игры покрыты обходом.') }
Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
Copy-Item $repFile (Join-Path $Script:Runtime 'scan-last.txt') -Force
Write-Color ('Отчёт сохранён: ' + $repFile) Gray

if ($newNets.Count -eq 0) {
    Write-Color 'Все нужные адреса игры уже покрыты обходом. Ничего менять не нужно.' Green
    exit 0
}

Write-Color ('Эти адреса обход сейчас не трогает: ' + ($newNets -join ', ')) White
Write-Color 'Добавляйте, только если игра на них замерзает или вылетает: Flowseal их тоже не трогал.' Gray
if (-not (Read-YesNo 'Добавить в lists\ipset-user.txt?')) { exit 0 }

$f = Join-Path $Script:Lists 'ipset-user.txt'
$text = if (Test-Path $f) { [System.IO.File]::ReadAllText($f) } else { '' }
if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
$text += ('# добавлено сканером ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`r`n") + (($newNets -join "`r`n") + "`r`n")
Write-TextNoBom $f $text
Write-Color 'Список обновлён. winws2 сам его перечитает, перезапуск не нужен.' Green
