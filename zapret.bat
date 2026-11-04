@echo off
rem zapret - launcher. Requests admin rights and opens the menu.
cd /d "%~dp0"
set "ZAPRET_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ZAPRET_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if /i "%~1"=="elevated" goto run
net session >nul 2>&1
if %errorlevel% equ 0 goto run

set "ZAPRET_BAT=%~f0"
"%ZAPRET_PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ZAPRET_BAT -ArgumentList 'elevated' -Verb RunAs"
exit /b

:run
"%ZAPRET_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\recovery.ps1" -Recover
if errorlevel 1 (
    pause
    exit /b 1
)
"%ZAPRET_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\menu.ps1"
