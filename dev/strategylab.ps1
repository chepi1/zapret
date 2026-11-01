# Лаборатория стратегий: быстро сравнивает варианты стратегии на настоящих адресах автоподбора.
# Перехватывается ТОЛЬКО трафик к проверяемым адресам (--wf-raw-filter): прокси и другие программы не затрагиваются.
# Работающий обход на время проверки останавливается, в конце запускается снова. Нужны права администратора.
# Варианты берутся из файлов *.queue в папке -Dir, результаты пишутся туда же (*.tsv, *.summary, lab.log).
# Формат очереди: "@ имя варианта", дальше строки --payload=, --out-range=, --lua-desync= ; "@sleep N" - пауза N секунд.
# Завершается по файлу stop в папке, по времени, а также если запустилась игра или поднялся VPN-туннель.
param(
    [Parameter(Mandatory = $true)] [string] $Dir,
    [string] $Pkg = '',
    [string] $ExtraBlobs,
    [int] $MaxMinutes = 40,
    [int] $IdleMinutes = 10,
    [int] $TimeoutSec = 5,
    [int] $Parallel = 16
)
$ErrorActionPreference = 'Stop'
if (-not $Pkg) { $Pkg = Split-Path -Parent $PSScriptRoot }
. (Join-Path $Pkg 'tools\lib.ps1')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logFile = Join-Path $Dir 'lab.log'
function Log([string]$Text) { [IO.File]::AppendAllText($logFile, ((Get-Date -Format 'HH:mm:ss') + ' ' + $Text + "`r`n"), $utf8); Write-Host $Text }

# Функции стратегий, которые можно запускать. luaexec и подобные не входят: очередь лежит в обычной папке, а лаборатория работает с правами администратора
$allowed = 'fake|multisplit|multidisorder|fakedsplit|fakeddisorder|hostfakesplit|hostfakesplit_alt|tls_client_hello_clone|syndata|tcpseg|send|drop|oob|wsize|wssize|http_hostcase|http_domcase|http_methodeol|http_unixeol|pktmod'
$lineOk = '^(--payload=[a-z0-9_,]+|--out-range=[-A-Za-z0-9<>+.]+|--lua-desync=(' + $allowed + ')(:[A-Za-z0-9_=,.+%-]*)*)$'

# ---------- адреса ----------
function Read-LabTargets {
    $list = New-Object System.Collections.Generic.List[object]
    $fresh = Join-Path $Script:Runtime 'dpi-suite.json'
    $file = if (Test-Path $fresh) { $fresh } else { Join-Path $Pkg 'tools\dpi-suite.json' }
    $items = ConvertFrom-Json ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
    foreach ($x in @($items)) {
        if ($x.PSObject.Properties['host'] -and $x.host) { $list.Add((New-Object PSObject -Property @{ Key = 'DPI|' + $x.id; Host = $x.host; Url = 'https://' + $x.host + '/'; Post = $true; Ip = $null })) }
    }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Pkg 'tools\targets.txt'))) {
        if ($line.Trim() -match '^([A-Za-z0-9]+)\.([A-Za-z0-9_]+)\s*=\s*(https?://\S+)$') {
            $u = [uri]$matches[3]
            $list.Add((New-Object PSObject -Property @{ Key = $matches[1] + '|' + $matches[2]; Host = $u.Host; Url = $u.AbsoluteUri; Post = $false; Ip = $null }))
        }
    }
    foreach ($t in $list) {
        try { $t.Ip = @(Resolve-DnsName $t.Host -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })[0] } catch { }
    }
    return @($list | Where-Object { $_.Ip })
}

# Подключается ли TCP вообще (без данных): адреса, заблокированные по IP, проверять незачем
function Test-TcpOpen($Targets, [int]$TimeoutMs = 2500) {
    $jobs = @(foreach ($t in $Targets) {
        $c = New-Object Net.Sockets.TcpClient ([Net.Sockets.AddressFamily]::InterNetwork)
        New-Object PSObject -Property @{ T = $t; C = $c; Task = $c.ConnectAsync([Net.IPAddress]::Parse($t.Ip), 443) }
    })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($j in $jobs) { try { [void]$j.Task.Wait([math]::Max(0, $TimeoutMs - $sw.ElapsedMilliseconds)) } catch { } }
    $open = @($jobs | Where-Object { $_.Task.Status -eq 'RanToCompletion' } | ForEach-Object { $_.T })
    foreach ($j in $jobs) { try { $j.C.Close() } catch { } }
    return $open
}

function Invoke-LabBatch($Targets, [string]$PostFile) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $queue = New-Object System.Collections.Queue
    foreach ($t in $Targets) { $queue.Enqueue($t) }
    $running = New-Object System.Collections.ArrayList
    $rows = New-Object System.Collections.Generic.List[object]
    $inv = [Globalization.CultureInfo]::InvariantCulture
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
            $t = $queue.Dequeue()
            $a = '-s -o NUL --noproxy "*" --ssl-no-revoke --http1.1 --max-time ' + $TimeoutSec + ' --connect-timeout 4 -r 0-65535 --resolve "' + $t.Host + ':443:' + $t.Ip + '"' +
                 ' -w "%{http_code} %{size_upload} %{size_download} %{time_connect} %{time_appconnect}"'
            if ($t.Post) { $a += ' -X POST --data-binary "@' + $PostFile + '"' }
            $a += ' "' + $t.Url + '"'
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $curl; $psi.Arguments = $a; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($psi)
            [void]$running.Add((New-Object PSObject -Property @{ T = $t; P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Started = [Diagnostics.Stopwatch]::StartNew() }))
        }
        Start-Sleep -Milliseconds 50
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            $r = $running[$i]
            if ($r.P.HasExited -or $r.Started.Elapsed.TotalSeconds -gt ($TimeoutSec + 4)) {
                if (-not $r.P.HasExited) { try { $r.P.Kill() } catch { } }
                $r.P.WaitForExit()
                $x = @($r.Out.Result.Trim() -split '\s+')
                $code = '000'; $up = 0.0; $down = 0.0; $tcp = 0.0; $tls = 0.0
                if ($x.Count -ge 5) { $code = $x[0]; try { $up = [double]::Parse($x[1], $inv); $down = [double]::Parse($x[2], $inv); $tcp = [double]::Parse($x[3], $inv); $tls = [double]::Parse($x[4], $inv) } catch { } }
                $exit = $r.P.ExitCode
                # + открылся, F отправка встала (заморозка), H нет ответа на ClientHello или нет соединения, 5 ошибка TLS, c<код> другое
                $st = if ($code -ne '000') { '+' } elseif ($exit -eq 28 -and $up -gt 0) { 'F' } elseif ($exit -eq 28) { 'H' } elseif ($exit -eq 35) { '5' } else { 'c' + $exit }
                $rows.Add((New-Object PSObject -Property @{ Key = $r.T.Key; St = $st; Code = $code; Exit = $exit; Up = $up; Down = $down; Tcp = [math]::Round($tcp * 1000); Tls = [math]::Round($tls * 1000) }))
                $running.RemoveAt($i)
            }
        }
    }
    return $rows.ToArray()
}

function Write-LabResult([string]$Base, [string]$Name, [int]$Seq, $Rows, $BaseTls) {
    $tsv = @($Rows | Sort-Object Key | ForEach-Object { ($Name, $Seq, $_.Key, $_.St, $_.Code, $_.Exit, $_.Up, $_.Down, $_.Tcp, $_.Tls) -join "`t" })
    [IO.File]::AppendAllText($Base + '.tsv', (($tsv -join "`r`n") + "`r`n"), $utf8)
    $parts = @()
    foreach ($g in @($Rows | ForEach-Object { ($_.Key -split '[|]')[0] } | Sort-Object -Unique)) {
        $gr = @($Rows | Where-Object { $_.Key.StartsWith($g + '|') })
        $parts += ('{0} {1}/{2}' -f $g, @($gr | Where-Object { $_.St -eq '+' }).Count, $gr.Count)
    }
    $ok = @($Rows | Where-Object { $_.St -eq '+' -and $_.Tls -gt 0 } | ForEach-Object { $_.Tls } | Sort-Object)
    $med = if ($ok.Count) { $ok[[int]($ok.Count / 2)] } else { 0 }
    $bad = @($Rows | Where-Object { $_.St -ne '+' } | Sort-Object Key | ForEach-Object { ($_.Key -split '[|]')[1].Split(' ')[0] + ':' + $_.St })
    $line = '{0,-34} {1} TLS~{2} | {3}' -f $Name, ($parts -join ' '), $med, ($bad -join ' ')
    [IO.File]::AppendAllText($Base + '.summary', ($line + "`r`n"), $utf8)
    Log $line
}

function Get-LabArgs($Lines, [string]$FilterFile) {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('--wf-tcp-out=80,443')
    $a.Add('--wf-raw-filter=@' + $FilterFile)
    foreach ($l in 'zapret-lib.lua', 'zapret-antidpi.lua', 'zapret-auto.lua', 'fooling.lua', 'autoring.lua') { $a.Add('--lua-init=@' + (Join-Path $Pkg ('lua\' + $l))) }
    $names = @{ quic_google = 'quic_initial_www_google_com.bin'; quic_4pda = 'quic_initial_4pda_to.bin'; stun_fs = 'stun.bin'; stun2 = 'stun2.bin'; tls_google = 'tls_clienthello_www_google_com.bin'
        tls_4pda = 'tls_clienthello_4pda_to.bin'; tls_sferum = 'tls_clienthello_www_sferum_ru.bin'; tls_sochi = 'tls_clienthello_sochi_park.bin'; discord_udp = 'ACTIVE_DISCORD_UDP.bin'; game_udp = 'ACTIVE_GAME_UDP.bin' }
    foreach ($k in $names.Keys) { $a.Add('--blob=' + $k + ':@' + (Join-Path $Pkg ('fake\' + $names[$k]))) }
    if ($ExtraBlobs -and (Test-Path $ExtraBlobs)) {
        foreach ($f in Get-ChildItem $ExtraBlobs -Filter '*.bin') { $a.Add('--blob=x_' + ($f.BaseName -replace '[^A-Za-z0-9_]', '_') + ':@' + $f.FullName) }
    }
    $a.Add('--filter-tcp=80,443')
    # как в рабочем запуске: поддельные сбросы фильтра выбрасываются (lua\autoring.lua)
    foreach ($l in '--payload=all', '--out-range=x', '--in-range=a', '--lua-desync=rst_guard', '--in-range=x', '--out-range=a', '--out-range=-d10') { $a.Add($l) }
    foreach ($l in $Lines) { $a.Add($l) }
    foreach ($l in '--payload=all', '--out-range=-d10', '--lua-desync=rst_mark') { $a.Add($l) }
    return @($a)
}

function Start-LabInstance($Lines, [string]$FilterFile) {
    $cmd = ConvertTo-WinCmdLine (Get-LabArgs $Lines $FilterFile)
    for ($try = 1; $try -le 3; $try++) {
        $trace = Join-Path $Dir ('instance-' + [guid]::NewGuid().ToString('N'))
        $p = Start-Process -FilePath $Script:Exe -ArgumentList $cmd -WorkingDirectory $Script:Bin -WindowStyle Hidden -RedirectStandardOutput ($trace + '.out.log') -RedirectStandardError ($trace + '.err.log') -PassThru
        Start-Sleep -Milliseconds 1200
        if (-not $p.HasExited) { return $p }
    }
    $r = Invoke-Native $Script:Exe ('--dry-run ' + $cmd) $Script:Bin 10
    Log ('winws2 не запустился: ' + (@($r.Output -split "`n") | Select-Object -Last 2) -join ' ')
    return $null
}
function Stop-LabInstance($P) {
    if (-not $P) { return }
    try { if (-not $P.HasExited) { $P.Kill(); [void]$P.WaitForExit(3000) } } catch { }
}

function Test-LabMustStop {
    if (Test-Path (Join-Path $Dir 'stop')) { return 'файл stop' }
    $g = @(Get-RunningGames)
    if ($g.Count) { return 'запущена игра: ' + ($g -join ', ') }
    if (@(Get-TunAdapters).Count) { return 'поднялся VPN-туннель' }
    return $null
}

# ---------- работа ----------
$clock = [Diagnostics.Stopwatch]::StartNew()
Log ('лаборатория: старт, версия ' + $Script:Version)
$stop = Test-LabMustStop
if ($stop) { Log ('не запускаю: ' + $stop); exit 0 }
$wasOn = @(Get-OurProcesses).Count -gt 0
$post = Join-Path $Script:Runtime 'post64k.bin'
if (-not (Test-Path $post) -or (Get-Item $post).Length -ne 65536) {
    $bytes = New-Object byte[] 65536
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [IO.File]::WriteAllBytes($post, $bytes)
}
$current = $null
try {
    Stop-Bypass
    $targets = @(Read-LabTargets)
    $open = @(Test-TcpOpen $targets)
    $dead = @($targets | Where-Object { $open -notcontains $_ } | ForEach-Object { $_.Key })
    Log ('адресов: ' + $targets.Count + ', без TCP-соединения (не проверяются): ' + ($dead -join ', '))
    $targets = $open
    $filter = Join-Path $Dir 'filter.txt'
    $ips = @($targets | ForEach-Object { $_.Ip } | Sort-Object -Unique)
    [IO.File]::WriteAllText($filter, ('ip and (' + (@($ips | ForEach-Object { 'ip.DstAddr==' + $_ + ' or ip.SrcAddr==' + $_ }) -join ' or ') + ')'), $utf8)
    Log ('в перехвате только адреса проверки: ' + $ips.Count)
    $baseRows = @(Invoke-LabBatch $targets $post)
    Write-LabResult (Join-Path $Dir 'baseline') 'без обхода' 0 $baseRows $null
    $idle = [Diagnostics.Stopwatch]::StartNew()
    $seq = 0
    while ($true) {
        $why = Test-LabMustStop
        if (-not $why -and $clock.Elapsed.TotalMinutes -ge $MaxMinutes) { $why = 'вышло время' }
        if (-not $why -and $idle.Elapsed.TotalMinutes -ge $IdleMinutes) { $why = 'очередь пуста' }
        if ($why) { Log ('завершаю: ' + $why); break }
        $q = Get-ChildItem $Dir -Filter '*.queue' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
        if (-not $q) { Start-Sleep -Seconds 2; continue }
        $idle.Restart()
        Log ('очередь ' + $q.Name)
        $base = Join-Path $Dir $q.BaseName
        # файл мог ещё дописываться: читаем целиком, очередь пишется атомарно (rename)
        $name = $null; $lines = New-Object System.Collections.Generic.List[string]
        $blocks = New-Object System.Collections.Generic.List[object]
        foreach ($l in [IO.File]::ReadAllLines($q.FullName, [Text.Encoding]::UTF8)) {
            $t = $l.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($t -match '^@sleep\s+(\d+)$') {
                if ($name) { $blocks.Add((New-Object PSObject -Property @{ Name = $name; Lines = @($lines); Sleep = 0 })); $name = $null; $lines = New-Object System.Collections.Generic.List[string] }
                $blocks.Add((New-Object PSObject -Property @{ Name = $null; Lines = @(); Sleep = [int]$matches[1] }))
            } elseif ($t -match '^@\s*(.+)$') {
                if ($name) { $blocks.Add((New-Object PSObject -Property @{ Name = $name; Lines = @($lines); Sleep = 0 })) }
                $name = $matches[1]; $lines = New-Object System.Collections.Generic.List[string]
            } elseif ($t -match $lineOk) { $lines.Add($t) }
            else { Log ('строка отклонена: ' + $t) }
        }
        if ($name) { $blocks.Add((New-Object PSObject -Property @{ Name = $name; Lines = @($lines); Sleep = 0 })) }
        foreach ($b in $blocks) {
            $why = Test-LabMustStop
            if ($why) { break }
            if ($b.Sleep) { Start-Sleep -Seconds $b.Sleep; continue }
            $seq++
            if (@($b.Lines).Count) {
                $current = Start-LabInstance $b.Lines $filter
                if (-not $current) { continue }
            }
            try { $rows = @(Invoke-LabBatch $targets $post) } finally { Stop-LabInstance $current; $current = $null }
            Write-LabResult $base $b.Name $seq $rows $null
        }
        Move-Item -LiteralPath $q.FullName -Destination ($q.FullName + '.done') -Force
        $idle.Restart()
    }
} catch {
    Log ('ошибка: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
} finally {
    Stop-LabInstance $current
    foreach ($p in @(Get-OurProcesses)) { try { Stop-Process -Id $p.Id -Force } catch { } }
    if ($wasOn) {
        $ok = $false
        try { $ok = Start-Bypass -Quiet } catch { Log ('запуск обхода: ' + $_.Exception.Message) }
        Log ('обход запущен снова: ' + $ok)
    } else { Log 'обход до проверки не работал, не запускаю' }
    Log 'лаборатория: конец'
    [IO.File]::WriteAllText((Join-Path $Dir 'finished'), (Get-Date -Format 'HH:mm:ss'), $utf8)
}
