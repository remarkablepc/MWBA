@echo off
setlocal enabledelayedexpansion
title MWBA - Make Windows Boot Again
color 0A

:: ============================================================
:: 1. AUTO-ELEVATE TO ADMINISTRATOR
:: ============================================================
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ============================================================
    echo  [!] Administrator privileges required. Elevating...
    echo ============================================================
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/k \"\"%~f0\"\" %*' -Verb RunAs"
    exit /b
)

:: ============================================================
:: 2. INITIALIZE WORKING DIRECTORY & EXECUTE MWBA
:: ============================================================
cd /d "%~dp0"

set TARGET_PWSH=powershell
if exist "%~dp0PowerShell\pwsh.exe" set TARGET_PWSH="%~dp0PowerShell\pwsh.exe"
if exist "%~dp0pwsh.exe" set TARGET_PWSH="%~dp0pwsh.exe"

%TARGET_PWSH% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MWBA.ps1" %*

echo.
echo ============================================================
echo  MWBA execution finished.
echo  Press any key to exit.
echo ============================================================
pause >nul
