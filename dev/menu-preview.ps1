# Render the actual menu functions with sample data; menu startup hooks are never executed.
param([string]$OutDir=(Join-Path (Split-Path -Parent $PSScriptRoot) 'dist/ui-preview'),[ValidateRange(24,200)][int]$Width=80)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools/lib.ps1')
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'tools/menu.ps1'),[ref]$null,[ref]$null)
foreach($f in $ast.FindAll({$args[0] -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:previewRows=New-Object 'Collections.Generic.List[object]'
$script:previewSegments=New-Object 'Collections.Generic.List[object]'
function Write-Host {
    param($Object,[string]$ForegroundColor='Gray',[switch]$NoNewline)
    $script:previewSegments.Add([pscustomobject]@{Text=[string]$Object;Color=$ForegroundColor})
    if(-not $NoNewline){$script:previewRows.Add($script:previewSegments.ToArray());$script:previewSegments.Clear()}
}
function Write-Rgb {
    param($Text,[int[]]$Rgb,$Fallback,[switch]$NoNewline)
    Write-Host $Text -ForegroundColor ('#{0:X2}{1:X2}{2:X2}' -f $Rgb[0],$Rgb[1],$Rgb[2]) -NoNewline:$NoNewline
}
function Clear-Host{$script:previewRows.Clear();$script:previewSegments.Clear()}
function Get-ConsoleWidth{return $Width}
function Read-Host($Prompt){Write-Host ($Prompt+': ');return ''}
function Get-Settings{return @{alt='12';auto='on';telegram='on';game='all';gametcp=$Script:GamePortsPreset.tcp;gameudp=$Script:GamePortsPreset.udp;ipset='loaded';autolist='on';notify='on'}}
function Get-Strategy{return [pscustomobject]@{Name='ALT12'}}
function Get-OurProcesses{return [pscustomobject]@{StartTime=(Get-Date).AddMinutes(-42)}}
function Get-OurService{return [pscustomobject]@{Status='Running';StartType='Automatic'}}
function Get-ServiceHealthSummary{return [pscustomobject]@{State='Good';Text='HTTPS: последняя проверка 14:32, ответили 4/4'}}
function Get-TgBridgeState{return 'Open'}
function Test-PackageIntegrity{return @()}
function Test-AutotuneRunning{return $false}
function Get-ForeignBypass{return @()}
function Get-GameBoosters{return @()}
function Get-SystemConflicts{return @()}
function Get-ProxyStuckApps{return @()}
function Get-HostsStatus{return @{}}
function Get-HostsYoutube{return @()}
function Get-ZapretUpdate{return $null}
function Get-ListsAgeDays{return 0}
function Get-UpstreamNews{return @('zapret2 v1.0.7 (в сборке v1.0.6)')}
function Get-AutotuneTask{return $null}
function Get-AutotuneText{return 'выкл'}
function Get-AutolistDomains{return @('sample.invalid','another.invalid')}

Add-Type -AssemblyName System.Drawing
[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutDir))|Out-Null
$palette=@{Gray='#CCCCCC';DarkGray='#767676';White='#F2F2F2';Cyan='#61D6D6';Green='#16C60C';Yellow='#F9F1A5';Red='#E74856'}
$font=[Drawing.Font]::new('Consolas',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$captionFont=[Drawing.Font]::new('Segoe UI',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$format=[Drawing.StringFormat]::GenericTypographic.Clone()
$format.FormatFlags=$format.FormatFlags -bor [Drawing.StringFormatFlags]::MeasureTrailingSpaces
try{
    foreach($screen in @('main','settings','tools','notifications')){
        switch($screen){
            'main'{Show-Header;Show-Main;Write-Host 'Выбор: '}
            'settings'{Show-SettingsMenu}
            'tools'{Show-ToolsMenu}
            'notifications'{Show-NotificationsMenu}
        }
        $probe=[Drawing.Bitmap]::new(1,1);$measure=[Drawing.Graphics]::FromImage($probe)
        try{$cell=$measure.MeasureString('M',$font,100,$format).Width}finally{$measure.Dispose();$probe.Dispose()}
        $max=0;foreach($row in $script:previewRows){$count=0;foreach($segment in $row){$count+=$segment.Text.Length};$max=[math]::Max($max,$count)}
        $bitmap=[Drawing.Bitmap]::new([int][math]::Ceiling($max*$cell+48),[int]($script:previewRows.Count*22+96))
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{
            $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#0C0C0C'))
            $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $captionBrush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#A0A0A0'))
            try{$graphics.DrawString('Предпросмотр · демонстрационные данные',$captionFont,$captionBrush,[single]24,[single]18)}finally{$captionBrush.Dispose()}
            $y=58
            foreach($row in $script:previewRows){
                $x=[single]24
                foreach($segment in $row){
                    $color=if($palette.ContainsKey($segment.Color)){$palette[$segment.Color]}elseif($segment.Color -match '^#[A-Fa-f0-9]{6}$'){$segment.Color}else{$palette.Gray}
                    $brush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($color))
                    try{$graphics.DrawString($segment.Text,$font,$brush,$x,[single]$y,$format)}finally{$brush.Dispose()}
                    $x+=[single]($segment.Text.Length*$cell)
                }
                $y+=22
            }
            $path=Join-Path ([IO.Path]::GetFullPath($OutDir)) ($screen+'.png')
            $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
            [Console]::WriteLine($path)
        }finally{$graphics.Dispose();$bitmap.Dispose()}
    }
}finally{$format.Dispose();$font.Dispose();$captionFont.Dispose()}
