# Защита от подмены и приватность отчётов - на копии папки:
#  - сверка SHA-256 файлов zapret2 замечает изменённый и пропавший файл;
#  - Protect-Package закрывает папки с кодом на запись (без прав администратора проверяется всё, кроме смены владельца);
#  - копия для разработки (есть dev\) не закрывается;
#  - Protect-ReportText скрывает имя пользователя Windows и свой IP;
#  - Get-IpInfo не подставляет в URL ничего, кроме IP-адресов.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$fails = 0
function Check($Name, $Cond) { if ($Cond) { Write-Host ('ok   ' + $Name) -ForegroundColor Green } else { Write-Host ('FAIL ' + $Name) -ForegroundColor Red; $script:fails++ } }
$stage = Join-Path $env:TEMP ('nba-sec-' + [guid]::NewGuid().ToString('N'))
& robocopy.exe $Pkg (Join-Path $stage 'pkg') /E /XD .git dist dev runtime /NFL /NDL /NJH /NJS /NP | Out-Null
. (Join-Path $stage 'pkg\tools\lib.ps1')

Check 'integrity ok on clean copy' (@(Test-PackageIntegrity).Count -eq 0)
$lua = Join-Path $Script:Root 'lua\zapret-auto.lua'
[System.IO.File]::AppendAllText($lua, "`n-- tampered`n")
$bad = @(Test-PackageIntegrity)
Check ('tampered file detected: ' + ($bad -join '; ')) ($bad.Count -eq 1 -and $bad[0] -like 'lua\zapret-auto.lua*')
Remove-Item (Join-Path $Script:Root 'bin\cygwin1.dll')
Check 'missing file detected' (@(Test-PackageIntegrity | Where-Object { $_ -like '*cygwin1.dll - нет файла' }).Count -eq 1)

# закрытие на запись: на копии без dev\. Смена владельца без прав администратора не пройдёт - её не проверяем
$tools = Join-Path $Script:Root 'tools'
Protect-Package
$acl = Get-Acl $tools
$writers = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::WriteData) -and
    @('S-1-5-18', 'S-1-5-32-544') -notcontains $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
Check 'tools: inheritance off' ($acl.AreAccessRulesProtected)
Check ('tools: only SYSTEM and Administrators can write (' + $writers.Count + ' others)') ($writers.Count -eq 0)
$canRead = $true
try { [System.IO.File]::ReadAllText((Join-Path $tools 'lib.ps1')) | Out-Null } catch { $canRead = $false }
Check 'tools: still readable' $canRead
$isAdmin = Test-Admin
$wrote = $true
try { [System.IO.File]::AppendAllText((Join-Path $tools 'menu.ps1'), '#') } catch { $wrote = $false }
if (-not $isAdmin) { Check 'tools: write blocked without admin rights' (-not $wrote) }
Unprotect-Package
Check 'unprotect: inheritance back' (-not (Get-Acl $tools).AreAccessRulesProtected)

New-Item -ItemType Directory (Join-Path $Script:Root 'dev') | Out-Null
Protect-Package
Check 'dev checkout is not protected' (-not (Get-Acl $tools).AreAccessRulesProtected)

$t = "Папка: $env:USERPROFILE\Downloads\pkg`r`nC:\Users\$env:USERNAME\Desktop`r`nIP 203.0.113.57 и снова 203.0.113.57"
$m = Protect-ReportText $t '203.0.113.57'
Check 'report hides profile path' ($m -notmatch [regex]::Escape($env:USERPROFILE) -and $m -match '%USERPROFILE%')
Check 'report hides user name' ($m -notmatch ('\\Users\\' + [regex]::Escape($env:USERNAME) + '\\'))
Check 'report masks own IP' ($m -notmatch '203\.0\.113\.57' -and $m -match '203\.0\.113\.x')
Check 'ip lookup rejects non-IP input' (@((Get-IpInfo @('a;b', '"x"', '../etc') 2).Keys).Count -eq 0)

& icacls.exe $stage /reset /T /C /Q 2>&1 | Out-Null
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
