param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name);$script:fails++ } }
if (-not (Get-Command Get-PrimaryDecisionText -ErrorAction SilentlyContinue)) { throw 'FAIL primary selection explanation is missing' }
function Alt($Id,$Name,$Score) { [pscustomobject]@{Id=$Id;Name=$Name;Score=$Score;Freeze=0} }
# Literal reproduction of the reported run: tied current score, different historical leader,
# and the current primary only 0.5 points behind the average leader.
$alts=@((Alt '31' 'ALT11 мягкая' 48),(Alt '58' 'ALT11 белый 4 лёгкая' 48),(Alt '60' 'ALT11 белый 6' 48))
$averages=@{'31'=[pscustomobject]@{Avg=48.25;Runs=2};'58'=[pscustomobject]@{Avg=48.5;Runs=2};'60'=[pscustomobject]@{Avg=49.0;Runs=2}}
$choice=Get-PrimaryChoice $alts $averages '58' @('31','58','60')
$line=Get-PrimaryDecisionText $choice $averages 'ALT11 белый 4 лёгкая' 2
Check 'same current score does not rewrite the established average choice policy' ($choice.Top.Id -eq '60' -and $choice.Noise -and $choice.Current.Id -eq '58')
Check 'small-gap explanation names both strategies and numerical reason to retain primary' ($line.Contains('ALT11 белый 4 лёгкая') -and $line.Contains('ALT11 белый 6') -and $line.Contains('49') -and $line.Contains('48.5') -and $line.Contains('0.5') -and $line.Contains('2') -and $line.Contains('сохраняется'))
Check 'small-gap message does not present random Wi-Fi noise as established fact' ($line -notmatch 'случайный разброс|это случайность')
$choice=Get-PrimaryChoice $alts $averages '60' @('31','58','60')
$line=Get-PrimaryDecisionText $choice $averages 'ALT11 белый 6' 2
Check 'retained average leader is explicitly distinct from a new application' ($line.Contains('ALT11 белый 6') -and $line.Contains('сохраняется') -and $line.Contains('49') -and $line.Contains('среднему'))
$averages['58'].Avg=46
$choice=Get-PrimaryChoice $alts $averages '58' @('31','58','60')
$line=Get-PrimaryDecisionText $choice $averages 'ALT11 белый 4 лёгкая' 2
Check 'a clear average lead is an offer pending confirmation rather than a claim of application' ($line.Contains('ALT11 белый 6') -and $line.Contains('предлагается') -and $line.Contains('49') -and $line.Contains('проверки') -and $line -notmatch 'применена')
$line=Get-PrimaryDecisionText $choice $averages 'ALT11 белый 4 лёгкая' 2 -ReportOnly
Check 'report mode explains retention regardless of the average leader' ($line.Contains('ALT11 белый 4 лёгкая') -and $line.Contains('режим отчёта') -and $line.Contains('сохраняется'))
$line=Get-PrimaryDecisionText $choice $averages 'ALT11 белый 4 лёгкая' 2 -KeepPrimary
Check 'scheduled mode explains that only circles are being considered' ($line.Contains('ALT11 белый 4 лёгкая') -and $line.Contains('круги') -and $line.Contains('сохраняется'))
$choice=Get-PrimaryChoice $alts $averages 'unmeasured' @('31','58','60')
$line=Get-PrimaryDecisionText $choice $averages 'Прежняя стратегия' 2
Check 'unmeasured primary does not fabricate a comparison score' ($line.Contains('не проверялась') -and $line.Contains('предлагается') -and $line -notmatch 'Прежняя стратегия.* - 0')
$line=Get-PrimaryResultText 'Прежняя стратегия' 'Кандидат' Rejected 'Итоговая комбинация не подтверждена: DPI/SG.OR-01 Oracle'
Check 'rejected replay reports actual retained primary and failed candidate explicitly' ($line.StartsWith('Основная после теста: Прежняя стратегия.') -and $line.Contains('Кандидат') -and $line.Contains('Oracle') -and $line.Contains('не применена'))
$line=Get-PrimaryResultText 'Кандидат' 'Кандидат' Applied
Check 'successful save is the only outcome that claims the strategy was applied' ($line.StartsWith('Основная после теста: Кандидат.') -and $line.ToLowerInvariant().Contains('применена'))
$line=Get-PrimaryResultText 'Прежняя стратегия' 'Прежняя стратегия' Kept
Check 'confirmed retained configuration does not masquerade as a primary switch' ($line.Contains('Прежняя стратегия') -and $line.ToLowerInvariant().Contains('сохранена') -and $line -notmatch 'применена')
$line=Get-PrimaryResultText 'Прежняя стратегия' '' ReportOnly
Check 'report-only outcome names the primary without claiming a working-mode replay' ($line.Contains('Прежняя стратегия') -and $line.Contains('режим отчёта') -and $line -notmatch 'подтверждена|применена')
$line=Get-PrimaryResultText 'Прежняя стратегия' '' QualityRejected 'Недостаточно повторяемых контрольных запросов.'
Check 'measurement rejection names retained primary and uncertainty' ($line.Contains('Прежняя стратегия') -and $line.Contains('измерений отклонены') -and $line.Contains('Недостаточно') -and $line -notmatch 'применена')
# Execute the real report-only persistence block. The result must be in the saved header.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
$reportOnlyBlock=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($ReportOnly)') -and $n.Extent.Text.Contains('Get-PrimaryResultText')},$true)
if (-not $reportOnlyBlock) { throw 'FAIL report-only final summary is not persisted' }
$Script:Runtime=Join-Path $Script:Runtime ('primary-report-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($Script:Runtime)
$report=New-Object 'System.Collections.Generic.List[string]';$report.Add('fixture heading');$report.Add('current-run ranking')
$primaryNameBefore='Прежняя стратегия';$ReportOnly=$true;$repFile=Join-Path $Script:Runtime 'fixture-report.txt'
. ([scriptblock]::Create($reportOnlyBlock.Extent.Text))
$saved=[IO.File]::ReadAllLines((Join-Path $Script:Runtime 'test-last.txt'))
Check 'report-only saved report leads with the actual primary rather than just a probe winner' ($saved[1].StartsWith('Основная после теста: Прежняя стратегия.'))
if ($fails) { exit 1 }
