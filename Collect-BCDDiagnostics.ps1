#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Collect-BCDDiagnostics.ps1 -- Universal EFI & BCD Health Diagnostic Engine
.DESCRIPTION
    Audits the UEFI / EFI System Partition (ESP) and Boot Configuration Data (BCD)
    store for missing bootloaders (bootmgfw.efi, bootx64.efi, winload.efi), corrupted
    BCD stores, invalid device/osdevice pointers, and VSS snapshot availability.
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
    $OutputFile = Join-Path $logDir "bcd_diagnostics_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
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
Log "   MWBA: UNIVERSAL BCD & EFI DIAGNOSTIC ENGINE                   " "Cyan"
Log "   Target Volume : $cleanDrive                                   " "Cyan"
Log "   Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')      " "Cyan"
Log ("=" * 67) "Cyan"

# -------------------------------------------------------------------------
# 1. Target Volume Status
# -------------------------------------------------------------------------
Section "[1] Target Volume Accessibility"
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
    Log "[-] $cleanDrive\Windows\System32 is NOT accessible. Cannot proceed." "Red"
    $lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    exit 1
}
Log "[+] Target Windows verified: $cleanDrive\Windows" "Green"

# -------------------------------------------------------------------------
# 2. Locate EFI System Partition (ESP)
# -------------------------------------------------------------------------
Section "[2] EFI System Partition (ESP) Discovery"
$partLetter = $cleanDrive.TrimEnd(':')
$partWin = Get-Partition | Where-Object { $_.DriveLetter -eq $partLetter }
if (-not $partWin) {
    Log "[-] Could not find physical partition for $cleanDrive" "Red"
    $lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    exit 1
}

$diskNum = $partWin[0].DiskNumber
Log "[+] Windows volume maps to Disk $diskNum, Partition $($partWin[0].PartitionNumber)" "Green"

$espPart = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

if (-not $espPart) {
    Log "[-] No EFI System Partition found on Disk $diskNum!" "Red"
    $diskStyle = (Get-Disk -Number $diskNum -ErrorAction SilentlyContinue).PartitionStyle
    Log "[*] Partition Style for Disk ${diskNum}: $diskStyle" "Yellow"
    $lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    exit 1
}

Log "[+] Found ESP: Disk $diskNum, Partition $($espPart.PartitionNumber), Size $([math]::Round($espPart.Size/1MB,1)) MB" "Green"

# Mount ESP temporarily if needed
$espLetter = $espPart.DriveLetter
$mountedHere = $false
if (-not $espLetter -or -not (Test-Path "${espLetter}:\EFI\Microsoft\Boot\BCD")) {
    $used = (Get-Volume).DriveLetter | Where-Object { $_ }
    $candidates = 83..90 | ForEach-Object { [char]$_ }
    foreach ($cand in $candidates) {
        if ($used -notcontains $cand -and (-not (Test-Path "${cand}:\"))) {
            $espLetter = "$cand"
            break
        }
    }
    if (-not $espLetter) { $espLetter = "S" }

    try {
        Set-Partition -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -NewDriveLetter $espLetter -ErrorAction Stop
        Start-Sleep -Seconds 1
        $mountedHere = $true
        Log "[>] Temporarily mounted ESP as ${espLetter}:\" "Yellow"
    } catch {
        Log "[-] Could not assign drive letter to ESP: $_" "Red"
        $lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
        exit 1
    }
}

# -------------------------------------------------------------------------
# 3. Check BCD Store
# -------------------------------------------------------------------------
Section "[3] BCD Store Integrity"
$bcdPath = "${espLetter}:\EFI\Microsoft\Boot\BCD"
$bcdBackupPath = "${espLetter}:\EFI\Microsoft\Boot\BCD.bak"
$bcdOldPath = "${espLetter}:\EFI\Microsoft\Boot\BCD.old"

if (Test-Path $bcdPath) {
    $bcdFile = Get-Item $bcdPath
    Log "[+] BCD store found: $bcdPath" "Green"
    Log "    Size: $($bcdFile.Length) bytes" "Gray"
    Log "    Last Modified: $($bcdFile.LastWriteTime)" "Gray"
    if (Test-Path $bcdBackupPath) {
        $bak = Get-Item $bcdBackupPath
        Log "[i] Backup BCD exists: $bcdBackupPath ($($bak.Length) bytes)" "Gray"
    }
    if (Test-Path $bcdOldPath) {
        $old = Get-Item $bcdOldPath
        Log "[i] Stale BCD backup exists: $bcdOldPath ($($old.Length) bytes)" "Gray"
    }
} else {
    Log "[-] CRITICAL: NO BCD file found at $bcdPath!" "Red"
    Log "[*] Root cause of 0xc0000034 / 0xc0000098 boot failure." "Red"
}

# -------------------------------------------------------------------------
# 4. Enumerate BCD Elements
# -------------------------------------------------------------------------
Section "[4] Offline BCD Store Enumeration"
if (Test-Path $bcdPath) {
    $enum = & bcdedit.exe /store "$bcdPath" /enum all 2>&1
    if ($enum) {
        foreach ($e in $enum) { Log "  $e" "White" }
        
        Log "" "Gray"
        Log "[*] --- PARSED BCD SUMMARY ---" "Cyan"
        $hasDefault = $enum -match '{default}'
        $hasBootmgr = $enum -match '{bootmgr}'
        Log "  {default} exists : $hasDefault" "Gray"
        Log "  {bootmgr} exists : $hasBootmgr" "Gray"
        
        $defaultSection = $false
        $defaultDevice = ""
        $defaultOsDevice = ""
        foreach ($e in $enum) {
            if ($e -match '{default}') { $defaultSection = $true }
            elseif ($e -match 'identifier\s+{') { $defaultSection = $false }
            
            if ($defaultSection) {
                if ($e -match 'device\s+=\s+(.*)') { $defaultDevice = $Matches[1] }
                if ($e -match 'osdevice\s+=\s+(.*)') { $defaultOsDevice = $Matches[1] }
            }
        }
        if ($defaultDevice) { Log "  {default} device    : $defaultDevice" "White" }
        if ($defaultOsDevice) { Log "  {default} osdevice  : $defaultOsDevice" "White" }
    }
}

# -------------------------------------------------------------------------
# 5. EFI Bootloader File Verification
# -------------------------------------------------------------------------
Section "[5] EFI Bootloader File Verification"
$bootMgfwPath = "${espLetter}:\EFI\Microsoft\Boot\bootmgfw.efi"
$bootX64Path = "${espLetter}:\EFI\Boot\bootx64.efi"
$winLoadPath = "$cleanDrive\Windows\System32\Boot\winload.efi"
$winLoadExePath = "$cleanDrive\Windows\System32\winload.exe"

if (Test-Path $bootMgfwPath) {
    $f = Get-Item $bootMgfwPath
    Log "[+] bootmgfw.efi : $($f.Length) bytes, LastWrite: $($f.LastWriteTime)" "Green"
} else {
    Log "[-] bootmgfw.efi MISSING from EFI\Microsoft\Boot!" "Red"
}

if (Test-Path $bootX64Path) {
    $f = Get-Item $bootX64Path
    Log "[+] bootx64.efi  : $($f.Length) bytes, LastWrite: $($f.LastWriteTime)" "Green"
} else {
    Log "[-] bootx64.efi MISSING from EFI\Boot!" "Yellow"
}

if (Test-Path $winLoadPath) {
    $f = Get-Item $winLoadPath
    Log "[+] winload.efi  : $($f.Length) bytes, LastWrite: $($f.LastWriteTime)" "Green"
} else {
    Log "[-] winload.efi MISSING from System32\Boot!" "Red"
}

if (Test-Path $winLoadExePath) {
    $f = Get-Item $winLoadExePath
    Log "[+] winload.exe  : $($f.Length) bytes, LastWrite: $($f.LastWriteTime)" "Green"
}

# -------------------------------------------------------------------------
# 6. Volume Shadow Copies (VSS)
# -------------------------------------------------------------------------
Section "[6] Volume Shadow Copies (VSS) on Target"
try {
    $rawShadows = vssadmin list shadows /for="$cleanDrive" 2>&1 | Out-String
    $shadowCount = ([regex]::Matches($rawShadows, "Shadow Copy Volume:").Count)
    if ($shadowCount -gt 0) {
        Log "[+] Found $shadowCount VSS snapshot(s) on $cleanDrive." "Green"
        $blocks = $rawShadows -split "(?=Contents of Shadow Copy ID:)"
        foreach ($block in $blocks) {
            if ($block -match 'Shadow Copy Volume: .*\\HarddiskVolumeShadowCopy(\d+)' -and $block -match 'Creation Time: (.*)') {
                Log "    - Snapshot #$($Matches[1]): $($Matches[2].Trim())" "Gray"
            }
        }
    } else {
        Log "[*] No VSS snapshots found on $cleanDrive." "Gray"
    }
} catch {
    Log "[*] Could not query VSS: $_" "Gray"
}

# -------------------------------------------------------------------------
# 7. Diagnostic Summary & Remediation
# -------------------------------------------------------------------------
Section "[7] Diagnostic Summary"
$issues = @()
if (-not (Test-Path $bcdPath)) { $issues += "BCD store is missing" }
if (-not (Test-Path $bootMgfwPath)) { $issues += "bootmgfw.efi is missing" }
if (-not (Test-Path $winLoadPath)) { $issues += "winload.efi is missing" }

if ($issues.Count -gt 0) {
    Log "[!] Issues Detected:" "Yellow"
    foreach ($i in $issues) { Log "    - $i" "Yellow" }
    Log "[>] Recommended Fix: Run Fix-BCDError34.ps1 to reconstruct BCD and boot files." "Cyan"
} else {
    Log "[+] All critical EFI and BCD boot files are physically present." "Green"
}

# Cleanup temporary mount
if ($mountedHere -and $espLetter) {
    Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
    Log "[+] Dismounted temporary ESP letter ${espLetter}:\" "Gray"
}

Log ""
Log ("=" * 67) "Green"
Log "  DIAGNOSTICS SAVED TO: $OutputFile" "Green"
Log ("=" * 67) "Green"
Log ""

$lines | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
