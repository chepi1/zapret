param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$work=Join-Path $Pkg ('runtime/buildtest-'+[guid]::NewGuid().ToString('N'))
$out=Join-Path $work 'output with spaces'
New-Item -ItemType Directory -Path $out -Force|Out-Null
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Build([switch]$DigestFailure) {
    $savedPreference=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue'
        if($DigestFailure){
            & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'digest-failure.ps1') -Builder (Join-Path $Pkg 'dev/build.ps1') -OutDir $out *> (Join-Path $work 'build.log')
        }else{
            & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Pkg 'dev/build.ps1') -OutDir $out *> (Join-Path $work 'build.log')
        }
        return $LASTEXITCODE
    }finally{$ErrorActionPreference=$savedPreference}
}
function Read-Entry($Zip,$Name){
    $entry=$Zip.GetEntry('zapret/'+$Name)
    if(-not $entry){return $null}
    $stream=$entry.Open();$memory=New-Object IO.MemoryStream
    try{$stream.CopyTo($memory);return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
}
function Same-Bytes($A,$B){return [Convert]::ToBase64String([byte[]]$A) -ceq [Convert]::ToBase64String([byte[]]$B)}
$marker='PRIVATE-'+[guid]::NewGuid().ToString('N')
$utf8=New-Object Text.UTF8Encoding($false)
$users=@('list-general-user.txt','list-exclude-user.txt','ipset-user.txt','ipset-exclude-user.txt')
$saved=@{};$marked=@{};$expected=@{}
$strays=@('.env','local-notes.txt','tools/private-session.ps1','lists/autohostlist.txt','lists/list-general.txt.bak')
$straySaved=@{}
$manifest=Join-Path $Pkg 'dev/package-files.txt'
$manifestBytes=$null
if(Test-Path -LiteralPath $manifest){$manifestBytes=[IO.File]::ReadAllBytes($manifest)}
$required=Join-Path $Pkg 'tools/filtercheck.cs';$requiredHidden=$required+'.fixture'
try{
    foreach($name in $users){
        $path=Join-Path $Pkg ('lists/'+$name);$saved[$name]=[IO.File]::ReadAllBytes($path)
        $template=Join-Path $Pkg ('dev/package-defaults/lists/'+$name)
        $expected[$name]=if(Test-Path -LiteralPath $template){[IO.File]::ReadAllBytes($template)}else{$saved[$name]}
        $marked[$name]=$utf8.GetBytes("# $marker`r`n"+[IO.File]::ReadAllText($path))
        [IO.File]::WriteAllBytes($path,$marked[$name])
    }
    foreach($name in $strays){
        $path=Join-Path $Pkg $name
        if(Test-Path -LiteralPath $path){$straySaved[$name]=[IO.File]::ReadAllBytes($path)}
        [IO.File]::WriteAllText($path,$marker,$utf8)
    }
    Check 'release build succeeds with local user data present' ((Build) -eq 0)
    $archives=@(Get-ChildItem -LiteralPath $out -Filter 'zapret-v*.zip')
    Check 'one complete release archive exists' ($archives.Count -eq 1)
    if($archives.Count -eq 1){
        $archive=$archives[0].FullName;$zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{
            $names=@($zip.Entries|ForEach-Object{$_.FullName})
            Check 'undeclared private files are excluded' (-not @($strays|Where-Object{$names -contains ('zapret/'+$_)}).Count)
            Check 'runtime contains only its empty placeholder' (@($names|Where-Object{$_ -like 'zapret/runtime/*' -and $_ -ne 'zapret/runtime/' -and $_ -ne 'zapret/runtime/.keep'}).Count -eq 0)
            foreach($name in $users){Check ('clean default '+$name) (Same-Bytes (Read-Entry $zip ('lists/'+$name)) $expected[$name])}
            $valve=$utf8.GetString((Read-Entry $zip 'lists/list-exclude-user.txt'))
            Check 'shared Steam and Valve game exclusions are retained' ($valve -match '(?m)^dota2.com\r?$' -and $valve -match '(?m)^steamserver.net\r?$')
            Check 'new compiler and binary bytes are packaged' ((Same-Bytes (Read-Entry $zip 'tools/filtercheck.cs') ([IO.File]::ReadAllBytes($required))) -and (Same-Bytes (Read-Entry $zip 'bin/WinDivert.dll') ([IO.File]::ReadAllBytes((Join-Path $Pkg 'bin/WinDivert.dll')))))
            if($manifestBytes){
                $declared=@([IO.File]::ReadAllLines($manifest)|Where-Object{$_ -and -not $_.StartsWith('#')}|ForEach-Object{'zapret/'+$_})+@('zapret/runtime/.keep')
                Check 'ZIP entries match the declared manifest exactly' (@(Compare-Object ($declared|Sort-Object) ($names|Sort-Object)).Count -eq 0)
            }else{Check 'release files have a committed allowlist' $false}
        }finally{$zip.Dispose()}
        foreach($name in $users){Check ('local user list is preserved '+$name) (Same-Bytes ([IO.File]::ReadAllBytes((Join-Path $Pkg ('lists/'+$name)))) $marked[$name])}
        $digest=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        Check 'repeated build succeeds' ((Build) -eq 0)
        Check 'identical inputs produce identical ZIP bytes' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        Move-Item -LiteralPath $required -Destination $requiredHidden
        try{
            Check 'missing required input rejects the build' ((Build) -ne 0)
            Check 'missing input preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        }finally{Move-Item -LiteralPath $requiredHidden -Destination $required}
        if($manifestBytes){
            foreach($bad in @('../outside.txt','tools/lib.ps1','TOOLS/lib.ps1','C:/outside.txt','lists/list-general-user.txt.','lists./list-exclude-user.txt','tools/NUL.txt')){
                [IO.File]::WriteAllBytes($manifest,($manifestBytes+$utf8.GetBytes("`n$bad`n")))
                Check ('unsafe or duplicate manifest path is rejected: '+$bad) ((Build) -ne 0)
                Check 'bad manifest preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
            }
            [IO.File]::WriteAllBytes($manifest,$manifestBytes)
            $alias=[IO.File]::ReadAllText($manifest).Replace('lists/list-general-user.txt','LISTS/LIST-GENERAL-USER.TXT')
            [IO.File]::WriteAllText($manifest,$alias,$utf8)
            Check 'case alias of a user list still builds safely' ((Build) -eq 0)
            $aliasZip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{Check 'case alias cannot package the private user list' (Same-Bytes (Read-Entry $aliasZip 'LISTS/LIST-GENERAL-USER.TXT') $expected['list-general-user.txt'])}finally{$aliasZip.Dispose()}
            [IO.File]::WriteAllBytes($manifest,$manifestBytes)
            Check 'restored manifest reproduces the original archive' ((Build) -eq 0 -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        }
        $template=Join-Path $Pkg 'dev/package-defaults/lists/list-exclude-user.txt'
        if(Test-Path -LiteralPath $template){
            Move-Item -LiteralPath $template -Destination ($template+'.fixture')
            try{Check 'missing clean template rejects the build' ((Build) -ne 0)}finally{Move-Item -LiteralPath ($template+'.fixture') -Destination $template}
            Check 'missing template preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        }
        $sourceLock=[IO.File]::Open($required,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try{Check 'unreadable source reports a failed build' ((Build) -ne 0)}finally{$sourceLock.Dispose()}
        Check 'partial ZIP failure preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        $tools=Join-Path $Pkg 'tools';$linkedTools=Join-Path $work 'linked tools'
        Move-Item -LiteralPath $tools -Destination $linkedTools
        try{
            New-Item -ItemType Junction -Path $tools -Target $linkedTools|Out-Null
            Check 'linked input directory is rejected' ((Build) -ne 0)
            Check 'linked input preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        }finally{
            if(Test-Path -LiteralPath $tools){[IO.Directory]::Delete($tools,$false)}
            Move-Item -LiteralPath $linkedTools -Destination $tools
        }
        $lock=[IO.File]::Open($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{Check 'locked destination reports a failed publication' ((Build) -ne 0)}finally{$lock.Dispose()}
        Check 'locked destination preserves previous archive' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        $hashFixture=@'
param($Builder,$OutDir)
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Utility
function Get-FileHash {throw 'Injected digest read failure'}
try{& $Builder -OutDir $OutDir;if(-not $?){exit 1}}catch{exit 1}
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $work 'digest-failure.ps1'),$hashFixture,$utf8)
        $sourceBytes=[IO.File]::ReadAllBytes($required)
        try{
            [IO.File]::AppendAllText($required,"`n// changed archive fixture",$utf8)
            Check 'digest failure reports an unsuccessful build' ((Build -DigestFailure) -ne 0)
            Check 'digest failure cannot replace the previous ZIP' ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ceq $digest)
        }finally{[IO.File]::WriteAllBytes($required,$sourceBytes)}
        Check 'failed builds remove their owned temporary ZIP' (@(Get-ChildItem -LiteralPath $out -Force|Where-Object{$_.Name -ne [IO.Path]::GetFileName($archive)}).Count -eq 0)
    }
}finally{
    if(Test-Path -LiteralPath $requiredHidden){Move-Item -LiteralPath $requiredHidden -Destination $required -Force}
    if($manifestBytes){[IO.File]::WriteAllBytes($manifest,$manifestBytes)}
    foreach($name in $saved.Keys){[IO.File]::WriteAllBytes((Join-Path $Pkg ('lists/'+$name)),$saved[$name])}
    foreach($name in $strays){
        $path=Join-Path $Pkg $name
        if($straySaved.ContainsKey($name)){[IO.File]::WriteAllBytes($path,$straySaved[$name])}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
    }
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::GetFullPath((Join-Path $Pkg 'runtime')).TrimEnd('\')){throw 'Unsafe build test directory'}
    Remove-Item -LiteralPath $work -Recurse -Force
}
if($fails){exit 1}
