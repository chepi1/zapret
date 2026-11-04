param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-UpdateTrustSids{return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
$Script:ControlMutexName='Local\zapret-updatearchive-'+[guid]::NewGuid().ToString('N')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$initialRoot=$Script:Root;$initialRuntime=$Script:Runtime
$work=[IO.Path]::GetFullPath((Join-Path $initialRuntime ('updatearchive-'+[guid]::NewGuid().ToString('N'))))
$realNative=${function:Invoke-Native}
$Script:Root=Join-Path $work 'installed';$Script:Runtime=Join-Path $Script:Root 'runtime'
New-Item -ItemType Directory -Path $Script:Runtime -Force|Out-Null
$good=Join-Path $work 'valid.zip';$bad=Join-Path $work 'bad.zip'
try{
    $zip=[IO.Compression.ZipFile]::Open($good,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($item in @(@('zapret/zapret.bat','fixture launcher'),@('zapret/tools/lib.ps1',"`$Script:Version='9.9'"),@('zapret/bin/winws2.exe','fixture only, never executed'),@('zapret/BROKEN.txt','CRC-DAMAGE-PAYLOAD-TEST'))){
            $entry=$zip.CreateEntry($item[0],[IO.Compression.CompressionLevel]::NoCompression);$stream=$entry.Open()
            try{$bytes=[Text.Encoding]::ASCII.GetBytes($item[1]);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
        }
    }finally{$zip.Dispose()}
    $bytes=[IO.File]::ReadAllBytes($good);$marker=[Text.Encoding]::ASCII.GetBytes('CRC-DAMAGE-PAYLOAD-TEST');$position=-1
    for($i=0;$i -le $bytes.Length-$marker.Length;$i++){
        $same=$true;for($j=0;$j -lt $marker.Length;$j++){if($bytes[$i+$j] -ne $marker[$j]){$same=$false;break}}
        if($same){$position=$i;break}
    }
    if($position -lt 0){throw 'CRC fixture payload not found'}
    $bytes[$position]=$bytes[$position] -bxor 1;[IO.File]::WriteAllBytes($bad,$bytes)
    $tar=Join-Path $env:SystemRoot 'System32/tar.exe';$probe=Join-Path $work 'standalone extraction'
    New-Item -ItemType Directory -Path $probe|Out-Null
    $result=& $realNative $tar (ConvertTo-WinCmdLine @('-x','-f',$bad,'-C',$probe)) $work 10
    Check 'real tar reports corrupted late entry after extracting valid headers' ($result.ExitCode -ne 0 -and -not $result.TimedOut -and (Test-Path -LiteralPath (Join-Path $probe 'zapret/zapret.bat')) -and (Test-Path -LiteralPath (Join-Path $probe 'zapret/tools/lib.ps1')) -and (Test-Path -LiteralPath (Join-Path $probe 'zapret/bin/winws2.exe')))
    $script:stops=0;$script:archive=$bad;$script:timeout=$false
    function Get-OurProcesses{return @([pscustomobject]@{Id=999999})}
    function Assert-BypassControlAllowed{}
    function Stop-BypassCore {$script:stops++}
    function Start-Bypass {throw 'Fixture must never start a live bypass'}
    function Invoke-Native($File,$Arguments,$WorkDir,$TimeoutSec){
        if([IO.Path]::GetFileName($File) -eq 'curl.exe'){
            if($Arguments -notmatch '-o "([^"]+)"'){throw 'Missing download fixture output'}
            Copy-Item -LiteralPath $script:archive -Destination $Matches[1]
            return [pscustomobject]@{ExitCode=0;TimedOut=$false;Output='fixture download'}
        }
        if([IO.Path]::GetFileName($File) -eq 'tar.exe'){
            if($script:timeout){return [pscustomobject]@{ExitCode=0;TimedOut=$true;Output='late zero exit'}}
            return & $realNative $File $Arguments $WorkDir $TimeoutSec
        }
        throw ('Unexpected native operation: '+$File)
    }
    foreach($case in @('crc','timeout','valid')){
        $Script:Root=Join-Path $work ('installation '+$case);$Script:Runtime=Join-Path $Script:Root 'runtime'
        New-Item -ItemType Directory -Path (Join-Path $Script:Root 'tools'),$Script:Runtime -Force|Out-Null
        $target=Join-Path $Script:Root 'tools/lib.ps1';Write-TextNoBom $target 'old working code'
        $oldHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        $script:stops=0;$script:timeout=($case -eq 'timeout');$script:archive=if($case -eq 'crc'){$bad}else{$good}
        $release=[pscustomobject]@{Name='zapret-v9.9.zip';Tag='v9.9';Url='https://fixture.invalid/never-requested';Sha256=(Get-FileHash -LiteralPath $script:archive -Algorithm SHA256).Hash.ToLowerInvariant()}
        $preference=$ErrorActionPreference
        try{$ErrorActionPreference='Continue';$ok=Install-ZapretUpdate $release}finally{$ErrorActionPreference=$preference}
        if($case -eq 'valid'){
            Check 'valid archive still reaches one controlled stop and installs' ($ok -and $script:stops -eq 1 -and [IO.File]::ReadAllText($target) -eq "`$Script:Version='9.9'")
        }else{
            Check ($case+' extraction failure preserves running bypass before stop') (-not $ok -and $script:stops -eq 0)
            Check ($case+' extraction failure preserves target code and has no pending transaction') ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ceq $oldHash -and -not (Test-PendingUpdate $Script:Root))
        }
    }
}finally{
    $Script:Root=$initialRoot;$Script:Runtime=$initialRuntime
    if([IO.Path]::GetDirectoryName($work) -ne [IO.Path]::GetFullPath($initialRuntime).TrimEnd('\')){throw 'Unsafe archive test directory'}
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
if($fails){exit 1}
