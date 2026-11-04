param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$sourcePath=Join-Path $Pkg 'tools/test.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$null,[ref]$null)
foreach($fn in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($fn.Extent.Text))}
if(-not(Get-Command Get-RetryProbePolicy -ErrorAction SilentlyContinue)){throw 'FAIL bounded retry policy missing'}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{Write-Host ('FAIL '+$Name);$script:fails++}}
foreach($parallelism in @(1,2,4,16,64)){
    $policy=Get-RetryProbePolicy $parallelism
    Check ('retry width respects both user parallelism and cap4: '+$parallelism) ($policy.Width -eq [math]::Min(4,$parallelism) -and $policy.DelayMs -eq 250)
}
$narrow=Get-TestInstanceLifetimeMs 100 16 5 4
$wide=Get-TestInstanceLifetimeMs 100 16 5 16
Check 'narrower retry waves receive a larger native guard budget' ($narrow -gt $wide -and $narrow -ge 222250)
Check 'A/B warmup and main are budgeted separately' ((Get-TestInstanceLifetimeMs 100 4 5 4 2) -gt (Get-TestInstanceLifetimeMs 100 4 5 4 1))
Check 'small runs retain a conservative two-minute native minimum' ((Get-TestInstanceLifetimeMs 1 16 5) -eq 120000)
$invalid=$false;try{Get-TestInstanceLifetimeMs 1000 1 60 | Out-Null}catch{$invalid=$true}
Check 'over30min stage is rejected instead of silently expiring' $invalid
$before=[Diagnostics.Stopwatch]::GetTimestamp();$deadline=Get-TestProbeDeadline 120000
$remaining=1000.0*($deadline-$before)/[Diagnostics.Stopwatch]::Frequency
Check 'parent deadline precedes native guard by5s' ($remaining -ge 115000 -and $remaining -lt 116000)
$validationMarker=Join-Path $Script:Runtime 'retry-validation-reached.txt'
$validationScript=Join-Path $Script:Runtime 'retry-validation.ps1'
$guarded=[IO.File]::ReadAllText($sourcePath).Replace(". (Join-Path `$PSScriptRoot 'lib.ps1')",("[IO.File]::WriteAllText('"+$validationMarker.Replace("'","''")+"','reached');throw 'Import reached'"))
[IO.File]::WriteAllText($validationScript,$guarded,(New-Object Text.UTF8Encoding($true)))
foreach($args0 in @(@('-Parallel','0'),@('-Parallel','65'),@('-TimeoutSec','0'),@('-TimeoutSec','61'))){
    Remove-Item -LiteralPath $validationMarker -ErrorAction SilentlyContinue
    $command=ConvertTo-WinCmdLine (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$validationScript)+$args0)
    $child=Invoke-Native (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') $command $Pkg 10
    Check ('invalid parameters fail before import/control: '+($args0 -join ' ')) ($child.ExitCode -ne 0 -and -not(Test-Path $validationMarker))
}
$loop=$ast.Find({param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.StartsWith('foreach ($roundPlan in $measurementOrder.Rounds)')},$true)
$Parallel=16;$TimeoutSec=5;$Rounds=1;$RetryMax=16;$HarmSlowMs=500;$HopelessRuns=3;$GroupNames=[ordered]@{DPI='DPI';Clean='Clean'}
$targets=@([pscustomobject]@{Group='Clean';Name='clean';Url='https://clean.example/';Post=$false},[pscustomobject]@{Group='DPI';Name='flaky';Url='https://flaky.example/';Post=$false})
$measurementOrder=New-TestMeasurementOrder @([pscustomobject]@{Id='12';Name='fixture'}) 1 42
$settings=@{};$testLifetimeMs=120000;$postFile='';$scoreFingerprints=@{'12'=('C'*64)}
$script:failureMode='';$script:probeCalls=@();$script:sleeps=@();$script:fakeProcess=$null
function Start-TestInstance {$script:fakeProcess=[pscustomobject]@{Id=123456;HasExited=($script:failureMode -eq 'pre')};$script:fakeProcess|Add-Member ScriptMethod WaitForExit {return $this.HasExited};return $script:fakeProcess}
function Stop-Process {param($Id,[switch]$Force,$ErrorAction);if($Id -ne 123456){throw 'Fixture refuses real process'};$script:fakeProcess.HasExited=$true}
function Start-Sleep {param($Milliseconds,$Seconds);$script:sleeps+=,$Milliseconds;if($script:failureMode -eq 'pause' -and $Milliseconds -eq 250){$script:fakeProcess.HasExited=$true}}
function Get-IpBlocked {return @()}
function Format-Summary {return 'fixture'}
function Invoke-CurlBatch($Targets,$PostFile,$Width=0,[long]$DeadlineTicks=0,$RequiredProcess=$null){
    $attempt=1+@($script:probeCalls|Where-Object{$_.Strategy -eq $metadata.StrategyId}).Count
    $script:probeCalls+=,[pscustomobject]@{Strategy=$metadata.StrategyId;Width=$Width;Deadline=$DeadlineTicks;Required=($null -ne $RequiredProcess);Attempt=$attempt}
    foreach($target in $Targets){$state=if($metadata.StrategyId -ne '0' -and $target.Group -eq 'DPI' -and $attempt -eq 1){'FAIL'}else{'OK'};[pscustomobject]@{Group=$target.Group;Name=$target.Name;Url=$target.Url;State=$state;Code=$(if($state -eq 'OK'){'200'}else{'000'});Exit=0;Up=0;Down=1;ConnMs=50;TlsMs=100;Tries=1;Flaky=$false}}
    if($RequiredProcess -and (($script:failureMode -eq 'main' -and $attempt -eq 1) -or ($script:failureMode -eq 'retry' -and $attempt -eq 2))){$RequiredProcess.HasExited=$true}
}
foreach($mode in @('','pre','main','retry','pause')){
    $script:failureMode=$mode;$script:probeCalls=@();$script:sleeps=@();$script:fakeProcess=$null
    $table=@{};$ipSkip=@{};$failRuns=@{};$everOk=@{};$p=$null
    $journalFile=Join-Path $Script:Runtime ('retry-'+[guid]::NewGuid().ToString('N')+'.jsonl')
    $metadata=@{RunId='fixture';Seed=42;Sequence=0;Round=0;Stage='baseline';StrategyId='0';StrategyHash='';NetworkKey=('A'*64);InputsHash=('B'*64)}
    $failure=$null
    try{. ([scriptblock]::Create($loop.Extent.Text))}catch{$failure=$_}finally{if($p -and -not $p.HasExited){$p.HasExited=$true}}
    if(-not(Test-Path $journalFile)){if($failure){Write-Host $failure;Write-Host $failure.ScriptStackTrace};throw 'Fixture failed before any requests were journaled'}
    $events=@([IO.File]::ReadAllLines($journalFile)|ForEach-Object{$_|ConvertFrom-Json})
    if(-not $mode){
        $calls=@($script:probeCalls|Where-Object{$_.Strategy -eq '12'})
        Check 'real scan uses main16 retry4 and a250ms pause' ($null -eq $failure -and $calls.Count -eq 2 -and $calls[0].Width -eq 16 -and $calls[1].Width -eq 4 -and $script:sleeps -contains 250)
        Check 'normal strategy requests share a finite deadline and required engine' ($calls[0].Deadline -gt 0 -and $calls[0].Deadline -eq $calls[1].Deadline -and @($calls|Where-Object{-not $_.Required}).Count -eq 0)
        $raw=@($events|Where-Object{$_.StrategyId -eq '12' -and $_.Name -eq 'flaky'})
        Check 'first failure remains raw and successful retry remains half-credit flaky' ($raw.Count -eq 2 -and $raw[0].State -eq 'FAIL' -and $raw[1].State -eq 'OK' -and @($table['12']|Where-Object{$_.Name -eq 'flaky' -and $_.Flaky -and $_.Tries -eq 2}).Count -eq 1)
    }else{
        Check ($mode+' engine interruption cannot enter score table') ($failure -and $failure.Exception.Data['Kind'] -eq 'EngineUnavailable' -and -not $table.ContainsKey('12'))
        if($mode -eq 'pre'){Check 'engine gone before first probe cannot launch requests' (@($script:probeCalls|Where-Object{$_.Strategy -eq '12'}).Count -eq 0)}
        elseif($mode -eq 'pause'){Check 'death during quiet window prevents the retry request' (@($script:probeCalls|Where-Object{$_.Strategy -eq '12'}).Count -eq 1)}
        else{Check ($mode+' interruption retains aborted raw evidence') (@($events|Where-Object{$_.StrategyId -eq '12' -and $_.Stage -like '*-aborted'}).Count -gt 0)}
    }
}
$callsBefore=$script:probeCalls.Count;$failure=$null
$shortDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+[long]([Diagnostics.Stopwatch]::Frequency*0.05)
try{Invoke-TestProbeBatch $targets '' 4 $shortDeadline $null (Join-Path $Script:Runtime 'retry-too-late.jsonl') $metadata 2 250 | Out-Null}catch{$failure=$_}
Check 'retry pause that cannot fit deadline starts no request' ($failure -and $failure.Exception.Data['Kind'] -eq 'RunDeadline' -and $script:probeCalls.Count -eq $callsBefore)
if($fails){exit 1}
