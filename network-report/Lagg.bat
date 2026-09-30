@echo off
chcp 65001 >nul
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

if exist "%~dp0NetworkReport.exe" (
    "%~dp0NetworkReport.exe"
) else (
    echo NetworkReport.exe not found. Run build.bat first to compile it.
    pause
)
