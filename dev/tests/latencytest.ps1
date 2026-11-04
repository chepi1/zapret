param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
$module=Join-Path $Pkg 'tools/latency.ps1'
if(-not(Test-Path $module)){throw 'FAIL bounded latency evidence missing'}
. $module
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
$store=New-LatencyStore
$ip='203.0.113.1'
$empty=Get-LatencySummary $store $ip icmp 0 0
Check 'no observation stays unknown without zero latency' ($empty.Count -eq 0 -and $null -eq $empty.MedianMs -and $null -eq $empty.P95Ms)
foreach($value in @(10,20,30,140)){Add-LatencyResult $store $ip icmp 0 Success $value 1 | Out-Null}
$summary=Get-LatencySummary $store $ip icmp 0 1
Check 'even median min max and last retain observed values' ($summary.MedianMs -eq 25 -and $summary.MinMs -eq 10 -and $summary.MaxMs -eq 140 -and $summary.LastMs -eq 140)
Check 'small sample does not invent P95' ($null -eq $summary.P95Ms -and $summary.SuccessCount -eq 4)
Check 'spike threshold is explicitly50ms above median' ($summary.Spikes -eq 1)
foreach($value in 1..20){Add-LatencyResult $store '203.0.113.2' icmp 0 Success $value 2 | Out-Null}
$summary=Get-LatencySummary $store '203.0.113.2' icmp 0 2
Check 'nearest-rank P95 only becomes available with20 successes' ($summary.P95Ms -eq 19 -and $summary.MedianMs -eq 10.5)
Add-LatencyResult $store $ip icmp 0 Timeout $null 3 | Out-Null
Add-LatencyResult $store $ip icmp 0 Error $null 3 | Out-Null
$summary=Get-LatencySummary $store $ip icmp 0 3
Check 'timeouts and local errors are counted separately without fake RTT' ($summary.Count -eq 6 -and $summary.SuccessCount -eq 4 -and $summary.Timeouts -eq 1 -and $summary.Errors -eq 1 -and $summary.MedianMs -eq 25)
$before=$summary.Count
Add-LatencyResult $store $ip icmp 0 Cancelled $null 3 | Out-Null
Check 'cancellation is not a failed network attempt' ((Get-LatencySummary $store $ip icmp 0 3).Count -eq $before)
foreach($bad in @($null,[double]::NaN,[double]::PositiveInfinity,-1)){
    Check 'invalid success latency cannot enter evidence' (-not(Add-LatencyResult $store $ip icmp 0 Success $bad 3))
}
Check 'invalid outcome and literal address are rejected' (-not(Add-LatencyResult $store 'example.test' icmp 0 Success 10 3) -and -not(Add-LatencyResult $store $ip icmp 0 Bad 10 3))
Add-LatencyResult $store $ip tcp 443 Success 100 4 | Out-Null
Add-LatencyResult $store $ip tcp 8443 Success 200 4 | Out-Null
Check 'same-IP ICMP and each TCP port are independent' ((Get-LatencySummary $store $ip icmp 0 4).MedianMs -eq 25 -and (Get-LatencySummary $store $ip tcp 443 4).MedianMs -eq 100 -and (Get-LatencySummary $store $ip tcp 8443 4).MedianMs -eq 200)
$tcpOnly=New-LatencyStore
Add-LatencyResult $tcpOnly $ip tcp 443 Success 17 5 | Out-Null
$udp=Get-LatencyDisplay $tcpOnly $ip udp 27015 5
Check 'TCP latency is never presented as UDP game ping' ($udp.Text -eq '—' -and $udp.Kind -eq 'icmp')
$tcp=Get-LatencyDisplay $tcpOnly $ip tcp 443 5
Check 'TCP fallback identifies exact port and unknown P95' ($tcp.Kind -eq 'tcp' -and $tcp.Text -eq '17/—t' -and $tcp.Detail.Contains('TCP443'))
Check 'TCP latency cannot leak into a different TCP port' ((Get-LatencyDisplay $tcpOnly $ip tcp 8443 5).Text -eq '—')
$stale=Get-LatencyDisplay $tcpOnly $ip tcp 443 66
Check 'old success is not a fresh answer after60s' ($stale.Text -eq '—' -and $stale.Detail.Contains('свежих'))
$short=New-LatencyStore -Capacity 2 -MaxSamples 3 -WindowSeconds 10
foreach($value in 1..5){Add-LatencyResult $short $ip icmp 0 Success $value $value | Out-Null}
$summary=Get-LatencySummary $short $ip icmp 0 5
Check 'per-stream sample count is bounded and oldest observations evicted' ($summary.Count -eq 3 -and $summary.MinMs -eq 3 -and $summary.MedianMs -eq 4)
Add-LatencyResult $short '203.0.113.2' icmp 0 Success 7 6 | Out-Null
Get-LatencySummary $short $ip icmp 0 7 | Out-Null
Add-LatencyResult $short '203.0.113.3' icmp 0 Success 8 8 | Out-Null
Check 'bounded stream LRU retains recently read endpoint' ($short.Streams.Count -eq 2 -and (Get-LatencySummary $short '203.0.113.2' icmp 0 8).Count -eq 0 -and (Get-LatencySummary $short $ip icmp 0 8).Count -eq 3)
Check 'expired window is unknown rather than a historical best' ((Get-LatencySummary $short $ip icmp 0 20).Count -eq 0)
$schedule=New-LatencyStore
Check 'first probe is due' (Test-LatencyProbeDue $schedule $ip icmp 0 0)
Set-LatencyProbeScheduled $schedule $ip icmp 0 0 | Out-Null
Check 'ICMP cadence cannot exceed once every5s' (-not(Test-LatencyProbeDue $schedule $ip icmp 0 4) -and (Test-LatencyProbeDue $schedule $ip icmp 0 5))
foreach($time in @(5,10,15)){Set-LatencyProbeScheduled $schedule $ip icmp 0 $time | Out-Null;Add-LatencyResult $schedule $ip icmp 0 Timeout $null $time | Out-Null}
Check 'three failures cool ICMP down but do not disable it forever' (-not(Test-LatencyProbeDue $schedule $ip icmp 0 74) -and (Test-LatencyProbeDue $schedule $ip icmp 0 75))
Set-LatencyProbeScheduled $schedule $ip tcp 443 75 | Out-Null
Check 'TCP keeps20s cadence independently of ICMP' (-not(Test-LatencyProbeDue $schedule $ip tcp 443 94) -and (Test-LatencyProbeDue $schedule $ip tcp 443 95))
Check 'clock rollback cannot insert an out-of-order sample' (-not(Add-LatencyResult $schedule $ip icmp 0 Success 1 1))
Check 'display exposes probe counts and distinguishes timeouts from errors' ((Get-LatencyDisplay $store $ip udp 27015 10).Detail.Contains('тайм-ауты 1, ошибки 1'))
Check 'invalid clocks cannot authorize a new probe' (-not(Test-LatencyProbeDue $schedule $ip icmp 0 ([double]::NaN)) -and -not(Test-LatencyProbeDue $schedule $ip icmp 0 ([double]::PositiveInfinity)))
$zero=New-LatencyStore;Add-LatencyResult $zero $ip icmp 0 Success 0 0 | Out-Null
Check 'genuine measured zero is retained separately from missing values' ((Get-LatencySummary $zero $ip icmp 0 0).MedianMs -eq 0)
$delayed=New-LatencyStore
Add-LatencyResult $delayed $ip icmp 0 Success 7 121 0 | Out-Null
$old=Get-LatencySummary $delayed $ip icmp 0 121
Check 'ingestion cannot turn an old completion into a fresh reply' ($old.Count -eq 1 -and $old.LastSuccessAge -eq 121 -and -not $old.Fresh)
Check 'completion outside retention window is discarded at ingestion' (-not(Add-LatencyResult $delayed $ip tcp 443 Success 9 700 0) -and (Get-LatencySummary $delayed $ip tcp 443 700).Count -eq 0)
$ordered=New-LatencyStore
Add-LatencyResult $ordered $ip icmp 0 Success 20 30 20 | Out-Null
Add-LatencyResult $ordered $ip icmp 0 Success 10 30 10 | Out-Null
Check 'out-of-order ingestion preserves actual last reply time and latency' ((Get-LatencySummary $ordered $ip icmp 0 30).LastMs -eq 20 -and (Get-LatencySummary $ordered $ip icmp 0 30).LastSuccessAge -eq 10)
if($fails){exit 1}
