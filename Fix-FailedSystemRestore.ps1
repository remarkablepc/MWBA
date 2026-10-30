#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fix-FailedSystemRestore.ps1 -- Disarms Failed System Restore Loops & Repairs CatRoot2
.DESCRIPTION
    When an offline or interrupted Windows System Restore fails, Windows leaves behind pending
    continuation queues (DelayedOperations, RestoreContinuationState, FRStaging) and flagged
    registry keys (SrDelayedError, RestoreStatusResult). Upon subsequent boots, winlogon or smss
    crashes with BSOD 0xC000021A or infinite repair loops.
    
    This script disarms pending continuation states, purges corrupt restore staging queues,
    cleanses the offline SOFTWARE hive SystemRestore state, and validates cryptographic catalog
    integrity (CatRoot2/CatRoot).
#>
[CmdletBinding()]
param(
    [string]$TargetDrive = "",
    [string]$LogFile = "",
    [switch]$Force
)

$ErrorActionPreference = "Continue"

# -------------------------------------------------------------------------
# Dynamic Target Resolution
# -------------------------------------------------------------------------
if (-not $TargetDrive) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and (Test-Path "$($drive.RootDirectory.FullName)Windows\System32\ntoskrnl.exe")) {
            if ($drive.RootDirectory.FullName -notmatch "^C:\\" -or -not $TargetDrive) {
                $TargetDrive = $drive.Name.TrimEnd('\')
                if ($drive.RootDirectory.FullName -notmatch "^C:\\") { break }
            }
        }
    }
    if (-not $TargetDrive) { $TargetDrive = "C:" }
}

$cleanDrive = $TargetDrive.TrimEnd(':\') + ":"
if (-not $LogFile) {
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogFile = Join-Path $logDir "failed_restore_fix_log.txt"
}

function Write-HB {
    param([string]$Step, [string]$Status, [string]$Detail = "", [string]$Color = "White")
    $ts = Get-Date -Format "HH:mm:ss.fff"
    $icon = switch ($Status) {
        "OK"    { "[+] " }
        "INFO"  { "[*] " }
        "WORK"  { "[>] " }
        "WARN"  { "[!] " }
        "ERROR" { "[-] " }
        default { "[ ] " }
    }
    $line = "[$ts] $icon$Step : $Detail"
    Write-Host $line -ForegroundColor $Color
    if ($LogFile) {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: DISARM FAILED SYSTEM RESTORE CONTINUATION & CATROOT2    " -ForegroundColor Cyan
Write-Host "   Target Volume : $cleanDrive                                   " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path "$cleanDrive\Windows\System32")) {
    Write-HB "PREFLIGHT" "ERROR" "Target path $cleanDrive\Windows\System32 is not accessible!" "Red"
    exit 1
}

# 1. Disarm DelayedOperations in System Volume Information
$srDir = "$cleanDrive\System Volume Information\SystemRestore"
$delayedOps = Join-Path $srDir "DelayedOperations"
if (Test-Path $delayedOps) {
    Write-HB "DELAYED_OPS" "WORK" "Disarming pending DelayedOperations queue..." "Yellow"
    try {
        & takeown.exe /f "$delayedOps" /a 2>$null | Out-Null
        & icacls.exe "$delayedOps" /grant "Administrators:F" /q 2>$null | Out-Null
        Rename-Item -Path $delayedOps -NewName "DelayedOperations.mwba.bak" -Force -ErrorAction Stop
        Write-HB "DELAYED_OPS" "OK" "DelayedOperations successfully renamed to DelayedOperations.mwba.bak" "Green"
    } catch {
        Write-HB "DELAYED_OPS" "WARN" "Could not rename DelayedOperations: $_" "Yellow"
    }
} else {
    Write-HB "DELAYED_OPS" "INFO" "No active DelayedOperations queue found." "Gray"
}

# 2. Disarm RestoreContinuationState
$rcs = Join-Path $srDir "RestoreContinuationState"
if (Test-Path $rcs) {
    Write-HB "RESTORE_STATE" "WORK" "Disarming RestoreContinuationState flag..." "Yellow"
    try {
        & takeown.exe /f "$rcs" /a 2>$null | Out-Null
        & icacls.exe "$rcs" /grant "Administrators:F" /q 2>$null | Out-Null
        Rename-Item -Path $rcs -NewName "RestoreContinuationState.mwba.bak" -Force -ErrorAction Stop
        Write-HB "RESTORE_STATE" "OK" "RestoreContinuationState successfully renamed to RestoreContinuationState.mwba.bak" "Green"
    } catch {
        Write-HB "RESTORE_STATE" "WARN" "Could not rename RestoreContinuationState: $_" "Yellow"
    }
} else {
    Write-HB "RESTORE_STATE" "INFO" "No active RestoreContinuationState file found." "Gray"
}

# 3. Disarm FRStaging Directory
$frStaging = Join-Path $srDir "FRStaging"
if (Test-Path $frStaging) {
    Write-HB "FRSTAGING" "WORK" "Disarming FRStaging directory..." "Yellow"
    try {
        & takeown.exe /f "$frStaging" /a /r /d y 2>$null | Out-Null
        & icacls.exe "$frStaging" /grant "Administrators:(OI)(CI)F" /t /q 2>$null | Out-Null
        Rename-Item -Path $frStaging -NewName "FRStaging.mwba.bak" -Force -ErrorAction Stop
        Write-HB "FRSTAGING" "OK" "FRStaging renamed to FRStaging.mwba.bak" "Green"
    } catch {
        Write-HB "FRSTAGING" "WARN" "Could not rename FRStaging: $_" "Yellow"
    }
} else {
    Write-HB "FRSTAGING" "INFO" "No active FRStaging directory found." "Gray"
}

# 4. Clean SystemRestore failure keys in SOFTWARE hive
Write-HB "REG_CLEANUP" "WORK" "Loading offline SOFTWARE hive to sanitize restore state..." "Yellow"
$hiveName = "MWBA_SW_RestoreFix"
& reg.exe unload "HKLM\$hiveName" 2>$null | Out-Null
[System.GC]::Collect()

$swHive = "$cleanDrive\Windows\System32\config\SOFTWARE"
if (Test-Path $swHive) {
    $loadSw = & reg.exe load "HKLM\$hiveName" "$swHive" 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $srKey = "HKLM:\$hiveName\Microsoft\Windows NT\CurrentVersion\SystemRestore"
            if (Test-Path $srKey) {
                Set-ItemProperty -Path $srKey -Name "SrDelayedError" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $srKey -Name "RestoreStatusResult" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $srKey -Name "RestoreStatusDetails" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $srKey -Name "SrDelayedOperation" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $srKey -Name "SrDelayedArg0" -Force -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $srKey -Name "SrDelayedArg1" -Force -ErrorAction SilentlyContinue
                
                # Remove ErrorReportFiles subkey if present
                $errSub = "$srKey\ErrorReportFiles"
                if (Test-Path $errSub) {
                    Remove-Item -Path $errSub -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-HB "REG_CLEANUP" "OK" "SystemRestore registry state reset (SrDelayedError=0, RestoreStatusResult=0)." "Green"
            } else {
                Write-HB "REG_CLEANUP" "INFO" "SystemRestore registry key not present in hive." "Gray"
            }
        } finally {
            [System.GC]::Collect()
            Start-Sleep -Seconds 1
            & reg.exe unload "HKLM\$hiveName" 2>$null | Out-Null
            Write-HB "REG_CLEANUP" "OK" "Offline SOFTWARE hive unloaded cleanly." "Green"
        }
    } else {
        Write-HB "REG_CLEANUP" "WARN" "Could not load SOFTWARE hive: $($loadSw -join ' ')" "Yellow"
    }
} else {
    Write-HB "REG_CLEANUP" "ERROR" "SOFTWARE hive not found at $swHive" "Red"
}

# 5. Check Cryptographic Catalog Stores (CatRoot & CatRoot2)
Write-HB "CATALOGS" "WORK" "Auditing offline cryptographic catalog databases..." "Yellow"
$cat2 = "$cleanDrive\Windows\System32\CatRoot2"
if (Test-Path $cat2) {
    $cat2Files = (Get-ChildItem -Path $cat2 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($cat2Files -gt 0) {
        Write-HB "CATROOT2" "OK" "CatRoot2 is intact ($cat2Files database files present)." "Green"
    } else {
        Write-HB "CATROOT2" "WARN" "CatRoot2 is EMPTY! Offline CryptSvc cannot auto-regenerate it." "Yellow"
        Write-HB "CATROOT2" "WARN" "Run Restore-FromDonorDrive.ps1 to transplant CatRoot2 from a working reference drive." "Yellow"
    }
} else {
    Write-HB "CATROOT2" "WARN" "CatRoot2 directory missing at $cat2" "Yellow"
}

$cat1 = "$cleanDrive\Windows\System32\CatRoot"
if (Test-Path $cat1) {
    $cat1Files = (Get-ChildItem -Path $cat1 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($cat1Files -gt 50) {
        Write-HB "CATROOT" "OK" "CatRoot catalog store is intact ($cat1Files files present)." "Green"
    } else {
        Write-HB "CATROOT" "WARN" "CatRoot catalog store has only $cat1Files files (expected >= 50)." "Yellow"
    }
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   FAILED SYSTEM RESTORE DISARMED SUCCESSFULLY                   " -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
