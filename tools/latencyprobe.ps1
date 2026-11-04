# Lazy managed TCP completion/timeout. No connections or compilation on import.
function Initialize-LatencyProbeType {
    if('Zapret.Diagnostics.ConnectOperation' -as [type]){return}
    $source=@'
using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
namespace Zapret.Diagnostics {
    public sealed class ConnectOperation : IDisposable {
        private readonly IDisposable owner;
        private readonly Timer timer;
        private readonly long started;
        private readonly int timeout;
        private int finished, ready;
        public string Outcome { get; private set; }
        public double? Milliseconds { get; private set; }
        public double CompletedSeconds { get; private set; }
        public bool IsCompleted { get { return Volatile.Read(ref ready) != 0; } }
        private double Elapsed { get { return (Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency; } }
        public ConnectOperation(Task task, IDisposable owner, long started, int timeout) {
            if(task == null || owner == null || timeout < 1 || timeout > 60000) throw new ArgumentException("Invalid connect operation");
            this.owner=owner;this.started=started;this.timeout=timeout;Outcome="Pending";
            timer=new Timer(delegate { Finish("Timeout",null); },null,Timeout.Infinite,Timeout.Infinite);
            task.ContinueWith(delegate(Task result) {
                if(result.IsFaulted) { var observed=result.Exception;Finish("Error",null); }
                else if(result.IsCanceled) Finish("Cancelled",null);
                else { var elapsed=Elapsed;Finish(elapsed<=this.timeout?"Success":"Timeout",elapsed<=this.timeout?(double?)elapsed:null); }
            },CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
            var remaining=timeout-Elapsed;
            if(remaining<=0) Finish("Timeout",null);
            else if(Volatile.Read(ref finished)==0) {
                try { timer.Change((int)Math.Ceiling(remaining),Timeout.Infinite); }
                catch(ObjectDisposedException) { }
            }
        }
        private void Finish(string outcome,double? milliseconds) {
            if(Interlocked.CompareExchange(ref finished,1,0)!=0) return;
            Outcome=outcome;Milliseconds=milliseconds;
            CompletedSeconds=Math.Min(Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency,started/(double)Stopwatch.Frequency+timeout/1000.0);
            try { timer.Dispose(); } catch { }
            try { owner.Dispose(); } catch { }
            Volatile.Write(ref ready,1);
        }
        public void Dispose() { Finish("Cancelled",null); }
    }
    public sealed class CompletionStamp {
        private int ready;
        public double CompletedSeconds { get; private set; }
        public bool IsCompleted { get { return Volatile.Read(ref ready)!=0; } }
        public CompletionStamp(Task task,double started,int timeout) {
            if(task==null || double.IsNaN(started) || double.IsInfinity(started) || started<0 || timeout<1 || timeout>60000) throw new ArgumentException("Invalid completion observer");
            task.ContinueWith(delegate(Task result) {
                if(result.IsFaulted) { var observed=result.Exception; }
                // A suspended process cannot make an old bounded request fresh on resume.
                CompletedSeconds=Math.Min(Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency,started+timeout/1000.0);
                Volatile.Write(ref ready,1);
            },CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}
function Start-LatencyTcpOperation([string]$Ip,[ValidateRange(1,65535)][int]$Port,[ValidateRange(1,60000)][int]$TimeoutMs=1000){
    $address=$null
    if(-not[Net.IPAddress]::TryParse($Ip,[ref]$address)){throw 'TCP probe requires a literal address'}
    Initialize-LatencyProbeType
    $client=New-Object Net.Sockets.TcpClient($address.AddressFamily)
    $started=[Diagnostics.Stopwatch]::GetTimestamp()
    try{
        $task=$client.ConnectAsync($address,$Port)
        return New-Object Zapret.Diagnostics.ConnectOperation -ArgumentList $task,$client,$started,$TimeoutMs
    }catch{$client.Dispose();throw}
}
function Start-LatencyIcmpOperation([string]$Ip,[ValidateRange(1,60000)][int]$TimeoutMs=1000){
    $address=$null
    if(-not[Net.IPAddress]::TryParse($Ip,[ref]$address)){throw 'ICMP probe requires a literal address'}
    Initialize-LatencyProbeType
    $owner=New-Object Net.NetworkInformation.Ping
    $started=[Diagnostics.Stopwatch]::GetTimestamp()/[double][Diagnostics.Stopwatch]::Frequency
    try{
        $task=$owner.SendPingAsync($address,$TimeoutMs)
        $completion=New-Object Zapret.Diagnostics.CompletionStamp -ArgumentList $task,$started,$TimeoutMs
        return [pscustomobject]@{Kind='icmp';Ip=$Ip;Port=0;Owner=$owner;Task=$task;Started=$started;Completion=$completion}
    }catch{$owner.Dispose();throw}
}
