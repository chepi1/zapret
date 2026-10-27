@echo off
rem zapret - launcher. Requests admin rights and opens the menu.
cd /d "%~dp0"

if /i "%~1"=="elevated" goto run
net session >nul 2>&1
if %errorlevel% equ 0 goto run

set "ZAPRET_BAT=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ZAPRET_BAT -ArgumentList 'elevated' -Verb RunAs"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\menu.ps1"
