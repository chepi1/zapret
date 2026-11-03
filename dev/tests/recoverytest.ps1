param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if (Test-Path (Join-Path $Pkg '.git')) { throw 'Run on a package copy.' }
$ErrorActionPreference = 'Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:ControlMutexName = 'Local\zapret-recoverytest-'+[guid]::NewGuid().ToString('N')
$fails = 0
function Check($Name,$Ok) { if ($Ok) { Write-Host ('ok '+$Name) } else { Write-Host ('FAIL '+$Name); $script:fails++ } }
if (-not (Get-Command Restore-InterruptedUpdate -ErrorAction SilentlyContinue)) { throw 'FAIL update has no persistent recovery' }
$stage = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('zapret-recovery-'+[guid]::NewGuid().ToString('N'))))
if ([IO.Path]::GetDirectoryName($stage) -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) { throw 'Unsafe test directory' }
New-Item -ItemType Directory $stage | Out-Null
try {
    $ownerAcl = Get-Acl -LiteralPath $stage
    $ownerAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    [IO.Directory]::SetAccessControl($stage,$ownerAcl)
    Check 'ordinary writable runtime data is not trusted for elevated recovery' (-not (Test-UpdateTrustedPath $stage))
    # Current-user ACL only in isolated tests. Production permits SYSTEM/Administrators exclusively.
    function Get-UpdateTrustSids { return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
    $src = Join-Path $stage 'src'; $dst = Join-Path $stage 'dst'
    New-Item -ItemType Directory $src,$dst | Out-Null
    Write-TextNoBom (Join-Path $src 'a.txt') 'new a'; Write-TextNoBom (Join-Path $src 'b.txt') 'new b'
    Write-TextNoBom (Join-Path $dst 'a.txt') 'old a'
    $worker = Join-Path $stage 'worker.ps1'
    Write-TextNoBom $worker @'
param($Pkg,$Source,$Destination,$Signal,[bool]$WasRunning=$true,$CrashAt='replace')
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
function Get-UpdateTrustSids { return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
$script:realCopy = (Get-Command Copy-UpdateFile).ScriptBlock
function Copy-UpdateFile($Source,$Target,$Hash) {
    & $script:realCopy $Source $Target $Hash
    if ($CrashAt -eq 'replace' -and $Target -eq (Join-Path $Destination 'a.txt')) { [IO.File]::WriteAllText($Signal,'changed'); while ($true) { Start-Sleep -Seconds 1 } }
}
$backup=Join-Path $Destination ('runtime/update/'+[guid]::NewGuid().ToString('N')+'/backup')
Install-UpdateFiles $Source $Destination $backup @('b.txt','a.txt') @() -WasRunning:$WasRunning -BeforeApply {
    if ($CrashAt -eq 'prepared') { [IO.File]::WriteAllText($Signal,'prepared'); while ($true) { Start-Sleep -Seconds 1 } }
}
'@
    $signal = Join-Path $stage 'signal.txt'
    $ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'" -Pkg "'+$Pkg+'" -Source "'+$src+'" -Destination "'+$dst+'" -Signal "'+$signal+'"'
    $child = Start-Process $ps -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $stage 'worker-error.txt')
    try {
        for ($i=0; $i -lt 100 -and -not (Test-Path $signal) -and -not $child.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
        if (-not (Test-Path $signal)) { throw ('Worker never reached crash point. '+[IO.File]::ReadAllText((Join-Path $stage 'worker-error.txt'))) }
        Stop-Process -Id $child.Id -Force; $child.WaitForExit()
    } finally { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force; $child.WaitForExit() }; $child.Dispose() }
    Check 'hard-killed writer leaves a durable pending transaction' ((Test-PendingUpdate $dst) -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'new a' -and (Test-Path (Join-Path $dst 'b.txt')))
    $journalFile = @(Get-ChildItem (Join-Path $dst 'runtime/update') -Filter journal.json -Recurse)[0].FullName
    $journal = Read-UpdateJournal $dst $journalFile
    $backupA = Join-Path (Split-Path $journalFile) 'backup/a.txt'
    Write-TextNoBom $backupA 'tampered backup'
    $refused = $false; try { Restore-InterruptedUpdate $dst | Out-Null } catch { $refused = $true }
    Check 'damaged backup rejects recovery before any destination write' ($refused -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'new a')
    Write-TextNoBom $backupA 'old a'
    $recoverWorker = Join-Path $stage 'recover-only.ps1'
    Write-TextNoBom $recoverWorker @'
param($Pkg,$Destination)
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/recovery.ps1')
$Script:ControlMutexName='Local\zapret-recover-child-'+[guid]::NewGuid().ToString('N')
function Get-UpdateTrustSids { return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
if (-not (Restore-InterruptedUpdate $Destination)) { exit 1 }
'@
    $recoverArgs = '-NoProfile -ExecutionPolicy Bypass -File "'+$recoverWorker+'" -Pkg "'+$Pkg+'" -Destination "'+$dst+'"'
    $recovery = Invoke-Native $ps $recoverArgs $stage 15
    Check 'fresh process recovers without loading lib or menu' ($recovery.ExitCode -eq 0 -and -not $recovery.TimedOut)
    if ($recovery.ExitCode -ne 0) { Write-Host $recovery.Output }
    Check 'recovery restores originals and removes newly added files' ([IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'old a' -and -not (Test-Path (Join-Path $dst 'b.txt')) -and -not (Test-PendingUpdate $dst))
    Check 'previous running intent survives a process crash' ([IO.File]::ReadAllText((Join-Path $dst 'runtime/update-restart.txt')).Trim() -eq 'start')
    Check 'recovery is idempotent' (Restore-InterruptedUpdate $dst)
    Remove-Item -LiteralPath $signal
    $child = Start-Process $ps -ArgumentList ($arguments+' -CrashAt prepared') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $stage 'prepared-error.txt')
    try {
        for ($i=0; $i -lt 100 -and -not (Test-Path $signal) -and -not $child.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
        if (-not (Test-Path $signal)) { throw 'FAIL no durable preparation before stop callback' }
        Stop-Process -Id $child.Id -Force; $child.WaitForExit()
    } finally { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force; $child.WaitForExit() }; $child.Dispose() }
    $prepared = @(@(Get-UpdateJournalPaths $dst) | ForEach-Object { Read-UpdateJournal $dst $_ } | Where-Object { $_.State -eq 'Prepared' })
    Check 'running intent is durable before first file change or bypass stop' ($prepared.Count -eq 1 -and $prepared[0].WasRunning -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'old a')
    Write-TextNoBom (Join-Path $dst 'a.txt') 'edited while only prepared'
    Check 'prepared recovery preserves edits because no update files were applied' ((Restore-InterruptedUpdate $dst) -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'edited while only prepared')
    Check 'crash before any file replacement preserves restart intent' ([IO.File]::ReadAllText((Join-Path $dst 'runtime/update-restart.txt')).Trim() -eq 'start')
    Write-TextNoBom (Join-Path $dst 'a.txt') 'old a'
    $backup = Join-Path $dst ('runtime/update/'+[guid]::NewGuid().ToString('N')+'/backup')
    Check 'complete update commits journal' (Install-UpdateFiles $src $dst $backup @('a.txt','b.txt') @() -WasRunning:$false)
    Check 'stopped bypass stays stopped after successful update' ([IO.File]::ReadAllText((Join-Path $dst 'runtime/update-restart.txt')).Trim() -eq '' -and -not (Test-PendingUpdate $dst))
    Check 'committed files are not reverted on next boot' ((Restore-InterruptedUpdate $dst) -and [IO.File]::ReadAllText((Join-Path $dst 'a.txt')) -eq 'new a')
    $journalFile = Join-Path (Split-Path $backup) 'journal.json'
    $journal = Read-UpdateJournal $dst $journalFile
    $journal.State = 'Applying'; $journal.Entries[0].Relative = '..\outside.txt'
    Write-UpdateJournal $journalFile $journal
    $refused = $false; try { Restore-InterruptedUpdate $dst | Out-Null } catch { $refused = $true }
    Check 'journal cannot address a file outside the package' $refused
    $journal.Entries[0].Relative = 'a.txt'; $journal.Root = $src
    Write-UpdateJournal $journalFile $journal
    $refused = $false; try { Restore-InterruptedUpdate $dst | Out-Null } catch { $refused = $true }
    Check 'journal cannot redirect recovery to another package' $refused
    $journal.Root = [IO.Path]::GetFullPath($dst).TrimEnd('\'); $journal.State = 'Committed'
    Write-UpdateJournal $journalFile $journal
    $junction = Join-Path $dst 'redirect'; New-Item -ItemType Junction -Path $junction -Target $src | Out-Null
    $refused = $false; try { Resolve-UpdateFilePath $dst 'redirect/a.txt' | Out-Null } catch { $refused = $true }
    Check 'reparse points cannot redirect update writes' $refused
    [IO.Directory]::Delete($junction)
    $bat = [IO.File]::ReadAllText((Join-Path $Pkg 'zapret.bat'))
    Check 'launcher runs independent recovery before loading the menu' ($bat.IndexOf('tools\recovery.ps1') -ge 0 -and $bat.IndexOf('tools\recovery.ps1') -lt $bat.IndexOf('tools\menu.ps1'))
} finally { Remove-Item -LiteralPath $stage -Recurse -Force }
if ($fails) { exit 1 }
