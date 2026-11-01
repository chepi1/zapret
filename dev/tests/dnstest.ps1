# Проверка выводов диагностики DNS без сети, на копии пакета.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run through run-all.ps1 on a copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
$fails = 0
function Check($Name, $Ok) { if ($Ok) { Write-Host ('ok   ' + $Name) } else { Write-Host ('FAIL ' + $Name); $script:fails++ } }
if (-not (Get-Command Get-DnsCheck -ErrorAction SilentlyContinue)) { Write-Host 'FAIL DNS check has no explicit availability result'; exit 1 }
$Script:DnsProbeNames = @('one.example', 'two.example')
function Get-OurProcesses { return 'running' }
function Get-DohAddresses { return @() }
function Resolve-DnsName { New-Object PSObject -Property @{ Type = 'A'; IPAddress = '1.1.1.1' } }
function Test-TlsIps { return @() }
$r = Get-DnsCheck
Check 'DoH unavailable is unknown, not clean' ($r.Checked -eq 0 -and $r.Total -eq 2 -and $r.Suspect.Count -eq 0)
Check 'unknown is visible in report text' ((Get-DnsCheckText $r) -match 'не удалось')
function Get-DohAddresses { return '1.1.1.1' }
$r = Get-DnsCheck
Check 'matching answers are checked' ($r.Checked -eq 2 -and $r.Suspect.Count -eq 0)
function Get-DohAddresses { return '2.2.2.2' }
function Test-TlsIps { param($Name, $Ips, $TimeoutMs) New-Object PSObject -Property @{ Ok = ($Ips -contains '2.2.2.2') } }
$r = Get-DnsCheck
Check 'different reachable endpoint is only suspected' ($r.Checked -eq 2 -and $r.Suspect.Count -eq 2 -and (Get-DnsCheckText $r) -match 'возможная')
function Test-TlsIps { New-Object PSObject -Property @{ Ok = $false } }
$r = Get-DnsCheck
Check 'both endpoints failed is unknown' ($r.Checked -eq 0 -and $r.Suspect.Count -eq 0)
function Test-TlsIps { New-Object PSObject -Property @{ Ok = $true } }
$r = Get-DnsCheck
Check 'different working CDN answers are fine' ($r.Checked -eq 2 -and $r.Suspect.Count -eq 0)
function Get-OurProcesses { return @() }
$r = Get-DnsCheck
Check 'different public answers without bypass are unknown' ($r.Checked -eq 0)
function Resolve-DnsName { New-Object PSObject -Property @{ Type = 'A'; IPAddress = '10.0.0.1' } }
$r = Get-DnsCheck
Check 'private answers are flagged without bypass' ($r.Checked -eq 2 -and $r.Suspect.Count -eq 2)
function Get-DohAddresses { param($Name) if ($Name -eq 'one.example') { return '2.2.2.2' } }
$r = Get-DnsCheck
Check 'partial check retains its coverage' ($r.Checked -eq 1 -and $r.Total -eq 2 -and $r.Suspect.Count -eq 1)
if ($fails) { exit 1 }
Write-Host 'all ok'
