# проверка повторов автоподбора (Merge-Retry, Get-RetryTargets, Get-RunSummary) и файла рейтинга с полбаллами.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
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
if (Test-Path (Get-PkgPath $Script:RankFile)) {
    $real = Get-TestRank
    $lines = @([System.IO.File]::ReadAllLines((Get-PkgPath $Script:RankFile)) | Where-Object { $_ -match '^\d+\s' })
    Check ('real rank parses (' + $lines.Count + ' rows)') ($real -and $real.Rows.Count -eq $lines.Count -and $real.BaseOk -gt 0)
    Write-Host ('  youtube ring: ' + ((Get-SectionRank $real 'google') -join ',') + ' | general ring: ' + ((Get-SectionRank $real 'general') -join ','))
    Check 'real rings not empty' (@(Get-SectionRank $real 'google').Count -ge 1 -and @(Get-SectionRank $real 'general').Count -ge 1)
} else { Write-Host '  (рейтинга этого ПК нет - автоподбор ещё не запускали)' }
[Threading.Thread]::CurrentThread.CurrentCulture = 'ru-RU'
Check ('points use a dot in ru-RU: ' + (Format-Points 44.5)) ((Format-Points 44.5) -eq '44.5')
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
