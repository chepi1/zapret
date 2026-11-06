param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
$Script:Runtime=Join-Path $Script:Runtime ('menutest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Script:Runtime)
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Pkg 'tools/menu.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$fails=0
function Check($Name,$Ok){if($Ok){[Console]::WriteLine('ok '+$Name)}else{$script:fails++;[Console]::WriteLine('FAIL '+$Name)}}
$exists=$null -ne (Get-Command Get-MenuStatus -ErrorAction SilentlyContinue)
Check 'menu has an explicit display state' $exists
if(-not $exists){exit 1}
$proc=[pscustomobject]@{StartTime=(Get-Date).AddMinutes(-8)}
$running=Get-MenuStatus @($proc) ([pscustomobject]@{Status='Running'}) ([pscustomobject]@{State='Healthy';Text='healthy'})
Check 'confirmed process displays a working bypass' ($running.State -eq 'Running' -and $running.CanRestart -and $running.Color -eq 'Green')
$partial=Get-MenuStatus @($proc) $null ([pscustomobject]@{State='Partial';Text='partial'})
Check 'partial health remains a warning instead of a green success' ($partial.State -eq 'Partial' -and $partial.Color -eq 'Yellow')
$serviceOnly=Get-MenuStatus @() ([pscustomobject]@{Status='Running'}) $null
Check 'running service with unreadable process is unconfirmed rather than stopped' ($serviceOnly.State -eq 'Unconfirmed' -and $serviceOnly.CanRestart -and $serviceOnly.Color -eq 'Yellow')
$stopped=Get-MenuStatus @() $null $null
Check 'absence of process and service offers a start' ($stopped.State -eq 'Stopped' -and -not $stopped.CanRestart)
$starting=Get-MenuStatus @($proc) ([pscustomobject]@{Status='StartPending'}) $null
Check 'service transition takes precedence over an already-created process' ($starting.State -eq 'Starting' -and $starting.CanRestart -and $starting.Color -ne 'Green')
$startupApi=$null -ne (Get-Command Get-MenuStartupText -ErrorAction SilentlyContinue)
Check 'autostart display distinguishes installed and automatic services' $startupApi
if($startupApi){
    Check 'manual service is not reported as Windows autostart' ((Get-MenuStartupText ([pscustomobject]@{Status='Running';StartType='Manual'})) -eq 'вручную')
    Check 'automatic service is reported as Windows autostart' ((Get-MenuStartupText ([pscustomobject]@{Status='Running';StartType='Automatic'})) -eq 'с Windows')
}

# Capture actual console fragments without changing the desktop or running startup hooks.
$script:render='';$script:consoleWidth=80;$script:fixtureRunning=$true;$script:noticeMode=$true
function Get-ConsoleWidth{return $script:consoleWidth}
function Clear-Host{}
function Write-Host {param($Object,$ForegroundColor,[switch]$NoNewline);$script:render+=[string]$Object;if(-not $NoNewline){$script:render+="`n"}}
function Write-Rgb {param($Text,$Rgb,$Fallback,[switch]$NoNewline);Write-Host $Text -NoNewline:$NoNewline}
function Get-Settings{return @{alt='12';auto='on';telegram='on'}}
function Get-Strategy{return [pscustomobject]@{Name='ALT12'}}
function Get-OurProcesses{if($script:fixtureRunning){return $proc}}
function Get-OurService{return [pscustomobject]@{Status='Running'}}
function Get-ServiceHealthSummary{return [pscustomobject]@{State='Healthy';Text='healthy'}}
function Get-TgBridgeState{return 'Open'}
function Test-PackageIntegrity{return @()}
function Test-AutotuneRunning{return $false}
function Get-ForeignBypass{return @()}
function Get-GameBoosters{return @()}
function Get-SystemConflicts{return @()}
function Get-ProxyStuckApps{return @()}
function Get-HostsStatus{return @{}}
function Get-HostsYoutube{return @()}
function Get-ZapretUpdate{if($script:noticeMode){return 'v9.9'}}
function Get-ListsAgeDays{return 0}
function Get-UpstreamNews{if($script:noticeMode){return @('zapret2 v1.0.7 (в сборке v1.0.6)')}}
function Read-Host{return ''}
Show-Header;Show-Main
$main=$script:render
Check 'main keeps keys1..7 and exposes notifications on8' (@(1..8|Where-Object{$main -notmatch ('(?m)\b'+$_+'\s+\S')}).Count -eq 0)
Check 'main offers restart when a process or running service exists' ($main -match 'Перезапустить обход')
$script:render='';Show-NotificationsMenu
Check 'all self and upstream update details remain accessible' ($script:render -match 'новая версия zapret v9\.9' -and $script:render -match 'zapret2 v1\.0\.7' -and $script:render -match 'Настройки')
$script:render='';Show-Header;Show-Main
Check 'viewed notices disappear from the main header and unread count' ($Script:MenuView.Notices.Count -eq 2 -and $Script:MenuView.UnreadNotices.Count -eq 0 -and $script:render -notmatch 'Новых уведомлений:|Уведомления \([0-9]+\)')
$script:render='';Show-NotificationsMenu
Check 'reopening notifications reads persisted acknowledgements without redisplaying old notices' ($script:render -match 'Сейчас нет уведомлений' -and $script:render -notmatch 'новая версия zapret v9\.9|zapret2 v1\.0\.7')
$script:consoleWidth=24;$script:render=''
function Test-PackageIntegrity{return @('lua/zapret-antidpi.lua - изменён')}
Show-NotificationsMenu
$content=$script:render -replace '[\s│╭╮╰╯─├┤]',''
Check 'narrow notifications preserve the exact changed-file name across wrapped rows' ($content.Contains('lua/zapret-antidpi.lua'))
function Test-PackageIntegrity{return @()}
$script:consoleWidth=80
$script:noticeMode=$false;$script:fixtureRunning=$false
function Get-OurService{return $null}
$script:render='';Show-Header;Show-Main
Check 'stopped menu offers start without claiming an active bypass' ($script:render -match 'Запустить обход' -and $script:render -match 'Обход остановлен')
foreach($width in @(24,40,80)){
    $script:consoleWidth=$width;$script:render=''
    Write-BoxTop (' '+('оченьдлинныйзаголовок'*8)+' ')
    Write-BoxRow ('  '+('длинноеслово'*40))
    Write-BoxRow ('  '+(('обычный текст '*20).Trim()))
    Write-BoxBottom
    $rows=@($script:render.TrimEnd("`n") -split "`n")
    $expected=(Get-BoxWidth)+2
    Check ('frame and long words stay rectangular at console width '+$width) (@($rows|Where-Object{$_.Length -ne $expected}).Count -eq 0 -and $expected -le $width)
}
$dispatch=$ast.Find({$args[0] -is [Management.Automation.Language.SwitchStatementAst] -and $args[0].Extent.Text.Contains("'7' { Show-ToolsMenu }")},$true)
$originalNotices=${function:Show-NotificationsMenu};$script:openedNotices=0;$Script:LetterKeys=@{}
function Show-NotificationsMenu{$script:openedNotices++}
$c='8';& ([scriptblock]::Create($dispatch.Extent.Text))
${function:Show-NotificationsMenu}=$originalNotices
Check 'key8 dispatches directly to the read-only notifications page' ($script:openedNotices -eq 1)
$originalRuntime=$Script:Runtime
$Script:Runtime=Join-Path $originalRuntime 'menu-notice-fixture'
[void][IO.Directory]::CreateDirectory($Script:Runtime)
$notices=@([pscustomobject]@{Title='First';Text='Version 1'},[pscustomobject]@{Title='Second';Text='Version 1'})
Check 'two unseen notices are returned before reading' (@(Get-UnreadMenuNotices $notices).Count -eq 2)
Check 'marking notices read emits no menu content' (@(Get-UnreadMenuNotices $notices -MarkRead).Count -eq 0)
Check 'PowerShell 5.1 deserializes multiple read keys without nesting them' (@(Get-UnreadMenuNotices $notices).Count -eq 0)
$notices[0].Text='Version 2'
$unread=@(Get-UnreadMenuNotices $notices)
Check 'changed notice content becomes unread again' ($unread.Count -eq 1 -and $unread[0].Title -eq 'First')
Get-UnreadMenuNotices $notices -MarkRead
Get-UnreadMenuNotices @($notices[0]) | Out-Null
$unread=@(Get-UnreadMenuNotices $notices)
Check 'a resolved notice is new when the condition recurs' ($unread.Count -eq 1 -and $unread[0].Title -eq 'Second')
Write-TextNoBom (Join-Path $Script:Runtime 'menu-notices-read.json') '{broken'
Check 'invalid acknowledgement data keeps notices visible' (@(Get-UnreadMenuNotices $notices).Count -eq 2)
$Script:Runtime=$originalRuntime
Remove-Item -LiteralPath Function:\Write-Host
if($fails){exit 1}
