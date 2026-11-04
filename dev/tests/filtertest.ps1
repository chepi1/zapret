param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$env:__COMPAT_LAYER='RunAsInvoker'
$Script:ControlMutexName='Local\zapret-filtertest-'+[guid]::NewGuid().ToString('N')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$script:badCandidate=ConvertTo-WinCmdLine @('--wf-raw=outbound and zapret_unknown_field')
$good=ConvertTo-WinCmdLine @('--wf-raw=outbound and tcp')
Check 'native preflight accepts a valid complete filter' ((Test-ConfigDry @{} -CmdLine $good).Ok)
$invalid=Test-ConfigDry @{} -CmdLine $script:badCandidate
Check 'native preflight rejects a raw field that dry-run alone accepts' (-not $invalid.Ok)
$bomPath=Join-Path $Script:Runtime 'bom-filter.txt'
[IO.File]::WriteAllBytes($bomPath,([byte[]]@(0xEF,0xBB,0xBF)+[Text.Encoding]::ASCII.GetBytes('true')))
$script:bomCandidate=ConvertTo-WinCmdLine @('--wf-raw=@'+$bomPath)
Check 'raw UTF8 BOM is not silently removed before native validation' (-not (Test-ConfigDry @{} -CmdLine $script:bomCandidate).Ok)
$helper=Get-Command Test-CaptureFilter -ErrorAction SilentlyContinue
Check 'capture filter compiler helper exists' ($null -ne $helper)
if($helper){
    Check 'byte API accepts the unchanged native expression' ((Test-CaptureFilter -FilterBytes ([Text.Encoding]::ASCII.GetBytes('outbound and tcp'))).Ok)
    Check 'byte API rejects BOM instead of validating a decoded replacement' (-not (Test-CaptureFilter -FilterBytes ([IO.File]::ReadAllBytes($bomPath))).Ok)
    foreach($filter in @('true','false','outbound and tcp','ip and udp.DstPort==443','ipv6 and inbound and tcp.Syn')){
        Check ('native helper accepts '+$filter) ((Test-CaptureFilter $filter).Ok)
    }
    foreach($filter in @('','tcp and (','zapret_unknown_field',('tcp'+[char]0+' or udp'))){
        $result=Test-CaptureFilter $filter
        Check 'invalid or truncated filter cannot pass' (-not $result.Ok -and $result.Output)
    }
    $result=Test-CaptureFilter 'outbound and zapret_unknown_field'
    Check 'native syntax failure has a useful position and message' (-not $result.Ok -and $result.Position -ge 0 -and $result.Output -match 'WinDivert')
    $dll=Get-PkgPath 'bin/WinDivert.dll';$hidden=$dll+'.fixture'
    try{
        Move-Item -LiteralPath $dll -Destination $hidden
        Check 'missing compiler DLL fails closed' (-not (Test-CaptureFilter 'true').Ok)
        [IO.File]::WriteAllText($dll,'invalid DLL fixture')
        Check 'corrupted compiler DLL fails closed' (-not (Test-CaptureFilter 'true').Ok)
    }finally{if(Test-Path -LiteralPath $hidden){if(Test-Path -LiteralPath $dll){Remove-Item -LiteralPath $dll};Move-Item -LiteralPath $hidden -Destination $dll}}
    Check 'DLL recovery works in the same PowerShell process' ((Test-CaptureFilter 'true').Ok)
    Check 'oversized filter is rejected before native compilation' (-not (Test-CaptureFilter ('x'*1048577)).Ok)
    $settings=Get-Settings;$beforeHash=Get-RingCompositionKey $settings
    $source=Get-PkgPath 'tools/filtercheck.cs';$sourceBytes=[IO.File]::ReadAllBytes($source)
    try{
        [IO.File]::AppendAllText($source,"`n// fingerprint fixture",$Script:Utf8NoBom)
        Check 'compiler source participates in the composition fingerprint' ((Get-RingCompositionKey $settings) -cne $beforeHash)
    }finally{[IO.File]::WriteAllBytes($source,$sourceBytes)}
}
# Exercise the actual launcher's architecture selection, without UAC/recovery/menu execution.
$launcher=[IO.File]::ReadAllText((Join-Path $Pkg 'zapret.bat'))
$prefix=($launcher -split 'if /i "%~1"=="elevated" goto run',2)[0]
$probe=Join-Path $Script:Runtime 'launcher-arch.cmd'
[IO.File]::WriteAllText($probe,$prefix+"`r`n"+'"%ZAPRET_PS%" -NoProfile -Command "[Console]::WriteLine([Environment]::Is64BitProcess)"'+"`r`n",[Text.Encoding]::ASCII)
foreach($folder in @('System32','SysWOW64')){
    $shell=Join-Path $env:SystemRoot ($folder+'/cmd.exe')
    $result=Invoke-Native $shell ('/d /s /c "'+(ConvertTo-WinArg $probe)+'"') $Pkg 10
    Check ($folder+' launcher selects x64 PowerShell') ($result.ExitCode -eq 0 -and -not $result.TimedOut -and $result.Output.Trim() -ceq 'True')
}
# Record the real export files to verify cleanup on both native success and syntax failure.
$savedNative=${function:Invoke-Native};$script:exports=@()
function Invoke-Native {
    param($File,$Arguments,$WorkDir,$TimeoutSec)
    if($Arguments -match '"--wf-save=([^"]+)"'){$script:exports+=@($Matches[1])}
    & $savedNative $File $Arguments $WorkDir $TimeoutSec
}
try{
    $valid=Test-ConfigDry @{} -CmdLine $good
    $invalid=Test-ConfigDry @{} -CmdLine $script:badCandidate
    Check 'preflight export files are removed for success and failure' ($valid.Ok -and -not $invalid.Ok -and $script:exports.Count -eq 2 -and -not @($script:exports|Where-Object{Test-Path -LiteralPath $_}).Count)
}finally{Set-Item -LiteralPath 'Function:\Invoke-Native' -Value $savedNative}
$originalNative=${function:Invoke-Native}
try{
    function Invoke-Native {return @{ExitCode=0;TimedOut=$false;Output='incomplete native success'}}
    Check 'zero exit without an exported filter is rejected' (-not (Test-ConfigDry @{} -CmdLine $good).Ok)
    function Invoke-Native {return @{ExitCode=0;TimedOut=$true;Output='late native success'}}
    Check 'timeout cannot turn a late zero exit into success' (-not (Test-ConfigDry @{} -CmdLine $good).Ok)
}finally{Set-Item -LiteralPath 'Function:\Invoke-Native' -Value $originalNative}
# Real preflight is retained; only OS/service effects are replaced.
$script:stops=0;$script:launches=0
function Get-NetworkObservation {return [pscustomobject]@{Known=$true;Key=('A'*64)}}
function Test-PendingUpdate {return $false}
function Get-RunningGames {return @()}
function Test-PackageIntegrity {return @()}
function Get-Settings {return @{gamepins='off'}}
function Update-RuntimeLists {}
function Get-BypassCmdLine {return $script:badCandidate}
function Stop-Bypass {$script:stops++}
function Repair-WinDivertService {}
function Enable-TcpTimestamps {}
function Get-OurService {return $null}
function Start-Process {$script:launches++}
function Wait-BypassAlive {return $true}
function Start-NetworkWatcher {return $true}
function Set-HighPriority {}
function Remove-OldRingMemory {}
$ok=Start-Bypass -Quiet
Check 'bad native filter preserves the running bypass before stop' (-not $ok -and $script:stops -eq 0 -and $script:launches -eq 0)
$script:badCandidate=$script:bomCandidate
$ok=Start-Bypass -Quiet
Check 'BOM-corrupted raw file also preserves the running bypass' (-not $ok -and $script:stops -eq 0 -and $script:launches -eq 0)
if($fails){exit 1}
