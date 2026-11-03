# проверка повторов автоподбора (Merge-Retry, Get-RetryTargets, Get-RunSummary) и файла рейтинга с полбаллами.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { Write-Host 'Тест пишет файлы в runtime: запускайте его через run-all.ps1, на копии папки.' -ForegroundColor Red; exit 1 }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
function Get-NetworkObservation { [pscustomobject]@{Known=$true;Key=('A'*64);ObservedUtc=[datetime]::UtcNow} }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools\test.ps1'), [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$GroupNames = [ordered]@{ DPI = '16-20 КБ'; Discord = 'Discord'; YouTube = 'YouTube'; SoundCloud = 'SoundCloud'; NBA2K = '2K'; EAC = 'EAC/Epic'; Clean = 'без блока' }
$HarmSlowMs = 500; $RetryMax = 16; $Parallel = 16
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }
function Row($G, $N, $S, $Tls = 100) {
    New-Object PSObject -Property @{ Group = $G; Name = $N; Url = "https://$N/"; State = $S; Code = $(if ($S -eq 'OK') { '200' } else { '000' }); Exit = 0
        Up = 0.0; Down = 0.0; ConnMs = 50; TlsMs = $Tls; Tries = 1; Flaky = $false }
}
function Tgt($G, $N) { New-Object PSObject -Property @{ Group = $G; Name = $N; Url = "https://$N/"; Post = $false } }

$targets = @((Tgt DPI a), (Tgt DPI b), (Tgt YouTube yt), (Tgt Clean bing), (Tgt Clean adobe), (Tgt Clean sony), (Tgt Clean apple))
$base = @{ bing = 100; adobe = 100; sony = 100; apple = 100 }
$rows = @((Row DPI a OK), (Row DPI b FREEZE), (Row YouTube yt FAIL), (Row Clean bing FAIL), (Row Clean adobe OK 900), (Row Clean sony OK 120), (Row Clean apple FAIL))
$again = @(Get-RetryTargets $targets $rows $base)
Check 'retry picks fail/freeze/slow clean' ((($again | ForEach-Object { $_.Name }) -join ',') -eq 'b,yt,bing,adobe,apple')
$again0 = @(Get-RetryTargets $targets $rows $null)
Check 'base run: no slow check' ((($again0 | ForEach-Object { $_.Name }) -join ',') -eq 'b,yt,bing,apple')
# безнадёжный заблокированный адрес не перепроверяется, незаблокированные сайты (вред) - всегда
$hb = @{ (Get-RowKey ($rows | Where-Object { $_.Name -eq 'b' })) = $true; (Get-RowKey ($rows | Where-Object { $_.Name -eq 'bing' })) = $true }
$againH = @(Get-RetryTargets $targets $rows $base $hb)
Check 'hopeless blocked skipped, clean kept' ((($againH | ForEach-Object { $_.Name }) -join ',') -eq 'yt,bing,adobe,apple')

$retry = @((Row DPI b FREEZE), (Row YouTube yt OK 200), (Row Clean bing OK 110), (Row Clean adobe OK 700), (Row Clean apple FAIL))
$m = @(Merge-Retry $rows $retry)
$by = @{}; foreach ($r in $m) { $by[$r.Name] = $r }
Check 'b stays freeze' ($by.b.State -eq 'FREEZE' -and -not $by.b.Flaky -and $by.b.Tries -eq 2)
Check 'yt flaky ok' ($by.yt.State -eq 'OK' -and $by.yt.Flaky -and $by.yt.TlsMs -eq 200)
Check 'bing flaky ok' ($by.bing.State -eq 'OK' -and $by.bing.Flaky)
Check 'adobe min tls' ($by.adobe.TlsMs -eq 700 -and -not $by.adobe.Flaky)
Check 'apple still fail' ($by.apple.State -eq 'FAIL')
Check 'a untouched' ($by.a.Tries -eq 1)

$s = Get-RunSummary '11' 'ALT11' $m $base
# пробито: a OK, b нет, yt OK со второй = 1 + 0.5 = 1.5 из 3; вред: adobe 700>600, apple не открылся = 2; bing - не вред
Check ('points 1.5 got ' + $s.Ok) ($s.Ok -eq 1.5)
Check ('harm 2 got ' + $s.Harm + ' ' + ($s.HarmList -join ';')) ($s.Harm -eq 2)
Check ('score -0.5 got ' + $s.Score) ($s.Score -eq -0.5)
Check 'youtube group 0.5' ($s.Groups['YouTube'].Ok -eq 0.5)
Check 'flaky list' ((($s.FlakyList | Sort-Object) -join ',') -eq 'bing,yt')
$line = Format-Summary $s
Write-Host $line
Check 'summary has 1.5' ($line -match '1\.5/3' -and $line -match 'YouTube 0\.5/1')

# много сбоев у заблокированных - повторяем только Clean
$many = @(); $tg = @()
for ($i = 0; $i -lt 20; $i++) { $many += (Row DPI ("h$i") FREEZE); $tg += (Tgt DPI ("h$i")) }
$many += (Row Clean bing FAIL); $tg += (Tgt Clean bing)
$ag = @(Get-RetryTargets $tg $many $base)
Check 'over RetryMax: only clean' ($ag.Count -eq 1 -and $ag[0].Name -eq 'bing')

# файл рейтинга: дробные баллы туда и обратно, старый формат читается
$Script:RankFile = 'runtime/dev-rank-check.txt'
$b0 = Get-RunSummary '0' 'без обхода' @((Row DPI a FREEZE), (Row DPI b FREEZE), (Row YouTube yt FAIL), (Row Clean bing OK)) $null
Save-TestRank $b0 @($s)
$rk = Get-TestRank
Check ('rank roundtrip score ' + $rk.Rows[0].Score) ($rk.Rows[0].Score -eq -0.5 -and $rk.Rows[0].Ok -eq 1.5 -and $rk.Rows[0].Groups['YouTube'] -eq 0.5)
Write-Host ([System.IO.File]::ReadAllText((Get-PkgPath $Script:RankFile)))
Remove-Item (Get-PkgPath $Script:RankFile)
$Script:RankFile = 'runtime/test-rank.txt'
# рейтинг этого ПК (если автоподбор уже запускали) читается и даёт круги
$real = Get-TestRank
if ($real) {
    # стратегии, убранные обновлением, из рейтинга выпадают
    $lines = @([System.IO.File]::ReadAllLines((Get-PkgPath $Script:RankFile)) | Where-Object { $_ -match '^(\d+)\s' -and (Get-Strategy $matches[1]) })
    Check ('real rank parses (' + $lines.Count + ' rows)') ($real -and $real.Rows.Count -eq $lines.Count -and $real.BaseOk -gt 0)
    Write-Host ('  youtube ring: ' + ((Get-SectionRank $real 'google') -join ',') + ' | general ring: ' + ((Get-SectionRank $real 'general') -join ','))
    Check 'real rings not empty' (@(Get-SectionRank $real 'google').Count -ge 1 -and @(Get-SectionRank $real 'general').Count -ge 1)
} else { Write-Host '  (рейтинга этого ПК нет - автоподбор ещё не запускали)' }

# средний балл: основную не меняет случайный разброс между прогонами
$Script:ScoreHistoryFile = 'runtime/dev-scores-check.txt'
function Alt([string]$Id, $Name, $Score, $Freeze = 0) { New-Object PSObject -Property @{ Id = $Id; Name = $Name; Score = [double]$Score; Freeze = $Freeze } }
$order = @('50', '58', '60')
$r1 = @((Alt 50 'белый 1' 47), (Alt 58 'белый 4' 46))
Add-ScoreHistory $r1 test-context | Out-Null
$av = Get-AverageScores $r1 test-context
$c = Get-PrimaryChoice $r1 $av '50' $order
Check 'one run: leader stays' ($c.Top.Id -eq '50' -and -not $c.Noise -and $av['50'].Runs -eq 1)
$r2 = @((Alt 50 'белый 1' 44), (Alt 58 'белый 4' 47.5))
Add-ScoreHistory $r2 test-context | Out-Null
$av = Get-AverageScores $r2 test-context
$c = Get-PrimaryChoice $r2 $av '50' $order
Check ('noise: avg 45.5 vs 46.75 got ' + $av['50'].Avg + ' ' + $av['58'].Avg) ($av['50'].Avg -eq 45.5 -and $av['58'].Avg -eq 46.75 -and $c.Top.Id -eq '58' -and $c.Noise -and $c.Current.Id -eq '50')
$r3 = @((Alt 50 'белый 1' 44), (Alt 58 'белый 4' 48))
Add-ScoreHistory $r3 test-context | Out-Null
$av = Get-AverageScores $r3 test-context
$c = Get-PrimaryChoice $r3 $av '50' $order
Check 'clear gap: change offered' ($c.Top.Id -eq '58' -and -not $c.Noise -and $av['58'].Runs -eq 3)
$r4 = @((Alt 50 'белый 1' 46), (Alt 58 'белый 4' 48))
Add-ScoreHistory $r4 test-context | Out-Null
$av = Get-AverageScores $r4 test-context
Check ('only last 3 runs got ' + $av['50'].Runs + ' ' + (Format-Points $av['50'].Avg)) ($av['50'].Runs -eq 3 -and [math]::Abs($av['50'].Avg - 134 / 3) -lt 0.001)
$c = Get-PrimaryChoice $r4 $av '60' $order
Check 'primary not tested: no noise block' ($c.Top.Id -eq '58' -and -not $c.Noise -and -not $c.Current)
$tie = @((Alt 50 'x' 40), (Alt 58 'y' 40))
$tieAvg = @{ '50' = (New-Object PSObject -Property @{ Avg = 40.0; Runs = 1 }); '58' = (New-Object PSObject -Property @{ Avg = 40.0; Runs = 1 }) }
Check 'tie: primary wins' ((Get-PrimaryChoice $tie $tieAvg '58' $order).Top.Id -eq '58')
# другой файл под тем же номером и старые прогоны в среднее не идут; испорченные строки не мешают
$old = (Get-Date).AddDays(-40).ToString('yyyy-MM-dd HH:mm')
$new = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd HH:mm')
Write-TextNoBom (Get-PkgPath $Script:ScoreHistoryFile) ("# comment`r`n$old|50|a|10`r`n$new|50|b|20`r`n$new|50|a|30`r`nbroken line`r`n$new|50|a|x`r`n")
$av = Get-AverageScores @((Alt 50 'a' 32)) test-context
Check ('old, renamed and broken skipped got ' + $av['50'].Avg) ($av['50'].Avg -eq 32 -and $av['50'].Runs -eq 1)
Remove-Item (Get-PkgPath $Script:ScoreHistoryFile)
$Script:ScoreHistoryFile = 'runtime/test-scores.txt'

# круг по покрытию: за первой идёт та, что открывает другие адреса, даже со слабым баллом
$Script:CoverFile = 'runtime/dev-cover-check.txt'
function RankRow($Id, $Score) { New-Object PSObject -Property @{ Id = $Id; Score = [double]$Score; Freeze = 0 } }
$coverContext = Get-TestResultContext
$rankC = New-Object PSObject -Property @{ Context = $coverContext; Rows = @((RankRow '58' 47), (RankRow '52' 46), (RankRow '51' 45), (RankRow '13' 13), (RankRow '9' 10), (RankRow '7' 9)) }
# tcp=0 tls=0: curl так пишет и зависание после ClientHello. Это неудача стратегии, другая стратегия этот адрес открывает
$hung = Row DPI d FAIL; $hung.ConnMs = 0
$tableC = [ordered]@{
    '0'  = @((Row Clean bing OK))
    '58' = @((Row Clean bing OK), (Row DPI a OK), (Row DPI b OK), (Row DPI c FREEZE), $hung)
    '7'  = @((Row DPI d OK))
    '52' = @((Row Clean bing OK), (Row DPI a OK), (Row DPI b OK))
    '51' = @((Row Clean bing OK), (Row DPI a OK))
    '13' = @((Row DPI c OK))
    '9'  = @((Row YouTube yt OK))
}
Save-TestCover $tableC $coverContext
Check 'cover file roundtrip' ((Get-TestCover $rankC)['58'].Count -eq 3 -and (Get-TestCover $rankC)['58'] -notcontains 'DPI|d' -and (Get-TestCover $rankC)['0'][0] -eq 'Clean|bing')
$ringC = @(Get-RingByCover @('58', '52', '51') 'general' '58' $rankC)
Check ('ring: coverage goes second, hung target counts got ' + ($ringC -join ',')) (($ringC -join ',') -eq '58,13,7,52,51')
# файл версии 1.7 с метками "?": такие адреса - обычные неудачи
$Script:RingCache = @{}
Write-TestResultFile (Get-PkgPath $Script:CoverFile) @("0`tClean|bing", "58`tDPI|a`t?DPI|d", "7`tDPI|d", "52`tDPI|a") $coverContext
$ringOld = @(Get-RingByCover @('58', '52') 'general' '58' $rankC)
Check ('ring: old file with ? marks got ' + ($ringOld -join ',')) (($ringOld -join ',') -eq '58,7,52')
$Script:RingCache = @{}
Save-TestCover $tableC $coverContext
$ringY = @(Get-RingByCover @('52', '58') 'google' '58' $rankC)
Check ('ring: youtube targets only in its ring got ' + ($ringY -join ',')) (($ringY -join ',') -eq '58,9,52')
$ringP = @(Get-RingByCover @('52', '51') 'general' '58' $rankC)
Check ('ring: weak primary is not forced got ' + ($ringP -join ',')) ($ringP[0] -eq '52' -and $ringP -contains '13')
Remove-Item (Get-PkgPath $Script:CoverFile)
$Script:RingCache = @{}
Check 'ring: no cover file - only by score' ((@(Get-RingByCover @('58', '52') 'general' '58' $rankC) -join ',') -eq '58,52')
$Script:CoverFile = 'runtime/test-cover.txt'

# стратегия, убранная обновлением сборки, не занимает место в круге: балл у неё в файле есть, а работать ей нечем
$Script:RankFile = 'runtime/dev-rank-check.txt'
Write-TestResultFile (Get-PkgPath $Script:RankFile) @('base 20 54 DPI=10/36', '58 47 47 54 0 0 DPI=30/36', '999 46 46 54 0 0 DPI=30/36') (Get-TestResultContext)
$rkGone = Get-TestRank
Check 'rank: removed strategy dropped' (@($rkGone.Rows).Count -eq 1 -and $rkGone.Rows[0].Id -eq '58')
Remove-Item (Get-PkgPath $Script:RankFile)
$Script:RankFile = 'runtime/test-rank.txt'

# подмена DNS: адреса CDN законно разные, подмена - только частный адрес или нет сертификата по адресу системного DNS
Check 'dns: same address' (-not (Test-DnsAnswerForged @('1.1.1.1') @('1.1.1.1', '2.2.2.2') $false $true))
Check 'dns: other cdn address with a certificate is fine' (-not (Test-DnsAnswerForged @('3.3.3.3') @('4.4.4.4') $true $true))
Check 'dns: address without a certificate is forged' (Test-DnsAnswerForged @('3.3.3.3') @('4.4.4.4') $false $true)
Check 'dns: bypass off, both fail: no conclusion' (-not (Test-DnsAnswerForged @('3.3.3.3') @('4.4.4.4') $false $false))
Check 'dns: private address is forged' (Test-DnsAnswerForged @('10.0.0.1') @('4.4.4.4') $false $false)
Check 'dns: no doh answer: no conclusion' (-not (Test-DnsAnswerForged @('10.0.0.1') @() $false $false))
Check 'dns: no system answer: no conclusion' (-not (Test-DnsAnswerForged @() @('4.4.4.4') $false $true))
Check 'dns: private ranges' ((Test-PrivateIp '172.16.0.1') -and (Test-PrivateIp '100.64.0.1') -and -not (Test-PrivateIp '172.32.0.1') -and -not (Test-PrivateIp '11.0.0.1') -and -not (Test-PrivateIp '100.128.0.1'))

[Threading.Thread]::CurrentThread.CurrentCulture = 'ru-RU'
Check ('points use a dot in ru-RU: ' + (Format-Points 44.5)) ((Format-Points 44.5) -eq '44.5')
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
