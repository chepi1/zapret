# hosts Flowseal - проверка, совет и запись на КОПИИ системного hosts (настоящий не трогаем).
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
. (Join-Path $Pkg 'tools\lib.ps1')
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }

$t = [Diagnostics.Stopwatch]::StartNew()
$st = Get-HostsStatus
Write-Host ('  status (' + $t.ElapsedMilliseconds + ' ms): ' + (Get-HostsStatusText $st))
foreach ($g in $st.Keys) { Write-Host ('    {0}: present={1} stale={2} missing={3} dups={4}' -f $g, $st[$g].Present, $st[$g].Stale, $st[$g].Missing, $st[$g].Dups) }
$t.Restart()
$rows = @(Test-HostsPins)
Write-Host ('  pins (' + [math]::Round($t.Elapsed.TotalSeconds, 1) + ' s):')
foreach ($x in $rows) { Write-Host ('    {0,-9} dns {1,-16} ok={2} {3,4} ms | pin {4,-16} ok={5} {6,4} ms -> {7}' -f $x.Group, $x.Dns.Ip, $x.Dns.Ok, $x.Dns.Ms, $x.Pin.Ip, $x.Pin.Ok, $x.Pin.Ms, $x.Verdict) }
$want = @(Get-HostsAdvice $rows $st)
Write-Host ('  advice: ' + ($want -join ', '))
Write-Host ('  ' + (Get-HostsReportText $rows $st))
Check 'youtube entries none' (@(Get-HostsYoutube).Count -eq 0)

# запись - в копию
$real = $Script:HostsFile
$Script:HostsFile = Join-Path $env:TEMP ('hosts-test-' + [guid]::NewGuid().ToString('N'))
Copy-Item $real $Script:HostsFile
$Script:Runtime = Join-Path $env:TEMP ('nba-hosts-rt-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $Script:Runtime | Out-Null
$origBytes = [System.IO.File]::ReadAllBytes($real)
Check 'write Telegram+Discord' (Set-HostsFlowseal @('Telegram', 'Discord'))
$b = [System.IO.File]::ReadAllBytes($Script:HostsFile)
$txt = [System.Text.Encoding]::UTF8.GetString($b)
Check 'BOM kept' ($b[0] -eq 0xEF -and $b[1] -eq 0xBB)
Check 'line endings kept (LF)' (-not $txt.Contains("`r`n") -or ([System.Text.Encoding]::UTF8.GetString($origBytes)).Contains("`r`n"))
Check 'docker lines kept' ($txt -match 'host\.docker\.internal' -and $txt -match 'kubernetes\.docker\.internal')
Check 'MS header kept' ($txt -match 'Copyright \(c\) 1993-2009 Microsoft Corp')
$s2 = Get-HostsStatus
Check 'GitHub removed' (-not $s2['GitHub'].Present)
Check 'Telegram once, current' ($s2['Telegram'].Present -and $s2['Telegram'].Dups -eq 0 -and $s2['Telegram'].Stale -eq 0 -and $s2['Telegram'].Missing -eq 0)
Check 'Discord once, current' ($s2['Discord'].Present -and $s2['Discord'].Dups -eq 0 -and $s2['Discord'].Missing -eq 0)
Check 'one marked block' (([regex]::Matches($txt, [regex]::Escape($Script:HostsBegin))).Count -eq 1 -and ([regex]::Matches($txt, [regex]::Escape($Script:HostsEnd))).Count -eq 1)
Check 'backup made' (@(Get-ChildItem $Script:Runtime -Filter 'hosts-*.bak').Count -eq 1)
Set-HostsFlowseal @('Telegram', 'Discord') | Out-Null
Check 'idempotent' ([System.IO.File]::ReadAllText($Script:HostsFile) -eq $txt)
Set-HostsFlowseal @() | Out-Null
$txt0 = [System.IO.File]::ReadAllText($Script:HostsFile)
$s3 = Get-HostsStatus
Check 'remove all' (-not $s3['GitHub'].Present -and -not $s3['Telegram'].Present -and -not $s3['Discord'].Present -and $txt0 -notmatch 'hosts Flowseal - начало')
Check 'docker kept after remove' ($txt0 -match 'host\.docker\.internal')
# блок, записанный версией до переименования (старые метки), узнаётся и заменяется новым
[System.IO.File]::AppendAllText($Script:HostsFile, "`n" + $Script:HostsLegacyBegin[0] + "`n149.154.167.220 t.me`n" + $Script:HostsLegacyEnd[0] + "`n")
Set-HostsFlowseal @('Telegram') | Out-Null
$txtL = [System.IO.File]::ReadAllText($Script:HostsFile)
Check 'legacy block replaced' ($txtL -notmatch 'NBA2K27-zapret2' -and ([regex]::Matches($txtL, [regex]::Escape($Script:HostsBegin))).Count -eq 1 -and (Get-HostsStatus)['Telegram'].Dups -eq 0)
Set-HostsFlowseal @($Script:HostsGroups.Keys) | Out-Null
$s4 = Get-HostsStatus
Check 'all like Flowseal' ($s4['GitHub'].Present -and $s4['GitHub'].Missing -eq 0 -and $s4['GitHub'].Dups -eq 0)
Write-Host '  --- tail of written copy:'
Get-Content $Script:HostsFile -Tail 4 | ForEach-Object { '    ' + $_ }

# серверы игр: TLS с проверкой имени (чужой сертификат - не годится), запись блока рядом с блоком Flowseal
$tls = @(Test-TlsIps 'api.quago.io' @('104.18.124.108'))
Check 'game pins: foreign certificate rejected' ($tls.Count -eq 1 -and -not $tls[0].Ok)
$u = Update-GamePins
Write-Host ('  game pins: ' + (Get-GamePinsText $u))
$gp = [System.IO.File]::ReadAllText($Script:HostsFile)
Check 'game pins: block written, Flowseal kept' ($gp -match [regex]::Escape($Script:GamePinsBegin) -and $gp -match [regex]::Escape($Script:HostsBegin))
$bak = @(Get-ChildItem $Script:Runtime -Filter 'hosts-*.bak').Count
Set-GamePins $u.Pins | Out-Null
Check 'game pins: unchanged - no rewrite' (@(Get-ChildItem $Script:Runtime -Filter 'hosts-*.bak').Count -eq $bak)
Set-HostsFlowseal @($Script:HostsGroups.Keys) | Out-Null
Check 'game pins: survive Flowseal rewrite' ([System.IO.File]::ReadAllText($Script:HostsFile) -match [regex]::Escape($Script:GamePinsBegin))
Set-GamePins @{} | Out-Null
$gp0 = [System.IO.File]::ReadAllText($Script:HostsFile)
Check 'game pins: removed, Flowseal kept' ($gp0 -notmatch 'quago' -and $gp0 -match [regex]::Escape($Script:HostsBegin))
Check 'real hosts untouched' ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($real)) -eq [Convert]::ToBase64String($origBytes))
Remove-Item $Script:HostsFile, $Script:Runtime -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
