param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok   '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
if(-not (Get-Command Get-ScoreContext -ErrorAction SilentlyContinue)){Write-Host 'FAIL scoped score history is missing';exit 1}
if(-not (Get-Command Get-ScoreInputsHash -ErrorAction SilentlyContinue)){Write-Host 'FAIL input snapshot before measurement is missing';exit 1}
$originalFiles=@{}
foreach($relative in @('tools/lib.ps1','lua/zapret-lib.lua','strategies/alt50.txt')) {
    $path=Join-Path $Script:Root $relative
    $originalFiles[$path]=[IO.File]::ReadAllBytes($path)
}
try {
$Script:ScoreHistoryFile='runtime/history-test.txt'
$a=New-Object PSObject -Property @{Id='50';Name='a';Score=10}
$targets=@((New-Object PSObject -Property @{Group='DPI';Name='one';Url='https://example.com/'}),(New-Object PSObject -Property @{Group='Clean';Name='two';Url='https://example.org/'}))
$info=New-Object PSObject -Property @{As='AS8402 provider';CountryCode='RU';Ip='192.0.2.1'}
$ctx=Get-ScoreContext $info $targets
Check 'context generated without requiring public IP' ($ctx -match '^[A-Fa-f0-9]{64}$')
$info.Ip='192.0.2.2'
Check 'dynamic IP change does not reset provider history' ((Get-ScoreContext $info $targets) -eq $ctx)
Check 'target order does not change context' ((Get-ScoreContext $info @($targets[1],$targets[0])) -eq $ctx)
Check 'duplicated target changes measurement weighting and context' ((Get-ScoreContext $info @($targets[0],$targets[1],$targets[0])) -ne $ctx)
Check 'known context saves a result' (Add-ScoreHistory @($a) $ctx)
$a.Score=20
Check 'same context saves another result' (Add-ScoreHistory @($a) $ctx)
Check 'same context averages both runs' ((Get-AverageScores @($a) $ctx)['50'].Avg -eq 15)
$stamp=Get-ScoreInputsHash $targets @{}
$fingerprints=@{'50'=(Get-StrategyFingerprint '50')}
Check 'unchanged input snapshot is valid' (Test-ScoreInputs $stamp $targets @{} $fingerprints)
$info.As='AS1234 another provider'
$other=Get-ScoreContext $info $targets
Check 'another provider has another context' ($other -ne $ctx)
Check 'another provider uses current result instead of old average' ((Get-AverageScores @($a) $other)['50'].Avg -eq 20)
$targets[0].Url='https://example.net/'
Check 'target change invalidates context' ((Get-ScoreContext $info $targets) -ne $other)
Check 'test parameters invalidate context' ((Get-ScoreContext $info $targets @{TimeoutSec=1}) -ne (Get-ScoreContext $info $targets @{TimeoutSec=10}))
$strategy=Join-Path $Script:StratDir 'alt50.txt'
$stamp=Get-ScoreInputsHash $targets @{}
[IO.File]::AppendAllText($strategy,"`n# revised",$Script:Utf8NoBom)
Check 'edit during a run invalidates its captured inputs' (-not (Test-ScoreInputs $stamp @($targets[1],$targets[0]) @{} $fingerprints))
Check 'strategy edit with same id and name rejects old average' ((Get-AverageScores @($a) $ctx)['50'].Avg -eq 20)
Check 'captured strategy revision cannot be saved after edit' (-not (Add-ScoreHistory @($a) $ctx $fingerprints))
$contextBefore=Get-ScoreContext $info $targets
[IO.File]::AppendAllText((Join-Path $Script:Root 'tools/lib.ps1'),"`n# changed composition",$Script:Utf8NoBom)
Check 'composition code changes invalidate context' ((Get-ScoreContext $info $targets) -ne $contextBefore)
$contextBefore=Get-ScoreContext $info $targets
[IO.File]::AppendAllText((Join-Path $Script:Root 'lua/zapret-lib.lua'),"`n-- changed library",$Script:Utf8NoBom)
Check 'loaded Lua library changes invalidate context' ((Get-ScoreContext $info $targets) -ne $contextBefore)
$info.As=''
Check 'unknown provider produces no shareable context' (-not (Get-ScoreContext $info $targets))
Check 'unknown context does not persist a score' (-not (Add-ScoreHistory @($a) ''))
Check 'unknown context uses current result' ((Get-AverageScores @($a) '')['50'].Avg -eq 20)
$path=Get-PkgPath $Script:ScoreHistoryFile
$date=Get-Date -Format 'yyyy-MM-dd HH:mm'
$legacy="$date|50|a|99`r`n"
Write-TextNoBom $path $legacy
Check 'legacy unscoped scores are not averaged' ((Get-AverageScores @($a) $ctx)['50'].Avg -eq 20)
Add-ScoreHistory @($a) $ctx | Out-Null
Check 'legacy file has an exact preservation copy' ([IO.File]::ReadAllText($path+'.v1.bak') -ceq $legacy)
Check 'fresh scoped record is used after migration' ((Get-AverageScores @($a) $ctx)['50'].Avg -eq 20)
if($fails){exit 1}
Write-Host 'all ok'
} finally {
    foreach($path in $originalFiles.Keys){[IO.File]::WriteAllBytes($path,$originalFiles[$path])}
}
