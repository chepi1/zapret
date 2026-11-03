# Транзакция обновления на временных файлах, без сети, служб и настоящего реестра.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools\lib.ps1')
function Get-UpdateTrustSids { return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
$Script:ControlMutexName='Local\zapret-updatetest-'+[guid]::NewGuid().ToString('N')
$fails = 0
function Check($Name, $Ok) { if ($Ok) { Write-Host ('ok   ' + $Name) } else { Write-Host ('FAIL ' + $Name); $script:fails++ } }
$stage = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('zapret-update-test-' + [guid]::NewGuid().ToString('N'))))
if ([IO.Path]::GetDirectoryName($stage) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) { throw 'Unsafe test directory' }
$src = Join-Path $stage 'src'; $dst = Join-Path $stage 'dst'
function New-TestBackup { return (Join-Path $dst ('runtime/update/'+[guid]::NewGuid().ToString('N')+'/backup')) }
$backup = New-TestBackup
foreach ($base in @($src, $dst)) { New-Item -ItemType Directory (Join-Path $base 'strategies') -Force | Out-Null }
try {
    if (-not (Get-Command Install-UpdateFiles -ErrorAction SilentlyContinue)) { Write-Host 'FAIL update has no fail-safe file transaction'; exit 1 }
    Write-TextNoBom (Join-Path $src 'strategies\retired.txt') "alt54.txt`r`n"
    Write-TextNoBom (Join-Path $dst 'strategies\alt54.txt') 'old retired strategy'
    Write-TextNoBom (Join-Path $dst 'strategies\alt99.txt') 'custom strategy'
    Write-TextNoBom (Join-Path $dst 'runtime-note.txt') 'user data'
    Write-TextNoBom (Join-Path $src 'a.txt') 'new a'
    Write-TextNoBom (Join-Path $dst 'a.txt') 'old a'
    Write-TextNoBom (Join-Path $src 'b.txt') 'new b'
    $remove = @(Get-RetiredStrategies $src $dst)
    Check 'only explicitly retired strategies removed' (($remove -join ',') -eq 'strategies\alt54.txt')
    $ok = Install-UpdateFiles $src $dst $backup @('a.txt','b.txt') $remove
    Check 'update replaces and adds files' ($ok -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'new a' -and (Test-Path (Join-Path $dst 'b.txt')))
    Check 'retired removed, custom and user data kept' (-not (Test-Path (Join-Path $dst 'strategies\alt54.txt')) -and (Test-Path (Join-Path $dst 'strategies\alt99.txt')) -and [IO.File]::ReadAllText((Join-Path $dst 'runtime-note.txt')) -eq 'user data')
    if (Get-Command Prepare-UpdateSettings -ErrorAction SilentlyContinue) {
        New-Item -ItemType Directory (Join-Path $dst 'runtime') -Force | Out-Null
        Write-TextNoBom (Join-Path $dst 'runtime\settings.ini') "alt=54`r`nauto=off`r`n"
        Copy-Item -LiteralPath (Join-Path $Pkg 'strategies\alt12.txt') -Destination (Join-Path $src 'strategies\alt12.txt')
        $migration = @(Prepare-UpdateSettings $src $dst @('strategies\alt54.txt'))
        $backup = New-TestBackup
        $ok = Install-UpdateFiles $src $dst $backup $migration @()
        $settings = [IO.File]::ReadAllText((Join-Path $dst 'runtime\settings.ini'))
        Check 'retired primary migrates without changing other settings' ($ok -and $settings -match '(?m)^alt=12\r?$' -and $settings -match '(?m)^auto=off\r?$' -and (Test-Path (Join-Path $src 'strategies\alt12.txt')))
    } else { Check 'retired primary has an update migration' $false }
    # Ошибка копии в backup не должна разрешать последующую запись в папку пользователя.
    Write-TextNoBom (Join-Path $dst 'a.txt') 'old a'
    $script:failMode = 'backup'
    function Copy-Item {
        [CmdletBinding()]param([string]$LiteralPath, [Parameter(Position=0)][string]$Destination, [switch]$Force)
        if ($script:failMode -eq 'backup' -and $Destination.StartsWith($backup)) { Write-Error 'simulated backup failure'; return }
        if ($script:failMode -eq 'replace' -and $LiteralPath -eq (Join-Path $src 'b.txt')) {
            [IO.File]::WriteAllText($Destination, 'partial overwrite')
            Write-Error 'simulated partial write'; return
        }
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    }
    $backup = New-TestBackup
    $ok = Install-UpdateFiles $src $dst $backup @('a.txt') @()
    Check 'backup error aborts before overwrite' (-not $ok -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'old a')
    $script:failMode = 'replace'
    $backup = New-TestBackup
    $ok = Install-UpdateFiles $src $dst $backup @('a.txt','b.txt') @()
    Check 'partial overwrite restores current and previous files' (-not $ok -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'old a' -and [IO.File]::ReadAllText((Join-Path $dst 'b.txt')) -eq 'new b')
    Remove-Item Function:\Copy-Item
    # Реестр HKCU в уникальном тестовом разделе.
    $Script:PriorityKey = 'HKCU:\Software\zapret-update-test-' + [guid]::NewGuid().ToString('N')
    try {
        New-Item -Path ($Script:PriorityKey + '\PerfOptions') -Force | Out-Null
        New-ItemProperty -Path $Script:PriorityKey -Name 'UnrelatedSetting' -Value 'keep' | Out-Null
        New-ItemProperty -Path ($Script:PriorityKey + '\PerfOptions') -Name 'IoPriority' -PropertyType DWord -Value 2 | Out-Null
        Set-BypassPriorityPolicy $true
        Set-BypassPriorityPolicy $false
        $unrelated = Get-ItemProperty -LiteralPath $Script:PriorityKey -ErrorAction SilentlyContinue
        $perf = Get-ItemProperty -LiteralPath ($Script:PriorityKey + '\PerfOptions') -ErrorAction SilentlyContinue
        Check 'disabling priority preserves other settings' ($unrelated -and $unrelated.UnrelatedSetting -eq 'keep' -and $perf -and $perf.IoPriority -eq 2 -and (Get-BypassPriorityPolicy) -eq 0)
        foreach ($before in @(2, 3)) {
            New-ItemProperty -Path ($Script:PriorityKey + '\PerfOptions') -Name 'CpuPriorityClass' -PropertyType DWord -Value $before -Force | Out-Null
            Set-BypassPriorityPolicy $true
            Set-BypassPriorityPolicy $false
            Check ('original CpuPriorityClass restored: ' + $before) ((Get-BypassPriorityPolicy) -eq $before)
        }
    } finally { Remove-Item -LiteralPath $Script:PriorityKey -Recurse -Force -ErrorAction SilentlyContinue }
} finally { Remove-Item -LiteralPath $stage -Recurse -Force }
if ($fails) { exit 1 }
Write-Host 'all ok'
