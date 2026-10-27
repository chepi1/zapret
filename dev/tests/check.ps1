# Проверка пакета без перехвата трафика: BOM и синтаксис скриптов, winws2 --dry-run на разных настройках,
# состав профилей и длина командной строки. Права администратора не нужны.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$fails = 0
# Windows PowerShell 5.1 без BOM читает русские строки скриптов в кодировке ANSI и ломается
foreach ($f in @(Get-ChildItem (Join-Path $Pkg 'tools\*.ps1')) + @(Get-ChildItem (Join-Path $Pkg 'dev\tests\*.ps1'))) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { "FAIL no BOM: $($f.Name)"; $fails++ }
}
foreach ($f in Get-ChildItem (Join-Path $Pkg 'tools\*.ps1')) {
    $t = $null; $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e.Count) { $fails++; "FAIL parse $($f.Name):"; $e | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" } }
}
'syntax checked'
# у winws2.exe в манифесте requireAdministrator; --dry-run выходит до открытия WinDivert, поэтому запускаем как есть
$env:__COMPAT_LAYER = 'RunAsInvoker'
. (Join-Path $Pkg 'tools\lib.ps1')
Update-RuntimeLists
$base = Get-Settings
foreach ($st in Get-Strategies) { if ($st.Missing.Count) { "FAIL $($st.Name): нет секций $($st.Missing -join ',')"; $fails++ } }
$cases = @()
foreach ($alt in @('10', '11', '12', '13', '21', '22', '23')) { foreach ($auto in @('on', 'off')) { $cases += @{ alt = $alt; auto = $auto } } }
foreach ($game in @('tcp', 'udp', 'off')) { $cases += @{ game = $game } }
foreach ($ip in @('any', 'none')) { $cases += @{ ipset = $ip } }
$cases += @{ autolist = 'off' }
foreach ($c in $cases) {
    $s = $base.Clone(); foreach ($k in $c.Keys) { $s[$k] = $c[$k] }
    $label = 'alt={0} auto={1} game={2} ipset={3} autolist={4}' -f $s.alt, $s.auto, $s.game, $s.ipset, $s.autolist
    $cmd = Get-BypassCmdLine -Settings $s -Name 'check' -DryRun
    $x = Invoke-Native $Script:Exe $cmd $Script:Bin 60
    # cygwin изредка падает при старте молча - как и пакет, пробуем ещё раз
    if ($x.ExitCode -ne 0 -and -not $x.Output) { Start-Sleep -Milliseconds 500; $x = Invoke-Native $Script:Exe $cmd $Script:Bin 60 }
    if ($x.ExitCode -eq 0) { "ok   $label" } else { $fails++; ('FAIL {0} exit={1} output=[{2}]' -f $label, $x.ExitCode, $x.Output) }
}
$list = New-BypassArgList -Settings $base
'profiles: ' + ((@($list | Where-Object { $_ -match '^--(name|new)=' }) | ForEach-Object { $_ -replace '^--(name|new)=', '' }) -join ', ')
if (@($list | Where-Object { $_ -match '^--ipset-exclude=.*taketwo' }).Count -lt 8) { 'FAIL серверы Take-Two исключены не во всех профилях'; $fails++ }
if (@($list | Where-Object { $_ -match '^--ipset-exclude=.*valve' }).Count -lt 8) { 'FAIL серверы Valve исключены не во всех профилях'; $fails++ }
$len = (ConvertTo-WinCmdLine $list).Length
'cmdline length: ' + $len
if ($len -gt 30000) { 'FAIL командная строка близко к пределу Windows'; $fails++ }
if ($fails) { "$fails FAILED"; exit 1 } else { 'all ok' }
