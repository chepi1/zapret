# Real release ZIP -> representative v1.9 personal state -> file transaction -> native preflight.
param([string]$Pkg=(Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
if(Test-Path (Join-Path $Pkg '.git')){throw 'Run on a package copy.'}
$ErrorActionPreference='Stop'
. (Join-Path $Pkg 'tools/lib.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$env:__COMPAT_LAYER='RunAsInvoker'
function Get-UpdateTrustSids{return @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)}
$fails=0
function Check($Name,$Ok){if($Ok){Write-Host ('ok '+$Name)}else{$script:fails++;Write-Host ('FAIL '+$Name)}}
$initialRuntime=$Script:Runtime
$work=[IO.Path]::GetFullPath((Join-Path $initialRuntime ('migrationtest-'+[guid]::NewGuid().ToString('N'))))
$src=Join-Path $work 'extracted/zapret';$dst=Join-Path $work 'installed 1.9'
$output=Join-Path $work 'build'
$oldCopy=${function:Copy-UpdateFile}
try{
    New-Item -ItemType Directory -Path $output -Force|Out-Null
    $ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Pkg 'dev/build.ps1') -OutDir $output *> (Join-Path $work 'build.log')
    if($LASTEXITCODE -ne 0){Get-Content (Join-Path $work 'build.log');throw 'Migration package build failed'}
    $zip=@(Get-ChildItem -LiteralPath $output -Filter 'zapret-v*.zip')[0]
    [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName,(Join-Path $work 'extracted'))
    foreach($folder in @('runtime','tools','lists','strategies')){New-Item -ItemType Directory -Path (Join-Path $dst $folder) -Force|Out-Null}
    $oldLib=Join-Path $dst 'tools/lib.ps1';Write-TextNoBom $oldLib "# representative legacy code`r`n`$Script:Version='1.9'`r`n"
    $oldHash=(Get-FileHash -LiteralPath $oldLib -Algorithm SHA256).Hash
    $personal=@{
        'runtime/settings.ini'="alt=31`r`nauto=off`r`ngame=udp`r`nipset=none`r`ngametcp=20000-26000`r`ngameudp=30000-30100`r`nautolist=off`r`ntelegram=off`r`nnotify=on`r`ngamepins=off`r`ncustom=keep`r`n"
        'runtime/test-rank.txt'="# legacy unscoped ranking`r`n12 100 10 10`r`n"
        'runtime/test-cover.txt'="# legacy coverage`r`n12 1 1`r`n"
        'runtime/personal-report.txt'='private report kept locally'
        'lists/autohostlist.txt'="personal-autohost.invalid`r`n"
        'strategies/alt999.txt'='# personal strategy retained'
    }
    foreach($name in @('list-general-user.txt','list-exclude-user.txt','ipset-user.txt','ipset-exclude-user.txt')){
        $personal['lists/'+$name]=[IO.File]::ReadAllText((Join-Path $src ('lists/'+$name)))+"`r`n# personal list marker`r`n"
    }
    foreach($name in $Script:FlowsealLists.Keys){$personal['lists/'+$name]=[IO.File]::ReadAllText((Join-Path $src ('lists/'+$name)))+"`r`n# locally fresher upstream list`r`n"}
    foreach($path in $personal.Keys){Write-TextNoBom (Join-Path $dst $path) $personal[$path]}
    [IO.File]::WriteAllText((Join-Path $dst 'runtime/settings.ini'),$personal['runtime/settings.ini'],(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $dst 'runtime/personal-report.txt'),$personal['runtime/personal-report.txt'],[Text.Encoding]::Unicode)
    $personalHashes=@{};foreach($path in $personal.Keys){$personalHashes[$path]=(Get-FileHash -LiteralPath (Join-Path $dst $path) -Algorithm SHA256).Hash}
    Write-TextNoBom (Join-Path $dst 'strategies/alt53.txt') '# explicitly retired bundled strategy'
    $plan=@(Get-UpdatePlan $src $dst);$remove=@(Get-RetiredStrategies $src $dst)
    # Force an existing code replacement before the later injected failure, not just untouched sentinels.
    $plan=@('tools\lib.ps1')+@($plan|Where-Object{$_ -ne 'tools\lib.ps1'})
    $migrate=@(Prepare-UpdateSettings $src $dst $remove)
    Check 'ordinary v1.9 settings require no destructive migration' ($migrate.Count -eq 0 -and $plan -contains 'tools\filtercheck.cs' -and $plan -notcontains 'runtime\settings.ini')
    Check 'only explicitly retired bundled strategies are removed' ($remove -contains 'strategies\alt53.txt' -and $remove -notcontains 'strategies\alt999.txt')
    $script:injected=$false;$script:sawReplacedCode=$false;$script:sawNewDependency=$false
    function Copy-UpdateFile($Source,$Target,$Hash){
        if(-not $script:injected -and $Target -ieq (Join-Path $dst 'tools/filtercheck.cs')){
            $script:injected=$true
            $script:sawReplacedCode=(Get-FileHash -LiteralPath $oldLib -Algorithm SHA256).Hash -cne $oldHash
            $script:sawNewDependency=Test-Path -LiteralPath (Join-Path $dst 'bin/winws2.exe')
            throw 'Injected migration write failure'
        }
        & $oldCopy $Source $Target $Hash
    }
    $backup=Join-Path $dst ('runtime/update/'+[guid]::NewGuid().ToString('N')+'/backup')
    $ok=Install-UpdateFiles $src $dst $backup $plan $remove
    Check 'failed package migration rolls back already-replaced code and installed dependency' (-not $ok -and $script:injected -and $script:sawReplacedCode -and $script:sawNewDependency -and (Get-FileHash -LiteralPath $oldLib -Algorithm SHA256).Hash -ceq $oldHash -and -not (Test-Path -LiteralPath (Join-Path $dst 'bin/winws2.exe')))
    Check 'failed migration preserves retired file and closes journal' ((Test-Path -LiteralPath (Join-Path $dst 'strategies/alt53.txt')) -and -not (Test-PendingUpdate $dst))
    Check 'failed migration preserves every personal file byte for byte' (-not @($personalHashes.Keys|Where-Object{(Get-FileHash -LiteralPath (Join-Path $dst $_) -Algorithm SHA256).Hash -cne $personalHashes[$_]}).Count)
    Set-Item -LiteralPath 'Function:\Copy-UpdateFile' -Value $oldCopy
    $backup=Join-Path $dst ('runtime/update/'+[guid]::NewGuid().ToString('N')+'/backup')
    $script:beforeApply=0
    $ok=Install-UpdateFiles $src $dst $backup $plan $remove -WasRunning:$true -BeforeApply {$script:beforeApply++}
    Check 'complete release package installs through the file transaction' ($ok -and $script:beforeApply -eq 1 -and -not (Test-PendingUpdate $dst))
    foreach($path in $personal.Keys){Check ('preserved bytes '+$path) ((Get-FileHash -LiteralPath (Join-Path $dst $path) -Algorithm SHA256).Hash -ceq $personalHashes[$path])}
    Check 'restart intent is retained without starting any live process' ([IO.File]::ReadAllText((Join-Path $dst 'runtime/update-restart.txt')) -eq 'start')
    Check 'retired bundled file is removed after successful migration' (-not (Test-Path -LiteralPath (Join-Path $dst 'strategies/alt53.txt')))
    $missing=@(Get-ChildItem -LiteralPath $src -Recurse -File|Where-Object{
        $relative=$_.FullName.Substring($src.Length).TrimStart('\')
        $relative -notlike 'runtime\*' -and -not (Test-Path -LiteralPath (Join-Path $dst $relative))
    })
    Check 'every distributed runtime dependency is installed' ($missing.Count -eq 0)
    . (Join-Path $dst 'tools/lib.ps1')
    $settings=Get-Settings
    Check 'installed code loads selected strategy and v1.9 options' ($settings.alt -eq '31' -and $settings.auto -eq 'off' -and $settings.game -eq 'udp' -and $settings.ipset -eq 'none' -and $settings.gameudp -eq '30000-30100' -and $settings.custom -eq 'keep')
    Check 'legacy unscoped scores are not accepted as new network measurements' ($null -eq (Get-TestRank))
    Check 'installed official engine files retain their expected hashes' (@(Test-PackageIntegrity).Count -eq 0)
    Update-RuntimeLists|Out-Null
    $check=Test-ConfigDry $settings
    Check 'installed package passes actual CLI and WinDivert filter preflight' $check.Ok
    if(-not $check.Ok){Write-Host $check.Output}
}finally{
    Set-Item -LiteralPath 'Function:\Copy-UpdateFile' -Value $oldCopy
    if([IO.Path]::GetDirectoryName($work) -ne [IO.Path]::GetFullPath($initialRuntime).TrimEnd('\')){throw 'Unsafe migration test directory'}
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
if($fails){exit 1}
