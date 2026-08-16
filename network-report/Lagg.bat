net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoExit -ExecutionPolicy Bypass -File "%~dp0Lagg.ps1"
) else (
    powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0Lagg.ps1"
)