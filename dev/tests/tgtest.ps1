# Встроенный мост Telegram вживую: мост на отдельном порту со случайным secret, через него - первый запрос входа
# (req_pq_multi, без учётной записи) к DC2 и DC4, обычным и медиа. Telegram отвечает resPQ - путь работает.
# Ходит в интернет (веб-вход Telegram), поэтому run-all.ps1 -Offline его пропускает. Трафик не перехватывается.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { Write-Host 'Тест пишет файлы в runtime: запускайте его через run-all.ps1, на копии папки.' -ForegroundColor Red; exit 1 }
$fails = 0
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmp = Join-Path $env:TEMP ('zapret-tgtest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$secret = -join @((1..16) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
$port = 14430 + (Get-Random -Maximum 500)
$bridge = Join-Path $Pkg 'tools\tgbridge.ps1'
$p = Start-Process $ps -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $bridge + '" -Port ' + $port + ' -Secret ' + $secret + ' -Log "' + $tmp + '\bridge.log"') -WindowStyle Hidden -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) {
    Start-Sleep -Milliseconds 250
    $up = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq $port }).Count -gt 0
}
if (-not $up) { Write-Host 'FAIL мост не запустился' -ForegroundColor Red; $fails++ }
else {
    foreach ($dc in @(2, 4, -2, -4, 2, 4)) {
        $out = (& $ps -NoProfile -ExecutionPolicy Bypass -File $bridge -Port $port -Secret $secret -LiveTest $dc 2>&1 | Out-String).Trim()
        if ($out -eq 'ok') { Write-Host ('ok   DC' + $dc + ': Telegram ответил через мост') -ForegroundColor Green }
        else { Write-Host ('FAIL DC' + $dc + ': ' + $out) -ForegroundColor Red; $fails++ }
    }
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
# PID-файл мост пишет в runtime копии - там он и останется, настоящий runtime не трогается
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
