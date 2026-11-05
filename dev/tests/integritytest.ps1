param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$exists=$null -ne (Get-Command Read-CoreManifest -ErrorAction SilentlyContinue)
Check 'one core manifest reader exists' $exists
if(-not $exists){exit 1}
$path=Join-Path $Pkg 'tools/upstream.txt';$bytes=[IO.File]::ReadAllBytes($path);$text=[IO.File]::ReadAllText($path)
$manifest=Read-CoreManifest $path
Check 'baseline manifest owns all eight fixed official dependencies' ($manifest.Tag -match '^v\d+\.\d+\.\d+$' -and $manifest.Hashes.Count -eq 8 -and $manifest.Hashes.Contains('bin\winws2.exe') -and $manifest.Hashes.Contains('windivert\quic_initial_ietf.txt'))
Check 'runtime integrity and update notice use the same loaded manifest' ($Script:Upstream['zapret2'].Base -ceq $manifest.Tag -and $Script:UpstreamHashes.Count -eq 8 -and @(Test-PackageIntegrity).Count -eq 0)
Check 'human CHECKSUMS block is derived from the pins' ([IO.File]::ReadAllText((Join-Path $Pkg 'CHECKSUMS.txt')).Replace("`r`n","`n").StartsWith($manifest.ChecksumsBlock.Replace("`r`n","`n"),[StringComparison]::Ordinal))
$fixture=Join-Path $Script:Runtime 'invalid-core-manifest.txt'
$invalid=@(
    ($text+"`nunknown=value`n"),
    ($text+"`ntag="+$manifest.Tag+"`n"),
    ($text.Replace('schema=1','schema=2')),
    ($text.Replace(('tag='+$manifest.Tag),('tag=v0'+$manifest.Tag.Substring(1)))),
    ($text.Replace('bin/winws2.exe=','../winws2.exe=')),
    ($text.Replace('bin/winws2.exe=','bin/WINWS2.exe=')),
    ($text -replace '(?m)^bin/winws2\.exe=.*\r?\n',''),
    ($text.Replace('archive-sha256=','archive-sha256=bad')),
    ($text.Replace('bin/winws2.exe=','bin/winws2.exe=bad')),
    ($text.Replace('commit=','commit=z')),
    ('# missing all data'),
    ('#'+('x'*8192))
)
foreach($value in $invalid){
    [IO.File]::WriteAllText($fixture,$value,(New-Object Text.UTF8Encoding($false)))
    $blocked=$false;try{Read-CoreManifest $fixture|Out-Null}catch{$blocked=$true}
    Check 'malformed duplicate missing unknown or oversized manifest is rejected' $blocked
}
foreach($badBytes in @([byte[]]@(0xFF,0xFE,0,0),[byte[]]@(0xC3,0x28))){
    [IO.File]::WriteAllBytes($fixture,$badBytes);$blocked=$false
    try{Read-CoreManifest $fixture|Out-Null}catch{$blocked=$true}
    Check 'invalid UTF8 cannot be normalized into accepted pins' $blocked
}
foreach($control in @([char]0,[char]0x00AD)){
    foreach($field in @('schema','tag-key')){
        $value=if($field -eq 'schema'){$text.Replace('schema=1',('schema=1'+$control))}else{$text.Replace('tag=',('tag'+$control+'='))}
        [IO.File]::WriteAllText($fixture,$value,(New-Object Text.UTF8Encoding($false)));$blocked=$false
        try{Read-CoreManifest $fixture|Out-Null}catch{$blocked=$true}
        Check ('PS5 rejects ignorable character '+[int]$control+' in '+$field) $blocked
    }
}
$stamp=[IO.File]::GetLastWriteTimeUtc($path)
try{
    $nextTag=if($manifest.Tag.EndsWith('6')){$manifest.Tag.Substring(0,$manifest.Tag.Length-1)+'7'}else{$manifest.Tag.Substring(0,$manifest.Tag.Length-1)+'6'}
    [IO.File]::WriteAllText($path,$text.Replace(('tag='+$manifest.Tag),('tag='+$nextTag)),(New-Object Text.UTF8Encoding($false)))
    [IO.File]::SetLastWriteTimeUtc($path,$stamp)
    Check 'loaded manifest detects same-size same-time disk changes' (-not (Test-CoreManifestCurrent $Script:CoreManifest $path))
    Check 'cached and full integrity both reject stale loaded pins' (@(Test-PackageIntegrity).Count -gt 0 -and @(Test-PackageIntegrity -Cached).Count -gt 0)
    $loaded=Get-LoadedPackageCodeSnapshot ${function:Read-CoreManifest}.Ast 'tools/integrity.ps1'
    Check 'loaded code snapshot does not substitute current disk pins' ($loaded['tools/upstream.txt'] -ceq $manifest.ContentHash)
    Check 'stale loaded pins invalidate watcher state and persisted composition' ((Get-NetworkWatchCodeState $loaded) -eq 'Changed' -and -not (Get-RingCompositionKey (Get-Settings) -ExpectedCode $loaded))
}finally{[IO.File]::WriteAllBytes($path,$bytes);[IO.File]::SetLastWriteTimeUtc($path,$stamp)}
Check 'restoring the manifest recovers integrity in the same process' ((Test-CoreManifestCurrent $Script:CoreManifest $path) -and @(Test-PackageIntegrity).Count -eq 0)
$writer=[IO.File]::Open($path,'Open','ReadWrite','ReadWrite');$blocked=$false
try{try{Read-CoreManifest $path|Out-Null}catch{$blocked=$true}}finally{$writer.Dispose()}
Check 'writer-open metadata cannot be loaded as a coherent pin' $blocked
if($fails){exit 1}
