#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Collect-BootLogs.ps1 -- Post-Boot Crash Forensics & Subsystem Health Analyzer
.DESCRIPTION
    Performs deep post-mortem analysis on an unbootable or crashing Windows installation.
    Analyzes minidumps, MEMORY.DMP, ntbtlog.txt, System.evtx, critical subsystem binaries,
    and offline registry configurations (LSA, Subsystems, AppCertDLLs, Filters, Winlogon).
#>
[CmdletBinding()]
param(
    [string]$TargetDrive = "",
    [string]$OutputFile = "",
    [string]$BitLockerKey = ""
)

$ErrorActionPreference = "Continue"

# Auto-detect target Windows if not provided
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
if (-not $OutputFile) {
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $OutputFile = Join-Path $logDir "boot_analysis_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
}

$lines = [System.Collections.Generic.List[string]]::new()

function Log {
    param([string]$msg, [string]$color = "White")
    Write-Host $msg -ForegroundColor $color
    $lines.Add($msg)
}

function Section {
    param([string]$title)
    Log ""
    Log ("=" * 67) "Cyan"
    Log "  $title" "Cyan"
    Log ("=" * 67) "Cyan"
}

Log ("=" * 67) "Cyan"
Log "   MWBA: COMPREHENSIVE POST-BOOT LOG & CRASH ANALYZER            " "Cyan"
Log "   Target Volume : $cleanDrive                                   " "Cyan"
Log "   Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')      " "Cyan"
Log ("=" * 67) "Cyan"

# -------------------------------------------------------------------------
# 1. Drive Online & BitLocker Check
# -------------------------------------------------------------------------
Section "[1] Target Volume & BitLocker Status"
$bdeStatus = & manage-bde -status "$cleanDrive" 2>&1 | Out-String
if ($bdeStatus -match "Locked") {
    Log "[!] Drive $cleanDrive is BitLocker-locked!" "Yellow"
    if (-not $BitLockerKey) {
        $BitLockerKey = Read-Host "  Enter BitLocker Recovery Key for $cleanDrive"
    }
    if ($BitLockerKey) {
        & manage-bde -unlock "$cleanDrive" -RecoveryPassword $BitLockerKey 2>&1 | Out-Null
        & manage-bde -autounlock -enable "$cleanDrive" 2>&1 | Out-Null
    }
}

if (-not (Test-Path "$cleanDrive\Windows\System32")) {
    Log "[-] ERROR: $cleanDrive\Windows\System32 is not accessible. Drive may be offline or locked." "Red"
    $lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    exit 1
}
Log "[+] Target drive $cleanDrive is online and accessible." "Green"

# -------------------------------------------------------------------------
# 2. Crash Dumps & Memory Dump
# -------------------------------------------------------------------------
Section "[2] Crash Dumps & Memory Dumps"
$minidumps = Get-ChildItem "$cleanDrive\Windows\Minidump\*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($minidumps) {
    Log "[+] Found $($minidumps.Count) Minidump file(s):" "Green"
    foreach ($d in $minidumps) {
        Log "    - $($d.Name) ($($d.Length) bytes, Last Modified: $($d.LastWriteTime))" "Cyan"
    }
} else {
    Log "[*] No minidumps found in $cleanDrive\Windows\Minidump" "Gray"
}

if (Test-Path "$cleanDrive\Windows\MEMORY.DMP") {
    $memDmp = Get-Item "$cleanDrive\Windows\MEMORY.DMP"
    Log "[+] MEMORY.DMP found: $($memDmp.Length) bytes, Last Modified: $($memDmp.LastWriteTime)" "Green"
} else {
    Log "[*] No MEMORY.DMP present." "Gray"
}

# -------------------------------------------------------------------------
# 3. Boot Log (ntbtlog.txt)
# -------------------------------------------------------------------------
Section "[3] Windows Boot Log (ntbtlog.txt)"
$btPath = "$cleanDrive\Windows\ntbtlog.txt"
if (Test-Path $btPath) {
    $btLog = Get-Item $btPath
    Log "[+] Found ntbtlog.txt (Last Modified: $($btLog.LastWriteTime), Size: $($btLog.Length) bytes)" "Green"
    $btContent = Get-Content $btPath -ErrorAction SilentlyContinue
    if ($btContent) {
        Log "--- Last 30 Drivers Loaded / Attempted ---" "Cyan"
        $last30 = $btContent | Select-Object -Last 30
        foreach ($l in $last30) { Log "    $l" "Gray" }
    }
} else {
    Log "[*] ntbtlog.txt does not exist on target." "Gray"
    Log "[*] Tip: Use Set-NormalBoot.bat or Set-SafeModeBoot.bat to enable boot logging." "Cyan"
}

# -------------------------------------------------------------------------
# 4. Offline Event Logs (System.evtx)
# -------------------------------------------------------------------------
Section "[4] Offline Event Log Analysis (System.evtx)"
$evtxPath = "$cleanDrive\Windows\System32\winevt\Logs\System.evtx"
if (Test-Path $evtxPath) {
    try {
        $events = Get-WinEvent -Path $evtxPath -MaxEvents 30 -ErrorAction SilentlyContinue |
            Where-Object { $_.LevelDisplayName -in @("Critical", "Error") -or $_.Id -in @(1001, 41, 6008, 7001, 7023, 7034, 7031) }
        if ($events) {
            Log "[+] Found $($events.Count) critical/error event(s) in System.evtx:" "Green"
            foreach ($e in $events) {
                Log "---------------------------------------------------------" "DarkCyan"
                Log "TimeCreated: $($e.TimeCreated)" "Cyan"
                Log "Event ID:    $($e.Id) | Provider: $($e.ProviderName)" "Yellow"
                Log "Level:       $($e.LevelDisplayName)" "Yellow"
                Log "Message:     $($e.Message -replace '[\r\n]+', ' ')" "White"
            }
        } else {
            Log "[*] No recent Critical/Error events found in System.evtx." "Gray"
        }
    } catch {
        Log "[-] Failed to read System.evtx: $_" "Yellow"
    }
} else {
    Log "[*] System.evtx not found at $evtxPath" "Gray"
}

# -------------------------------------------------------------------------
# 5. Critical System Binaries Check
# -------------------------------------------------------------------------
Section "[5] Critical Subsystem Binaries Audit"
$criticalBins = @(
    "smss.exe", "csrss.exe", "wininit.exe", "winlogon.exe", "services.exe", "lsass.exe", "ntoskrnl.exe",
    "basesrv.dll", "winsrv.dll", "sxssrv.dll", "sspicli.dll", "lsasrv.dll", "crypt32.dll",
    "user32.dll", "gdi32.dll", "gdi32full.dll", "kernel32.dll", "kernelbase.dll", "ntdll.dll", "win32k.sys"
)

foreach ($b in $criticalBins) {
    $p = "$cleanDrive\Windows\System32\$b"
    if ($b -match "\.sys$") {
        if (-not (Test-Path $p)) { $p = "$cleanDrive\Windows\System32\drivers\$b" }
    }
    if (Test-Path $p) {
        $fi = Get-Item $p
        Log "    [+] $b : $($fi.Length) bytes, LastWrite: $($fi.LastWriteTime)" "Green"
    } else {
        Log "    [-] MISSING BINARY: $b at $p" "Red"
    }
}

# -------------------------------------------------------------------------
# 6. Offline SYSTEM Registry Hive
# -------------------------------------------------------------------------
Section "[6] Offline SYSTEM Registry Hive Forensics"
$hiveSYS = "MWBA_DiagSYS"
& reg.exe unload "HKLM\$hiveSYS" 2>$null | Out-Null
$sysPath = "$cleanDrive\Windows\System32\config\SYSTEM"
if (Test-Path $sysPath) {
    $load = & reg.exe load "HKLM\$hiveSYS" "$sysPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $csNum = "001"
            $csQ = (& reg.exe query "HKLM\$hiveSYS\Select" /v "Current" 2>&1) -join " "
            if ($csQ -match "0x0*([1-9][0-9]*)") { $csNum = $Matches[1].PadLeft(3,"0") }
            Log "    [+] Active ControlSet: ControlSet$csNum" "Cyan"

            # LSA
            Log "    --- LSA Packages ---" "Cyan"
            $lsaSec = (& reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Lsa" /v "Security Packages" 2>$null) -join " "
            $lsaAuth = (& reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Lsa" /v "Authentication Packages" 2>$null) -join " "
            Log "        Security Packages:       $lsaSec" "White"
            Log "        Authentication Packages: $lsaAuth" "White"

            # SubSystems
            Log "    --- SubSystems ---" "Cyan"
            $subWin = (& reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Session Manager\SubSystems" /v "Windows" 2>$null) -join " "
            $subKmode = (& reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Session Manager\SubSystems" /v "Kmode" 2>$null) -join " "
            Log "        Windows SubSystem: $subWin" "White"
            Log "        Kmode SubSystem:   $subKmode" "White"

            # AppCertDLLs
            $appCert = & reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Session Manager\AppCertDLLs" 2>$null
            if ($appCert -and ($appCert -join " ") -notmatch "ERROR") {
                Log "        [!] AppCertDLLs FOUND: $($appCert -join ' ')" "Yellow"
            } else {
                Log "        [+] AppCertDLLs is clean/empty." "Green"
            }

            # Class UpperFilters
            Log "    --- Storage & Device Class UpperFilters ---" "Cyan"
            $classes = & reg.exe query "HKLM\$hiveSYS\ControlSet$csNum\Control\Class" /s /f "UpperFilters" 2>$null
            foreach ($c in $classes) {
                if ($c -match "REG_MULTI_SZ|HKEY_LOCAL_MACHINE") { Log "        $c" "Gray" }
            }
        } finally {
            [System.GC]::Collect()
            Start-Sleep -Seconds 1
            & reg.exe unload "HKLM\$hiveSYS" 2>$null | Out-Null
            Log "    [+] SYSTEM hive unloaded cleanly." "Green"
        }
    } else {
        Log "    [-] Failed to load SYSTEM hive: $load" "Red"
    }
} else {
    Log "    [-] SYSTEM hive missing at $sysPath" "Red"
}

# -------------------------------------------------------------------------
# 7. Offline SOFTWARE Registry Hive
# -------------------------------------------------------------------------
Section "[7] Offline SOFTWARE Registry Hive Forensics"
$hiveSW = "MWBA_DiagSW"
& reg.exe unload "HKLM\$hiveSW" 2>$null | Out-Null
$swPath = "$cleanDrive\Windows\System32\config\SOFTWARE"
if (Test-Path $swPath) {
    $loadSW = & reg.exe load "HKLM\$hiveSW" "$swPath" 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $wlKey = "HKLM\$hiveSW\Microsoft\Windows NT\CurrentVersion\Winlogon"
            $ui = (& reg.exe query "$wlKey" /v "Userinit" 2>$null) -join " "
            $sh = (& reg.exe query "$wlKey" /v "Shell" 2>$null) -join " "
            Log "    [+] Winlogon Userinit: $ui" "White"
            Log "    [+] Winlogon Shell:    $sh" "White"

            # Credential Providers
            Log "    --- Active Credential Providers ---" "Cyan"
            $cpList = & reg.exe query "HKLM\$hiveSW\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers" 2>$null
            foreach ($cp in $cpList) {
                if ($cp -match "HKEY_LOCAL_MACHINE") {
                    $guid = $cp.Split("\")[-1]
                    $val = (& reg.exe query "$cp" /ve 2>$null) -join " "
                    Log "        $guid -> $val" "Gray"
                }
            }
        } finally {
            [System.GC]::Collect()
            Start-Sleep -Seconds 1
            & reg.exe unload "HKLM\$hiveSW" 2>$null | Out-Null
            Log "    [+] SOFTWARE hive unloaded cleanly." "Green"
        }
    } else {
        Log "    [-] Failed to load SOFTWARE hive: $loadSW" "Red"
    }
} else {
    Log "    [-] SOFTWARE hive missing at $swPath" "Red"
}

Log ""
Log ("=" * 67) "Green"
Log "  FORENSIC ANALYSIS COMPLETE: Output saved to: $OutputFile" "Green"
Log ("=" * 67) "Green"
Log ""

$lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
