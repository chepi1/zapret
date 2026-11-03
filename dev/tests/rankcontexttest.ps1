param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails = 0
function Check($Name, $Ok) { if ($Ok) { Write-Host ('ok ' + $Name) } else { Write-Host ('FAIL ' + $Name); $script:fails++ } }
if (-not (Get-Command Get-TestResultContext -ErrorAction SilentlyContinue)) { throw 'FAIL ranking has no network/config context' }
$script:networkKey = 'A' * 64; $script:networkKnown = $true
function Get-NetworkObservation { [pscustomobject]@{Known=$script:networkKnown;Key=$script:networkKey;ObservedUtc=[datetime]::UtcNow} }
$settings = Get-Settings
$context = Get-TestResultContext $settings
Check 'context does not need external provider lookup' ($context -and $context.NetworkKey -eq $script:networkKey -and $context.InputsHash -match '^[A-F0-9]{64}$')
$changed = $settings.Clone(); $changed.alt = '11'; $changed.auto = 'off'; $changed.notify = 'on'
Check 'chosen primary and presentation settings do not invalidate their own ranking' (Test-TestResultContext $context (Get-TestResultContext $changed))
$changed.ipset = 'none'
Check 'actual capture settings invalidate ranking' (-not (Test-TestResultContext $context (Get-TestResultContext $changed)))
$Script:RankFile = 'runtime/scoped-rank.txt'; $Script:CoverFile = 'runtime/scoped-cover.txt'
$legacy = [byte[]](239,187,191,35,32,111,108,100,13,10)
[IO.File]::WriteAllBytes((Get-PkgPath $Script:RankFile), $legacy)
[IO.File]::WriteAllBytes((Get-PkgPath $Script:CoverFile), $legacy)
Check 'unscoped legacy measurements are not applied' ($null -eq (Get-TestRank) -and $null -eq (Get-TestCover))
$base = [pscustomobject]@{Ok=0;Total=2;Groups=@{DPI=@{Ok=0;Total=2}}}
$alts = @(
    [pscustomobject]@{Id='12';Name='fixture-primary';Score=2;Ok=2;Total=2;Harm=0;Freeze=0;Groups=@{DPI=@{Ok=2;Total=2}}},
    [pscustomobject]@{Id='7';Name='fixture-other';Score=1;Ok=1;Total=2;Harm=0;Freeze=0;Groups=@{DPI=@{Ok=1;Total=2}}})
$table = @{'0'=@();'12'=@([pscustomobject]@{Group='DPI';Name='a';State='OK'});'7'=@([pscustomobject]@{Group='DPI';Name='b';State='OK'})}
Save-TestRank $base $alts $context
Save-TestCover $table $context
Check 'legacy rank is backed up byte for byte' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-PkgPath ($Script:RankFile+'.v1.bak')))) -eq [Convert]::ToBase64String($legacy))
Check 'legacy coverage is backed up byte for byte' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-PkgPath ($Script:CoverFile+'.v1.bak')))) -eq [Convert]::ToBase64String($legacy))
$rank = Get-TestRank
Check 'compatible rank and coverage roundtrip' ($rank.Rows.Count -eq 2 -and (Get-TestCover)['7'][0] -eq 'DPI|b')
$firstRing = @(Get-RingByCover @('12') general 12 $rank)
Check 'compatible coverage populates cache' (($firstRing -join ',') -eq '12,7' -and $Script:RingCache.Count -gt 0)
$script:networkKey = 'B' * 64
Check 'different WiFi rejects rank and coverage' ($null -eq (Get-TestRank) -and $null -eq (Get-TestCover))
Check 'old rank object cannot reuse cached coverage on another network' ((@(Get-RingByCover @('12') general 12 $rank) -join ',') -eq '12')
$script:networkKnown = $false
Check 'unknown network never shares persisted results' ($null -eq (Get-TestRank) -and $null -eq (Get-TestResultContext $settings))
$script:networkKnown = $true; $script:networkKey = 'A' * 64
Check 'return to unchanged network restores compatibility' ($null -ne (Get-TestRank))
$file = Join-Path $Script:StratDir 'alt12.txt'; $bytes = [IO.File]::ReadAllBytes($file)
try { [IO.File]::AppendAllText($file,"`n# same name, changed actions"); Check 'same ID/name with changed bytes rejects ranking' ($null -eq (Get-TestRank)) } finally { [IO.File]::WriteAllBytes($file,$bytes) }
$file = Join-Path $Script:Lists 'list-general-user.txt'; $bytes = [IO.File]::ReadAllBytes($file)
try { [IO.File]::AppendAllText($file,"`nexample.org"); Check 'list-only edit rejects coverage' ($null -eq (Get-TestCover)) } finally { [IO.File]::WriteAllBytes($file,$bytes) }
$otherRun = Get-TestResultContext $settings
Save-TestCover $table $otherRun
Check 'interrupted pair publication cannot mix different runs' ($null -ne (Get-TestRank) -and $null -eq (Get-TestCover))
Save-TestCover $table $context
Check 'same run can be restored after rollback' ($null -ne (Get-TestCover))
$diskRank = [IO.File]::ReadAllBytes((Get-PkgPath $Script:RankFile))
$diskCover = [IO.File]::ReadAllBytes((Get-PkgPath $Script:CoverFile))
$previewContext = Get-TestResultContext $settings
$Script:TestResultPreview = New-TestResultPreview $base @($alts[1]) $table $previewContext
try {
    Check 'final replay reads provisional ranking from memory' ((Get-TestRank).Rows.Count -eq 1 -and (Get-TestRank).Context.RunId -eq $previewContext.RunId -and $null -ne (Get-TestCover))
    Check 'provisional candidate leaves accepted files unchanged' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-PkgPath $Script:RankFile))) -eq [Convert]::ToBase64String($diskRank) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-PkgPath $Script:CoverFile))) -eq [Convert]::ToBase64String($diskCover))
    $script:networkKey = 'B' * 64
    Check 'provisional ranking cannot escape its original network' ($null -eq (Get-TestRank) -and $null -eq (Get-TestCover))
    $script:networkKey = 'A' * 64
} finally { $Script:TestResultPreview = $null }
Check 'ending preview restores previously accepted ranking' ((Get-TestRank).Rows.Count -eq 2)
$script:networkKnown = $false; $rejected = $false
try { Save-TestRank $base $alts } catch { $rejected = $true }
Check 'unknown network cannot publish a trusted ranking' $rejected
if ($fails) { exit 1 }
