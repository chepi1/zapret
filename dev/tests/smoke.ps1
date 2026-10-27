# Дымовой прогон настоящих скриптов без перехвата трафика и без прав администратора:
#  - функции меню: шапка, проверка подключения, тексты кругов и автонастройки (strict mode из lib.ps1);
#  - отчёт R целиком (report.ps1 -NoPrompt -NoOpen);
#  - трекер по записанному журналу сети: -Etl <файл.etl> -EtlPid <PID игры> (track.ps1 -Replay).
# Лучше запускать на копии папки (run-all.ps1 так и делает): отчёт и трекер пишут файлы в runtime.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)), [string]$Etl, [int]$EtlPid = 0)
$fails = 0
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $Pkg 'tools\lib.ps1')
# функции меню без его главного цикла
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools\menu.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$s = Get-Settings
# вопросы меню - сразу пустой ответ ("ничего не менять")
function Read-Host { return '' }
function Pause-Menu { }
$steps = [ordered]@{
    'шапка меню'           = { Show-Header }
    'главный экран'        = { Show-Main }
    'настройки (N)'        = { Show-SettingsMenu }
    'инструменты (I)'      = { Show-ToolsMenu }
    'выбор стратегии (4)'  = { Select-AltManual }
    'неизвестное действие' = { Invoke-MenuAction 'нет-такого' }
    'проверка обходов (C)'      = { Show-PcCheck }
    'проверка подключения' = { Show-ConnectionCheck | Out-Null }
    'стратегия и круги'    = { Get-AltText $s; Get-RingsText $s }
    'автонастройка'        = { Get-AutotuneText; Test-AutotuneRunning }
    'hosts'                = { Get-HostsStatusText (Get-HostsStatus); Get-HostsYoutube }
    'ускорители'           = { Get-GameBoosters }
    'командная строка'     = { Get-BypassCmdLine -Settings $s -Name 'smoke' }
}
foreach ($k in $steps.Keys) {
    try { & $steps[$k] *> $null; Write-Host ('ok   ' + $k) -ForegroundColor Green }
    catch { Write-Host ('FAIL ' + $k + ': ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage) -ForegroundColor Red; $fails++ }
}
# сбой запуска: причина и подсказки по выводу winws2 - без настоящего winws2 и без настоящей службы
$realService = $Script:ServiceName
$origInvoke = ${function:Invoke-Native}; $origStop = ${function:Stop-Bypass}
$Script:ServiceName = 'zapret-smoke-none'
$errFile = Join-Path $Script:Runtime 'start-error.txt'
function Invoke-Native { return New-Object PSObject -Property @{ ExitCode = 1; TimedOut = $false; Output = "github version v1.0.6`nwindivert: error opening filter: Access is denied." } }
function Start-Process { $script:fallbackStarted = $true }
# настоящий Stop-Bypass остановил бы обход этого ПК, если тест запущен не на копии
function Stop-Bypass { }
$script:fallbackStarted = $false
$sf1 = Show-StartFailure 'Служба не ответила на запрос своевременно.' (Get-Date).AddMinutes(-1) 6>$null
$t1 = [System.IO.File]::ReadAllText($errFile)
$fb1 = $script:fallbackStarted
function Invoke-Native { return New-Object PSObject -Property @{ ExitCode = -1; TimedOut = $true; Output = 'github version v1.0.6' } }
$sf2 = Show-StartFailure '' (Get-Date).AddMinutes(-1) 6>$null
$t2 = [System.IO.File]::ReadAllText($errFile)
${function:Invoke-Native} = $origInvoke; ${function:Stop-Bypass} = $origStop; Remove-Item function:Start-Process
$Script:ServiceName = $realService
$okFail = ($sf1 -eq $false) -and $t1.Contains('Access is denied') -and $t1.Contains('антивирус блокирует') -and $t1.Contains('не ответила Windows вовремя') -and -not $fb1
$okSvc = ($sf2 -eq $false) -and $t2.Contains('сбой только у службы') -and $script:fallbackStarted
if ($okFail -and $okSvc) { Write-Host 'ok   причина сбоя запуска' -ForegroundColor Green }
else { Write-Host ('FAIL причина сбоя запуска: sf1={0} sf2={1} fallback={2} | {3} || {4}' -f $sf1, $sf2, $script:fallbackStarted, $t1, $t2) -ForegroundColor Red; $fails++ }
# новое в 1.2: Steam на выключенном прокси (по журналу Steam), исключение игры по трекеру, план обновления, правила для прокси
$tmpDir = Join-Path $env:TEMP ('zapret-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpDir | Out-Null
$now = Get-Date
$steamLog = Join-Path $tmpDir 'connection_log.txt'
[System.IO.File]::WriteAllLines($steamLog, @(
    ('[{0:yyyy-MM-dd HH:mm:ss}] [Logged Off, 4, 0] ConnectionDisconnected(''Disconnected By Remote Host'') : ''OK'' (127.0.0.1:10809, WebSocket)' -f $now),
    ('[{0:yyyy-MM-dd HH:mm:ss}] [Connecting, 4, 2] Connect() starting connection (162.254.197.1:27017, UDP)' -f $now)))
$proxyOk = (Test-SteamProxyLog @(10809) $steamLog $now.AddMinutes(-1)) -and -not (Test-SteamProxyLog @(10808) $steamLog $now.AddMinutes(-1)) -and -not (Test-SteamProxyLog @(10809) $steamLog $now.AddMinutes(5))
$trackLog = Join-Path $tmpDir 'track.txt'
[System.IO.File]::WriteAllLines($trackLog, @(
    'zapret v1.2 - трекер (dota2), начало 2026-10-27 20:32:31',
    'Все адреса (пакетов всего вых/вх, повторных отправок TCP, мин. пинг, где, обход):',
    '  UDP 185.25.182.10:27015                          dota2        100/90     retx 0   пинг 40      Вена AT | обход: да',
    '  UDP [2a01:bc80:4::13]:27019                       dota2        10/10      retx 0   пинг 40      Вена AT | обход: да (user)',
    '  TCP 155.133.229.5:27018                          steam        10/10      retx 0   пинг 40      Вена AT | обход: нет (Valve)',
    '  UDP 104.29.153.97:19336                          Discord      23/0       retx 0   пинг молчит  NL | обход: да (голос)'))
$tb = Get-TrackBypassedNets $trackLog
$trackOk = $tb.App -eq 'dota2' -and (@($tb.Nets) -join ',') -eq '185.25.182.0/24,2a01:bc80:4::/64'
$src = Join-Path $tmpDir 'new\zapret'; $dst = Join-Path $tmpDir 'old'
foreach ($p in @('tools\lib.ps1', 'lists\ipset-user.txt', 'lists\ipset-all.txt', 'lists\ipset-valve.txt', 'lists\new-list.txt', 'runtime\.keep', 'bin\same.bin')) {
    foreach ($base in @($src, $dst)) { New-Item -ItemType Directory (Split-Path -Parent (Join-Path $base $p)) -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $src $p), 'new ' + $p)
    if ($p -ne 'lists\new-list.txt') { [System.IO.File]::WriteAllText((Join-Path $dst $p), $(if ($p -eq 'bin\same.bin') { 'new ' + $p } else { 'old ' + $p })) }
}
$plan = @(Get-UpdatePlan $src $dst | Sort-Object)
$planOk = ($plan -join ',') -eq 'lists\ipset-valve.txt,lists\new-list.txt,tools\lib.ps1'
$rules = @(Get-DirectRulesText)
$rulesOk = ($rules -contains 'domain:steampowered.com') -and ($rules -contains '155.133.224.0/21') -and -not ($rules -match 'steamcommunity')
$stuckOk = $true
try { Get-ProxyStuckApps | Out-Null; Get-ProxyAppsNow | Out-Null } catch { $stuckOk = $false }
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
if ($proxyOk -and $trackOk -and $planOk -and $rulesOk -and $stuckOk) { Write-Host 'ok   прокси, исключение игры, план обновления, правила' -ForegroundColor Green }
else { Write-Host ('FAIL 1.2: proxy={0} track={1} ({2}) plan={3} ({4}) rules={5} stuck={6}' -f $proxyOk, $trackOk, (@($tb.Nets) -join ','), $planOk, ($plan -join ','), $rulesOk, $stuckOk) -ForegroundColor Red; $fails++ }
# новые версии: сравнение по числам и своя версия по сохранённой проверке - без сети
$uf = Get-PkgPath $Script:UpdatesFile
$savedUpd = if (Test-Path $uf) { [System.IO.File]::ReadAllText($uf) } else { $null }
$cmp = @((Test-NewerVersion 'v1.0.7' 'v1.0.6'), (Test-NewerVersion '1.10.4' '1.9'), (Test-NewerVersion 'v2' '1.1'), (-not (Test-NewerVersion 'v1.0' '1.0')), (-not (Test-NewerVersion 'v1.0' '1.1')))
Write-TextNoBom $uf "zapret2=v1.0.6`r`nFlowseal=1.10.4`r`nzapret=v9.9`r`n"
$newer = Get-ZapretUpdate
$all = @(Get-AllNews)
$hdr = ''; try { $hdr = (Show-Header 6>&1 | Out-String) } catch { $hdr = 'ERROR ' + $_.Exception.Message }
Write-TextNoBom $uf "zapret=v1.0`r`n"
$older = Get-ZapretUpdate
if ($null -ne $savedUpd) { Write-TextNoBom $uf $savedUpd } else { Remove-Item $uf -ErrorAction SilentlyContinue }
if (-not @($cmp | Where-Object { -not $_ }).Count -and $newer -eq 'v9.9' -and $all.Count -eq 1 -and $all[0] -like 'zapret v9.9*' -and -not $older -and $hdr -match 'новая версия zapret v9\.9') {
    Write-Host 'ok   новые версии zapret' -ForegroundColor Green
} else { Write-Host ('FAIL новые версии zapret: cmp=' + ($cmp -join ',') + ' newer=' + $newer + ' all=' + ($all -join '; ') + ' older=' + $older) -ForegroundColor Red; $fails++ }
$before = @(Get-ChildItem (Join-Path $Pkg 'runtime') -Filter 'report-*.txt' -ErrorAction SilentlyContinue).Count
$out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Pkg 'tools\report.ps1') -NoPrompt -NoOpen 2>&1
$rep = @(Get-ChildItem (Join-Path $Pkg 'runtime') -Filter 'report-*.txt' | Sort-Object LastWriteTime -Descending)
if ($LASTEXITCODE -eq 0 -and $rep.Count -gt $before) {
    $text = [System.IO.File]::ReadAllText($rep[0].FullName)
    Write-Host ('ok   отчёт R: ' + $rep[0].Name + ', ' + $text.Length + ' символов')
    # отчёт пересылают: свой внешний IP в нём должен быть замаскирован (последний октет - x)
    $self = Get-DirectConnectionInfo
    if ($self -and $text.Contains($self.Ip)) { Write-Host 'FAIL в отчёте открытый внешний IP' -ForegroundColor Red; $fails++ }
    if ($text -match ('\\Users\\' + [regex]::Escape($env:USERNAME) + '\\')) { Write-Host 'FAIL в отчёте имя пользователя Windows' -ForegroundColor Red; $fails++ }
} else { Write-Host ('FAIL отчёт R: ' + ($out | Out-String)) -ForegroundColor Red; $fails++ }
if ($Etl) {
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Pkg 'tools\track.ps1') -Replay $Etl -ReplayPid $EtlPid 2>&1
    $tr = Join-Path $Pkg 'runtime\track-replay.txt'
    if ($LASTEXITCODE -eq 0 -and (Test-Path $tr) -and ([System.IO.File]::ReadAllText($tr) -match 'Итог')) {
        Write-Host ('ok   трекер по журналу: ' + @([System.IO.File]::ReadAllLines($tr)).Count + ' строк')
    } else { Write-Host ('FAIL трекер по журналу: ' + (($out | Select-Object -Last 8) -join ' | ')) -ForegroundColor Red; $fails++ }
}
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
