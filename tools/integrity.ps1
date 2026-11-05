# Pinned core data is protected by the same tools-directory ACL as the loader.
# Pure file/parser helpers; importing this module performs no OS or network changes.
function Read-CoreManifestBytes([string]$Path){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length -lt 1 -or $stream.Length -gt 8192){throw 'Core manifest exceeds its size budget.'}
        $bytes=New-Object byte[] ([int]$stream.Length);$count=0
        while($count -lt $bytes.Length){$n=$stream.Read($bytes,$count,$bytes.Length-$count);if($n -le 0){throw 'Incomplete core manifest.'};$count+=$n}
        return ,$bytes
    }finally{$stream.Dispose()}
}
function Get-CoreManifestHash([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function Read-CoreManifest([string]$Path){
    $bytes=Read-CoreManifestBytes $Path
    $encoding=New-Object Text.UTF8Encoding($false,$true)
    $text=$encoding.GetString($bytes)
    if($text.Length -and $text[0] -eq [char]0xFEFF){$text=$text.Substring(1)}
    $files=@('bin/winws2.exe','bin/cygwin1.dll','bin/WinDivert.dll','bin/WinDivert64.sys','lua/zapret-lib.lua','lua/zapret-antidpi.lua','lua/zapret-auto.lua','windivert/quic_initial_ietf.txt')
    $allowed=@('schema','tag','commit','archive-sha256')+$files
    $allowedKeys=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($key in $allowed){[void]$allowedKeys.Add($key)}
    $values=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach($raw in @($text -split "`r?`n")){
        if($raw.TrimStart([char]' ').StartsWith('#',[StringComparison]::Ordinal)){continue}
        # PS5 culture comparisons can ignore NUL/soft hyphen in keys and values.
        # Validate the untrimmed record and use ordinal dictionaries for authority data.
        if($raw -cmatch '[^\x20-\x7E]'){throw 'Core manifest records must be printable ASCII.'}
        $line=$raw.Trim([char]' ');if(-not $line){continue}
        $eq=$line.IndexOf('=')
        if($eq -lt 1){throw 'Invalid core manifest record.'}
        $name=$line.Substring(0,$eq);$value=$line.Substring($eq+1)
        if(-not $allowedKeys.Contains($name) -or $values.ContainsKey($name)){throw 'Unknown or duplicate core manifest key.'}
        $values[$name]=$value
    }
    if($values.Count -ne $allowed.Count -or -not [string]::Equals($values['schema'],'1',[StringComparison]::Ordinal)){throw 'Incomplete or unsupported core manifest.'}
    if($values.tag -cnotmatch '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'){throw 'Invalid core manifest tag.'}
    $null=[version]$values.tag.Substring(1)
    if($values.commit -notmatch '^[a-fA-F0-9]{40}$' -or $values['archive-sha256'] -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid core manifest provenance.'}
    $hashes=[ordered]@{};$lines=@(
        ('SHA-256 файлов zapret2 '+$values.tag+' (без изменений из официального релиза github.com/bol-van/zapret2/releases/tag/'+$values.tag+','),
        ('архив zapret2-'+$values.tag+'.zip sha256 '+$values['archive-sha256'].ToLowerInvariant()+'):')
    )
    foreach($file in $files){
        if($values[$file] -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid pinned core file hash.'}
        $hash=$values[$file].ToLowerInvariant();$hashes[$file.Replace('/','\')]=$hash
        $lines+=@($hash+'  '+[IO.Path]::GetFileName($file))
    }
    return [pscustomobject]@{Schema=1;Tag=$values.tag;Commit=$values.commit.ToLowerInvariant();ArchiveSha256=$values['archive-sha256'].ToLowerInvariant();Hashes=$hashes;ContentHash=(Get-CoreManifestHash $bytes);ChecksumsBlock=(($lines -join "`r`n")+"`r`n")}
}
function Test-CoreManifestCurrent($Manifest,[string]$Path){
    try{return $null -ne $Manifest -and $Manifest.ContentHash -ceq (Get-CoreManifestHash (Read-CoreManifestBytes $Path))}catch{return $false}
}
