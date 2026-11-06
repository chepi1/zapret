# Код фонового наблюдателя должен совпадать с кодом, вошедшим в подтверждённый состав.
function Get-LoadedPackageCodeSnapshot([Management.Automation.Language.Ast]$EntryAst,[string]$RequiredEntry) {
    $sha=$null
    try{
        if($null -eq $EntryAst){return $null}
        $prefix=[IO.Path]::GetFullPath((Join-Path $Script:Root 'tools')).TrimEnd('\')+'\'
        $root=[IO.Path]::GetFullPath($Script:Root).TrimEnd('\')+'\'
        $asts=@($EntryAst)
        foreach($command in @(Get-Command -CommandType Function -ListImported)){
            if($null -ne $command.ScriptBlock){$asts+=@($command.ScriptBlock.Ast)}
        }
        $snapshot=@{};$seenRoots=@{};$encoding=New-Object Text.UTF8Encoding($true)
        $sha=[Security.Cryptography.SHA256]::Create()
        foreach($ast in $asts){
            if(-not $ast.Extent.File){continue}
            $path=[IO.Path]::GetFullPath($ast.Extent.File)
            if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
            while($null -ne $ast.Parent){$ast=$ast.Parent}
            $name=$path.Substring($root.Length).Replace('\','/')
            if($seenRoots.ContainsKey($name) -and [object]::ReferenceEquals($seenRoots[$name],$ast)){continue}
            # Все штатные PowerShell-файлы пакета имеют UTF-8 BOM (проверяет check).
            [byte[]]$bytes=$encoding.GetPreamble()+$encoding.GetBytes($ast.Extent.Text)
            $hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')
            if($snapshot.ContainsKey($name) -and $snapshot[$name] -cne $hash){return $null}
            $snapshot[$name]=$hash
            $seenRoots[$name]=$ast
        }
        if(-not $RequiredEntry -or -not $snapshot.ContainsKey($RequiredEntry)){return $null}
        $snapshot['tools/upstream.txt']=$Script:CoreManifest.ContentHash
        return $snapshot
    }catch{return $null}finally{if($null -ne $sha){$sha.Dispose()}}
}

function Get-NetworkWatchCodeSnapshot([Management.Automation.Language.Ast]$EntryAst) {
    return Get-LoadedPackageCodeSnapshot $EntryAst 'tools/netwatch.ps1'
}

function Get-NetworkWatchCodeState([hashtable]$Snapshot) {
    if($null -eq $Snapshot -or -not $Snapshot.Count){return 'Unknown'}
    try{
        foreach($name in $Snapshot.Keys){
            $hash=(Get-FileHash -LiteralPath (Join-Path $Script:Root $name) -Algorithm SHA256 -ErrorAction Stop).Hash
            if($hash -cne $Snapshot[$name]){return 'Changed'}
        }
        return 'Current'
    }catch{return 'Unknown'}
}
