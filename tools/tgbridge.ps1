# zapret: встроенный мост Telegram (tools\tgbridge.cs). Запускается фоновой задачей пользователя "zapret notify"
# без окна и без прав администратора; слушает только 127.0.0.1. Порт и secret - из runtime\telegram.txt.
# -SelfTest: только проверка шифров (dev\tests), -LiveTest <dc>: запрос к дата-центру через уже запущенный мост.
# Совместимо с Windows PowerShell 5.1.
param([int]$Port = 0, [string]$Secret = '', [string]$Log = '', [switch]$SelfTest, [int]$LiveTest = 0)
. (Join-Path $PSScriptRoot 'lib.ps1')

# C# компилируется заново при каждом запуске (секунда-две): готовой программы в папке нет, подменять нечего
Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'tgbridge.cs'))) -Language CSharp

if ($SelfTest) { [ZapretTg.Bridge]::SelfTest(); exit 0 }

$cfg = Get-TgConfig
if (-not $Port) { $Port = $cfg.Port }
if (-not $Secret) { $Secret = $cfg.Secret }
if ($LiveTest) { [ZapretTg.Bridge]::LiveTest($Port, $Secret, $LiveTest); exit 0 }
if (-not $Log) { $Log = Join-Path $Script:Runtime 'tgbridge.log' }

# PID и время запуска - чтобы меню и задача узнавали именно этот процесс
$me = Get-Process -Id $PID
Write-TextNoBom (Get-PkgPath $Script:TgPidFile) ('{0}|{1}' -f $PID, $me.StartTime.Ticks)
[ZapretTg.Bridge]::Run($Port, $Secret, $Log)
