param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
& python -I (Join-Path $PSScriptRoot 'profile-import.py') $Pkg
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$alt=Get-Strategy 5
if(-not($alt.PSObject.Properties.Name -contains 'MatchL3')){throw 'Profile match model missing'}
Check 'ALT5 shared TCP remains IPv4 only' ($alt.MatchL3['general'] -eq 'ipv4' -and $alt.MatchL3['google'] -eq 'ipv4' -and $alt.MatchL3['discord_media'] -eq 'ipv4')
Check 'ALT5 game TCP is not wrongly restricted' (-not $alt.MatchL3.ContainsKey('game_tcp'))
$settings=Get-Settings;$settings.alt='5';$settings.auto='off'
Update-RuntimeLists | Out-Null
$args0=New-BypassArgList -Settings $settings
Check 'restricted profile produces explicit native IPv4 filter' ($args0 -contains '--filter-l3=ipv4')
Check 'restricted-only template has no IPv6 import' (-not(@($args0|Where-Object{$_ -eq '--import=tpl_general_ipv6'}).Count))
# Mixed circular must preserve IPv6 support of the compatible strategy.
$other=Get-Strategy 12
$script:testPrimary=$alt;$script:testOther=$other
function Get-RotationOrder { return @($script:testPrimary,$script:testOther) }
$settings.auto='on'
$mixed=New-BypassArgList -Settings $settings
Check 'mixed ring creates independent family templates' ($mixed -contains '--template=tpl_general_ipv4' -and $mixed -contains '--template=tpl_general_ipv6')
$text=$mixed -join "`n"
$v6=($text -split '--template=tpl_general_ipv6',2)[1] -split '--new',2
Check 'IPv4-only syndata never enters IPv6 template' ($v6[0] -notmatch 'syndata')
Check 'compatible IPv6 strategy is retained' ($v6[0] -match 'lua-desync=')
$compact=ConvertTo-CompactBypassArguments $mixed
Check 'compact arguments reduce repeated package paths' ((ConvertTo-WinCmdLine $compact).Length -lt (ConvertTo-WinCmdLine $mixed).Length)
Check 'compact arguments explicitly select package working directory' ($compact[0] -eq ('--chdir='+$Script:Root))
foreach($name in @('discord_media_ipv6','google_ipv6')){
    $body=($text -split ([regex]::Escape('--new='+$name)),2)[1] -split '--new',2
    Check ($name+' never executes IPv4-only action') ($body[0] -notmatch 'syndata' -and $body[0] -match '--filter-l3=ipv6')
}
$compat=$env:__COMPAT_LAYER
try{
    $env:__COMPAT_LAYER='RunAsInvoker'
    foreach($config in @($args0,$mixed)){
        $r=Invoke-Native $Script:Exe ('--dry-run '+(ConvertTo-WinCmdLine $config)) $Script:Bin 15
        Check 'engine accepts L3-separated profile configuration' ($r.ExitCode -eq 0 -and -not $r.TimedOut)
        if($r.ExitCode -ne 0){Write-Host $r.Output}
    }
    $r=Invoke-Native $Script:Exe ('--dry-run '+(ConvertTo-WinCmdLine $compact)) (Join-Path $env:SystemRoot 'System32') 15
    Check 'compact command resolves files even from service working directory' ($r.ExitCode -eq 0 -and -not $r.TimedOut)
    if($r.ExitCode -ne 0){Write-Host $r.Output}
}finally{$env:__COMPAT_LAYER=$compat}
$path=Join-Path $Script:StratDir 'alt5.txt';$original=[IO.File]::ReadAllBytes($path)
try{
    $bad=[IO.File]::ReadAllText($path).Replace('# match-l3: ipv4','# match-l3: invalid')
    [IO.File]::WriteAllText($path,$bad,$Script:Utf8NoBom);$Script:StrategiesCache=$null
    Check 'invalid metadata rejects only the affected strategy' ((Get-Strategy 5).Missing.Count -gt 0 -and (Get-Strategy 12).Missing.Count -eq 0)
    [IO.File]::WriteAllText($path,$bad.Replace('# match-l3: invalid','# match-l3:'),$Script:Utf8NoBom);$Script:StrategiesCache=$null
    Check 'empty family cannot silently broaden profile to any IP' ((Get-Strategy 5).Missing.Count -gt 0)
}finally{[IO.File]::WriteAllBytes($path,$original);$Script:StrategiesCache=$null}
if($fails){exit 1}
