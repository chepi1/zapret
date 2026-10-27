# статическая проверка скриптов пакета встроенным парсером PowerShell (без сторонних модулей).
#  1. вызовы функций, которых нет ни в пакете, ни среди команд Windows PowerShell;
#  2. переменные, которые читаются, но нигде в файле (и в lib.ps1) не присваиваются - кандидаты в опечатки;
#  3. функции lib.ps1, которые нигде не вызываются;
#  4. Read-Host вне функций меню.
param([string]$Pkg = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$files = @(Get-ChildItem (Join-Path $Pkg 'tools\*.ps1'))
$asts = @{}
foreach ($f in $files) { $asts[$f.Name] = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null) }
$defined = @{}
foreach ($n in $asts.Keys) {
    foreach ($fd in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $defined[$fd.Name] = $n }
}
$known = @{}
foreach ($c in (Get-Command -CommandType Cmdlet, Function, Alias, Application -ErrorAction SilentlyContinue)) { $known[$c.Name] = 1 }
$findings = 0
Write-Host '== 1. unknown commands'
foreach ($n in $asts.Keys) {
    foreach ($ca in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $ca.GetCommandName()
        if (-not $name -or $name -match '[\\/.]' -or $name.StartsWith('$')) { continue }
        if ($defined.ContainsKey($name) -or $known.ContainsKey($name)) { continue }
        # программы Windows (netsh, logman) Get-Command знает с .exe
        if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
        Write-Host ('  {0}:{1} {2}' -f $n, $ca.Extent.StartLineNumber, $name) -ForegroundColor Yellow
        $findings++
    }
}
Write-Host '== 2. variables read but never assigned (per file + lib)'
$auto = @('_', 'args', 'true', 'false', 'null', 'PSScriptRoot', 'matches', 'PID', 'Host', 'env', 'LASTEXITCODE', 'input', 'this', 'PSCmdlet', 'ErrorActionPreference', 'PSBoundParameters', 'PSItem', 'ExecutionContext', 'MyInvocation', 'Error', 'HOME', 'PROFILE', 'OFS', 'switch', 'foreach', 'sender', 'eventArgs', 'Event')
function Get-Assigned($Ast) {
    $s = @{}
    foreach ($a in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        foreach ($v in $a.Left.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { $s[$v.VariablePath.UserPath -replace '^(script|global|local):', ''] = 1 }
    }
    foreach ($p in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $s[$p.Name.VariablePath.UserPath] = 1 }
    foreach ($fe in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $s[$fe.Variable.VariablePath.UserPath] = 1 }
    foreach ($v in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $args[0].Parent -is [System.Management.Automation.Language.CommandExpressionAst] -and $args[0].Parent.Parent -is [System.Management.Automation.Language.CommandAst] }, $true)) { }
    # [ref]$x и -Variable/ -OutVariable
    foreach ($c in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ConvertExpressionAst] -and $args[0].Type.TypeName.Name -eq 'ref' }, $true)) {
        foreach ($v in $c.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { $s[$v.VariablePath.UserPath] = 1 }
    }
    return $s
}
$libAssigned = Get-Assigned $asts['lib.ps1']
foreach ($n in $asts.Keys) {
    $as = Get-Assigned $asts[$n]
    $seen = @{}
    foreach ($v in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath -replace '^(script|global|local|using):', ''
        if ($v.VariablePath.IsDriveQualified -or $auto -contains $name -or $as.ContainsKey($name) -or $libAssigned.ContainsKey($name) -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = 1
        Write-Host ('  {0}:{1} ${2}' -f $n, $v.Extent.StartLineNumber, $name) -ForegroundColor Yellow
        $findings++
    }
}
Write-Host '== 3. lib functions never called'
$called = @{}
foreach ($n in $asts.Keys) { foreach ($ca in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) { $cn = $ca.GetCommandName(); if ($cn) { $called[$cn] = 1 } } }
foreach ($fn in $defined.Keys | Sort-Object) { if (-not $called.ContainsKey($fn)) { Write-Host ('  {0} ({1})' -f $fn, $defined[$fn]) -ForegroundColor Yellow; $findings++ } }
# автоподбор и автонастройка работают и без человека (-NoPrompt, задача от SYSTEM): Read-Host там подвесил бы их
Write-Host '== 4. Read-Host outside menu.ps1 / provider-check.ps1 / Read-YesNo'
foreach ($n in $asts.Keys) {
    if (@('menu.ps1', 'provider-check.ps1', 'diag.ps1', 'lib.ps1') -contains $n) { continue }
    foreach ($ca in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'Read-Host' }, $true)) {
        Write-Host ('  {0}:{1} {2}' -f $n, $ca.Extent.StartLineNumber, $ca.Extent.Text.Substring(0, [math]::Min(80, $ca.Extent.Text.Length))) -ForegroundColor Yellow
        $findings++
    }
}
# Write-Color 'a' + $b Gray - в режиме команды "+" становится отдельным аргументом, нужны скобки
Write-Host '== 5. bare + among command arguments'
foreach ($n in $asts.Keys) {
    foreach ($ca in $asts[$n].FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if (@($ca.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq '+' -and $_.StringConstantType -eq 'BareWord' }).Count) {
            Write-Host ('  {0}:{1} {2}' -f $n, $ca.Extent.StartLineNumber, $ca.Extent.Text.Substring(0, [math]::Min(80, $ca.Extent.Text.Length))) -ForegroundColor Yellow
            $findings++
        }
    }
}
if ($findings) { Write-Host "$findings findings" -ForegroundColor Red; exit 1 } else { Write-Host 'all ok' -ForegroundColor Green }
