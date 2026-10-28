# Все проверки разработчика по очереди - на копии папки, настоящий runtime не трогается.
# Трафик не перехватывается: winws2 запускается только с --dry-run. liststest и hoststest ходят в интернет
# (GitHub, DNS, TLS к GitHub/Telegram/Discord, мост Telegram); -Offline их пропускает.
param([switch]$Offline)
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stage = Join-Path $env:TEMP ('nba-tests-' + [guid]::NewGuid().ToString('N'))
$pkg = Join-Path $stage 'pkg'
& robocopy.exe $root $pkg /E /XD .git dist /NFL /NDL /NJH /NJS /NP | Out-Null
$tests = @('astlint', 'check', 'drystrat', 'retrytest', 'autotunetest', 'boostertest', 'securitytest', 'smoke')
if (-not $Offline) { $tests += @('liststest', 'hoststest', 'tgtest') }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failed = @()
foreach ($t in $tests) {
    Write-Host ('===== ' + $t) -ForegroundColor Cyan
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot ($t + '.ps1')) -Pkg $pkg
    if ($LASTEXITCODE -ne 0) { $failed += $t }
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($failed.Count) { Write-Host ('НЕ ПРОШЛИ: ' + ($failed -join ', ')) -ForegroundColor Red; exit 1 }
Write-Host 'Все проверки прошли.' -ForegroundColor Green
