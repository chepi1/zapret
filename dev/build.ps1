# Архив для пользователей (Releases на GitHub): копия папки без dev\, .git и данных этого ПК.
# Результат - dist\zapret-v<версия>.zip, версия берётся из tools\lib.ps1.
param([string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$temporary=$null;$owned=$false;$archive=$null;$file=$null
try{
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $version=[regex]::Match([IO.File]::ReadAllText((Join-Path $root 'tools/lib.ps1')), "Script:Version\s*=\s*'([^']+)'").Groups[1].Value
    if($version -notmatch '^[0-9][0-9A-Za-z._-]*$'){throw 'Invalid package version in tools/lib.ps1'}
    $manifest=Join-Path $PSScriptRoot 'package-files.txt'
    $names=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($line in [IO.File]::ReadAllLines($manifest)){
        if(-not $line -or $line.StartsWith('#')){continue}
        if($line -notmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or @($line.Split('/')|Where-Object{$_ -eq '.' -or $_ -eq '..'}).Count){throw ('Invalid package path: '+$line)}
        foreach($segment in $line.Split('/')){
            if($segment.EndsWith('.') -or $segment -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'){throw ('Noncanonical Windows package path: '+$line)}
        }
        if($line -match '/' -and $line -notmatch '^(bin|fake|lists|lua|strategies|tools|windivert)/'){throw ('Invalid package directory: '+$line)}
        if($line -notmatch '/' -and $line -notmatch '^(CHANGELOG\.md|CHECKSUMS\.txt|LICENSE(?:-[A-Za-z0-9-]+\.txt)?|README(?:\.en)?\.md|THIRD-PARTY-NOTICES\.md|zapret\.bat)$'){throw ('Invalid package root file: '+$line)}
        if(-not $names.Add($line)){throw ('Duplicate package path: '+$line)}
    }
    $defaults=@('list-general-user.txt','list-exclude-user.txt','ipset-user.txt','ipset-exclude-user.txt')
    foreach($required in @('zapret.bat','tools/lib.ps1','tools/filtercheck.cs','bin/winws2.exe')+@($defaults|ForEach-Object{'lists/'+$_})){
        if(-not $names.Contains($required)){throw ('Missing required manifest entry: '+$required)}
    }
    $paths=[string[]]@($names);[Array]::Sort($paths,[StringComparer]::Ordinal)
    $inputs=@()
    foreach($path in $paths){
        $relative=$path
        if($path.StartsWith('lists/',[StringComparison]::OrdinalIgnoreCase) -and $defaults -contains $path.Substring(6)){$relative='dev/package-defaults/'+$path}
        # Check every component: a file in a linked directory is also outside the declared input tree.
        $source=$root
        foreach($part in $relative.Split('/')){
            $source=Join-Path $source $part
            $item=Get-Item -LiteralPath $source -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse package input: '+$relative)}
        }
        if($item.PSIsContainer){throw ('Package input is a directory: '+$relative)}
        $inputs+=@{Name=('zapret/'+$path);Source=$source}
    }
    $output=[IO.Path]::GetFullPath($OutDir)
    [IO.Directory]::CreateDirectory($output)|Out-Null
    $destination=Join-Path $output ('zapret-v'+$version+'.zip')
    $temporary=Join-Path $output ('.zapret-build-'+[guid]::NewGuid().ToString('N')+'.tmp.zip')
    $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$owned=$true
    $archive=New-Object IO.Compression.ZipArchive($file,[IO.Compression.ZipArchiveMode]::Create,$true)
    $timestamp=[DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
    foreach($inputFile in $inputs){
        $entry=$archive.CreateEntry($inputFile.Name,[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$timestamp
        $sourceStream=$null;$entryStream=$null
        try{
            $sourceStream=[IO.File]::Open($inputFile.Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $entryStream=$entry.Open();$sourceStream.CopyTo($entryStream)
        }finally{if($entryStream){$entryStream.Dispose()};if($sourceStream){$sourceStream.Dispose()}}
    }
    $entry=$archive.CreateEntry('zapret/runtime/.keep');$entry.LastWriteTime=$timestamp
    $archive.Dispose();$archive=$null;$file.Dispose();$file=$null
    $check=[IO.Compression.ZipFile]::OpenRead($temporary)
    try{
        $expected=@($inputs|ForEach-Object{$_.Name})+@('zapret/runtime/.keep')
        $actual=@($check.Entries|ForEach-Object{$_.FullName})
        if($actual.Count -ne $expected.Count -or @(Compare-Object $expected $actual -CaseSensitive).Count){throw 'ZIP entries do not match the package manifest'}
    }finally{$check.Dispose()}
    $digest=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
    if($digest -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Cannot compute package SHA256'}
    # Same-directory replacement is atomic; an inaccessible destination leaves the old ZIP intact.
    if([IO.File]::Exists($destination)){[IO.File]::Replace($temporary,$destination,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$destination)}
    $owned=$false
    Write-Host ('Готово: {0} ({1} файлов, SHA256 {2})' -f $destination,$expected.Count,$digest) -ForegroundColor Green
}catch{
    Write-Host ('Сборка не выполнена: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}finally{
    if($archive){$archive.Dispose()}
    if($file){$file.Dispose()}
    if($owned -and $temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
}
