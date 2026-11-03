param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){ . ([scriptblock]::Create($f.Extent.Text)) }
if(-not (Get-Command Test-FinalCandidateRows -ErrorAction SilentlyContinue)){ throw 'Final candidate verification missing' }
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
function Row($Group,$Name,$State,$Ms=100){[pscustomobject]@{Group=$Group;Name=$Name;State=$State;TlsMs=$Ms}}
$before=@((Row YouTube video OK),(Row Clean normal OK))
Check 'working final combination accepted' ((Test-FinalCandidateRows $before $before).Ok)
Check 'candidate failing with actual IPSet rejected' (-not (Test-FinalCandidateRows $before @((Row YouTube video FAIL),(Row Clean normal OK))).Ok)
Check 'missing observation is not success' (-not (Test-FinalCandidateRows $before @((Row Clean normal OK))).Ok)
Check 'clean site slowdown rejected' (-not (Test-FinalCandidateRows $before @((Row YouTube video OK),(Row Clean normal OK 900))).Ok)
Check 'unavailable original target does not become requirement' ((Test-FinalCandidateRows @($before + (Row DPI absent FAIL)) $before).Ok)
Check 'empty evidence does not pass' (-not (Test-FinalCandidateRows @() @()).Ok)
$script:argsSeen=$null
function Assert-BypassControlAllowed {}
function Get-BypassCmdLine { param($Settings,$Name,$Alt,[switch]$NoAuto,$IpsetMode) $script:argsSeen=@{NoAuto=[bool]$NoAuto;Ipset=$IpsetMode;Auto=$Settings.auto}; return 'mock' }
function Start-Process { return [pscustomobject]@{HasExited=$false} }
function Start-Sleep {}
$script:launchedCommand=''
function Start-Process { param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$PassThru) $script:launchedCommand=$ArgumentList;return [pscustomobject]@{HasExited=$false} }
Start-TestInstance @{auto='on';ipset='loaded'} 12 -Final | Out-Null
Check 'final launch keeps auto and actual IPSet' (-not $script:argsSeen.NoAuto -and -not $script:argsSeen.Ipset -and $script:argsSeen.Auto -eq 'on')
Start-TestInstance @{auto='on';ipset='loaded'} 12 | Out-Null
Check 'exploration still uses any without auto' ($script:argsSeen.NoAuto -and $script:argsSeen.Ipset -eq 'any')
Check 'temporary instance has independent exit timer' ($script:launchedCommand -match 'test_lifetime_guard' -and $script:launchedCommand -match 'timer_set')
Check 'larger slow batches receive sufficient timer budget' ((Get-TestInstanceLifetimeMs 100 1 2) -gt 120000)
$invalidBudget=$false
try{Get-TestInstanceLifetimeMs 1000 1 60 | Out-Null}catch{$invalidBudget=$true}
Check 'oversized stage is rejected instead of silently cutting test short' $invalidBudget
# Execute the actual publish/check/rollback block with all process and network effects replaced.
$block=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if (-not $ReportOnly)')},$true)
$script:finalBlock=[scriptblock]::Create($block.Extent.Text)
$selection=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($ReportOnly)') -and $n.Extent.Text.Contains('$apply = $false')},$true)
$script:selectionBlock=[scriptblock]::Create($selection.Extent.Text)
function Save-TestRank { Write-TextNoBom (Get-PkgPath $Script:RankFile) 'new rank' }
function Save-TestCover { Write-TextNoBom (Get-PkgPath $Script:CoverFile) 'new cover' }
function New-TestResultPreview { return 'fixture preview' }
function Get-TestResultContext { return 'fixture context' }
function Test-TestResultContext { return $true }
function Save-Settings { $script:savedSettings++ }
function Start-TestInstance { $obj=[pscustomobject]@{Id=1234;HasExited=$false}; $obj | Add-Member ScriptMethod WaitForExit { return $true }; return $obj }
function Stop-Process { }
function Test-ScoreInputs { return $true }
function Invoke-CurlBatch { return $script:actual }
function Run-FinalBlock($Rows, [switch]$KeepPrimary, [switch]$OnlyReport) {
    $script:actual=$Rows; $script:savedSettings=0
    $settings=@{alt='12';auto='on';ipset='loaded'}; $pick=@{Id='11';Name='Кандидат'}; $choice=@{Noise=$false}; $apply=$true; $ReportOnly=[bool]$OnlyReport; $NoPrompt=$true
    $primaryNameBefore='Прежняя стратегия'
    . $script:selectionBlock
    $base=@{}; $alts=@(); $table=@{'12'=$before;'11'=$before;'0'=@((Row Clean normal OK))}
    $targets=@(); $postFile=''; $p=$null; $scoreInputs='fixture'; $scoreParameters=@{}; $scoreFingerprints=@{}; $networkBefore=@{Known=$true;Key='fixture'}; $testLifetimeMs=120000; $resultContext='fixture context'
    $metadata=@{RunId='fixture';Sequence=0};$journalFile=Join-Path $Script:Runtime 'final-raw-fixture.jsonl'
    $report=New-Object 'System.Collections.Generic.List[string]'
    $report.Add('fixture heading')
    $repFile=Join-Path $Script:Runtime 'final-fixture.txt'
    Write-TextNoBom (Get-PkgPath $Script:RankFile) 'old rank'
    Write-TextNoBom (Get-PkgPath $Script:CoverFile) 'old cover'
    . $script:finalBlock
    return [pscustomobject]@{Rank=[IO.File]::ReadAllText((Get-PkgPath $Script:RankFile));Cover=[IO.File]::ReadAllText((Get-PkgPath $Script:CoverFile));Saved=$script:savedSettings;Applied=$apply;Header=$(if ($report.Count -gt 1) { $report[1] } else { '' })}
}
$rejected=Run-FinalBlock @((Row YouTube video FAIL),(Row Clean normal OK))
Check 'rejected replay restores exact previous rank and coverage' ($rejected.Rank -eq 'old rank' -and $rejected.Cover -eq 'old cover')
Check 'rejected replay never saves settings' ($rejected.Saved -eq 0 -and -not $rejected.Applied)
Check 'rejected replay report starts with retained primary and names rejected candidate' ($rejected.Header.StartsWith('Основная после теста: Прежняя стратегия.') -and $rejected.Header.Contains('Кандидат') -and $rejected.Header.Contains('YouTube/video') -and $rejected.Header.Contains('не применена'))
$passed=Run-FinalBlock $before
Check 'confirmed replay publishes rank and chosen settings' ($passed.Rank -eq 'new rank' -and $passed.Cover -eq 'new cover' -and $passed.Saved -eq 1)
Check 'successful replay report names the newly applied primary' ($passed.Header.StartsWith('Основная после теста: Кандидат.') -and $passed.Header -match 'Применена')
$kept=Run-FinalBlock $before -KeepPrimary
Check 'scheduled selection publishes confirmed circles while retaining primary' ($kept.Rank -eq 'new rank' -and $kept.Cover -eq 'new cover' -and $kept.Saved -eq 0 -and -not $kept.Applied)
Check 'scheduled replay report names retained primary rather than average candidate' ($kept.Header.StartsWith('Основная после теста: Прежняя стратегия.') -and $kept.Header -match 'Сохранена')
$reportOnlyResult=Run-FinalBlock $before -OnlyReport
Check 'provider report publishes neither ranking nor settings' ($reportOnlyResult.Rank -eq 'old rank' -and $reportOnlyResult.Cover -eq 'old cover' -and $reportOnlyResult.Saved -eq 0)
function Test-ScoreInputs { return $false }
$changed=Run-FinalBlock $before
Check 'changed source during replay prevents publication' ($changed.Rank -eq 'old rank' -and $changed.Saved -eq 0)
function Test-ScoreInputs { return $true }
function Start-TestInstance { return $null }
$failedStart=Run-FinalBlock $before
Check 'failed final launch restores previous configuration' ($failedStart.Rank -eq 'old rank' -and $failedStart.Cover -eq 'old cover' -and $failedStart.Saved -eq 0)
if($fails){exit 1}
