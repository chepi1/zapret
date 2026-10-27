# Автоподбор ALT: без обхода и с каждой ALT по отдельности проверяет то, что режет провайдер,
# и предлагает сделать лучшую основной. Запускается из меню (zapret.bat). Совместимо с Windows PowerShell 5.1.
#  - замерзание 16-20 КБ: POST 64 КБ на сайты в AWS, Cloudflare, Hetzner и других хостингах (набор dpi-checkers, как у Flowseal);
#  - Discord, YouTube, 2K и EAC из tools\targets.txt;
#  - вред: незаблокированные сайты на разных CDN (группа Clean) не должны перестать открываться или замедлиться.
# Лучшая стратегия - с наибольшим "пробито минус вред".
# Сеть шумит, поэтому адрес, который не открылся, сразу проверяется второй раз той же стратегией:
# открылся со второй попытки - полбалла ("нестабильно"); вред - только если сбой или медленный TLS повторились.
# Во время теста IPSet временно "any", чтобы проверочные сайты точно попали под обход (так же делает тест Flowseal).
# -ReportOnly: только отчёт (для проверки провайдера) - основную стратегию не меняем и обход сами не включаем.
# -Full: все стратегии (27), иначе быстрый - основные 9 и те, что сейчас в кругах автосмены (Get-TestStrategies).
param([int]$TimeoutSec = 5, [int]$Parallel = 16, [int]$Rounds = 1, [switch]$NoPrompt, [switch]$ReportOnly, [switch]$Full)

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not (Test-Admin)) { Write-Color 'Нужны права администратора. Запускайте через zapret.bat.' Red; exit 1 }
if (Test-AutotuneRunning) {
    Write-Color 'Сейчас идёт автонастройка по расписанию: она сама проверяет стратегии и включит обход обратно через несколько минут.' Yellow
    exit 0
}

$GroupNames = [ordered]@{ DPI = '16-20 КБ'; Discord = 'Discord'; YouTube = 'YouTube'; SoundCloud = 'SoundCloud'; NBA2K = '2K'; EAC = 'EAC/Epic'; Clean = 'без блока' }
$HarmSlowMs = 500   # насколько медленнее рукопожатие TLS, чем без обхода, считается вредом
# Если заблокированных адресов не открылось больше этого, сбои у стратегии не случайные: повторяем только
# незаблокированные сайты (вред), иначе слабые стратегии добавили бы к тесту по 15-20 секунд без пользы
$RetryMax = 16

function Read-Targets {
    $list = @()
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'targets.txt'))) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^([A-Za-z0-9]+)\.([A-Za-z0-9_]+)\s*=\s*(https?://\S+)$') {
            $list += New-Object PSObject -Property @{ Group = $matches[1]; Name = $matches[2]; Url = $matches[3]; Post = $false }
        }
    }
    return $list
}

# Набор хостингов для проверки 16-20 КБ: свежий с hyperion-cs.github.io (его же берёт Flowseal), иначе копия из пакета.
function Read-DpiSuite {
    $fresh = Join-Path $Script:Runtime 'dpi-suite.json'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $r = Invoke-Native $curl ('-s -f --noproxy "*" --ssl-no-revoke --max-time 8 -o "' + $fresh + '" "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"') $Script:Runtime 15
    $bundled = Join-Path $PSScriptRoot 'dpi-suite.json'
    $items = $null
    # ConvertFrom-Json в PowerShell 5.1 отдаёт JSON-массив одним объектом, поэтому без конвейера
    foreach ($file in @($(if ($r.ExitCode -eq 0 -and (Test-Path $fresh)) { $fresh }), $bundled)) {
        if (-not $file) { continue }
        try { $items = ConvertFrom-Json ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)) } catch { $items = $null }
        if ($items -and @($items).Count -gt 1) { break }
    }
    $list = @()
    foreach ($x in @($items)) {
        if (-not $x) { continue }
        $h = $x.PSObject.Properties['host']
        if (-not $h -or -not $h.Value) { continue }
        $id = $x.PSObject.Properties['id']; $prov = $x.PSObject.Properties['provider']
        $name = ('' + $(if ($id) { $id.Value }) + ' ' + $(if ($prov) { $prov.Value })).Trim()
        $list += New-Object PSObject -Property @{ Group = 'DPI'; Name = $name; Url = ('https://' + $h.Value + '/'); Post = $true }
    }
    return $list
}

function Get-PostFile {
    $f = Join-Path $Script:Runtime 'post64k.bin'
    if (-not (Test-Path $f) -or (Get-Item $f).Length -ne 65536) {
        $bytes = New-Object byte[] 65536
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        [System.IO.File]::WriteAllBytes($f, $bytes)
    }
    return $f
}

function Convert-CurlResult($Item) {
    $parts = @($Item.Out.Result.Trim() -split '\s+')
    $code = '000'; $up = 0.0; $down = 0.0; $conn = 0.0; $tls = 0.0
    if ($parts.Count -ge 5) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $code = $parts[0]
        try {
            $up = [double]::Parse($parts[1], $inv); $down = [double]::Parse($parts[2], $inv)
            $conn = [double]::Parse($parts[3], $inv); $tls = [double]::Parse($parts[4], $inv)
        } catch { }
    }
    $exit = $Item.P.ExitCode
    $state = 'FAIL'
    if ($exit -eq 6) { $state = 'NA' }                                   # домен не резолвится: адрес не учитываем
    elseif ($code -ne '000') { $state = 'OK' }
    elseif ($exit -eq 28 -and $Item.T.Post -and $up -gt 0 -and $down -eq 0) { $state = 'FREEZE' }   # отправка встала: блок 16-20 КБ
    elseif ($exit -eq 28 -and -not $Item.T.Post -and $down -gt 0) { $state = 'FREEZE' }             # загрузка встала
    return New-Object PSObject -Property @{
        Group = $Item.T.Group; Name = $Item.T.Name; Url = $Item.T.Url; State = $state; Code = $code; Exit = $exit
        Up = $up; Down = $down; ConnMs = [math]::Round($conn * 1000); TlsMs = [math]::Round($tls * 1000)
        Tries = 1; Flaky = $false
    }
}

# Запускает curl.exe параллельно (не больше $Width, по умолчанию $Parallel, одновременно) и собирает результаты.
function Invoke-CurlBatch($Targets, [string]$PostFile, [int]$Width = 0) {
    if ($Width -le 0) { $Width = $Parallel }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $queue = New-Object System.Collections.Queue
    foreach ($t in $Targets) { $queue.Enqueue($t) }
    $running = New-Object System.Collections.ArrayList
    $results = @()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Width) {
            $t = $queue.Dequeue()
            $a = '-s -o NUL --noproxy "*" --ssl-no-revoke --http1.1 --max-time ' + $TimeoutSec + ' --connect-timeout 4 -r 0-65535' +
                 ' -w "%{http_code} %{size_upload} %{size_download} %{time_connect} %{time_appconnect}"'
            if ($t.Post) { $a += ' -X POST --data-binary "@' + $PostFile + '"' }
            $a += ' "' + $t.Url + '"'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = $a
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$running.Add((New-Object PSObject -Property @{ T = $t; P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Started = (Get-Date) }))
        }
        Start-Sleep -Milliseconds 100
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.P.HasExited -or ((Get-Date) - $r.Started).TotalSeconds -gt ($TimeoutSec + 5)) {
                if (-not $r.P.HasExited) { try { $r.P.Kill() } catch { } }
                $r.P.WaitForExit()
                $results += Convert-CurlResult $r
                $running.RemoveAt($i)
            }
        }
    }
    return $results
}

function Get-RowKey($R) { return ($R.Group + '|' + $R.Name + '|' + $R.Url) }

# Что проверить второй раз: не открывшееся (FAIL/FREEZE) и незаблокированные сайты с медленным TLS.
function Get-RetryTargets($Targets, $Rows, $CleanBase) {
    $blocked = @($Rows | Where-Object { $_.Group -ne 'Clean' -and ($_.State -eq 'FAIL' -or $_.State -eq 'FREEZE') })
    $keys = @{}
    if ($blocked.Count -le $RetryMax) { foreach ($r in $blocked) { $keys[(Get-RowKey $r)] = $true } }
    foreach ($r in @($Rows | Where-Object { $_.Group -eq 'Clean' })) {
        $slow = $r.State -eq 'OK' -and $CleanBase -and $CleanBase.ContainsKey($r.Name) -and $r.TlsMs -gt $CleanBase[$r.Name] + $HarmSlowMs
        if ($r.State -eq 'FAIL' -or $r.State -eq 'FREEZE' -or $slow) { $keys[(Get-RowKey $r)] = $true }
    }
    return @($Targets | Where-Object { $keys.ContainsKey((Get-RowKey $_)) })
}

# Две попытки одного адреса - в одну строку: открылся хотя бы раз - OK (со второго раза - Flaky), TLS и TCP - лучшие.
function Merge-Retry($Rows, $Retry) {
    $map = @{}
    foreach ($x in $Retry) { $map[(Get-RowKey $x)] = $x }
    foreach ($r in $Rows) {
        $k = Get-RowKey $r
        if (-not $map.ContainsKey($k)) { continue }
        $x = $map[$k]
        $r.Tries = 2
        if ($x.State -ne 'OK') {
            if ($r.State -ne 'OK' -and $x.State -eq 'FREEZE') { $r.State = 'FREEZE' }
            continue
        }
        if ($r.State -eq 'OK') {
            $r.TlsMs = [math]::Min($r.TlsMs, $x.TlsMs); $r.ConnMs = [math]::Min($r.ConnMs, $x.ConnMs)
        } else {
            foreach ($p in @('State', 'Code', 'Exit', 'Up', 'Down', 'ConnMs', 'TlsMs')) { $r.$p = $x.$p }
            $r.Flaky = $true
        }
    }
    return $Rows
}

function Start-TestInstance([hashtable]$Settings, [string]$Alt) {
    $cmd = Get-BypassCmdLine -Settings $Settings -Name 'test' -Alt $Alt -NoAuto -IpsetMode 'any'
    # winws2 (cygwin) изредка падает при старте без причины - тогда стратегия выпадала из теста. Пробуем до трёх раз.
    for ($try = 1; $try -le 3; $try++) {
        $p = Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 2
        if (-not $p.HasExited) { return $p }
        Start-Sleep -Milliseconds 700
    }
    return $null
}

# Как незаблокированные сайты открываются без обхода: имя -> минимальное время TLS (только те, что открылись)
function Get-CleanBaseline($BaseRows) {
    $map = @{}
    foreach ($r in @($BaseRows | Where-Object { $_.Group -eq 'Clean' -and $_.State -eq 'OK' })) {
        if (-not $map.ContainsKey($r.Name) -or $r.TlsMs -lt $map[$r.Name]) { $map[$r.Name] = $r.TlsMs }
    }
    return $map
}

# $CleanBase - результат Get-CleanBaseline; без него вред не считается (прогон без обхода)
function Get-RunSummary([string]$Id, [string]$Name, $Rows, $CleanBase) {
    $all = @($Rows | Where-Object { $_.State -ne 'NA' })
    # "пробито" считаем только по заблокированному и сервисам; незаблокированные сайты - отдельно, как вред
    $counted = @($all | Where-Object { $_.Group -ne 'Clean' })
    $ok = @($counted | Where-Object { $_.State -eq 'OK' })
    # открылся только со второй попытки - полбалла
    $points = $ok.Count - 0.5 * @($ok | Where-Object { $_.Flaky }).Count
    $harm = @(); $harmTotal = 0
    if ($CleanBase -and $Id -ne '0') {
        foreach ($r in @($all | Where-Object { $_.Group -eq 'Clean' -and $CleanBase.ContainsKey($_.Name) })) {
            $harmTotal++
            if ($r.State -ne 'OK') { $harm += ($r.Name + ' (не открылся)') }
            elseif ($r.TlsMs -gt $CleanBase[$r.Name] + $HarmSlowMs) { $harm += ('{0} (TLS {1} мс вместо {2})' -f $r.Name, $r.TlsMs, $CleanBase[$r.Name]) }
        }
    }
    $groups = [ordered]@{}
    foreach ($g in $GroupNames.Keys) {
        $gr = @($all | Where-Object { $_.Group -eq $g })
        if ($gr.Count) {
            $gok = @($gr | Where-Object { $_.State -eq 'OK' })
            $groups[$g] = New-Object PSObject -Property @{
                Ok = ($gok.Count - 0.5 * @($gok | Where-Object { $_.Flaky }).Count); Total = $gr.Count
                Freeze = @($gr | Where-Object { $_.State -eq 'FREEZE' }).Count
            }
        }
    }
    $conn = if ($ok.Count) { [math]::Round(($ok | Measure-Object -Property ConnMs -Average).Average) } else { 0 }
    return New-Object PSObject -Property @{
        Id = $Id; Name = $Name; Ok = $points; Total = $counted.Count
        Freeze = @($counted | Where-Object { $_.State -eq 'FREEZE' }).Count; ConnMs = $conn; Groups = $groups
        Harm = $harm.Count; HarmTotal = $harmTotal; HarmList = $harm; Score = ($points - $harm.Count)
        FlakyList = @($all | Where-Object { $_.Flaky } | ForEach-Object { $_.Name })
    }
}

# Строка результата: сначала балл (по нему выбирается лучшая), из чего он сложился, затем по группам.
# $Prefix - место в итоге ("1." ...) или пусто; без $Name - строка под заголовком стратегии во время теста.
function Format-Summary($S, [string]$Prefix = '', [switch]$NoName) {
    $parts = @()
    foreach ($g in $S.Groups.Keys) {
        if ($g -eq 'Clean') { continue }   # незаблокированные сайты - это и есть "вред"
        $x = $S.Groups[$g]
        $t = '{0} {1}/{2}' -f $GroupNames[$g], (Format-Points $x.Ok), $x.Total
        if ($x.Freeze) { $t += (' (замерзаний ' + $x.Freeze + ')') }
        $parts += $t
    }
    $head = if ($NoName) { '        ' } else { '  {0,-4}{1,-19}' -f $Prefix, $S.Name }
    $score = if ($S.Id -eq '0') { ' ' * 11 } else { 'балл {0,-6}' -f (Format-Points $S.Score) }
    $line = $head + $score + ('| пробито {0}/{1}' -f (Format-Points $S.Ok), $S.Total)
    if ($S.HarmTotal) { $line += (' | вред {0}/{1}' -f $S.Harm, $S.HarmTotal) }
    $line += ' | ' + ($parts -join ' | ')
    if ($S.Ok) { $line += (' | TCP ~{0} мс' -f $S.ConnMs) }
    return $line
}

# ---------------- main ----------------

$report = New-Object System.Collections.Generic.List[string]
$report.Add('zapret v' + $Script:Version + ' - автоподбор ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

Write-Color 'Проверка подключения:' Cyan
$direct = Show-ConnectionCheck
$info = Get-DirectConnectionInfo
if ($info) { $report.Add(('Подключение: {0} {1} {2}, {3} [{4}]' -f (Get-MaskedIp $info.Ip), $info.CountryCode, $info.City, $info.Isp, $info.As)) }
foreach ($x in @(Get-ProxyWarnings)) { $report.Add('Прокси/VPN: ' + $x) }
if (-not $direct) {
    Write-Color 'Тест имеет смысл только на прямом подключении: закройте VPN/прокси полностью (у Happ - выход из программы).' Yellow
    Write-Color 'Иначе проверится ваш VPN, а не провайдер.' Yellow
    if ($NoPrompt -or -not (Read-YesNo 'Всё равно продолжить?')) { exit 0 }
}

if (-not (Resolve-ForeignBypass -NoPrompt:$NoPrompt)) {
    Write-Color 'Другой обход будет влиять на результаты.' Yellow
    if ($NoPrompt -or -not (Read-YesNo 'Всё равно продолжить?')) { exit 0 }
}

# ExitLag и т.п. перехватывают трафик вместе с обходом (о них уже сказала проверка подключения выше)
$boost = @(Get-GameBoosters)
foreach ($b in $boost) { $report.Add('Игровой ускоритель: ' + $b + ' - перехватывает трафик вместе с обходом') }
if ($boost.Count) {
    Write-Color 'С ним результаты будут неточными: закройте ускоритель полностью и запустите проверку снова.' Yellow
    if ($NoPrompt -or -not (Read-YesNo 'Всё равно продолжить?')) { exit 0 }
}

# подменённый winws2.exe или lua не запускаем даже для теста (обход ещё не остановлен)
$bad = @(Test-PackageIntegrity)
if ($bad.Count) { Write-IntegrityError $bad; exit 1 }

$targets = @(Read-DpiSuite) + @(Read-Targets)
if ($targets.Count -eq 0) { Write-Color 'Нет адресов для проверки (tools\targets.txt и tools\dpi-suite.json).' Red; exit 1 }
$postFile = Get-PostFile

$settings = Get-Settings
$wasRunning = @(Get-OurProcesses).Count -gt 0
# Дальше обход выключен. Что бы ни случилось - ошибка, отказ winws2, Ctrl+C посреди теста, - тестовый winws2 не
# остаётся работать, а обход включается обратно, если работал до теста.
$p = $null
try {
    Stop-Bypass
    Enable-TcpTimestamps
    Update-RuntimeLists | Out-Null

    # IPv6 провайдера (без обхода): у некоторых провайдеров часть сетей не отвечает, отсюда "Steam не качает"
    $v6 = Get-Ipv6Report
    Write-Color $v6.Text $(if ($v6.Broken.Count -and -not $v6.PreferV4) { 'Yellow' } else { 'Gray' })
    if ($v6.Broken.Count -and -not $v6.PreferV4) { Write-Color '  Пункт 4 меню (проверка обходов) включит "предпочитать IPv4" (Steam перестанет ждать по 20 секунд).' Yellow }
    $report.Add($v6.Text)
    # hosts Flowseal: подменяет ли DNS провайдера адреса GitHub, Telegram и Discord (на некоторых провайдерах бывает)
    $hostsText = Get-HostsReportText @(Test-HostsPins) (Get-HostsStatus)
    Write-Color $hostsText Gray
    $report.Add($hostsText)

    # быстрый проверяет и круги целиком, полный - вообще всё: выпавшая из круга стратегия может в него вернуться
    $strategies = @(Get-TestStrategies -Full:$Full)
    $orderIds = @(Get-AllStrategiesOrdered | ForEach-Object { $_.Id })
    $dry = Test-ConfigDry $settings $strategies[0].Id -NoAuto -IpsetMode 'any'
    if (-not $dry.Ok) { Write-Color 'winws2 отклонил параметры:' Red; Write-Host $dry.Output; exit 1 }

    $table = @{}
    $mode = if ($Full) { 'полный автоподбор' } else { 'быстрый автоподбор' }
    $report.Add(('{0}: {1} стратегий' -f $mode, $strategies.Count))
    Write-Color ("{0}: проверяю {1} адресов без обхода и с {2} стратегиями, раундов: {3}. Около {4} мин." -f $mode, $targets.Count, $strategies.Count, $Rounds, [math]::Ceiling(($strategies.Count + 1) * 15 * $Rounds / 60)) Cyan
    for ($round = 1; $round -le $Rounds; $round++) {
        if ($Rounds -gt 1) { Write-Color ("--- раунд {0} ---" -f $round) DarkCyan }
        $runs = @(New-Object PSObject -Property @{ Id = '0'; Name = 'без обхода' }) + @($strategies | ForEach-Object { New-Object PSObject -Property @{ Id = $_.Id; Name = $_.Name } })
        $i = 0
        foreach ($run in $runs) {
            # у каждой стратегии свой заголовок: видно, что проверяется сейчас и сколько осталось
            $i++
            Write-Host ''
            Write-Color ('[{0,2}/{1}] {2}' -f $i, $runs.Count, $(if ($run.Id -eq '0') { 'без обхода (как режет провайдер)' } else { $run.Name })) Cyan
            Write-Host -NoNewline ('        проверяю {0} адресов...' -f $targets.Count)
            $p = $null
            if ($run.Id -ne '0') {
                $p = Start-TestInstance $settings $run.Id
                if (-not $p) { Write-Color ' winws2 не запустился' Red; continue }
            }
            $cleanBase = if ($table.ContainsKey('0')) { Get-CleanBaseline $table['0'] } else { $null }
            $res = @(Invoke-CurlBatch $targets $postFile)
            # вторая попытка той же стратегией, пока winws2 ещё работает; почти все повторы помещаются в одну волну
            $again = @(Get-RetryTargets $targets $res $(if ($run.Id -ne '0') { $cleanBase }))
            if ($again.Count) {
                Write-Host -NoNewline (' повтор {0}...' -f $again.Count)
                $res = @(Merge-Retry $res @(Invoke-CurlBatch $again $postFile ($Parallel * 2)))
            }
            if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } ; Start-Sleep -Milliseconds 700 }
            if (-not $table.ContainsKey($run.Id)) { $table[$run.Id] = @() }
            $table[$run.Id] += $res
            if ($run.Id -eq '0') { $cleanBase = Get-CleanBaseline $table['0'] }
            $sum = Get-RunSummary $run.Id $run.Name $res $cleanBase
            Write-Host ' готово'
            Write-Color (Format-Summary $sum -NoName) $(if ($run.Id -eq '0') { 'Gray' } elseif ($sum.Harm) { 'Yellow' } else { 'Green' })
        }
    }

    # ---------- итог ----------
    $summary = @()
    $cleanBase = if ($table.ContainsKey('0')) { Get-CleanBaseline $table['0'] } else { $null }
    foreach ($id in $table.Keys) {
        $name = if ($id -eq '0') { 'без обхода' } else { (Get-Strategy $id).Name }
        $summary += Get-RunSummary $id $name $table[$id] $cleanBase
    }
    $base = $summary | Where-Object { $_.Id -eq '0' } | Select-Object -First 1
    $alts = @($summary | Where-Object { $_.Id -ne '0' })

    Write-Host ''
    Write-Color 'Итог - лучшие сверху. Балл = пробито - вред:' Cyan
    Write-Color '  пробито - сколько заблокированных адресов открылось (замерзание - соединение встало на 16-20 КБ);' Cyan
    Write-Color ('  вред - сколько обычных сайтов дважды не открылось или стало медленнее больше чем на {0} мс;' -f $HarmSlowMs) Cyan
    Write-Color '  .5 - адрес открылся только со второй попытки, за него полбалла.' Cyan
    $report.Add('')
    $report.Add('Итог - лучшие сверху. Балл = пробито - вред:')
    $rank = 0
    foreach ($s in (@($base) + @($alts | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Freeze } }, @{ Expression = { [array]::IndexOf($orderIds, $_.Id) } }))) {
        if (-not $s) { continue }
        $prefix = if ($s.Id -eq '0') { '' } else { $rank++; [string]$rank + '.' }
        $line = Format-Summary $s $prefix
        $color = if ($s.Id -eq '0') { 'Gray' } elseif ($rank -eq 1) { 'Green' } elseif ($s.Harm) { 'Yellow' } else { 'Gray' }
        Write-Color $line $color
        $report.Add($line)
        if ($s.Harm) { $report.Add('      вред: ' + ($s.HarmList -join ', ')) }
        if ($s.FlakyList.Count) { $report.Add('      со второй попытки: ' + ($s.FlakyList -join ', ')) }
    }

    # Подробности по каждому адресу - только в файл отчёта
    $report.Add('')
    $report.Add('Подробно (состояние, HTTP-код, код curl, отправлено/получено байт, TCP мс, TLS мс, попыток; x2 - проверен дважды, лучший замер):')
    foreach ($id in ($table.Keys | Sort-Object)) {
        $name = if ($id -eq '0') { 'без обхода' } else { (Get-Strategy $id).Name }
        $report.Add('[' + $name + ']')
        foreach ($r in ($table[$id] | Sort-Object Group, Name)) {
            $st = if ($r.Flaky) { 'OK2' } else { $r.State }
            $line = '  {0,-10} {1,-8} {2,-34} {3} curl={4} up={5} down={6} tcp={7} tls={8}' -f $r.Group, $st, $r.Name, $r.Code, $r.Exit, $r.Up, $r.Down, $r.ConnMs, $r.TlsMs
            if ($r.Tries -gt 1) { $line += ' x2' }
            $report.Add($line)
        }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $repFile = Join-Path $Script:Runtime ('test-' + $stamp + '.txt')
    Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
    Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force

    if ($alts.Count -eq 0 -or (($alts | Measure-Object -Property Ok -Maximum).Maximum) -eq 0) {
        Write-Color 'Ни одна ALT не достучалась до проверочных адресов. Проверьте интернет/DNS и запустите тест ещё раз.' Red
        Write-Color ('Отчёт: ' + $repFile) Gray
        if ($wasRunning) { Start-Bypass -Quiet | Out-Null }
        exit 0
    }

    # Лучшая: больше всего "пробито минус вред", при равенстве - меньше замерзаний, затем основные стратегии (RotationPref) раньше
    $best = $alts | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Freeze } }, @{ Expression = { [array]::IndexOf($orderIds, $_.Id) } } | Select-Object -First 1
    Write-Host ''
    # строка начинается с "Лучший результат:" - по ней автонастройка находит итог в test-last.txt
    $bestLine = "Лучший результат: {0} - балл {1} (пробито {2}/{3}, вред {4}/{5})" -f $best.Name, (Format-Points $best.Score), (Format-Points $best.Ok), $best.Total, $best.Harm, $best.HarmTotal
    Write-Color $bestLine Green
    if ($best.Harm) { Write-Color ('  вред: ' + ($best.HarmList -join ', ')) Yellow }
    # почему не та, что пробила больше всех: у неё вред
    $why = $null
    $mostOk = $alts | Sort-Object @{ Expression = { $_.Ok }; Descending = $true }, @{ Expression = { $_.Harm } } | Select-Object -First 1
    if ($mostOk.Id -ne $best.Id -and $mostOk.Ok -gt $best.Ok) {
        $why = '  Больше всех пробила {0} ({1}), но она ломает обычные сайты (вред {2}: {3}) - её балл {4}.' -f $mostOk.Name, (Format-Points $mostOk.Ok), $mostOk.Harm,
            (($mostOk.HarmList | ForEach-Object { ($_ -split ' ')[0] }) -join ', '), (Format-Points $mostOk.Score)
        Write-Color $why Gray
    }
    $tied = @($alts | Where-Object { $_.Id -ne $best.Id -and $_.Score -eq $best.Score } | ForEach-Object { $_.Name })
    if ($tied.Count) { Write-Color ('  Столько же баллов у: ' + ($tied -join ', ') + '. При равенстве выбрана та, что реже замерзает, затем из основных стратегий.') Gray }
    $freezeLine = $null
    if ($base -and $base.Groups.Contains('DPI') -and $base.Groups['DPI'].Freeze -gt 0) {
        $freezeLine = 'Без обхода провайдер заморозил {0} из {1} проверочных хостингов: это тот блок, из-за которого вылетают игры.' -f $base.Groups['DPI'].Freeze, $base.Groups['DPI'].Total
        Write-Color $freezeLine Gray
    }
    # лучший результат - и в файл отчёта (он уже записан выше вместе с подробностями)
    $report.Insert(1, $bestLine)
    $at = 2
    if ($why) { $report.Insert($at, $why); $at++ }
    if ($freezeLine) { $report.Insert($at, $freezeLine) }
    Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
    Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force
    Write-TextNoBom (Join-Path $Script:Runtime 'test-best.txt') ($best.Id + "`r`n")
    # рейтинг для круга автосмены: порядок по "пробито минус вред", слабые в круг не попадают
    if ($base) { Save-TestRank $base $alts }
    Write-Color ('Отчёт сохранён: ' + $repFile) Gray

    $apply = $true
    if ($ReportOnly) {
        $apply = $false
    } elseif ($best.Id -eq $settings.alt) {
        Write-Color ('{0} уже основная.' -f $best.Name) Green
        $apply = $false
    } elseif (-not $NoPrompt) {
        $apply = Read-YesNo ("Сделать {0} основной?" -f $best.Name)
    }
    if ($apply) {
        $settings.alt = $best.Id
        Save-Settings $settings
        Write-Color ("Основная стратегия: {0}." -f $best.Name) Green
    }
    $inRing = @()
    foreach ($sec in @('general', 'google', 'discord_media', 'game_tcp')) { $inRing += @(Get-RotationOrder $settings.alt $sec | ForEach-Object { $_.Id }) }
    $outRing = @($alts | Where-Object { $inRing -notcontains $_.Id } | ForEach-Object { $_.Name })
    Write-Color ('Круг автосмены для сайтов: ' + ((Get-RotationOrder $settings.alt 'general' | ForEach-Object { $_.Name }) -join ' > ')) Gray
    foreach ($x in @(Get-RingsText $settings)) { Write-Color ('Свой круг - ' + $x) Gray }
    if ($outRing.Count) { Write-Color ('Слабые на вашем провайдере, ни в один круг не входят: ' + ($outRing -join ', ')) Gray }
    if ($ReportOnly) { Write-Color 'Круг применится, когда обход будет запущен или перезапущен.' DarkGray }
    if ($wasRunning -or $apply) { Start-Bypass | Out-Null }
} finally {
    if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } ; Start-Sleep -Milliseconds 700 }
    if ($wasRunning -and @(Get-OurProcesses).Count -eq 0) { Start-Bypass -Quiet | Out-Null }
}
