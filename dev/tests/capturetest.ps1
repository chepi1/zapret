param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
if(-not(Get-Command Get-CaptureExclusion -ErrorAction SilentlyContinue)){throw 'FAIL bounded transport capture compiler missing'}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
$sample=Get-CaptureExclusion @('# comment','104.255.104.0/22','198.133.210.0/24 # note','104.255.104.0/22')
Check 'deduplicated canonical CIDRs share a single launch snapshot' ($sample.Count -eq 2 -and $sample.IpArgument -eq '--ipset-exclude-ip=104.255.104.0/22,198.133.210.0/24')
Check 'IPv4 transport exclusion retains exact boundary neighbours' ($sample.Filter.Contains('ip.DstAddr<104.255.104.0 or ip.DstAddr>104.255.107.255'))
foreach($bad in @('2001:db8::/32','104.255.104.1/22','104.255.104/22','999.1.2.3/24','0.0.0.0/0','1.2.3.0/33','1.2.3.0/24 or true')){
    Check ('unsupported input retains file-based fallback: '+$bad) ($null -eq (Get-CaptureExclusion @('104.255.104.0/22',$bad)))
}
Check 'empty list cannot create a broad filter' ($null -eq (Get-CaptureExclusion @('# only comment','')))
$large=@(1..33|ForEach-Object{'8.8.'+$_+'.0/24'})
Check 'large lists keep the existing native file path' ($null -eq (Get-CaptureExclusion $large))
$settings=Get-Settings;$settings.auto='off';Update-RuntimeLists | Out-Null
$args0=New-BypassArgList -Settings $settings
$filters=@($args0|Where-Object{$_ -like '--wf-raw-filter=*'})
$snapshots=@($args0|Where-Object{$_ -like '--ipset-exclude-ip=*'})
Check 'one kernel AND clause accompanies every Take-Two profile snapshot' ($filters.Count -eq 1 -and $snapshots.Count -ge 8 -and @($snapshots|Select-Object -Unique).Count -eq 1 -and -not @($args0|Where-Object{$_ -match '^--ipset-exclude=.*taketwo'}).Count)
$profileName=$null;$hasSnapshot=$false;$missingSnapshots=@()
foreach($arg in $args0){
    if($arg -match '^--(?:name|new)=(.+)$'){
        if($profileName -and -not $hasSnapshot){$missingSnapshots+=$profileName}
        $profileName=$Matches[1];$hasSnapshot=$false
    }elseif($profileName -and $arg -eq $snapshots[0]){$hasSnapshot=$true}
}
if($profileName -and -not $hasSnapshot){$missingSnapshots+=$profileName}
Check 'every named profile already excludes the exact kernel snapshot for TCP and UDP' ($profileName -and $missingSnapshots.Count -eq 0)
Check 'Valve and user ipsets keep their existing live profile handling' (@($args0|Where-Object{$_ -like '--ipset-exclude=*ipset-exclude-user.txt'}).Count -gt 0 -and $filters[0] -notmatch 'Valve|ipset-user')
$source=Join-Path $Script:Lists 'ipset-taketwo.txt';$original=[IO.File]::ReadAllBytes($source)
try{
    [IO.File]::WriteAllText($source,"8.8.8.0/24`n",$Script:Utf8NoBom)
    $next=New-BypassArgList -Settings $settings
    Check 'source edits cannot change an already-built kernel/profile snapshot' ($snapshots[0] -match '104\.255\.104\.0/22' -and $next -contains '--ipset-exclude-ip=8.8.8.0/24')
    $maximum=@(100..131|ForEach-Object{'123.123.123.'+$_+'/32'})
    [IO.File]::WriteAllText($source,($maximum -join "`n")+"`n",$Script:Utf8NoBom)
    $wide=$settings.Clone();$wide.auto='on'
    $maxCmd=Get-BypassCmdLine -Settings $wide -Name 'capture-limit' -DryRun
    Check '32 maximum-length CIDRs with auto rotation fit the native launch budget' ($maxCmd.Length -le 32000)
    [IO.File]::WriteAllText($source,"104.255.104.0/22`n2001:db8::/32`n",$Script:Utf8NoBom)
    $fallback=New-BypassArgList -Settings $settings
    Check 'mixed-family fallback preserves full file semantics without partial kernel exclusion' (-not @($fallback|Where-Object{$_ -like '--wf-raw-filter=*'}).Count -and @($fallback|Where-Object{$_ -match '^--ipset-exclude=.*taketwo'}).Count -ge 8)
}finally{[IO.File]::WriteAllBytes($source,$original)}
$compat=$env:__COMPAT_LAYER
try{
    $env:__COMPAT_LAYER='RunAsInvoker'
    $beforeFile=Join-Path $Script:Runtime 'capture-before.txt';$afterFile=Join-Path $Script:Runtime 'capture-after.txt'
    $baseline=@($args0|Where-Object{$_ -notlike '--wf-raw-filter=*'})
    foreach($case in @(@{Args=$baseline;File=$beforeFile},@{Args=$args0;File=$afterFile})){
        $config=@('--dry-run',('--wf-save='+$case.File))+@($case.Args)
        $native=Invoke-Native $Script:Exe (ConvertTo-WinCmdLine $config) $Script:Bin 15
        Check 'bundled engine accepts configuration and exports its complete filter' ($native.ExitCode -eq 0 -and -not $native.TimedOut -and (Test-Path $case.File))
        if($native.ExitCode -ne 0 -or -not(Test-Path $case.File)){Write-Host $native.Output}
    }
    $maxFile=Join-Path $Script:Runtime 'capture-limit-filter.txt'
    $native=Invoke-Native $Script:Exe ($maxCmd+' '+(ConvertTo-WinArg ('--wf-save='+$maxFile))) $Script:Bin 15
    Check 'native engine exports the complete maximum-list filter within the launch budget' ($native.ExitCode -eq 0 -and -not $native.TimedOut -and (Test-Path $maxFile))
    if($native.ExitCode -ne 0 -or -not(Test-Path $maxFile)){Write-Host $native.Output}
    if((Test-Path $beforeFile) -and (Test-Path $afterFile)){
        & python -I (Join-Path $PSScriptRoot 'capture-filter.py') $Pkg $beforeFile $afterFile $maxFile
        Check 'native WinDivert filter compiler/evaluator passes the packet matrix without opening driver' ($LASTEXITCODE -eq 0)
    }
}finally{$env:__COMPAT_LAYER=$compat}
if($fails){exit 1}
