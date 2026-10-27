# --dry-run каждой стратегии по отдельности и кругов с новыми стратегиями (без перехвата трафика).
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$env:__COMPAT_LAYER = 'RunAsInvoker'
# всё - на копии пакета: настоящий runtime (рейтинг пользователя) не трогаем
$stage = Join-Path $env:TEMP ('nba-dry-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $stage | Out-Null
Copy-Item $Pkg (Join-Path $stage 'pkg') -Recurse
. (Join-Path $stage 'pkg\tools\lib.ps1')
$fails = 0
$all = @(Get-Strategies)
Write-Host ('strategies: ' + $all.Count + ' -> ' + (($all | ForEach-Object { $_.Id }) -join ','))
foreach ($st in $all) {
    if ($st.Missing.Count) { Write-Host ('MISSING ' + $st.Name + ': ' + ($st.Missing -join ',')) -ForegroundColor Red; $fails++; continue }
    $s = Get-Settings; $s.alt = $st.Id
    $r = Test-ConfigDry $s $st.Id -NoAuto -IpsetMode 'loaded'
    $own = if ($st.Sections.ContainsKey('ipset_tcp')) { ' [ipset_tcp]' } else { '' }
    if ($r.Ok) { Write-Host ('OK   {0,-3} {1}{2}' -f $st.Id, $st.Name, $own) -ForegroundColor Green }
    else { Write-Host ('FAIL {0,-3} {1}: {2}' -f $st.Id, $st.Name, ($r.Output -split "`n" | Select-Object -Last 3) -join ' | ') -ForegroundColor Red; $fails++ }
}
# круг из пяти разных по устройству стратегий: подменяем рейтинг на время проверки
$rankPath = Get-PkgPath $Script:RankFile
$backup = if (Test-Path $rankPath) { [System.IO.File]::ReadAllText($rankPath) } else { $null }
try {
    $lines = @('# date: 2026-10-27 12:00', 'base 20 54 DPI=10/36 Discord=0/4 YouTube=0/3', '7 45 45 54 0 0 DPI=30/36 Discord=4/4 YouTube=3/3',
        '5 44 44 54 0 0 DPI=30/36 Discord=4/4 YouTube=3/3', '45 43 43 54 0 0 DPI=30/36 Discord=4/4 YouTube=3/3',
        '41 42 42 54 0 0 DPI=30/36 Discord=4/4 YouTube=3/3', '3 41 41 54 0 0 DPI=30/36 Discord=4/4 YouTube=3/3')
    Write-TextNoBom $rankPath (($lines -join "`r`n") + "`r`n")
    $s = Get-Settings; $s.alt = '7'; $s.auto = 'on'
    Write-Host ('ring general: ' + ((Get-RotationOrder '7' 'general' | ForEach-Object { $_.Name }) -join ' > '))
    $r = Test-ConfigDry $s
    $cmd = Get-BypassCmdLine -Settings $s -Name 'devring'
    Write-Host ('ring dry-run: ' + $(if ($r.Ok) { 'OK' } else { 'FAIL ' + $r.Output })) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' })
    if (-not $r.Ok) { $fails++ }
    Write-Host ('ring cmdline: ' + $cmd.Length + ' chars, tcp_ipset own section: ' + ($cmd -match 'tcp_ipset"\s+(?:"--(?!import)[^"]*"\s+)*"--lua-desync=circular'))
    # без рейтинга: круг только из основных
    Remove-Item $rankPath
    Write-Host ('no-rank ring: ' + ((Get-RotationOrder '12' 'general' | ForEach-Object { $_.Id }) -join ','))
    Write-Host ('quick pool (no rank): ' + ((Get-TestStrategies | ForEach-Object { $_.Id }) -join ','))
    Write-Host ('full pool: ' + @(Get-TestStrategies -Full).Count)
} finally {
    if ($null -ne $backup) { [System.IO.File]::WriteAllText($rankPath, $backup, $Script:Utf8NoBom) }
    Remove-Item (Get-PkgPath 'runtime/args-devring.txt') -ErrorAction SilentlyContinue
}
Write-Host ('quick pool (real rank): ' + ((Get-TestStrategies | ForEach-Object { $_.Id }) -join ','))
Remove-Item $stage -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red } else { Write-Host 'all ok' -ForegroundColor Green }
