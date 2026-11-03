# Независимый от lib.ps1 файловый журнал. Запускается launcher до загрузки основного кода.
param([switch]$Recover, [string]$RecoveryRoot = (Split-Path -Parent $PSScriptRoot))

function New-ControlMutex([string]$Name) {
    $security = New-Object Security.AccessControl.MutexSecurity
    foreach ($sid in @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.MutexAccessRule($identity,[Security.AccessControl.MutexRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    $created = $false
    return (New-Object Threading.Mutex($false,$Name,[ref]$created,$security))
}
function Get-UpdateTrustSids { return @('S-1-5-18','S-1-5-32-544') }
function Protect-UpdatePath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update storage is a reparse point.' }
    $sids = @(Get-UpdateTrustSids)
    $acl = if ($item.PSIsContainer) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($sids[-1])))
    foreach ($sid in $sids) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $inherit = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    if ($item.PSIsContainer) { [IO.Directory]::SetAccessControl($Path,$acl) } else { [IO.File]::SetAccessControl($Path,$acl) }
}
function Test-UpdateTrustedPath([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $sids = @(Get-UpdateTrustSids)
        if ($sids -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
        $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        $writers = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writers) -and $sids -notcontains $rule.IdentityReference.Value) { return $false }
        }
        return $rules.Count -gt 0
    } catch { return $false }
}
function Initialize-UpdateStore([string]$Root) {
    $store = Resolve-UpdateFilePath $Root 'runtime/update'
    New-Item -ItemType Directory -Path $store -Force -ErrorAction Stop | Out-Null
    Protect-UpdatePath $store
    return $store
}
function New-UpdateTransactionDirectory([string]$Root) {
    $store = Initialize-UpdateStore $Root
    $dir = Join-Path $store ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    Protect-UpdatePath $dir
    return $dir
}
function Resolve-UpdateFilePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative)) { throw 'Invalid relative update path.' }
    $segments = @($Relative -split '[/\\]')
    foreach ($segment in $segments) {
        if (-not $segment -or $segment -in @('.','..') -or $segment -match '[<>:"|?*\x00-\x1f]' -or $segment -match '[. ]$' -or $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)' -or $segment.StartsWith('.')) { throw 'Invalid update path segment.' }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $target = [IO.Path]::GetFullPath((Join-Path $base ($segments -join '\')))
    if (-not $target.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Update path escapes package.' }
    $cursor = $target
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update path contains a reparse point.' }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $target
}
function Write-UpdateJournal([string]$Path, $Journal) {
    $temp = $Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 6 -Compress))
        $file = [IO.File]::Open($temp,'CreateNew','Write','None')
        try { $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        Protect-UpdatePath $temp
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Get-UpdateJournalPaths([string]$Root) {
    $dir = Resolve-UpdateFilePath $Root 'runtime/update'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($child.Name -notmatch '^[a-f0-9]{32}$') { continue }
        $path = Join-Path $child.FullName 'journal.json'
        if (Test-Path -LiteralPath $path) { $path }
    }
}
function Read-UpdateJournal([string]$Root, [string]$Path) {
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $dir = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $id = [IO.Path]::GetFileName($dir)
    if ($id -notmatch '^[a-f0-9]{32}$' -or $Path -ine (Resolve-UpdateFilePath $base ('runtime/update/'+$id+'/journal.json'))) { throw 'Unexpected update journal location.' }
    foreach ($trusted in @((Split-Path $dir),$dir,$Path)) { if (-not (Test-UpdateTrustedPath $trusted)) { throw ('Untrusted update journal: '+$trusted) } }
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Oversized update journal.' }
    $journal = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    foreach ($key in @('Schema','Id','Root','State','WasRunning','Entries')) { if (-not $journal.PSObject.Properties[$key]) { throw 'Incomplete update journal.' } }
    if ($journal.Schema -ne 1 -or $journal.Id -cne $id -or $journal.Root -ine $base -or $journal.State -notin @('Prepared','Applying','Committed','RolledBack') -or $journal.WasRunning -isnot [bool] -or @($journal.Entries).Count -gt 500) { throw 'Unsupported update journal.' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $journal.Entries) {
        foreach ($key in @('Relative','Existed','OldHash','NewHash','Remove')) { if (-not $entry.PSObject.Properties[$key]) { throw 'Incomplete update entry.' } }
        if (-not $seen.Add($entry.Relative) -or $entry.Existed -isnot [bool] -or $entry.Remove -isnot [bool] -or ($entry.Existed -and $entry.OldHash -notmatch '^[A-F0-9]{64}$') -or (-not $entry.Remove -and $entry.NewHash -notmatch '^[A-F0-9]{64}$')) { throw 'Invalid update entry.' }
        if ($entry.Relative -match '^(?i:runtime)[/\\]' -and $entry.Relative -ine 'runtime\settings.ini') { throw 'Unexpected runtime update entry.' }
        Resolve-UpdateFilePath $base $entry.Relative | Out-Null
        Resolve-UpdateFilePath (Join-Path $dir 'backup') $entry.Relative | Out-Null
    }
    return $journal
}
function Test-PendingUpdate([string]$Root) {
    foreach ($path in @(Get-UpdateJournalPaths $Root)) { if ((Read-UpdateJournal $Root $path).State -in @('Prepared','Applying')) { return $true } }
    return $false
}
# Копия публикуется rename/replace: сам recovery.ps1 и launcher никогда не остаются наполовину записанными.
function Copy-UpdateFile([string]$Source, [string]$Target, [string]$Hash) {
    $parent = Split-Path -Parent $Target
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $temp = Join-Path $parent ('.update-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force -ErrorAction Stop
        $file = [IO.File]::Open($temp,'Open','ReadWrite','None')
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actual = [BitConverter]::ToString($sha.ComputeHash($file)).Replace('-','') } finally { $sha.Dispose() }
            if ($actual -cne $Hash) { throw 'Update copy hash mismatch.' }
            $file.Flush($true)
        } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $Target) { [IO.File]::Replace($temp,$Target,[NullString]::Value) } else { [IO.File]::Move($temp,$Target) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Write-UpdateRestartIntent([string]$Root, [bool]$WasRunning) {
    $target = Resolve-UpdateFilePath $Root 'runtime/update-restart.txt'
    $temp = $target+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $file = [IO.File]::Open($temp,'CreateNew','Write','None')
        try { $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($WasRunning) { 'start' } else { '' })); $file.Write($bytes,0,$bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temp,$target,[NullString]::Value) } else { [IO.File]::Move($temp,$target) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}
function Restore-UpdateJournalFiles([string]$Root, [string]$Path) {
    $journal = Read-UpdateJournal $Root $Path
    if ($journal.State -eq 'Prepared') {
        # До Applying файлы не менялись. Обход мог ещё работать, либо остановка уже успела завершиться.
        Write-UpdateRestartIntent $Root ($journal.WasRunning -and (Test-UpdateRecoverySafe $Root))
        $journal.State = 'RolledBack'; Write-UpdateJournal $Path $journal
        return
    }
    if ($journal.State -ne 'Applying') { return }
    $backup = Join-Path (Split-Path $Path) 'backup'
    # Проверяем ВСЕ копии и текущие цели до первой записи. Постороннюю правку после сбоя не затираем.
    foreach ($entry in $journal.Entries) {
        if ($entry.Existed) {
            $old = Resolve-UpdateFilePath $backup $entry.Relative
            $cursor = $old
            while ($cursor.StartsWith($backup,[StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Test-UpdateTrustedPath $cursor)) { throw 'Untrusted update backup.' }
                $cursor = [IO.Path]::GetDirectoryName($cursor)
            }
            if ((Get-FileHash -LiteralPath $old -Algorithm SHA256 -ErrorAction Stop).Hash -cne $entry.OldHash) { throw 'Damaged update backup; recovery stopped.' }
        }
        $target = Resolve-UpdateFilePath $Root $entry.Relative
        if (Test-Path -LiteralPath $target) {
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($hash -cne $entry.OldHash -and $hash -cne $entry.NewHash) { throw ('File edited after update interruption: '+$entry.Relative) }
        }
    }
    $entries = @($journal.Entries)
    for ($i=$entries.Count-1; $i -ge 0; $i--) {
        $entry = $entries[$i]; $target = Resolve-UpdateFilePath $Root $entry.Relative
        if ($entry.Existed) { Copy-UpdateFile (Resolve-UpdateFilePath $backup $entry.Relative) $target $entry.OldHash }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
    }
    Write-UpdateRestartIntent $Root $journal.WasRunning
    $journal.State = 'RolledBack'; Write-UpdateJournal $Path $journal
}
function Test-UpdateRecoverySafe([string]$Root) {
    $exe = Join-Path $Root 'bin/winws2.exe'
    foreach ($process in @(Get-Process -Name winws2 -ErrorAction SilentlyContinue)) {
        try { if ($process.Path -ieq $exe) { return $false } } catch { return $false }
    }
    $service = Get-Service -Name 'zapret2-bypass' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -in @('Running','StartPending','StopPending')) {
        $key = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret2-bypass' -Name ImagePath -ErrorAction Stop
        if ($key.ImagePath -match [regex]::Escape($exe)) { return $false }
    }
    return $true
}
function Restore-InterruptedUpdate([string]$Root) {
    if (-not (Test-PendingUpdate $Root)) { return $true }
    $mutexName = if (Get-Variable ControlMutexName -Scope Script -ErrorAction SilentlyContinue) { $Script:ControlMutexName } else { 'Global\chepi1.zapret2.control.v2' }
    $mutex = New-ControlMutex $mutexName; $owns = $false
    try {
        try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
        if (-not $owns) { throw 'Another operation controls the bypass; recovery deferred.' }
        $pending = @(@(Get-UpdateJournalPaths $Root) | Where-Object { (Read-UpdateJournal $Root $_).State -in @('Prepared','Applying') })
        if ($pending.Count -gt 1) { throw 'Multiple unfinished updates; automatic recovery stopped.' }
        foreach ($path in $pending) { if ((Read-UpdateJournal $Root $path).State -eq 'Applying' -and -not (Test-UpdateRecoverySafe $Root)) { throw 'Bypass is running; automatic file recovery deferred.' } }
        foreach ($path in $pending) { Restore-UpdateJournalFiles $Root $path; Write-Host 'Незавершённое обновление отменено: прежние файлы восстановлены.' -ForegroundColor Yellow }
        return $true
    } finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

if ($Recover) {
    try { if (-not (Restore-InterruptedUpdate $RecoveryRoot)) { exit 1 } }
    catch { Write-Host ('Восстановление обновления остановлено: '+$_.Exception.Message) -ForegroundColor Red; exit 1 }
    exit 0
}
