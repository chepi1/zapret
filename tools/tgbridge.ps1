# zapret: встроенный мост Telegram (tools\tgbridge.cs). Запускается фоновой задачей пользователя "zapret notify"
# без окна и без прав администратора; слушает только 127.0.0.1. Порт и secret - из runtime\telegram.txt.
# -SelfTest: только проверка шифров (dev\tests), -LiveTest <dc>: запрос к дата-центру через уже запущенный мост.
# Совместимо с Windows PowerShell 5.1.
param([int]$Port = 0, [string]$Secret = '', [string]$Log = '', [switch]$SelfTest, [int]$LiveTest = 0)
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($SelfTest -or $LiveTest) {
    # Legacy C# is only a protocol test client now; its server is never used by the task.
    Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tgbridge.cs'))) -Language CSharp
    if ($SelfTest) { [ZapretTg.Bridge]::SelfTest(); exit 0 }
}

$cfg = Get-TgConfig
if (-not $Port) { $Port = $cfg.Port }
if (-not $Secret) { $Secret = $cfg.Secret }
if ($LiveTest) { [ZapretTg.Bridge]::LiveTest($Port, $Secret, $LiveTest); exit 0 }
Assert-TgWsBinary $Script:Root | Out-Null
$spec=Initialize-TgWsConfig -Port $Port -Secret $Secret
Initialize-TgWsRunner

# PID и время запуска - чтобы меню и задача узнавали именно этот процесс
$me = Get-Process -Id $PID
Write-TextNoBom (Get-PkgPath $Script:TgPidFile) ('{0}|{1}' -f $PID, $me.StartTime.Ticks)
$runner=$null
try{
    $runner=[ZapretTgWs.Runner]::Start($spec.Exe,(Split-Path -Parent $spec.Exe),$spec.AppData)
    Write-TextNoBom (Join-Path $Script:Runtime 'tgws-engine.txt') ('{0}|{1}|{2}|{3}' -f $PID,$me.StartTime.Ticks,(Get-TgWsRelease).Tag,$runner.JobName)
    $exitCode=$runner.Wait()
}finally{if($runner){$runner.Dispose()}}
exit $exitCode
