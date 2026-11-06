param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
if(-not(Get-Command Initialize-TgWsConfig -ErrorAction SilentlyContinue)){
    Check 'Telegram task embeds official TG WS Proxy with existing connection settings' $false
    exit 1
}
$secret='0123456789abcdef0123456789abcdef'
$spec=Initialize-TgWsConfig -Port 15443 -Secret $secret
$path=Join-Path $Script:Runtime 'tgws/TgWsProxy/config.json'
$config=[IO.File]::ReadAllText($path)|ConvertFrom-Json
Check 'upstream receives the existing MTProto port and secret unchanged' ($config.port -eq 15443 -and $config.secret -ceq $secret)
Check 'official app is restricted to loopback without independent autostart' ($config.host -ceq '127.0.0.1' -and -not $config.autostart -and -not $config.check_updates)
Check 'upstream WebSocket, CF fallback and HTTP2 defaults are available' ($config.pool_size -gt 0 -and $config.cfproxy -and $config.h2 -and -not $config.no_secure)
Check 'child AppData is isolated inside zapret runtime' ($spec.AppData -ceq (Join-Path $Script:Runtime 'tgws') -and $spec.Exe -ceq (Join-Path $Script:Root 'bin/tgws/TgWsProxy_windows.exe'))
Check 'a configured embedded app does not show the first-run wizard' (Test-Path (Join-Path (Split-Path $path) '.first_run_done_mtproto'))
$config|Add-Member NoteProperty cfproxy_user_domain @('custom.example') -Force
$config|Add-Member NoteProperty cfproxy_user_domain_enabled $true -Force
$config.port=9999;$config.secret='ffffffffffffffffffffffffffffffff';$config.host='0.0.0.0'
Write-TextNoBom $path ($config|ConvertTo-Json -Depth 5)
Initialize-TgWsConfig -Port 15443 -Secret $secret|Out-Null
$config=[IO.File]::ReadAllText($path)|ConvertFrom-Json
Check 'restart preserves custom upstream domains but restores managed listener credentials' ($config.cfproxy_user_domain[0] -ceq 'custom.example' -and $config.host -ceq '127.0.0.1' -and $config.port -eq 15443 -and $config.secret -ceq $secret)
$before=[IO.File]::ReadAllText($path);$refused=$false
try{Initialize-TgWsConfig -Port 15443 -Secret 'bad-secret'|Out-Null}catch{$refused=$true}
Check 'invalid credentials do not replace the existing config' ($refused -and [IO.File]::ReadAllText($path) -ceq $before)
$refused=$false;try{Assert-TgWsBinary|Out-Null}catch{$refused=$true}
if(-not(Test-Path $spec.Exe)){Check 'missing upstream binary cannot silently run the old C# server' $refused}
else{Check 'bundled official binary passes its pinned integrity check' (-not $refused)}
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Pkg 'tools/tgwsrunner.cs'))) -Language CSharp
Check 'owned process-tree containment compiles on Windows PowerShell 5.1' ($null -ne ('ZapretTgWs.Runner' -as [type]))
$fixture=Join-Path $Script:Runtime 'tgws-tree-fixture.exe'
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Net;
using System.Net.Sockets;
using System.Threading;
public static class TgTreeFixture {
    public static void Main(string[] args) {
        string folder=Environment.GetEnvironmentVariable("APPDATA");
        File.WriteAllText(Path.Combine(folder,args.Length==0?"parent.pid":"child.pid"),Process.GetCurrentProcess().Id.ToString());
        if(args.Length==0) {
            ProcessStartInfo info=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"child");
            info.UseShellExecute=false;info.CreateNoWindow=true;info.WindowStyle=ProcessWindowStyle.Hidden;Process.Start(info);
        } else {
            TcpListener listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
            File.WriteAllText(Path.Combine(folder,"child.port"),((IPEndPoint)listener.LocalEndpoint).Port.ToString());
        }
        Thread.Sleep(Timeout.Infinite);
    }
}
'@ -Language CSharp -OutputAssembly $fixture -OutputType ConsoleApplication
$data=Join-Path $Script:Runtime 'tgws-tree-data';New-Item -ItemType Directory -Path $data|Out-Null
$parentAppData=$env:APPDATA;$runner=$null;$parent=$null;$child=$null
try{
    $runner=[ZapretTgWs.Runner]::Start($fixture,$Script:Runtime,$data)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists((Join-Path $data 'child.port')) -and $clock.ElapsedMilliseconds -lt 5000){Start-Sleep -Milliseconds 50}
    $parent=Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $data 'parent.pid')))
    $child=Get-Process -Id ([int][IO.File]::ReadAllText((Join-Path $data 'child.pid')))
    Check 'contained child receives isolated AppData without changing the caller environment' ($env:APPDATA -ceq $parentAppData -and $parent.Id -eq $runner.ProcessId)
    if($null -eq $runner.GetType().GetMethod('MatchesCommand')){Check 'native command proof accepts the exact process and rejects another argument list' $false}
    else{
        Check 'native command proof accepts the exact process and rejects another argument list' ([ZapretTgWs.Runner]::MatchesCommand([uint32]$parent.Id,$parent.StartTime.Ticks,$fixture,('"'+$fixture+'"')) -and -not [ZapretTgWs.Runner]::MatchesCommand([uint32]$parent.Id,$parent.StartTime.Ticks,$fixture,('"'+$fixture+'" --other-config')))
    }
    $ownershipApi=$null -ne $runner.GetType().GetProperty('JobName')
    if(-not $ownershipApi){Check 'ready status requires a listener owned by the contained process tree' $false}
    else{
        $childPort=[int][IO.File]::ReadAllText((Join-Path $data 'child.port'))
        $owns=[ZapretTgWs.Runner]::OwnsListener($runner.JobName,$childPort)
        Check 'listener owned by a contained descendant is accepted' $owns
        $foreignListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        try{
            $foreignListener.Start();$foreignPort=$foreignListener.LocalEndpoint.Port
            $me=Get-Process -Id $PID
            Write-TextNoBom (Join-Path $Script:Runtime 'tgbridge.pid') ('{0}|{1}' -f $PID,$me.StartTime.Ticks)
            Write-TextNoBom (Join-Path $Script:Runtime 'tgws-engine.txt') ('{0}|{1}|{2}|{3}' -f $PID,$me.StartTime.Ticks,(Get-TgWsRelease).Tag,$runner.JobName)
            Write-TextNoBom (Join-Path $Script:Runtime 'telegram.txt') ("port=$foreignPort`r`nsecret=$secret`r`n")
            Check 'a foreign listener cannot make the bridge look ready' ((Get-TgBridgeState) -ne 'Open')
            Check 'native readiness rejects a listener outside the owned job' (-not [ZapretTgWs.Runner]::OwnsListener($runner.JobName,$foreignPort))
        }finally{$foreignListener.Stop()}
    }
    $runner.Dispose();$runner=$null
    $parentExited=$parent.WaitForExit(5000);$childExited=$child.WaitForExit(5000)
    Check 'closing the owner kills the bootloader and its descendant process' ($parentExited -and $childExited)
}finally{if($runner){$runner.Dispose()};if($parent){$parent.Dispose()};if($child){$child.Dispose()}}
$me=Get-Process -Id $PID
Write-TextNoBom (Join-Path $Script:Runtime 'tgbridge.pid') ('{0}|{1}' -f $PID,$me.StartTime.Ticks)
$script:forcedStops=@()
function Stop-ScheduledTask{}
function Stop-Process{param($Id);$script:forcedStops+=@($Id)}
Stop-TgBridge
Check 'a forged PID record cannot force-kill an unrelated process' ($script:forcedStops.Count -eq 0)
Check 'independent autostart with a legacy config argument is preserved' (-not (Test-TgWsLegacyRunCommand '"C:\Independent\TgWsProxy.exe" --config "C:\zapret\runtime\tg-ws-proxy\config.json"' 'C:\zapret\runtime\tg-ws-proxy'))
Check 'legacy executable ownership is parsed from the command itself' (Test-TgWsLegacyRunCommand '"C:\zapret\runtime\tg-ws-proxy\TgWsProxy.exe" --portable' 'C:\zapret\runtime\tg-ws-proxy')
$privateLog="Secret:        dd$secret`ntg://proxy?server=127.0.0.1&port=15443&secret=dd$secret`nConfig: {'secret': '$secret'}"
$safeLog=Protect-ReportText $privateLog ''
Check 'shared diagnostics hide upstream secrets and connection-link credentials' (-not $safeLog.Contains($secret) -and $safeLog.Contains('127.0.0.1'))
if($fails){exit 1}
Write-Host 'all ok'
