# Живая проверка автосмены: те же запросы, что в автоподборе (POST 64 КБ), идут через работающий обход к адресам, которые
# открывает не первая стратегия круга (по runtime\test-cover.txt). Обход не запускается и не останавливается, настройки
# не меняются. Ожидается: первая попытка не проходит, следующие - проходят, сайт появляется в памяти (runtime\ring).
# Запускать при выключенном VPN: через туннель проверять нечего.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), [int]$Tries = 4, [int]$Max = 6)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $Pkg 'tools\lib.ps1')
if (@(Get-TunAdapters).Count) { Write-Host 'Включён VPN в режиме туннеля: выключите его и запустите проверку снова.' -ForegroundColor Yellow; exit 1 }
$running = @(Get-Process -Name 'winws2' -ErrorAction SilentlyContinue).Count
if (-not $running) { Write-Host 'Обход не запущен.' -ForegroundColor Yellow; exit 1 }
$s = Get-Settings
$ring = @(Get-RotationOrder $s.alt 'general')
Write-Host ('Круг: ' + (($ring | ForEach-Object { $_.Name }) -join ' > '))
$cover = Get-TestCover
if (-not $cover) { Write-Host 'Нет runtime\test-cover.txt: сначала автоподбор.' -ForegroundColor Yellow; exit 1 }
$firstKeys = @($cover[$ring[0].Id])
$want = New-Object System.Collections.Generic.List[string]
foreach ($st in ($ring | Select-Object -Skip 1)) {
    foreach ($k in @($cover[$st.Id])) { if ($k.StartsWith('DPI|') -and $firstKeys -notcontains $k -and -not $want.Contains($k)) { $want.Add($k) } }
}
Write-Host ('Адреса, которые открывает не первая стратегия: ' + $want.Count)
$suite = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $Pkg 'tools\dpi-suite.json'), [System.Text.Encoding]::UTF8))
$fresh = Join-Path $Pkg 'runtime\dpi-suite.json'
if (Test-Path $fresh) { $suite = ConvertFrom-Json ([System.IO.File]::ReadAllText($fresh, [System.Text.Encoding]::UTF8)) }
$post = Join-Path $Pkg 'runtime\post64k.bin'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$done = 0
foreach ($k in $want) {
    if ($done -ge $Max) { break }
    $id = (($k -split '[|]')[1] -split ' ')[0]
    $x = @($suite) | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $x) { Write-Host ('  ' + $k + ': нет в наборе'); continue }
    $done++
    Write-Host ('{0} ({1})' -f $k.Substring(4), $x.provider)
    for ($i = 1; $i -le $Tries; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $a = '-s -o NUL --noproxy "*" --ssl-no-revoke --http1.1 --max-time 6 --connect-timeout 4 -r 0-65535 -w "%{http_code} %{size_upload} %{size_download}" -X POST --data-binary "@' + $post + '" "https://' + $x.host + '/"'
        $r = Invoke-Native $curl $a $Script:Runtime 12
        $p = @($r.Output -split ' ')
        $up = if ($p.Count -ge 2) { [int64]$p[1] } else { 0 }
        Write-Host ('  попытка {0}: код {1}, curl {2}, отправлено {3}, получено {4}, {5:N1} с - {6}' -f $i, $p[0], $r.ExitCode, $up, $(if ($p.Count -ge 3) { $p[2] }), $sw.Elapsed.TotalSeconds, $(if ($r.ExitCode -eq 0 -and $up -ge 65536) { 'OK' } else { 'не прошло' }))
    }
}
Write-Host '--- память автосмены (хостинги из проверки, без остальных сайтов):'
$hosts = @(@($suite) | ForEach-Object { $_.host })
foreach ($f in @(Get-ChildItem (Get-PkgPath $Script:RingDir) -Filter 'ring-*.txt' -ErrorAction SilentlyContinue)) {
    $lines = @([System.IO.File]::ReadAllLines($f.FullName))
    Write-Host ('  {0}: записей {1}' -f $f.Name, $lines.Count)
    # только проверочные хостинги: остальное в файле - сайты, которые открывал пользователь
    foreach ($h in $hosts) {
        $nld = (@($h -split '[.]') | Select-Object -Last 2) -join '.'
        foreach ($l in @($lines | Where-Object { $_.StartsWith($nld + ' ') })) { Write-Host ('    ' + $l) }
    }
}
Write-Host ('Падений обхода за час: ' + @(Get-BypassCrashes (Get-Date).AddHours(-1)).Count)
