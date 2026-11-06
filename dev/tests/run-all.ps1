# Все проверки разработчика по очереди - на копии папки, настоящий runtime не трогается.
# Трафик не перехватывается: winws2 запускается с --dry-run или пустым фильтром --intercept=0 (luatest). liststest и hoststest ходят в интернет
# (GitHub, DNS, TLS к GitHub/Telegram/Discord, мост Telegram); -Offline их пропускает.
param([switch]$Offline)
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stage = Join-Path $env:TEMP ('nba-tests-' + [guid]::NewGuid().ToString('N'))
$stage = [IO.Path]::GetFullPath($stage)
if ([IO.Path]::GetDirectoryName($stage) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) { throw 'Unsafe test directory' }
$pkg = Join-Path $stage 'pkg'
& robocopy.exe $root $pkg /E /XD .git dist runtime /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -lt 0 -or $LASTEXITCODE -ge 8) { throw ('robocopy: ошибка ' + $LASTEXITCODE) }
$tests = @('astlint', 'check', 'lintstrat', 'profiletest', 'capturetest', 'drystrat', 'retrytest', 'retrybudgettest', 'primarydecisiontest', 'selectiontest', 'measurementtest', 'curlcontroltest', 'curlresulttest', 'curlfailuretest', 'curldeadlinetest', 'curlenginetest', 'comparisontest', 'comparisonruntest', 'resourcetest', 'resourceprocesstest', 'latencytest', 'latencyprobetest', 'rankcontexttest', 'starttest', 'coordinatortest', 'healthtest', 'historytest', 'proxytest', 'netstatetest', 'contexttest', 'watchtest', 'watchluatest', 'linkguardtest', 'storeluatest', 'finalchecktest', 'guardtest', 'dnstest', 'updatetest', 'recoverytest', 'labtest', 'luatest', 'autotunetest', 'boostertest', 'securitytest', 'smoke')
$tests += @('hostcachetest','watchcodetest','restarttest','filtertest','buildtest','settingstest','migrationtest','convertertest','updatearchivetest','tgproxytest')
$tests += @('recipetest','reciperuntest')
$tests += @('integritytest')
$tests += @('menutest')
$tests += @('launchtest')
$tests += @('tgembedtest')
if (-not $Offline) { $tests += @('liststest', 'hoststest', 'tgtest') }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failed = @()
foreach ($t in $tests) {
    Write-Host ('===== ' + $t) -ForegroundColor Cyan
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot ($t + '.ps1')) -Pkg $pkg
    if ($LASTEXITCODE -ne 0) { $failed += $t }
}
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($failed.Count) { Write-Host ('НЕ ПРОШЛИ: ' + ($failed -join ', ')) -ForegroundColor Red; exit 1 }
Write-Host 'Все проверки прошли.' -ForegroundColor Green
