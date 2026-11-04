param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$previousRuntime=$Script:Runtime
$work=Join-Path $previousRuntime ('settingstest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force|Out-Null
$Script:Runtime=$work
$settingsFile=Join-Path $work 'settings.ini'
$worker=$null;$sha=[Security.Cryptography.SHA256]::Create()
function Get-SharedFileHash($Path){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try{return [BitConverter]::ToString($sha.ComputeHash($stream))}finally{$stream.Dispose()}
}
try{
    Save-Settings @{telegram='off';alt='12';auto='on';custom='Привет'}
    $expected=$Script:Utf8NoBom.GetBytes("alt=12`r`nauto=on`r`ncustom=Привет`r`ntelegram=off`r`n")
    Check 'first save retains sorted UTF8-no-BOM CRLF format' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFile)) -ceq [Convert]::ToBase64String($expected))
    $original=[IO.File]::ReadAllBytes($settingsFile)
    $lock=[IO.File]::Open($settingsFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $rejected=$false
    try{try{Save-Settings @{alt='11'}}catch{$rejected=$true}}finally{$lock.Dispose()}
    Check 'locked settings reject save and preserve old bytes' ($rejected -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFile)) -ceq [Convert]::ToBase64String($original))
    Check 'failed save removes its owned temporary file' (@(Get-ChildItem -LiteralPath $work -File).Count -eq 1)
    $realWriter=${function:Write-TextNoBom};$script:wrotePath=$null
    function Write-TextNoBom([string]$Path,[string]$Text){
        $script:wrotePath=$Path
        [IO.File]::WriteAllText($Path,'alt=',(New-Object Text.UTF8Encoding($false)))
        throw (New-Object IO.IOException('Injected partial text write'))
    }
    $rejected=$false
    try{try{Save-Settings @{alt='11'}}catch{$rejected=$true}}finally{Set-Item -LiteralPath 'Function:\Write-TextNoBom' -Value $realWriter}
    Check 'partial low-level write failure preserves old settings' ($rejected -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFile)) -ceq [Convert]::ToBase64String($original))
    Check 'partial write cleans only its owned temporary file' (@(Get-ChildItem -LiteralPath $work -File).Count -eq 1)
    $unrelated=Join-Path $work 'settings.ini.other-operation.tmp'
    [IO.File]::WriteAllText($unrelated,'keep')
    Save-Settings @{alt='12'}
    Check 'save does not remove another operation temporary file' ([IO.File]::ReadAllText($unrelated) -ceq 'keep')
    Remove-Item -LiteralPath $unrelated
    Save-Settings @{alt='12';padding=('x'*1048576)}
    $hashA=Get-SharedFileHash $settingsFile
    Save-Settings @{alt='11';padding=('y'*1048576)}
    $hashB=Get-SharedFileHash $settingsFile
    $signal=Join-Path $work 'writing.txt'
    $workerFile=Join-Path $work 'writer.ps1'
    $source=@'
param($Pkg,$Runtime,$Signal)
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:Runtime=$Runtime
$a=@{alt='12';padding=('x'*1048576)};$b=@{alt='11';padding=('y'*1048576)}
[IO.File]::WriteAllText($Signal,'ready')
for($i=0;$i -lt 48;$i++){if($i%2){Save-Settings $a}else{Save-Settings $b}}
'@
    [IO.File]::WriteAllText($workerFile,$source,(New-Object Text.UTF8Encoding($true)))
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $psi.Arguments=ConvertTo-WinCmdLine @('-NoProfile','-ExecutionPolicy','Bypass','-File',$workerFile,$Pkg,$work,$signal)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardError=$true;$psi.RedirectStandardOutput=$true
    $worker=[Diagnostics.Process]::Start($psi)
    $stdout=$worker.StandardOutput.ReadToEndAsync();$stderr=$worker.StandardError.ReadToEndAsync()
    $timer=[Diagnostics.Stopwatch]::StartNew();$samples=0;$bad=0
    while(-not $worker.HasExited -and $timer.Elapsed.TotalSeconds -lt 25){
        if(Test-Path -LiteralPath $signal){
            try{$current=Get-SharedFileHash $settingsFile;if($current -cne $hashA -and $current -cne $hashB){$bad++};$samples++}catch{$bad++}
        }else{Start-Sleep -Milliseconds 5}
    }
    if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit();throw 'Settings writer timed out'}
    Check 'real concurrent writer completes successfully' ($worker.ExitCode -eq 0)
    if($worker.ExitCode -ne 0){Write-Host ($stderr.Result+$stdout.Result)}
    Check ('reader sees only complete old/new settings ('+$samples+' reads)') ($samples -gt 0 -and $bad -eq 0)
    Check 'success leaves no temporary settings files' (@(Get-ChildItem -LiteralPath $work -Filter 'settings.ini.*.tmp').Count -eq 0)
    $settings=Get-Settings
    Check 'new settings retain normal loading defaults' ($settings.alt -in @('11','12') -and $settings.game -eq 'all' -and $settings.gameudp -eq '1024-65535')
}finally{
    if($worker){if(-not $worker.HasExited){$worker.Kill();$worker.WaitForExit()};$worker.Dispose()}
    $sha.Dispose();$Script:Runtime=$previousRuntime
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($work)) -ne [IO.Path]::GetFullPath($previousRuntime).TrimEnd('\')){throw 'Unsafe settings test directory'}
    Remove-Item -LiteralPath $work -Recurse -Force
}
if($fails){exit 1}
