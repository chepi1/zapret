# Small immutable launch exclusions. No processes, files or settings on import.
function Test-CaptureFilter {
    [CmdletBinding(DefaultParameterSetName='Text')]
    param(
        [Parameter(Position=0,ParameterSetName='Text')][AllowEmptyString()][string]$Filter,
        [Parameter(Mandatory=$true,ParameterSetName='Bytes')][AllowNull()][AllowEmptyCollection()][byte[]]$FilterBytes
    )
    try{
        if(-not ('ZapretFilter.Compiler' -as [type])){
            Add-Type -TypeDefinition ([IO.File]::ReadAllText((Get-PkgPath 'tools/filtercheck.cs'))) -Language CSharp -ErrorAction Stop
        }
        $dll=Get-PkgPath 'bin/WinDivert.dll'
        $checked=if($PSCmdlet.ParameterSetName -eq 'Bytes'){[ZapretFilter.Compiler]::CheckBytes($dll,$FilterBytes)}else{[ZapretFilter.Compiler]::Check($dll,$Filter)}
        $text=if($checked.Ok){''}else{'Ошибка фильтра WinDivert, позиция '+$checked.Position+': '+$checked.Error}
        return [pscustomobject]@{Ok=$checked.Ok;Output=$text;Position=$checked.Position}
    }catch{return [pscustomobject]@{Ok=$false;Output=('Не удалось проверить фильтр WinDivert: '+$_.Exception.Message);Position=$null}}
}

function ConvertTo-CaptureIp4([uint64]$Value){
    return ('{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255),(($Value -shr 16) -band 255),(($Value -shr 8) -band 255),($Value -band 255))
}
function Get-CaptureExclusion([string[]]$Lines){
    $nets=[ordered]@{}
    foreach($source in $Lines){
        $line=($source -split '#',2)[0].Trim()
        if(-not $line){continue}
        if($line -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}/(?:[1-9]|[12][0-9]|3[0-2])$'){return $null}
        $hostText,$prefixText=$line -split '/'
        $address=$null
        if(-not [Net.IPAddress]::TryParse($hostText,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $hostText){return $null}
        $bytes=$address.GetAddressBytes()
        $number=[uint64]$bytes[0]*16777216L+[uint64]$bytes[1]*65536L+[uint64]$bytes[2]*256L+$bytes[3]
        $size=[uint64][math]::Pow(2,32-[int]$prefixText)
        if($number % $size -ne 0){return $null}
        $nets[$line]=if($size -eq 1){'ip.DstAddr!='+$hostText}else{'(ip.DstAddr<'+$hostText+' or ip.DstAddr>'+(ConvertTo-CaptureIp4 ($number+$size-1))+')'}
        if($nets.Count -gt 32){return $null}
    }
    if(-not $nets.Count){return $null}
    # WinDivert negation accepts a field test, not an arbitrary parenthesized expression.
    $outsideDst=@($nets.Values) -join ' and '
    $outsideSrc=$outsideDst.Replace('ip.DstAddr','ip.SrcAddr')
    $outbound='not outbound or (not tcp and not udp) or not ip or ('+$outsideDst+')'
    $inbound='not inbound or not tcp or not ip or ('+$outsideSrc+')'
    return [pscustomobject]@{Count=$nets.Count;Cidrs=[string[]]@($nets.Keys);IpArgument=('--ipset-exclude-ip='+(@($nets.Keys) -join ','));Filter=('('+$outbound+') and ('+$inbound+')')}
}
