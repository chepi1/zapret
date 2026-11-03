# Автоподбор ALT: без обхода и с каждой ALT по отдельности проверяет то, что режет провайдер,
# и предлагает сделать лучшую основной. Запускается из меню (zapret.bat). Совместимо с Windows PowerShell 5.1.
#  - замерзание 16-20 КБ: POST 64 КБ на сайты в AWS, Cloudflare, Hetzner и других хостингах (набор dpi-checkers, как у Flowseal);
#  - Discord, YouTube, 2K и EAC из tools\targets.txt;
#  - вред: незаблокированные сайты на разных CDN (группа Clean) не должны перестать открываться или замедлиться.
# Лучшая стратегия - с наибольшим "пробито минус вред".
# Сеть шумит, поэтому адрес, который не открылся, сразу проверяется второй раз той же стратегией:
# открылся со второй попытки - полбалла ("нестабильно"); вред - только если сбой или медленный TLS повторились.
# Во время теста IPSet временно "any", чтобы проверочные сайты точно попали под обход (так же делает тест Flowseal).
# -ReportOnly: только отчёт (для проверки провайдера), настройки и круги не меняем.
# -KeepPrimary: обновить проверенный рейтинг и круги, сохранив выбранную основную (для автонастройки).
# -Full: все стратегии, иначе быстрый - основные 9 и те, что сейчас в кругах автосмены (Get-TestStrategies).
param([int]$TimeoutSec = 5, [int]$Parallel = 16, [ValidateRange(1,10)][int]$Rounds = 1, [ValidateRange(-1,2147483647)][int]$Seed = -1, [switch]$NoPrompt, [switch]$ReportOnly, [switch]$KeepPrimary, [switch]$Full,
    [string]$CompareA='', [string]$CompareB='', [ValidateRange(4,12)][int]$CompareBlocks=4)

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
# Адрес, который не открылся ни разу за столько стратегий подряд, второй раз не проверяем (Get-RetryTargets)
$HopelessRuns = 3

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

# Адреса, которые не открылись ни без обхода, ни с одной стратегией, и к которым не проходит даже TCP-подключение:
# провайдер режет их по IP. Обход тут ничего не сделает - нужен VPN; так и пишем, а не "стратегия не пробила".
function Get-IpBlocked($Table, [int]$TimeoutMs = 3000) {
    $byName = @{}
    foreach ($id in $Table.Keys) {
        foreach ($r in $Table[$id]) {
            $k = $r.Group + '|' + $r.Name
            if (-not $byName.ContainsKey($k)) { $byName[$k] = @{ Row = $r; Ok = $false } }
            if ($r.State -eq 'OK' -or $r.State -eq 'NA') { $byName[$k].Ok = $true }
        }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $jobs = @(foreach ($x in @($byName.Values | Where-Object { -not $_.Ok -and $_.Row.Group -ne 'Clean' })) {
        $ip = $null
        try { $ip = @([System.Net.Dns]::GetHostAddresses(([uri]$x.Row.Url).Host) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0] } catch { }
        if (-not $ip) { continue }
        $tc = New-Object System.Net.Sockets.TcpClient ([System.Net.Sockets.AddressFamily]::InterNetwork)
        $task = $null
        try { $task = $tc.ConnectAsync($ip, 443) } catch { }
        New-Object PSObject -Property @{ Name = $x.Row.Name; Tc = $tc; Task = $task }
    })
    foreach ($j in $jobs) { if ($j.Task) { try { [void]$j.Task.Wait([math]::Max(0, $TimeoutMs - $sw.ElapsedMilliseconds)) } catch { } } }
    $res = @($jobs | Where-Object { -not $_.Task -or $_.Task.Status -ne 'RanToCompletion' } | ForEach-Object { $_.Name } | Sort-Object)
    foreach ($j in $jobs) { try { $j.Tc.Close() } catch { } }
    return $res
}

# curl записывает время TCP, только когда завершился и TLS. Соединение есть, а ClientHello остался без ответа - будет tcp=0 и tls=0,
# как будто сервер недоступен (проверено на curl 8.21). Поэтому нули - не "нет соединения"; недоступность по IP проверяет Get-IpBlocked.
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
    $extra=@{DnsMs=$null;FirstByteMs=$null;TotalMs=$null}
    $indices=@{DnsMs=5;FirstByteMs=6;TotalMs=7}
    foreach ($key in $indices.Keys) {
        $value=0.0;$index=$indices[$key]
        if ($parts.Count -gt $index -and [double]::TryParse($parts[$index],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value) -and -not [double]::IsNaN($value) -and -not [double]::IsInfinity($value) -and $value -ge 0) { $extra[$key]=[math]::Round($value*1000) }
    }
    $startedUtc=$null;$startedMs=$null
    if ($Item.PSObject.Properties['Started']) { try { $startedUtc=([datetime]$Item.Started).ToUniversalTime().ToString('o') } catch { } }
    if ($Item.PSObject.Properties['StartedTicks']) { $startedMs=1000.0*$Item.StartedTicks/[Diagnostics.Stopwatch]::Frequency }
    $observedMs=1000.0*[Diagnostics.Stopwatch]::GetTimestamp()/[Diagnostics.Stopwatch]::Frequency
    $state = 'FAIL'
    if ($exit -eq 6) { $state = 'NA' }                                   # домен не резолвится: адрес не учитываем
    elseif ($code -ne '000') { $state = 'OK' }
    elseif ($exit -eq 28 -and $Item.T.Post -and $up -gt 0 -and $down -eq 0) { $state = 'FREEZE' }   # отправка встала: блок 16-20 КБ
    elseif ($exit -eq 28 -and -not $Item.T.Post -and $down -gt 0) { $state = 'FREEZE' }             # загрузка встала
    return New-Object PSObject -Property @{
        Group = $Item.T.Group; Name = $Item.T.Name; Url = $Item.T.Url; State = $state; Code = $code; Exit = $exit
        Up = $up; Down = $down; ConnMs = [math]::Round($conn * 1000); TlsMs = [math]::Round($tls * 1000)
        DnsMs=$extra.DnsMs;FirstByteMs=$extra.FirstByteMs;TotalMs=$extra.TotalMs;StartedUtc=$startedUtc;ObservedUtc=[datetime]::UtcNow.ToString('o');StartedMs=$startedMs;ObservedMs=$observedMs
        Tries = 1; Flaky = $false
    }
}

# Запускает curl.exe параллельно (не больше $Width, по умолчанию $Parallel, одновременно) и собирает результаты.
function Assert-ProbeDeadline([long]$DeadlineTicks) {
    if ($DeadlineTicks -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $DeadlineTicks) {
        $deadlineError=New-Object TimeoutException('Достигнут общий дедлайн запросов.')
        $deadlineError.Data['Kind']='RunDeadline'
        throw $deadlineError
    }
}
function Invoke-CurlBatch($Targets, [string]$PostFile, [int]$Width = 0, [switch]$Control, [long]$DeadlineTicks = 0) {
    if ($Width -le 0) { $Width = $Parallel }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $queue = New-Object System.Collections.Queue
    foreach ($t in $Targets) { $queue.Enqueue($t) }
    $running = New-Object System.Collections.ArrayList
    $results = @()
    try {
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        Assert-ProbeDeadline $DeadlineTicks
        while ($queue.Count -gt 0 -and $running.Count -lt $Width) {
            Assert-ProbeDeadline $DeadlineTicks
            $t = $queue.Dequeue()
            $a = '-s -o NUL --noproxy "*" --ssl-no-revoke --http1.1 --max-time ' + $TimeoutSec + ' --connect-timeout 4' +
                 ' -w "%{http_code} %{size_upload} %{size_download} %{time_connect} %{time_appconnect} %{time_namelookup} %{time_starttransfer} %{time_total}"'
            if ($Control) { $a += ' --head' } else { $a += ' -r 0-65535' }
            if (-not $Control -and $t.Post) { $a += ' -X POST --data-binary "@' + $PostFile + '"' }
            $a += ' "' + $t.Url + '"'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $curl
            $psi.Arguments = $a
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $startedTicks=[Diagnostics.Stopwatch]::GetTimestamp()
            $p = [System.Diagnostics.Process]::Start($psi)
            [void]$running.Add((New-Object PSObject -Property @{ T = $t; P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Started = (Get-Date);StartedTicks=$startedTicks }))
        }
        Start-Sleep -Milliseconds 100
        Assert-ProbeDeadline $DeadlineTicks
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.P.HasExited -or ([Diagnostics.Stopwatch]::GetTimestamp()-$r.StartedTicks)/[double][Diagnostics.Stopwatch]::Frequency -gt ($TimeoutSec + 5)) {
                if (-not $r.P.HasExited) { $r.P.Kill() }
                if (-not $r.P.WaitForExit(1000)) { throw 'curl не завершился после остановки.' }
                $results += Convert-CurlResult $r
                $r.P.Dispose()
                $running.RemoveAt($i)
            }
        }
    }
    return $results
    } catch {
        $failure=$_
        $failure.Exception.Data['ProbeProcessIds']=@($running | ForEach-Object { $_.P.Id })
        $cancelled=@()
        foreach ($r in $running) {
            try { if (-not $r.P.HasExited) { $r.P.Kill() };[void]$r.P.WaitForExit(1000) } catch { }
            $cancelled+=[pscustomobject]@{Group=$r.T.Group;Name=$r.T.Name;Url=$r.T.Url;State='CANCELLED';StartedMs=(1000.0*$r.StartedTicks/[Diagnostics.Stopwatch]::Frequency);ObservedMs=(1000.0*[Diagnostics.Stopwatch]::GetTimestamp()/[Diagnostics.Stopwatch]::Frequency);StartedUtc=$r.Started.ToUniversalTime().ToString('o');ObservedUtc=[datetime]::UtcNow.ToString('o')}
        }
        $failure.Exception.Data['Rows']=@($results)+$cancelled
        throw
    } finally {
        foreach ($r in $running) { try { if (-not $r.P.HasExited) { $r.P.Kill() };[void]$r.P.WaitForExit(1000) } finally { $r.P.Dispose() } }
    }
}

function Invoke-ControlWindow($Targets,[string]$PostFile,[string]$JournalFile,[hashtable]$Metadata,[switch]$Warmup) {
    if (-not @($Targets).Count) { return @() }
    $stage=$Metadata.Stage
    $measured=New-Object 'System.Collections.Generic.List[object]'
    try {
        $first=if ($Warmup) { 0 } else { 1 }
        for ($sample=$first; $sample -le 2; $sample++) {
            if (@(Get-OurProcesses).Count) { throw 'Контроль без обхода невозможен: тестовый процесс ещё работает.' }
            $Metadata.Stage=if ($sample -eq 0) { 'control-warmup' } else { $stage }
            $rows=@(Invoke-CurlBatch $Targets $PostFile ([math]::Min(4,$Parallel)) -Control)
            $Metadata.ControlUncontaminated=(@(Get-OurProcesses).Count -eq 0)
            Write-ProbeJournal $JournalFile $Metadata $rows ([math]::Max(1,$sample))
            if (-not $Metadata.ControlUncontaminated) { throw 'Во время контрольных запросов запустился обход; сравнение отменено.' }
            if ($sample -eq 0) { continue }
            foreach ($row in $rows) {
                $copy=$row.PSObject.Copy()
                $copy | Add-Member NoteProperty Attempt $sample -Force
                $measured.Add($copy)
            }
        }
    } finally { $Metadata.Stage=$stage;$Metadata.Remove('ControlUncontaminated') }
    return $measured.ToArray()
}

function Get-RowKey($R) { return ($R.Group + '|' + $R.Name + '|' + $R.Url) }

# Что проверить второй раз: не открывшееся (FAIL/FREEZE) и незаблокированные сайты с медленным TLS.
# $Hopeless - адреса, которые не открылись ни без обхода, ни несколькими стратегиями подряд: вторая попытка им не
# поможет, а каждая стоила стратегии лишних секунд ожидания. Первая попытка у них остаётся.
function Get-RetryTargets($Targets, $Rows, $CleanBase, $Hopeless = @{}) {
    $blocked = @($Rows | Where-Object { $_.Group -ne 'Clean' -and ($_.State -eq 'FAIL' -or $_.State -eq 'FREEZE') -and -not $Hopeless.ContainsKey((Get-RowKey $_)) })
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

function Test-FinalCandidateRows($Expected, $Actual) {
    $required = @($Expected | Where-Object { $_.State -eq 'OK' })
    $failed = @()
    foreach ($row in $required) {
        $matches = @($Actual | Where-Object { $_.Group -eq $row.Group -and $_.Name -eq $row.Name })
        if (-not $matches.Count -or @($matches | Where-Object { $_.State -ne 'OK' -or ($row.Group -eq 'Clean' -and $_.TlsMs -gt $row.TlsMs + 500) }).Count) {
            $failed += ($row.Group + '/' + $row.Name)
        }
    }
    return [pscustomobject]@{ Ok=($required.Count -gt 0 -and $failed.Count -eq 0); Failed=@($failed | Select-Object -Unique) }
}

function Get-TestInstanceLifetimeMs([int]$TargetCount, [int]$Parallelism, [int]$Timeout) {
    if ($TargetCount -lt 1 -or $Parallelism -lt 1 -or $Timeout -lt 1) { throw 'Некорректный бюджет тестового запуска.' }
    # Основные запросы и повторные попытки, запас на подготовку/завершение. Таймер не зависит от родителя.
    $budget = [math]::Max(120000, (30 + 4 * [math]::Ceiling($TargetCount / [double]$Parallelism) * $Timeout) * 1000)
    if ($budget -gt 1800000) { throw 'Один тестовый этап требует больше 30 минут; уменьшите тайм-аут или число адресов.' }
    return [int]$budget
}

function Start-TestInstance([hashtable]$Settings, [string]$Alt, [switch]$Final, [ValidateRange(1000,1800000)][int]$LifetimeMs = 120000) {
    Assert-BypassControlAllowed
    $cmd = if ($Final) { Get-BypassCmdLine -Settings $Settings -Name 'final-check' -Alt $Alt }
           else { Get-BypassCmdLine -Settings $Settings -Name 'test' -Alt $Alt -NoAuto -IpsetMode 'any' }
    $guard = "--lua-init=timer_set('test_lifetime_guard',function() os.exit(3) end," + $LifetimeMs.ToString([Globalization.CultureInfo]::InvariantCulture) + ',true)'
    $cmd += ' ' + (ConvertTo-WinArg $guard)
    # winws2 (cygwin) изредка падает при старте без причины - тогда стратегия выпадала из теста. Пробуем до трёх раз.
    for ($try = 1; $try -le 3; $try++) {
        Assert-BypassControlAllowed
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
    $head = if ($NoName) { '        ' } else { '  {0,-4}{1,-19} ' -f $Prefix, $S.Name }
    $score = if ($S.Id -eq '0') { ' ' * 11 } else { 'балл {0,-6}' -f (Format-Points $S.Score) }
    $line = $head + $score + ('| пробито {0}/{1}' -f (Format-Points $S.Ok), $S.Total)
    if ($S.HarmTotal) { $line += (' | вред {0}/{1}' -f $S.Harm, $S.HarmTotal) }
    $line += ' | ' + ($parts -join ' | ')
    if ($S.Ok) { $line += (' | TCP ~{0} мс' -f $S.ConnMs) }
    return $line
}

# Explicit shadow mode shares the controller/finally, but never enters the normal scoring/apply path.
function New-FinalistExperimentSpec([hashtable]$Settings,$Targets,[string]$AId,[string]$BId,[int]$PlanSeed,[int]$Blocks) {
    if ($TimeoutSec -lt 1 -or $Parallel -lt 1) { throw 'Неверный тайм-аут или параллельность сравнения.' }
    $all=@(Get-Strategies | Where-Object { $_.Missing.Count -eq 0 })
    $a=@($all | Where-Object { $_.Id -eq $AId });$b=@($all | Where-Object { $_.Id -eq $BId })
    if ($a.Count -ne 1 -or $b.Count -ne 1 -or $AId -eq $BId) { throw 'Для сравнения нужны две различные доступные стратегии: -CompareA ID -CompareB ID.' }
    $fixed=$Settings.Clone();$fixed.auto='no'
    $network=Get-NetworkObservation
    $context=Get-TestResultContext $fixed $network
    if ($null -eq $context) { throw 'Контекст сети неизвестен; достоверное сравнение сейчас невозможно.' }
    $parameters=@{Mode='finalists-v1';TimeoutSec=$TimeoutSec;Parallel=([math]::Min(4,$Parallel));Blocks=$Blocks;Configuration=$context.InputsHash;Settings=(@($fixed.Keys | Sort-Object | ForEach-Object { $_+'='+[string]$fixed[$_] }) -join '|')}
    $inputs=Get-ScoreInputsHash $Targets $parameters
    if ($PlanSeed -lt 0) { $PlanSeed=Get-Random -Minimum 0 -Maximum ([int]::MaxValue) }
    $plan=New-FinalistPlan $AId $BId (Get-StrategyFingerprint $AId) (Get-StrategyFingerprint $BId) $Targets $network.Key $inputs $PlanSeed $Blocks ([guid]::NewGuid().ToString('N'))
    foreach ($id in @($AId,$BId)) {
        $dry=Test-ConfigDry $fixed $id -NoAuto
        if (-not $dry.Ok) { throw ('Конфигурация сравнения отклонена до остановки обхода: '+$dry.Output) }
    }
    return [pscustomobject]@{Plan=$plan;Parameters=$parameters;Network=$network;Settings=$fixed;AName=$a[0].Name;BName=$b[0].Name}
}
function Write-FinalistArtifact([string]$Path,[string]$Text) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $bytes=[Text.Encoding]::UTF8.GetBytes($Text);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
}
function Assert-FinalistExperiment($Plan,$Targets,[hashtable]$Parameters,$NetworkBefore,[hashtable]$Settings,$Clock) {
    if ($Clock.Elapsed.TotalMinutes -ge 30) { throw 'Достигнут предел сравнения:30 минут; результат не применяется.' }
    Assert-BypassControlAllowed
    $current=$Parameters.Clone()
    $current.Configuration=Get-ProbeField (Get-TestResultContext $Settings (Get-NetworkObservation)) 'InputsHash'
    if (-not (Test-ScoreInputs $Plan.CapturedInputsHash $Targets $current @{$Plan.AId=$Plan.AHash;$Plan.BId=$Plan.BHash} -NetworkBefore $NetworkBefore)) { throw 'Сеть или файлы изменились во время сравнения; результат отклонён.' }
}
function Invoke-FinalistBatch($Targets,[string]$PostFile,[int]$Width,[long]$DeadlineTicks,[string]$JournalFile,[hashtable]$Metadata,[int]$Attempt) {
    try {
        $rows=@(Invoke-CurlBatch $Targets $PostFile $Width -DeadlineTicks $DeadlineTicks)
        Write-ProbeJournal $JournalFile $Metadata $rows $Attempt
        return $rows
    } catch {
        if ($_.Exception.Data.Contains('Rows')) {
            $aborted=$Metadata.Clone();$aborted.Stage='comparison-aborted'
            Write-ProbeJournal $JournalFile $aborted $_.Exception.Data['Rows'] $Attempt
        }
        throw
    }
}
function Invoke-FinalistExperiment([hashtable]$Settings,$Targets,[string]$PostFile,$Plan,[hashtable]$InputsParameters,$NetworkBefore,[ref]$ActiveProcess) {
    $fixed=$Settings.Clone();$fixed.auto='no'
    $width=[math]::Min(4,$Parallel)
    $lifetime=Get-TestInstanceLifetimeMs @($Targets).Count $width $TimeoutSec
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $deadlineTicks=[Diagnostics.Stopwatch]::GetTimestamp()+[long]([Diagnostics.Stopwatch]::Frequency*1800.0)
    $base=Join-Path $Script:Runtime ('comparison-'+$Plan.RunId)
    $planFile=$base+'.plan.json';$journalFile=$base+'.attempts.jsonl';$resultFile=$base+'.result.json'
    foreach ($path in @($planFile,$journalFile,$resultFile)) { if (Test-Path -LiteralPath $path) { throw 'Такой RunId уже существует; свидетельства не перезаписаны.' } }
    Write-FinalistArtifact $planFile ($Plan | ConvertTo-Json -Depth 8)
    Write-FinalistArtifact $journalFile ''
    $metadata=@{RunId=$Plan.RunId;Seed=$Plan.Seed;Sequence=0;Round=0;NetworkKey=$Plan.CapturedNetworkKey;InputsHash=$Plan.CapturedInputsHash}
    foreach ($slot in $Plan.Slots) {
        Assert-FinalistExperiment $Plan $Targets $InputsParameters $NetworkBefore $fixed $clock
        if (@(Get-OurProcesses).Count) { throw 'Перед следующим запуском остался процесс обхода; сравнение прервано.' }
        $metadata.StrategyId=$slot.StrategyId;$metadata.StrategyHash=$slot.StrategyHash
        $metadata.ComparisonSlot=$slot.Index;$metadata.ComparisonBlock=$slot.Block;$metadata.ComparisonKind=$slot.Kind;$metadata.ComparisonArm=$slot.Arm
        Write-Color ('Сравнение: запуск '+$slot.Index+'/'+$Plan.Slots.Count+' ('+$slot.Kind+', '+$slot.Arm+').') Gray
        try {
            $remainingMs=[math]::Floor(1000.0*($deadlineTicks-[Diagnostics.Stopwatch]::GetTimestamp())/[Diagnostics.Stopwatch]::Frequency)
            if ($remainingMs -lt 1000) { throw 'Недостаточно времени для следующего запуска.' }
            $ActiveProcess.Value=Start-TestInstance $fixed $slot.StrategyId -Final -LifetimeMs ([int][math]::Min($lifetime,$remainingMs))
            if (-not $ActiveProcess.Value -or $ActiveProcess.Value.HasExited) { throw 'Тестовый движок не запустился.' }
            foreach ($stage in @('comparison-warmup','comparison')) {
                $metadata.Stage=$stage
                $rows=@(Invoke-FinalistBatch $Targets $PostFile $width $deadlineTicks $journalFile $metadata 1)
                if ($ActiveProcess.Value.HasExited) { throw 'Тестовый движок завершился во время запросов.' }
                Assert-FinalistExperiment $Plan $Targets $InputsParameters $NetworkBefore $fixed $clock
            }
            $again=@($Targets | Where-Object { $key=Get-ProbeKey $_;@($rows | Where-Object { (Get-ProbeKey $_) -ceq $key -and $_.State -ne 'OK' }).Count -gt 0 })
            if ($again.Count) {
                $retry=@(Invoke-FinalistBatch $again $PostFile $width $deadlineTicks $journalFile $metadata 2)
                if ($ActiveProcess.Value.HasExited) { throw 'Тестовый движок завершился во время повторных запросов.' }
            }
        } finally {
            if ($ActiveProcess.Value) {
                if (-not $ActiveProcess.Value.HasExited) { Stop-Process -Id $ActiveProcess.Value.Id -Force -ErrorAction Stop }
                if (-not $ActiveProcess.Value.WaitForExit(5000)) { throw 'Тестовый процесс не завершился; его PID сохранён для очистки.' }
                $ActiveProcess.Value=$null
            }
        }
        Assert-FinalistExperiment $Plan $Targets $InputsParameters $NetworkBefore $fixed $clock
    }
    $evidence=@([IO.File]::ReadLines($journalFile) | ForEach-Object { $_ | ConvertFrom-Json })
    # Published only after every slot's liveness/context check and PID cleanup succeeded.
    $completion=New-FinalistCompletion $Plan $evidence
    $line=($completion | ConvertTo-Json -Compress)+"`n"
    if ((Get-Item -LiteralPath $journalFile).Length+[Text.Encoding]::UTF8.GetByteCount($line) -gt 67108864) { throw 'Недостаточно места в бюджете журнала для подтверждения завершения.' }
    [IO.File]::AppendAllText($journalFile,$line,(New-Object Text.UTF8Encoding($false)))
    $evidence+=$completion
    $assessment=Get-FinalistAssessment $Plan $evidence
    Write-FinalistArtifact $resultFile ($assessment | ConvertTo-Json -Depth 10)
    return [pscustomobject]@{Assessment=$assessment;PlanFile=$planFile;JournalFile=$journalFile;ResultFile=$resultFile}
}

# ---------------- main ----------------
$comparisonMode=[bool]($CompareA -or $CompareB)
if ($comparisonMode -and ($CompareA -notmatch '^\d+$' -or $CompareB -notmatch '^\d+$' -or $CompareA -eq $CompareB -or $CompareBlocks%2)) { throw 'Нужны два разных ID (-CompareA/-CompareB) и чётное число блоков4..12.' }

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
$primaryBefore=Get-Strategy $settings.alt
$primaryNameBefore=if ($primaryBefore) { $primaryBefore.Name } else { 'стратегия из настроек' }
$comparisonSpec=$null
if ($comparisonMode) { $comparisonSpec=New-FinalistExperimentSpec $settings $targets $CompareA $CompareB $Seed $CompareBlocks }
if (-not (Enter-BypassControl 'strategy-test')) { Write-Color 'Автоподбор отложен: другая операция управляет обходом.' Yellow; exit 1 }
$wasRunning = @(Get-OurProcesses).Count -gt 0
# Дальше обход выключен. Что бы ни случилось - ошибка, отказ winws2, Ctrl+C посреди теста, - тестовый winws2 не
# остаётся работать, а обход включается обратно, если работал до теста.
$p = $null
try {
    Stop-Bypass
    if ($comparisonMode) {
        Write-Color ('Фиксированные стратегии, автосмена выключена: A='+$comparisonSpec.AName+'; B='+$comparisonSpec.BName+'.') Cyan
        $comparison=Invoke-FinalistExperiment $comparisonSpec.Settings $targets $postFile $comparisonSpec.Plan $comparisonSpec.Parameters $comparisonSpec.Network ([ref]$p)
        Write-Color ('Shadow-результат: '+$comparison.Assessment.Status+'. Настройки и рейтинг не применяются.') Cyan
        Write-Color ('Отчёт: '+$comparison.ResultFile) Gray
        exit 0
    }
    Enable-TcpTimestamps
    Update-RuntimeLists | Out-Null

    # IPv6 провайдера (без обхода): у некоторых провайдеров часть сетей не отвечает, отсюда "Steam не качает".
    # Пробы IPv6 и hosts идут одновременно
    $v6Jobs = if (@(Get-Ipv6Addresses).Count) { Start-Ipv6Probes } else { $null }
    $pinJobs = Start-HostsPinProbes
    $v6 = Get-Ipv6Report $v6Jobs
    Write-Color $v6.Text $(if ($v6.Broken.Count -and -not $v6.PreferV4) { 'Yellow' } else { 'Gray' })
    if ($v6.Broken.Count -and -not $v6.PreferV4) { Write-Color '  Пункт 4 меню (проверка обходов) включит "предпочитать IPv4" (Steam перестанет ждать по 20 секунд).' Yellow }
    $report.Add($v6.Text)
    # hosts Flowseal: подменяет ли DNS провайдера адреса GitHub, Telegram и Discord (на некоторых провайдерах бывает)
    $hostsText = Get-HostsReportText @(Test-HostsPins -Pending $pinJobs) (Get-HostsStatus)
    Write-Color $hostsText Gray
    $report.Add($hostsText)

    # быстрый проверяет и круги целиком, полный - вообще всё: выпавшая из круга стратегия может в него вернуться
    $strategies = @(Get-TestStrategies -Full:$Full)
    $testLifetimeMs = Get-TestInstanceLifetimeMs $targets.Count $Parallel $TimeoutSec
    $networkBefore = Get-NetworkObservation
    $resultContext = Get-TestResultContext $settings $networkBefore
    Set-RingNetworkContext $networkBefore
    $settingsKey = @($settings.Keys | Sort-Object | ForEach-Object { $_+'='+[string]$settings[$_] }) -join '|'
    $scoreParameters = @{ TimeoutSec=$TimeoutSec; Parallel=$Parallel; Rounds=$Rounds; Settings=$settingsKey; Network=$networkBefore.Key }
    $scoreInputs = Get-ScoreInputsHash $targets $scoreParameters
    $scoreContext = Get-ScoreContext $info $targets $scoreParameters
    $scoreFingerprints = @{}
    foreach ($strategy in $strategies) { $scoreFingerprints[$strategy.Id] = Get-StrategyFingerprint $strategy.Id }
    $orderIds = @(Get-AllStrategiesOrdered | ForEach-Object { $_.Id })
    # Windows могла перезапустить службу после сбоя при остановке - тестовый winws2 с тем же фильтром не запустится
    if (@(Get-OurProcesses).Count) { Stop-Bypass }
    $dry = Test-ConfigDry $settings $strategies[0].Id -NoAuto -IpsetMode 'any'
    if (-not $dry.Ok) { Write-Color 'winws2 отклонил параметры:' Red; Write-Host $dry.Output; exit 1 }

    if ($Seed -lt 0) { $Seed=Get-Random -Minimum 0 -Maximum ([int]::MaxValue) }
    $measurementOrder=New-TestMeasurementOrder $strategies $Rounds $Seed
    $measurementId=[guid]::NewGuid().ToString('N')
    $journalFile=Join-Path $Script:Runtime ('test-attempts-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$measurementId.Substring(0,8)+'.jsonl')
    $metadata=@{RunId=$measurementId;Seed=$Seed;Sequence=0;Round=0;Stage='control-before';StrategyId='0';StrategyHash='';NetworkKey=$networkBefore.Key;InputsHash=$scoreInputs}
    $orderRecord=[ordered]@{Schema=1;RunId=$measurementId;Seed=$Seed;CapturedNetworkKey=$networkBefore.Key;CapturedInputsHash=$scoreInputs;Rounds=@($measurementOrder.Rounds | ForEach-Object { [pscustomobject]@{Number=$_.Number;StrategyIds=@($_.Strategies | ForEach-Object { $_.Id })} })}
    Write-TextNoBom (Join-Path $Script:Runtime ('test-order-'+$measurementId+'.json')) ($orderRecord | ConvertTo-Json -Depth 6)
    $report.Add('Порядок измерений: seed='+$Seed+'; соседние раунды в обратном порядке.')
    $report.Add('Журнал исходных попыток: '+[IO.Path]::GetFileName($journalFile))
    $controlTargets=@(Get-ControlTargets $targets)
    Write-Color 'Проверяю контрольные HTTPS-запросы без обхода...' Gray
    $controlBefore=@(Invoke-ControlWindow $controlTargets $postFile $journalFile $metadata -Warmup)

    $table = @{}
    $ipSkip = @{}   # группа|имя -> строка прогона без обхода: адреса, заблокированные по IP
    $failRuns = @{}; $everOk = @{}   # адрес -> сколько стратегий подряд он не открылся / открылся ли хоть раз
    $mode = if ($Full) { 'полный автоподбор' } else { 'быстрый автоподбор' }
    $report.Add(('{0}: {1} стратегий' -f $mode, $strategies.Count))
    Write-Color ("{0}: проверяю {1} адресов без обхода и с {2} стратегиями, раундов: {3}. Около {4} мин." -f $mode, $targets.Count, $strategies.Count, $Rounds, [math]::Ceiling(($strategies.Count + 1) * 15 * $Rounds / 60)) Cyan
    foreach ($roundPlan in $measurementOrder.Rounds) {
        $round=$roundPlan.Number
        $failRuns=@{};$everOk=@{}
        if ($Rounds -gt 1) { Write-Color ("--- раунд {0} ---" -f $round) DarkCyan }
        $runs = @(New-Object PSObject -Property @{ Id = '0'; Name = 'без обхода' }) + @($roundPlan.Strategies | ForEach-Object { New-Object PSObject -Property @{ Id = $_.Id; Name = $_.Name } })
        $i = 0
        foreach ($run in $runs) {
            $metadata.Round=$round;$metadata.StrategyId=$run.Id
            $metadata.Stage=if ($run.Id -eq '0') { 'baseline' } else { 'strategy' }
            $metadata.StrategyHash=if ($run.Id -eq '0') { '' } else { $scoreFingerprints[$run.Id] }
            # у каждой стратегии свой заголовок: видно, что проверяется сейчас и сколько осталось
            $i++
            Write-Host ''
            Write-Color ('[{0,2}/{1}] {2}' -f $i, $runs.Count, $(if ($run.Id -eq '0') { 'без обхода (как режет провайдер)' } else { $run.Name })) Cyan
            Write-Host -NoNewline ('        проверяю {0} адресов...' -f $(if ($run.Id -ne '0') { $targets.Count - $ipSkip.Count } else { $targets.Count }))
            $p = $null
            if ($run.Id -ne '0') {
                $p = Start-TestInstance $settings $run.Id -LifetimeMs $testLifetimeMs
                if (-not $p) { Write-Color ' winws2 не запустился' Red; continue }
            }
            $cleanBase = if ($table.ContainsKey('0')) { Get-CleanBaseline $table['0'] } else { $null }
            # заблокированные по IP (найдены в прогоне без обхода) стратегиям не открыть - их не ждём до тайм-аута
            # в каждом прогоне, а сразу записываем им тот же провал, что без обхода: баллы от этого не меняются
            $runTargets = if ($run.Id -ne '0' -and $ipSkip.Count) { @($targets | Where-Object { -not $ipSkip.ContainsKey($_.Group + '|' + $_.Name) }) } else { $targets }
            $res = @(Invoke-CurlBatch $runTargets $postFile)
            Write-ProbeJournal $journalFile $metadata $res 1
            # вторая попытка той же стратегией, пока winws2 ещё работает; почти все повторы помещаются в одну волну.
            # Безнадёжные (не открылись ни разу за $HopelessRuns стратегий подряд) второй раз не проверяем
            $hopeless = @{}
            foreach ($k in @($failRuns.Keys)) { if ($failRuns[$k] -ge $HopelessRuns -and -not $everOk.ContainsKey($k)) { $hopeless[$k] = $true } }
            $again = @(Get-RetryTargets $runTargets $res $(if ($run.Id -ne '0') { $cleanBase }) $hopeless)
            if ($again.Count) {
                Write-Host -NoNewline (' повтор {0}...' -f $again.Count)
                $retried=@(Invoke-CurlBatch $again $postFile ($Parallel * 2))
                Write-ProbeJournal $journalFile $metadata $retried 2
                $res = @(Merge-Retry $res $retried)
            }
            if ($run.Id -ne '0') {
                foreach ($r in $res) {
                    $k = Get-RowKey $r
                    if ($r.State -eq 'OK') { $everOk[$k] = $true } elseif (-not $everOk.ContainsKey($k)) { $failRuns[$k] = 1 + [int]$failRuns[$k] }
                }
                foreach ($k in $ipSkip.Keys) { $res += $ipSkip[$k].PSObject.Copy() }
            }
            elseif (-not $ipSkip.Count) {
                foreach ($n in @(Get-IpBlocked @{ '0' = $res })) {
                    $row = $res | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                    if ($row) { $ipSkip[$row.Group + '|' + $row.Name] = $row }
                }
                if ($ipSkip.Count) { Write-Host -NoNewline (' заблокированы по IP: {0} - стратегиям их не проверяю...' -f (@($ipSkip.Values | ForEach-Object { $_.Name }) -join ', ')) }
            }
            if ($p) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
                if (-not $p.WaitForExit(5000)) { throw 'Тестовый процесс не остановился; контрольные измерения отменены.' }
                $p=$null
                Start-Sleep -Milliseconds 700
            }
            if (-not $table.ContainsKey($run.Id)) { $table[$run.Id] = @() }
            $table[$run.Id] += $res
            if ($run.Id -eq '0') { $cleanBase = Get-CleanBaseline $table['0'] }
            $sum = Get-RunSummary $run.Id $run.Name $res $cleanBase
            Write-Host ' готово'
            Write-Color (Format-Summary $sum -NoName) $(if ($run.Id -eq '0') { 'Gray' } elseif ($sum.Harm) { 'Yellow' } else { 'Green' })
        }
    }

    $metadata.Stage='control-after';$metadata.Round=0;$metadata.StrategyId='0';$metadata.StrategyHash=''
    Write-Color 'Повторяю контрольные HTTPS-запросы после измерений...' Gray
    $controlAfter=@(Invoke-ControlWindow $controlTargets $postFile $journalFile $metadata)
    $controlAssessment=Get-ControlAssessment $controlTargets $controlBefore $controlAfter
    $controlAssessment | Add-Member NoteProperty RunId $measurementId
    Write-TextNoBom (Join-Path $Script:Runtime ('test-control-'+$measurementId+'.json')) ($controlAssessment | ConvertTo-Json -Depth 4)
    $report.Add(('Контроль измерений: {0}; сопоставимых адресов: {1}; причины: {2}' -f $controlAssessment.Status,$controlAssessment.MatchedTargets,($controlAssessment.Reasons -join ',')))

    # ---------- итог ----------
    if (-not (Test-ScoreInputs $scoreInputs $targets $scoreParameters $scoreFingerprints -NetworkBefore $networkBefore)) {
        $changed = 'Файлы изменились во время автоподбора. Результаты не применены и не добавлены в историю; повторите проверку после завершения правок.'
        Write-Color $changed Yellow
        $report.Add($changed)
        Write-TextNoBom (Join-Path $Script:Runtime 'test-last.txt') ($report -join "`r`n")
        exit 1
    }
    $summary = @()
    $cleanBase = if ($table.ContainsKey('0')) { Get-CleanBaseline $table['0'] } else { $null }
    foreach ($id in $table.Keys) {
        $name = if ($id -eq '0') { 'без обхода' } else { (Get-Strategy $id).Name }
        $summary += Get-RunSummary $id $name $table[$id] $cleanBase
    }
    $base = $summary | Where-Object { $_.Id -eq '0' } | Select-Object -First 1
    $alts = @($summary | Where-Object { $_.Id -ne '0' })

    Write-Host ''
    Write-Color 'Результаты текущего прогона, по баллу. Балл = пробито - вред:' Cyan
    Write-Color '  пробито - сколько заблокированных адресов открылось (замерзание - соединение встало на 16-20 КБ);' Cyan
    Write-Color ('  вред - сколько обычных сайтов дважды не открылось или стало медленнее больше чем на {0} мс;' -f $HarmSlowMs) Cyan
    Write-Color '  .5 - адрес открылся только со второй попытки, за него полбалла.' Cyan
    Write-Color '  Основная выбирается по среднему совместимых прогонов с порогом смены; причина решения будет ниже.' Gray
    $report.Add('')
    $report.Add('Результаты текущего прогона, по баллу. Балл = пробито - вред:')
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
    $report.Add('Подробно (состояние, HTTP-код, код curl, отправлено/получено байт, TCP мс, TLS мс, попыток; x2 - проверен дважды, лучший замер; tcp=0 tls=0 - нет ответа на ClientHello или нет соединения: curl их не различает):')
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
    $bestLine = "Лучший результат: {0} - балл {1} (пробито {2}/{3}, вред {4}/{5}); текущий прогон" -f $best.Name, (Format-Points $best.Score), (Format-Points $best.Ok), $best.Total, $best.Harm, $best.HarmTotal
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
    if ($tied.Count) {
        $tieLine='В этом прогоне столько же баллов у: '+($tied -join ', ')+'. Порядок при равенстве: меньше замерзаний, затем приоритет стратегии.'
        Write-Color $tieLine Gray
        $report.Add($tieLine)
    }
    $freezeLine = $null
    if ($base -and $base.Groups.Contains('DPI') -and $base.Groups['DPI'].Freeze -gt 0) {
        $freezeLine = 'Без обхода провайдер заморозил {0} из {1} проверочных хостингов: это тот блок, из-за которого вылетают игры.' -f $base.Groups['DPI'].Freeze, $base.Groups['DPI'].Total
        Write-Color $freezeLine Gray
    }
    $ipLine = $null
    $ipBlocked = @(Get-IpBlocked $table)
    if ($ipBlocked.Count) {
        $ipLine = 'Заблокированы по IP (не подключаются вовсе, ни одна стратегия их не откроет - только VPN): ' + ($ipBlocked -join ', ')
        Write-Color $ipLine Gray
    }
    # Баллы плавают от прогона к прогону: основную выбираем по среднему за последние прогоны, а не по этому одному
    if (-not $controlAssessment.CanApply) {
        $qualityLine=if ($controlAssessment.Status -eq 'Changed') { 'Контрольные HTTPS-запросы изменились во время автоподбора. Новый рейтинг не применён; сравнение нужно повторить.' } else { 'Недостаточно повторяемых контрольных запросов. Новый рейтинг не применён; это не доказывает отсутствие интернета.' }
        Write-Color $qualityLine Yellow
        $report.Add($qualityLine)
        $outcomeLine=Get-PrimaryResultText $primaryNameBefore '' QualityRejected $qualityLine
        Write-Color $outcomeLine Yellow
        $report.Insert(1,$outcomeLine)
        Write-TextNoBom $repFile (($report -join "`r`n")+"`r`n")
        Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force
        exit $(if ($ReportOnly) { 0 } else { 1 })
    }
    $historySaved = Add-ScoreHistory $alts $scoreContext $scoreFingerprints
    if (-not $historySaved) {
        if (-not (Test-ScoreInputs $scoreInputs $targets $scoreParameters $scoreFingerprints -NetworkBefore $networkBefore)) { throw 'Стратегии или код изменились перед сохранением. Результаты не применены; повторите автоподбор после завершения правок.' }
        $scoreContext = ''
        Write-Color 'Совместимая история недоступна: сравниваю только текущий прогон.' Yellow
    }
    else { $report.Add('История средних баллов: только этот провайдер, набор адресов и версия стратегии.') }
    $avg = Get-AverageScores $alts $scoreContext
    $choice = Get-PrimaryChoice $alts $avg $settings.alt $orderIds
    $decisionLine=Get-PrimaryDecisionText $choice $avg $primaryNameBefore $Script:ScoreMargin -ReportOnly:$ReportOnly -KeepPrimary:$KeepPrimary
    $avgTop = @($alts | Sort-Object @{ Expression = { $avg[$_.Id].Avg }; Descending = $true } | Select-Object -First 5 |
        ForEach-Object { '{0} {1} ({2})' -f $_.Name, (Format-Points $avg[$_.Id].Avg), $avg[$_.Id].Runs })
    $avgLine = ('Средний балл за последние прогоны (до {0}), в скобках их число: ' -f $Script:ScoreRuns) + ($avgTop -join ', ')
    Write-Color $avgLine Gray
    Write-Color $decisionLine Gray
    # лучший результат - и в файл отчёта (он уже записан выше вместе с подробностями)
    $report.Insert(1, $bestLine)
    $at = 2
    $report.Insert($at, $avgLine); $at++
    $report.Insert($at, $decisionLine); $at++
    if ($why) { $report.Insert($at, $why); $at++ }
    if ($freezeLine) { $report.Insert($at, $freezeLine); $at++ }
    if ($ipLine) { $report.Insert($at, $ipLine) }
    Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
    Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force
    Write-TextNoBom (Join-Path $Script:Runtime 'test-best.txt') ($best.Id + "`r`n")
    # рейтинг для круга автосмены: порядок по "пробито минус вред", слабые в круг не попадают
    # Рейтинг и круги публикуются только после проверки рабочей комбинации ниже.
    Write-Color ('Отчёт сохранён: ' + $repFile) Gray

    $apply = $true
    $pick = $choice.Top
    if ($ReportOnly) {
        $apply = $false
    } elseif ($KeepPrimary) {
        $apply = $false
    } elseif ($pick.Id -eq $settings.alt) {
        $apply = $false
    } elseif ($choice.Noise) {
        $apply = $false
    } elseif (-not $NoPrompt) {
        # автоподбор проверяет сайты, а игру в матче - нет: стратегию, проверенную в игре, он менять не должен молча
        if ($settings.game -ne 'off') {
            $cur = Get-Strategy $settings.alt
            Write-Color ('Автоподбор проверяет сайты, а игру в матче проверить не может. Если игра с {0} идёт без статтеров, основную лучше не менять.' -f $(if ($cur) { $cur.Name } else { 'текущей' })) Yellow
        }
        $apply = Read-YesNo ("Сделать {0} основной?" -f $pick.Name)
        if (-not $apply) {
            $declinedLine='Смена основной отклонена пользователем; сохраняется '+$primaryNameBefore+'.'
            Write-Color $declinedLine Gray
            $report.Add($declinedLine)
        }
    }
    if (-not $ReportOnly) {
        $candidate = $settings.Clone()
        if ($apply) { $candidate.alt = $pick.Id }
        $candidateName=if ($apply) { $pick.Name } else { $primaryNameBefore }
        $previous = @{}
        foreach ($file in @($Script:RankFile, $Script:CoverFile)) {
            $path = Get-PkgPath $file
            $previous[$path] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
        }
        $accepted = $false
        try {
            if ($base) { $Script:TestResultPreview = New-TestResultPreview $base $alts $table $resultContext }
            $Script:RingCache = @{}
            Assert-BypassControlAllowed
            if (-not $table.ContainsKey($candidate.alt)) { throw 'Рабочая стратегия не была измерена в этом прогоне.' }
            Write-Color 'Проверяю итоговую комбинацию с рабочими списками, IPSet и автосменой...' Cyan
            $p = Start-TestInstance $candidate $candidate.alt -Final -LifetimeMs $testLifetimeMs
            if (-not $p) { throw 'Итоговая конфигурация не запустилась; прежние настройки сохраняются.' }
            $finalRows = @(Invoke-CurlBatch $targets $postFile)
            $metadata.Stage='final';$metadata.Round=0;$metadata.StrategyId=$candidate.alt;$metadata.StrategyHash=$scoreFingerprints[$candidate.alt]
            Write-ProbeJournal $journalFile $metadata $finalRows 1
            $expected = @($table[$candidate.alt]) + @($table['0'] | Where-Object { $_.Group -eq 'Clean' })
            $check = Test-FinalCandidateRows $expected $finalRows
            if ($p.HasExited) { throw 'Процесс завершился во время итоговой проверки.' }
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            if (-not $p.WaitForExit(5000)) { throw 'Не удалось остановить итоговую проверку.' }
            $p = $null
            if (-not (Test-ScoreInputs $scoreInputs $targets $scoreParameters $scoreFingerprints -NetworkBefore $networkBefore)) { throw 'Входные файлы изменились во время итоговой проверки.' }
            if (-not (Test-TestResultContext $resultContext (Get-TestResultContext $candidate))) { throw 'Сеть или конфигурация рейтинга изменились во время итоговой проверки.' }
            if (-not $check.Ok) { throw ('Итоговая комбинация не подтверждена: ' + ($check.Failed -join ', ')) }
            Assert-BypassControlAllowed
            if ($base) { Save-TestRank $base $alts $resultContext; Save-TestCover $table $resultContext }
            if ($apply) { Save-Settings $candidate; $settings = $candidate }
            $accepted = $true
            $finalLine=Get-PrimaryResultText $candidateName $candidateName $(if ($apply) { 'Applied' } else { 'Kept' })
        } catch {
            $apply = $false
            $finalLine=Get-PrimaryResultText $primaryNameBefore $candidateName Rejected $_.Exception.Message
        } finally {
            $Script:TestResultPreview = $null
            $Script:RingCache = @{}
            if (-not $accepted) {
                foreach ($path in $previous.Keys) {
                    if ($null -eq $previous[$path]) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                    else { [IO.File]::WriteAllBytes($path, $previous[$path]) }
                }
                $Script:RingCache = @{}
            }
        }
        Write-Color $finalLine $(if ($accepted) { 'Green' } else { 'Yellow' })
        $report.Add($finalLine)
        $report.Insert(1,$finalLine)
        Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
        Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force
        if ($p) { throw 'Итоговый процесс требует завершения; восстановление выполняется в finally.' }
    }
    if ($ReportOnly) {
        $finalLine=Get-PrimaryResultText $primaryNameBefore '' ReportOnly
        Write-Color $finalLine Gray
        $report.Insert(1,$finalLine)
        Write-TextNoBom $repFile (($report -join "`r`n") + "`r`n")
        Copy-Item $repFile (Join-Path $Script:Runtime 'test-last.txt') -Force
    }
    $inRing = @()
    foreach ($sec in @('general', 'google', 'discord_media', 'game_tcp')) { $inRing += @(Get-RotationOrder $settings.alt $sec | ForEach-Object { $_.Id }) }
    $outRing = @($alts | Where-Object { $inRing -notcontains $_.Id } | ForEach-Object { $_.Name })
    Write-Color ('Круг автосмены для сайтов: ' + ((Get-RotationOrder $settings.alt 'general' | ForEach-Object { $_.Name }) -join ' > ')) Gray
    foreach ($x in @(Get-RingsText $settings)) { Write-Color ('Свой круг - ' + $x) Gray }
    if ($outRing.Count) { Write-Color ('Слабые на вашем провайдере, ни в один круг не входят: ' + ($outRing -join ', ')) Gray }
    if ($ReportOnly) { Write-Color 'Режим отчёта: настройки и круги не изменены.' DarkGray }
    if ($wasRunning -or $apply) { Start-Bypass | Out-Null }
} finally {
    if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } ; Start-Sleep -Milliseconds 700 }
    try {
        if ($wasRunning -and @(Get-OurProcesses).Count -eq 0) { Start-Bypass -Quiet | Out-Null }
    } finally { Exit-BypassControl }
}
