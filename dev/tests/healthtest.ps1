param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
$fails=0
function Check($Name,$Ok) { if($Ok){Write-Host ('ok   '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++} }
if (-not (Get-Command Save-ServiceHealth -ErrorAction SilentlyContinue)) { Write-Host 'FAIL service health snapshot is missing';exit 1 }
$script:healthProcess = New-Object PSObject -Property @{Id=101;StartTime=(Get-Date).AddMinutes(-1)}
function Get-OurProcesses { return @($script:healthProcess | Where-Object { $_ }) }
$rows=@($Script:ServiceProbes.Keys | ForEach-Object {New-Object PSObject -Property @{Name=$_;Ok=$true;Ms=100}})
$identity=Get-BypassIdentity @(Get-OurProcesses)
Check 'store complete observation for current process' (Save-ServiceHealth $rows $identity)
$summary=Get-ServiceHealthSummary @(Get-OurProcesses)
Check 'fresh observation contains passed count and time' ($summary.State -eq 'Good' -and $summary.Text -match '7/7' -and $summary.Text -match '\d\d:\d\d')
$path=Join-Path $Script:Runtime 'service-health.json'
$original=[IO.File]::ReadAllText($path)
$script:healthProcess.Id=102
Check 'new PID invalidates old observation' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
Check 'changed process during probing cannot save old observation' (-not (Save-ServiceHealth $rows $identity))
$script:healthProcess.Id=101
$script:healthProcess.StartTime=$script:healthProcess.StartTime.AddSeconds(1)
Check 'PID reuse with new start time invalidates observation' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
$script:healthProcess=$null
Check 'stopped bypass cannot display old green observation' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
$script:healthProcess=New-Object PSObject -Property @{Id=103;StartTime=(Get-Date)}
$identity=Get-BypassIdentity @(Get-OurProcesses)
$rows[0].Ok=$false
Check 'store partial reachability without treating it as a start failure' (Save-ServiceHealth $rows $identity)
Check 'failed target is visible' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Partial' -and (Get-ServiceHealthSummary @(Get-OurProcesses)).Text -match [regex]::Escape($rows[0].Name))
$saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$saved.CheckedUtc=(Get-Date).ToUniversalTime().AddMinutes(-11).ToString('o')
Write-TextNoBom $path ($saved | ConvertTo-Json -Depth 4)
Check 'old observation expires' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
$saved.CheckedUtc=(Get-Date).ToUniversalTime().AddMinutes(10).ToString('o')
Write-TextNoBom $path ($saved | ConvertTo-Json -Depth 4)
Check 'future observation is not trusted' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
Write-TextNoBom $path '{bad json'
Check 'damaged cache does not break menu' ((Get-ServiceHealthSummary @(Get-OurProcesses)).State -eq 'Unknown')
Check 'partial target list is not a full observation' (-not (Save-ServiceHealth @($rows[0]) $identity))
function Start-ServiceProbes { throw 'simulated probe failure' }
Update-ServiceHealth | Out-Null
Check 'probe failure is contained' $true
if($fails){exit 1}
Write-Host 'all ok'
