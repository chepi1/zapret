param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name); $script:fails++ } }
if (-not (Get-Command New-TestMeasurementOrder -ErrorAction SilentlyContinue)) { throw 'FAIL repeatable measurement helpers missing' }
$strategies=@(1..6 | ForEach-Object { [pscustomobject]@{Id=[string]$_;Name=('fixture '+$_)} })
$order=New-TestMeasurementOrder $strategies 4 42
$same=New-TestMeasurementOrder $strategies 4 42
Check 'seed reproduces complete round order' (($order | ConvertTo-Json -Depth 6 -Compress) -ceq ($same | ConvertTo-Json -Depth 6 -Compress))
$ids=@($order.Rounds[0].Strategies | ForEach-Object { $_.Id });[array]::Reverse($ids)
Check 'second round reverses first round' (($ids -join ',') -ceq (($order.Rounds[1].Strategies | ForEach-Object { $_.Id }) -join ','))
Check 'every round contains each strategy exactly once' (@($order.Rounds | Where-Object { (@($_.Strategies.Id | Sort-Object -Unique) -join ',') -ne '1,2,3,4,5,6' }).Count -eq 0)
Check 'order does not mutate original strategy array' (($strategies.Id -join ',') -ceq '1,2,3,4,5,6')
$targets=@('bing','github','pypi','aws','steam','other' | ForEach-Object { [pscustomobject]@{Group='Clean';Name=$_;Url=('https://'+$_+'.example/')} })
$controls=@(Get-ControlTargets $targets)
Check 'control is capped at five known Clean targets' ($controls.Count -eq 5 -and ($controls.Name -join ',') -eq 'bing,github,pypi,aws,steam')
$duplicates=@($targets[0],([pscustomobject]@{Group='Clean';Name='alias';Url=$targets[0].Url}),$targets[1],$targets[2])
Check 'aliases of one endpoint do not count as independent controls' (@(Get-ControlTargets $duplicates).Count -eq 3)
function Rows($State='OK',$Ms=100) {
    foreach ($target in $controls) { foreach ($attempt in 1,2) { [pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State=$State;TlsMs=$Ms;Attempt=$attempt} } }
}
$before=@(Rows);$after=@(Rows OK 120)
$stable=Get-ControlAssessment $controls $before $after
Check 'stable repeated controls allow publishing' ($stable.CanApply -and $stable.Status -eq 'Stable' -and $stable.MatchedTargets -eq 5)
$duplicateTargets=@($controls[0],$controls[0],$controls[0])
$single=@($before | Where-Object { $_.Name -eq 'bing' })
$duplicateAssessment=Get-ControlAssessment $duplicateTargets $single $single
Check 'duplicate control targets cannot inflate trustworthy sample count' (-not $duplicateAssessment.CanApply -and $duplicateAssessment.MatchedTargets -eq 1)
$slow=Get-ControlAssessment $controls $before @(Rows OK 900)
Check 'coherent slowdown rejects comparison' (-not $slow.CanApply -and $slow.Status -eq 'Changed' -and $slow.ShiftedUp.Count -eq 5)
$fast=Get-ControlAssessment $controls @(Rows OK 900) $before
Check 'coherent improvement also rejects temporal bias' (-not $fast.CanApply -and $fast.ShiftedDown.Count -eq 5)
$oneSlow=@(Rows);$oneSlow | Where-Object { $_.Name -eq 'bing' } | ForEach-Object { $_.TlsMs=1000 }
Check 'one slow service is not proof of global latency shift' ((Get-ControlAssessment $controls $before $oneSlow).CanApply)
$loss=@(Rows);$loss | Where-Object { $_.Name -eq 'bing' } | ForEach-Object { $_.State='FAIL' }
Check 'reproduced availability change rejects data' (-not (Get-ControlAssessment $controls $before $loss).CanApply)
$rare=@(Rows);$rare[0].State='FAIL'
$uncertain=Get-ControlAssessment $controls $before $rare
Check 'one loss remains uncertainty rather than confirmed connectivity change' ($uncertain.CanApply -and $uncertain.UncertainTargets.Count -eq 1 -and $uncertain.AvailabilityChanged.Count -eq 0)
$missing=@($after | Where-Object { $_.Name -in @('bing','github') })
Check 'missing control observations cannot become stable evidence' ((Get-ControlAssessment $controls $before $missing).Status -eq 'Unknown')
$unknown=Get-ControlAssessment $controls @(Rows NA) @(Rows NA)
Check 'DNS unknown is neither a good measurement nor proven connectivity change' (-not $unknown.CanApply -and $unknown.Status -eq 'Unknown' -and $unknown.AvailabilityChanged.Count -eq 0)
$bad=@(Rows);$bad | Where-Object { $_.Name -in @('bing','github','pypi') } | ForEach-Object { $_.TlsMs=[double]::NaN }
Check 'nonfinite latency is not zero or trusted control' ((Get-ControlAssessment $controls $before $bad).Status -eq 'Unknown')
Check 'URL path case stays part of target identity' ((Get-ProbeKey ([pscustomobject]@{Group='Clean';Name='same';Url='https://example.test/A'})) -cne (Get-ProbeKey ([pscustomobject]@{Group='Clean';Name='same';Url='https://example.test/a'})))
$path=Join-Path $Script:Runtime 'attempts-fixture.jsonl'
$metadata=@{RunId='fixture';Seed=42;Sequence=0;Round=1;Stage='strategy';StrategyId='12';StrategyHash=('D'*64);NetworkKey=('A'*64);InputsHash=('B'*64);ProxySecret='never-serialize-this'}
$row=[pscustomobject]@{Group='DPI';Name='fixture';Url='https://example.test/?secret=do-not-leak';State='FAIL';Code='000';Exit=28;Up=65536;Down=0;ConnMs=0;TlsMs=0;Tries=1;Flaky=$false}
Write-ProbeJournal $path $metadata @($row) 1
$row.State='OK';$row.Code='200';$row.Exit=0;$row.TlsMs=100
Write-ProbeJournal $path $metadata @($row) 2
$saved=@([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json })
Check 'journal keeps original failure and successful retry independently' ($saved.Count -eq 2 -and $saved[0].State -eq 'FAIL' -and $saved[0].Attempt -eq 1 -and $saved[1].State -eq 'OK' -and $saved[1].Attempt -eq 2)
Check 'missing metrics remain null in evidence' ($null -eq $saved[0].DnsMs -and $null -eq $saved[0].TotalMs)
$text=[IO.File]::ReadAllText($path)
Check 'journal never serializes URL credentials or extra metadata' ($text -notmatch 'do-not-leak|never-serialize|https://' -and $saved[0].TargetKey -match '^[A-F0-9]{64}$')
$rejected=$false;try { Write-ProbeJournal $path $metadata @($row) 1 -MaxBytes 1 } catch { $rejected=$true }
Check 'evidence budget failure leaves existing journal untouched' ($rejected -and [IO.File]::ReadAllText($path) -ceq $text)
$minimal=[pscustomobject]@{Group='Clean';Name='minimal';State='OK';TlsMs=100}
$writerOutput=@(Write-ProbeJournal $path $metadata @($minimal) 1)
Check 'journal writer is silent even with incomplete optional fields' ($writerOutput.Count -eq 0)
# Actual curl parser, with no process launch.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/test.ps1'),[ref]$null,[ref]$null)
foreach ($function in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) { . ([scriptblock]::Create($function.Extent.Text)) }
$item=[pscustomobject]@{T=[pscustomobject]@{Group='Clean';Name='fixture';Url='https://example.test/';Post=$false};P=[pscustomobject]@{ExitCode=0};Out=[pscustomobject]@{Result='200 0 65536 0.1 0.2 0.02 0.3 0.4'}}
$parsed=Convert-CurlResult $item
Check 'curl timing phases are preserved separately' ($parsed.DnsMs -eq 20 -and $parsed.FirstByteMs -eq 300 -and $parsed.TotalMs -eq 400 -and $parsed.ConnMs -eq 100 -and $parsed.TlsMs -eq 200)
$item.Out.Result='200 0 65536 0.1 0.2'
$old=Convert-CurlResult $item
Check 'older curl output keeps optional phases unknown' ($null -eq $old.DnsMs -and $null -eq $old.TotalMs)
if ($fails) { exit 1 }
