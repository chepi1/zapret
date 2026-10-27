# Архив для пользователей (Releases на GitHub): копия папки без dev\, .git и данных этого ПК.
# Результат - dist\zapret-v<версия>.zip, версия берётся из tools\lib.ps1.
param([string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'))
$root = Split-Path -Parent $PSScriptRoot
$ver = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $root 'tools\lib.ps1')), "Script:Version\s*=\s*'([^']+)'").Groups[1].Value
if (-not $ver) { Write-Host 'Не нашёл версию в tools\lib.ps1' -ForegroundColor Red; exit 1 }
$name = 'zapret'
$stage = Join-Path $env:TEMP ('zapret-build-' + [guid]::NewGuid().ToString('N'))
$dst = Join-Path $stage $name
# runtime - настройки и отчёты этого ПК; autohostlist.txt создаётся при первом запуске; .bak - старые списки
& robocopy.exe $root $dst /E /XD .git .github dev dist runtime /XF *.bak autohostlist.txt .gitignore .gitattributes /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host ('robocopy: ошибка ' + $LASTEXITCODE) -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory (Join-Path $dst 'runtime') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $dst 'runtime\.keep'), '')
New-Item -ItemType Directory $OutDir -Force | Out-Null
$zip = Join-Path $OutDir ('{0}-v{1}.zip' -f $name, $ver)
if (Test-Path $zip) { Remove-Item $zip -Force }
& (Join-Path $env:SystemRoot 'System32\tar.exe') -a -c -f $zip -C $stage $name
$files = @(& (Join-Path $env:SystemRoot 'System32\tar.exe') -tf $zip)
Remove-Item $stage -Recurse -Force
$bad = @($files | Where-Object { $_ -match '/runtime/.+' -and $_ -notmatch '/runtime/\.keep$' -or $_ -match '/dev/' })
if ($bad.Count) { Write-Host ('В архив попало лишнее: ' + ($bad -join ', ')) -ForegroundColor Red; exit 1 }
Write-Host ('Готово: {0} ({1} файлов, {2:N0} КБ)' -f $zip, $files.Count, ((Get-Item $zip).Length / 1KB)) -ForegroundColor Green
