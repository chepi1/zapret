# Проверка стратегий: то, чего не ловит winws2 --dry-run. Функции и их аргументы Lua видит только на живом пакете, поэтому опечатка в
# аргументе, незаявленный блоб или несуществующая функция дают запуск без ошибок и стратегию, которая молча не работает.
# Идея - из zapret-gui (avatarDD, MIT), правила свои. Ничего не запускает и не меняет.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$fails = 0
function Fail([string]$Text) { Write-Host ('FAIL ' + $Text) -ForegroundColor Red; $script:fails++ }

# Функции и их аргументы: из самих lua-файлов (--lua-desync=имя существует, только если есть function имя)
$funcs = @{}
foreach ($f in Get-ChildItem (Join-Path $Pkg 'lua') -Filter '*.lua') {
    $doc = New-Object System.Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        if ($l -match '^-- arg\s*:\s*(.+)$') {
            # "-- arg : a, b - что делает" или "-- arg : a=<x> - что делает": имена идут до первого тире с пробелами
            foreach ($n in (($matches[1] -split ' - ')[0] -split ',')) { if ($n.Trim() -match '^([a-z_0-9]+)') { $doc.Add($matches[1]) } }
            continue
        }
        if ($l -match '^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
            $funcs[$matches[1]] = @($doc)
            $doc.Clear()
        } elseif ($l -notmatch '^--') { $doc.Clear() }
    }
}
Write-Host ('функций в lua: ' + $funcs.Count)

# Стандартные аргументы (шапка zapret-antidpi.lua: direction, fooling, reconstruct, rawsend, payload, ip_id, ipfrag) и метки оркестратора
$standard = @('dir', 'payload', 'strategy', 'final', 'optional', 'nodrop',
    'ip_ttl', 'ip6_ttl', 'ip_autottl', 'ip6_autottl', 'ip6_hopbyhop', 'ip6_hopbyhop2', 'ip6_destopt', 'ip6_destopt2', 'ip6_routing', 'ip6_ah',
    'tcp_seq', 'tcp_ack', 'tcp_ts', 'tcp_md5', 'tcp_flags_set', 'tcp_flags_unset', 'tcp_ts_up', 'tcp_nop_del', 'fool',
    'badsum', 'repeats', 'ifout', 'fwmark', 'ip_id', 'ip_id_conn', 'ipfrag', 'ipfrag_disorder', 'ipfrag_pos_tcp', 'ipfrag_pos_udp', 'ipfrag_pos_icmp', 'ipfrag_pos', 'ipfrag_next')
# функции без полного описания аргументов в шапке
$extra = @{ fake = @('blob', 'tls_mod'); hostfakesplit_alt = @('host') }
$payloads = @('tls_client_hello', 'http_req', 'quic_initial', 'discord_ip_discovery', 'stun', 'unknown', 'all', 'empty')
$tlsMods = '^(rnd|rndsni|dupsid|padencap|none|sni=[A-Za-z0-9.%_-]+)$'

# Блобы, заявленные при запуске: читаем из сборки командной строки и проверяем, что файлы на месте
$libText = [IO.File]::ReadAllText((Join-Path $Pkg 'tools\lib.ps1'), [Text.Encoding]::UTF8)
$blobs = @{ fake_default_tls = $true; fake_default_http = $true; fake_default_quic = $true }
foreach ($m in [regex]::Matches($libText, "--blob=([A-Za-z_][A-Za-z0-9_]*):@' \+ \(Get-PkgPath '([^']+)'\)")) {
    $blobs[$m.Groups[1].Value] = $true
    if (-not (Test-Path (Join-Path $Pkg ($m.Groups[2].Value -replace '/', '\')))) { Fail ('нет файла блоба ' + $m.Groups[2].Value) }
}
Write-Host ('заявленных блобов: ' + $blobs.Count)

$checked = 0
foreach ($file in Get-ChildItem (Join-Path $Pkg 'strategies') -Filter 'alt*.txt') {
    $sec = ''
    foreach ($line in [IO.File]::ReadAllLines($file.FullName, [Text.Encoding]::UTF8)) {
        if ($line -match '^\[(.+)\]$') { $sec = $matches[1]; continue }
        $at = $file.Name + ' [' + $sec + ']: '
        if ($line -match '^--payload=(.+)$') {
            foreach ($p in $matches[1] -split ',') { if ($payloads -notcontains $p) { Fail ($at + 'неизвестный payload ' + $p) } }
            continue
        }
        if ($line -notmatch '^--lua-desync=(.+)$') { continue }
        $checked++
        $parts = @($matches[1] -split ':')
        $fn = $parts[0]
        if (-not $funcs.ContainsKey($fn)) { Fail ($at + 'нет функции ' + $fn); continue }
        $known = @($funcs[$fn]) + $standard
        if ($extra.ContainsKey($fn)) { $known += $extra[$fn] }
        $args_ = @{}
        foreach ($p in ($parts | Select-Object -Skip 1)) {
            $kv = $p -split '=', 2
            $args_[$kv[0]] = $(if ($kv.Count -gt 1) { $kv[1] } else { '' })
            if ($known -notcontains $kv[0]) { Fail ($at + $fn + ': неизвестный аргумент ' + $kv[0]) }
        }
        foreach ($k in 'blob', 'pattern', 'seqovl_pattern') {
            if ($args_.ContainsKey($k) -and $args_[$k] -notmatch '^0x[0-9A-Fa-f]+$' -and -not $blobs.ContainsKey($args_[$k])) { Fail ($at + $fn + ': блоб не заявлен: ' + $args_[$k]) }
        }
        if ($args_.ContainsKey('fool') -and -not $funcs.ContainsKey($args_['fool'])) { Fail ($at + 'нет функции порчи ' + $args_['fool']) }
        if ($fn -eq 'fake' -and -not $args_.ContainsKey('blob')) { Fail ($at + 'fake без blob') }
        if ($args_.ContainsKey('tls_mod')) {
            foreach ($mod in $args_['tls_mod'] -split ',') { if ($mod -notmatch $tlsMods) { Fail ($at + 'неизвестный tls_mod ' + $mod) } }
        }
        # Устаревший timestamp есть, только если его поддерживает сервер. Без него и без запасной порчи фейк дойдёт как настоящие данные
        if ($args_.ContainsKey('tcp_ts') -and -not ($args_.ContainsKey('fool') -or $args_.ContainsKey('tcp_md5') -or $args_.ContainsKey('tcp_seq') -or $args_.ContainsKey('badsum'))) {
            Fail ($at + $fn + ': tcp_ts без запасной порчи (fool=ts_or_md5, tcp_md5, tcp_seq)')
        }
        # Сегмент с неверным ACK Linux отбрасывает, только если timestamp идёт первой опцией (комментарий к tcp_ts_up в zapret-lib.lua)
        if ($args_.ContainsKey('tcp_ack') -and -not ($args_.ContainsKey('tcp_seq') -or $args_.ContainsKey('tcp_ts_up'))) {
            Fail ($at + $fn + ': tcp_ack без tcp_seq и без tcp_ts_up')
        }
    }
}
Write-Host ('проверено вызовов: ' + $checked)
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all ok' -ForegroundColor Green
