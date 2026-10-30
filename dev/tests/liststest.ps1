# обновление списков Flowseal и проверка новых версий - на копии пакета.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { Write-Host 'Тест пишет файлы в runtime: запускайте его через run-all.ps1, на копии папки.' -ForegroundColor Red; exit 1 }
$stage = Join-Path $env:TEMP ('nba-lists-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $stage | Out-Null
Copy-Item $Pkg (Join-Path $stage 'pkg') -Recurse
. (Join-Path $stage 'pkg\tools\lib.ps1')
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }

# старый list-general: без 5 доменов
$lg = Join-Path $Script:Lists 'list-general.txt'
$orig = [System.IO.File]::ReadAllLines($lg)
[System.IO.File]::WriteAllLines($lg, @($orig | Select-Object -Skip 5))
(Get-Item (Join-Path $Script:Lists 'list-google.txt')).LastWriteTime = (Get-Date).AddDays(-40)
$t = [Diagnostics.Stopwatch]::StartNew()
$res = @(Update-FlowsealLists)
Write-Host ('  ' + [math]::Round($t.Elapsed.TotalSeconds, 1) + ' s')
foreach ($u in $res) { Write-Host ('  ' + $u.Text + ' ok=' + $u.Ok + ' changed=' + $u.Changed) }
$g = $res | Where-Object { $_.Name -eq 'list-general.txt' }
Check 'list-general restored +5' ($g.Ok -and $g.Changed -and $g.Text -match '\+5 -0' -and (Test-Path ($lg + '.bak')))
Check 'list-general content = original' ((@(Get-ListLines $lg) -join "`n") -eq (@($orig | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) -join "`n"))
$gg = $res | Where-Object { $_.Name -eq 'list-google.txt' }
Check 'unchanged list touched mtime' ($gg.Ok -and -not $gg.Changed -and ((Get-Date) - (Get-Item (Join-Path $Script:Lists 'list-google.txt')).LastWriteTime).TotalMinutes -lt 5)
Check 'all ok' (@($res | Where-Object { -not $_.Ok }).Count -eq 0)

# плохой адрес - старый файл остаётся
$Script:FlowsealRaw = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/nonexistent/'
$before = [System.IO.File]::ReadAllText($lg)
$bad = Update-FlowsealList 'list-general.txt'
Write-Host ('  ' + $bad.Text)
Check 'bad url keeps file' (-not $bad.Ok -and [System.IO.File]::ReadAllText($lg) -eq $before)

# новые версии
Check 'upstream check ran' (Update-UpstreamCheck -Force)
Write-Host ('  updates.txt: ' + ([System.IO.File]::ReadAllText((Get-PkgPath $Script:UpdatesFile)).Trim() -replace "`r`n", ' | '))
Check 'no news on current base' (@(Get-UpstreamNews).Count -eq 0)
Check 'own release found' ([System.IO.File]::ReadAllText((Get-PkgPath $Script:UpdatesFile)) -match '(?m)^zapret=v\d')
Check 'no own update for this version' (-not (Get-ZapretUpdate))
Check 'cached: second call skipped' (-not (Update-UpstreamCheck))
$Script:Upstream['Flowseal'].Base = '1.10.3'
$news = @(Get-UpstreamNews)
Write-Host ('  news with old base: ' + ($news -join '; '))
Check 'news when base older' ($news.Count -eq 1 -and $news[0] -like 'Flowseal 1.10.4 (в сборке 1.10.3)')
Remove-Item $stage -Recurse -Force
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
