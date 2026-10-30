@echo off
setlocal enabledelayedexpansion
title MWBA - Make Windows Boot Again (Technician Edition)
color 0A

:: ============================================================
:: 1. AUTO-ELEVATE TO ADMINISTRATOR (Skip if already WinPE/SYSTEM)
:: ============================================================
if /i "%SystemDrive%"=="X:" goto :SKIP_ELEVATION
if /i "%USERNAME%"=="SYSTEM" goto :SKIP_ELEVATION

net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ============================================================
    echo  [!] Administrator privileges required. Elevating...
    echo ============================================================
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList '/k \"\"%~f0\"\" %*' -Verb RunAs" 2>nul
    if %ERRORLEVEL% EQU 0 exit /b
)

:SKIP_ELEVATION
cd /d "%~dp0"

:: ============================================================
:: 2. BULLETPROOF POWERSHELL LOCATOR
:: (Portable USB pwsh, Strelec WinPE, Target Client OS, WinPE RAMDisk)
:: ============================================================
set "TARGET_PWSH="

:: 2a. Check Portable PowerShell Core (pwsh.exe) on USB drive
for %%p in (
    "%~dp0..\..\bin\pwsh\pwsh.exe"
    "%~dp0..\bin\pwsh\pwsh.exe"
    "%~dp0bin\pwsh\pwsh.exe"
    "%~dp0PowerShell\pwsh.exe"
    "%~dp0pwsh.exe"
    "%~d0\WINTools\bin\pwsh\pwsh.exe"
    "%~d0\bin\pwsh\pwsh.exe"
) do (
    if not defined TARGET_PWSH if exist "%%~fp" (
        set "TARGET_PWSH=%%~fp"
        echo [OK] Located Portable PowerShell: %%~fp
    )
)

:: 2b. Check Sergei Strelec Tools Drives (Y:, B:, S:)
if not defined TARGET_PWSH (
    for %%d in (Y B S) do (
        if not defined TARGET_PWSH if exist "%%d:\Programs\PowerShell\pwsh.exe" (
            set "TARGET_PWSH=%%d:\Programs\PowerShell\pwsh.exe"
            echo [OK] Located Strelec PowerShell: %%d:\Programs\PowerShell\pwsh.exe
        )
        if not defined TARGET_PWSH if exist "%%d:\Programs\PowerShell\powershell.exe" (
            set "TARGET_PWSH=%%d:\Programs\PowerShell\powershell.exe"
            echo [OK] Located Strelec PowerShell: %%d:\Programs\PowerShell\powershell.exe
        )
    )
)

:: 2c. Check Active PATH and Standard System32 / Sysnative
if not defined TARGET_PWSH (
    if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
        set "TARGET_PWSH=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    ) else if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
        set "TARGET_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
    ) else if exist "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" (
        set "TARGET_PWSH=X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    )
)

:: 2d. Scavenge Client Windows Installations across all mounted drives (WinRE Mode)
if not defined TARGET_PWSH (
    for %%d in (C D E F G H I K L M N O P Q R S T U V W Y Z) do (
        if not defined TARGET_PWSH (
            if exist "%%d:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" (
                set "TARGET_PWSH=%%d:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
                echo [OK] Scavenged Client OS PowerShell: %%d:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
            ) else if exist "%%d:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" (
                set "TARGET_PWSH=%%d:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
                echo [OK] Scavenged Client OS SysWOW64 PowerShell: %%d:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe
            )
        )
    )
)

:: 2e. Check PATH fallback
if not defined TARGET_PWSH (
    where pwsh.exe >nul 2>&1 && set "TARGET_PWSH=pwsh.exe"
)
if not defined TARGET_PWSH (
    where powershell.exe >nul 2>&1 && set "TARGET_PWSH=powershell.exe"
)

:: ============================================================
:: 3. EXECUTE MWBA OR LAUNCH CMD EMERGENCY FALLBACK
:: ============================================================
if defined TARGET_PWSH (
    echo [i] Launching MWBA via: !TARGET_PWSH!
    echo.
    "%TARGET_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0MWBA.ps1" %*
    goto :FINISHED
)

:: Emergency Native CMD Fallback when no PowerShell runtime exists
color 0C
echo.
echo ===============================================================================
echo  [-] CRITICAL: PowerShell was not found in this WinRE / WinPE environment.
echo ===============================================================================
echo  MWBA requires PowerShell to execute full diagnostic pipelines.
echo  However, you can execute native emergency BCD repairs directly from this CMD prompt:
echo.
echo    [1] Arm Safe Mode Minimal (Bypasses crashing filter/antivirus drivers):
echo        bcdedit /set {default} safeboot minimal
echo        bcdedit /set {default} bootmenupolicy legacy
echo.
echo    [2] Defuse Stuck Windows Update:
echo        ren D:\Windows\WinSxS\pending.xml pending.xml.bak
echo.
echo    [3] Launch Sergei Strelec PowerShell:
echo        Y:\Programs\PowerShell\powershell.exe
echo ===============================================================================
echo.
set /p "EMERG_CHOICE=Run Emergency Safe Mode Arming now? [Y/n]: "
if "!EMERG_CHOICE!"=="" set "EMERG_CHOICE=Y"
if /i "!EMERG_CHOICE!"=="Y" (
    bcdedit /set {default} safeboot minimal >nul 2>&1
    bcdedit /set {current} safeboot minimal >nul 2>&1
    bcdedit /set {default} bootmenupolicy legacy >nul 2>&1
    echo [OK] Safe Mode Minimal armed on active BCD store.
    echo Reboot the machine (wpeutil reboot) to enter Safe Mode.
)

:FINISHED
echo.
echo ============================================================
echo  MWBA execution finished.
echo  Press any key to exit.
echo ============================================================
pause >nul
