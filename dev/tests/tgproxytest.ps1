param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Pkg 'tools/tgbridge.cs'))) -Language CSharp
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$exists=$null -ne ('ZapretTg.Upstream' -as [type])
Check 'Telegram bridge has an explicit system-proxy transport' $exists
if(-not $exists){exit 1}
foreach($raw in @('127.0.0.1:10808','https=127.0.0.1:10808','http=127.0.0.1:1;https=127.0.0.1:10808','http://localhost:10808')){
    $endpoint=[ZapretTg.Upstream]::ParseProxy($raw)
    Check 'manual local HTTPS proxy is selected' ($null -ne $endpoint -and $endpoint.Port -eq 10808 -and [Net.IPAddress]::IsLoopback($endpoint.Address))
}
Check 'HTTP-only proxy does not override HTTPS routing' ($null -eq [ZapretTg.Upstream]::ParseProxy('http=127.0.0.1:10808'))
Check 'empty setting preserves direct mode' ($null -eq [ZapretTg.Upstream]::ParseProxy(''))
foreach($raw in @('https=proxy.example:10808','https=http://name:password@127.0.0.1:10808','http://name:pass=word@127.0.0.1:10808','http://127.0.0.1:10808/?token=password','https=socks5://127.0.0.1:10808')){
    $rejected=$false;$message='';try{[ZapretTg.Upstream]::ParseProxy($raw)|Out-Null}catch{$rejected=$true;$message=$_.Exception.GetBaseException().Message}
    Check 'unsupported configured proxy is rejected without leaking its value' ($rejected -and $message -notmatch 'password|pass=word|proxy\.example')
}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public sealed class TgProxyFixture : IDisposable {
    private TcpListener listener;
    public int Port; public string Request; public Task Worker;
    public TgProxyFixture(string mode) {
        listener=new TcpListener(IPAddress.Loopback,0);listener.Start();Port=((IPEndPoint)listener.LocalEndpoint).Port;
        Worker=Task.Run(async delegate {
            using(TcpClient client=await listener.AcceptTcpClientAsync()) {
                NetworkStream stream=client.GetStream();MemoryStream header=new MemoryStream();byte[] one=new byte[1];
                while(header.Length<16384) { int n=await stream.ReadAsync(one,0,1);if(n==0)return;header.Write(one,0,1);byte[] b=header.ToArray();int l=b.Length;if(l>=4&&b[l-4]==13&&b[l-3]==10&&b[l-2]==13&&b[l-1]==10)break; }
                Request=Encoding.ASCII.GetString(header.ToArray());
                if(mode=="hang") { while(await stream.ReadAsync(one,0,1)>0){};return; }
                string response=mode=="reject"?"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n":"HTTP/1.1 200 Connection established\r\n\r\n";
                byte[] data=Encoding.ASCII.GetBytes(response);await stream.WriteAsync(data,0,data.Length);
                if(mode=="reject"){while(await stream.ReadAsync(one,0,1)>0){};return;}
                byte[] request=new byte[4];int count=0;while(count<4){int n=await stream.ReadAsync(request,count,4-count);if(n==0)return;count+=n;}
                byte[] reply=Encoding.ASCII.GetBytes("PONG");await stream.WriteAsync(reply,0,reply.Length);
            }
        });
    }
    public void Dispose(){listener.Stop();}
}
'@
foreach($mode in @('ok','reject','hang')){
    $fixture=New-Object TgProxyFixture($mode);$client=$null;$errorFound=$false
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try{
        try{$client=[ZapretTg.Upstream]::Connect('192.0.2.1','unit.invalid',443,700,(New-Object Net.IPEndPoint([Net.IPAddress]::Loopback,$fixture.Port))).GetAwaiter().GetResult()}catch{$errorFound=$true}
        if($mode -eq 'ok'){
            Check 'CONNECT uses the target hostname for proxy routing and remote DNS' (-not $errorFound -and $fixture.Request.StartsWith("CONNECT unit.invalid:443 HTTP/1.1`r`n"))
            $stream=$client.GetStream();$stream.ReadTimeout=1000;$stream.WriteTimeout=1000
            $data=[Text.Encoding]::ASCII.GetBytes('PING');$stream.Write($data,0,4);$reply=New-Object byte[] 4
            $count=$stream.Read($reply,0,4)
            Check 'established tunnel carries opaque Telegram/TLS bytes' ($count -eq 4 -and [Text.Encoding]::ASCII.GetString($reply) -ceq 'PONG')
        }else{Check ($mode+' proxy response is not accepted as a connection') ($errorFound -and $clock.Elapsed.TotalSeconds -lt 3)}
    }finally{if($client){$client.Close()};$fixture.Dispose()}
    Check ($mode+' tunnel closes the owned socket') ($fixture.Worker.Wait(2000))
}
Check 'bridge crypto/framing self-test remains valid' ([ZapretTg.Bridge]::SelfTest() -ceq 'ok')
if($fails){exit 1}
