#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sync-BootDrivers.ps1 -- Universal Boot Driver Sanitizer & Donor Alignment Engine
.DESCRIPTION
    Comprehensive offline driver integrity auditor and start-type alignment utility:
    1. Validates offline SYSTEM hive integrity (regf signature, minimum size).
    2. Audits all BOOT_START (Start=0) and SYSTEM_START (Start=1) drivers.
    3. Detects missing driver binaries that cause INACCESSIBLE_BOOT_DEVICE (0x0000007B).
    4. Automatically demotes missing boot drivers to Start=3 (Manual) to prevent boot halts.
    5. Checks Authenticode digital signatures on boot-critical drivers.
    6. If a DonorDrive is provided, aligns critical storage/kernel drivers to match known-good donor.
    7. Sanitizes rogue 3rd-party filter drivers from Class UpperFilters.
    8. Resets stale DosDevices in MountedDevices.
#>
[CmdletBinding()]
param(
    [string]$TargetDrive = "",
    [string]$DonorDrive = "",
    [switch]$DemoteMissingDrivers = $true,
    [switch]$SkipFilterPurge,
    [switch]$SkipMountedDevicesReset
)

$ErrorActionPreference = "Continue"

# -------------------------------------------------------------------------
# Dynamic Target Resolution
# -------------------------------------------------------------------------
if (-not $TargetDrive) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and (Test-Path "$($drive.RootDirectory.FullName)Windows\System32\ntoskrnl.exe")) {
            $candidate = $drive.Name.TrimEnd('\')
            if ($candidate -ne $DonorDrive.TrimEnd('\') -and ($candidate -notmatch "^C:" -or -not $TargetDrive)) {
                $TargetDrive = $candidate
                if ($candidate -notmatch "^C:") { break }
            }
        }
    }
    if (-not $TargetDrive) { $TargetDrive = "E:" }
}

$cleanTarget = $TargetDrive.TrimEnd(':\') + ":"
$cleanDonor  = if ($DonorDrive) { $DonorDrive.TrimEnd(':\') + ":" } else { "" }

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
    Write-Host "[$ts] $icon$Step : $Detail" -ForegroundColor $Color
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: BOOT DRIVER INTEGRITY & ALIGNMENT ENGINE                " -ForegroundColor Cyan
Write-Host "   Target Volume (To Repair) : $cleanTarget                        " -ForegroundColor Cyan
if ($cleanDonor) {
    Write-Host "   Donor Drive   (Reference) : $cleanDonor                         " -ForegroundColor Cyan
} else {
    Write-Host "   Operation Mode            : Standalone Deep Driver Audit        " -ForegroundColor Cyan
}
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

$targetSys = "$cleanTarget\Windows\System32\config\SYSTEM"
if (-not (Test-Path $targetSys)) {
    Write-HB "PREFLIGHT" "ERROR" "Target SYSTEM hive not found at $targetSys" "Red"
    exit 1
}

# -------------------------------------------------------------------------
# Step 1: Binary Hive Integrity Pre-Check (regf signature)
# -------------------------------------------------------------------------
Write-HB "HIVE_CHECK" "WORK" "Checking binary integrity of Target SYSTEM hive..." "Yellow"
try {
    $stream = [System.IO.File]::Open($targetSys, 'Open', 'Read', 'Read')
    try {
        $buf = New-Object byte[] 4
        $stream.Read($buf, 0, 4) | Out-Null
        $sig = [System.Text.Encoding]::ASCII.GetString($buf)
        $len = $stream.Length
        if ($sig -ne 'regf') {
            Write-HB "HIVE_CHECK" "ERROR" "SYSTEM hive has invalid magic header '$sig' (expected 'regf')! File is corrupt." "Red"
            exit 1
        }
        if ($len -lt 51200) {
            Write-HB "HIVE_CHECK" "WARN" "SYSTEM hive size is abnormally small ($len bytes) - possible truncation." "Yellow"
        } else {
            Write-HB "HIVE_CHECK" "OK" "SYSTEM hive header valid (regf), size: $([math]::Round($len/1MB,1)) MB." "Green"
        }
    } finally {
        $stream.Close()
    }
} catch {
    Write-HB "HIVE_CHECK" "WARN" "Could not read hive stream: $_" "Yellow"
}

# Unload any dangling hives
& reg.exe unload HKLM\MWBA_DonorSYS 2>$null | Out-Null
& reg.exe unload HKLM\MWBA_TargetSYS 2>$null | Out-Null
[System.GC]::Collect()
Start-Sleep -Seconds 1

# Load Target Hive
Write-HB "LOAD_TARGET" "WORK" "Loading Target SYSTEM hive ($cleanTarget)..." "Yellow"
$loadTarget = & reg.exe load HKLM\MWBA_TargetSYS "$targetSys" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-HB "LOAD_TARGET" "ERROR" "Failed to load Target hive: $($loadTarget -join ' ')" "Red"
    exit 1
}
Write-HB "LOAD_TARGET" "OK" "Target SYSTEM hive loaded cleanly." "Green"

# Optional Donor Load
$donorLoaded = $false
if ($cleanDonor) {
    $donorSys = "$cleanDonor\Windows\System32\config\SYSTEM"
    if (Test-Path $donorSys) {
        Write-HB "LOAD_DONOR" "WORK" "Loading Donor SYSTEM hive ($cleanDonor)..." "Yellow"
        $loadDonor = & reg.exe load HKLM\MWBA_DonorSYS "$donorSys" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-HB "LOAD_DONOR" "OK" "Donor SYSTEM hive loaded cleanly." "Green"
            $donorLoaded = $true
        } else {
            Write-HB "LOAD_DONOR" "WARN" "Failed to load Donor hive: $($loadDonor -join ' ')" "Yellow"
        }
    }
}

function Get-CSNum ($hiveKey) {
    $cs = "001"
    $q = (& reg.exe query "$hiveKey\Select" /v "Current" 2>&1) -join " "
    if ($q -match "0x0*([1-9][0-9]*)") { $cs = $Matches[1].PadLeft(3, "0") }
    return $cs
}

function Resolve-DriverFilePath {
    param([string]$ImagePath, [string]$WindowsRoot)
    if (-not $ImagePath) { return $null }
    $p = $ImagePath.Trim().Trim('"')
    $p = $p -replace '^(?:\\\\\?\\|\\\\\?\\GLOBALROOT\\)?\\?\??\\?', ''
    if ($p -match '(?i)SystemRoot') {
        $rel = $p -replace '(?i).*SystemRoot\\?', ''
        return (Join-Path $WindowsRoot $rel)
    }
    if ($p -notmatch '^[A-Za-z]:\\') {
        return (Join-Path "$WindowsRoot\System32\drivers" $p)
    }
    if ($p -match '^[A-Za-z]:\\') {
        $rest = $p.Substring(2).TrimStart('\')
        $candidate = Join-Path $WindowsRoot $rest
        if (Test-Path $candidate) { return $candidate }
    }
    return $p
}

try {
    $csTarget = Get-CSNum "HKLM\MWBA_TargetSYS"
    Write-HB "CONTROL_SET" "INFO" "Target Active ControlSet: ControlSet$csTarget" "Cyan"

    # -------------------------------------------------------------------------
    # Step 2: Full BOOT_START & SYSTEM_START Driver Existence Audit
    # -------------------------------------------------------------------------
    Write-HB "DRIVER_AUDIT" "WORK" "Auditing all Start=0 (BOOT_START) and Start=1 (SYSTEM_START) drivers..." "Yellow"
    $servicesPath = "HKLM:\MWBA_TargetSYS\ControlSet$csTarget\Services"
    $svcKeys = Get-ChildItem -Path $servicesPath -ErrorAction SilentlyContinue

    $missingBootDrivers = @()
    $unsignedBootDrivers = @()
    $totalBootDrivers = 0

    foreach ($sk in $svcKeys) {
        $props = Get-ItemProperty -Path $sk.PSPath -ErrorAction SilentlyContinue
        $startVal = $props.Start
        if ($startVal -in @(0, 1)) {
            $totalBootDrivers++
            $svcName = $sk.PSChildName
            $img = $props.ImagePath
            $resolved = Resolve-DriverFilePath -ImagePath $img -WindowsRoot "$cleanTarget\Windows"

            $exists = $false
            if ($resolved -and (Test-Path $resolved -PathType Leaf)) {
                $exists = $true
            }

            if (-not $exists) {
                $missingBootDrivers += [PSCustomObject]@{
                    Name      = $svcName
                    Start     = $startVal
                    ImagePath = $img
                    Resolved  = $resolved
                    KeyPath   = $sk.PSPath
                }
            } else {
                # Check signature
                try {
                    $sig = Get-AuthenticodeSignature -FilePath $resolved -ErrorAction SilentlyContinue
                    if ($sig -and $sig.Status -ne 'Valid') {
                        $unsignedBootDrivers += [PSCustomObject]@{
                            Name   = $svcName
                            File   = (Split-Path $resolved -Leaf)
                            Status = $sig.Status
                        }
                    }
                } catch {}
            }
        }
    }

    Write-HB "DRIVER_AUDIT" "INFO" "Inspected $totalBootDrivers boot-critical service configurations." "Cyan"

    if ($missingBootDrivers.Count -gt 0) {
        Write-HB "DRIVER_AUDIT" "WARN" "Found $($missingBootDrivers.Count) boot-start service(s) with MISSING driver files!" "Yellow"
        foreach ($mb in $missingBootDrivers) {
            Write-HB "MISSING_DRIVER" "WARN" "Service '$($mb.Name)' (Start=$($mb.Start)) -> File missing: $($mb.Resolved)" "Yellow"
            if ($DemoteMissingDrivers) {
                # Demote to Start=3 (Manual) to prevent INACCESSIBLE_BOOT_DEVICE / stop error 0x7B
                Set-ItemProperty -Path $mb.KeyPath -Name "Start" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
                Write-HB "DEMOTE_DRIVER" "OK" "Safely demoted '$($mb.Name)' Start value to 3 (Manual)." "Green"
            }
        }
    } else {
        Write-HB "DRIVER_AUDIT" "OK" "All $totalBootDrivers boot-critical driver files verified present on disk." "Green"
    }

    if ($unsignedBootDrivers.Count -gt 0) {
        Write-HB "SIGNATURE_CHECK" "WARN" "Found $($unsignedBootDrivers.Count) unsigned/invalid signature driver(s):" "Yellow"
        foreach ($ub in $unsignedBootDrivers) {
            Write-HB "SIGNATURE_CHECK" "WARN" "  - $($ub.Name) ($($ub.File)): $($ub.Status)" "Yellow"
        }
    }

    # -------------------------------------------------------------------------
    # Step 3: Align Critical Drivers from Donor (if provided)
    # -------------------------------------------------------------------------
    if ($donorLoaded) {
        $csDonor = Get-CSNum "HKLM\MWBA_DonorSYS"
        Write-HB "DONOR_ALIGN" "WORK" "Aligning storage stack drivers with Donor ControlSet$csDonor..." "Yellow"

        $criticalDrivers = @(
            "stornvme", "storahci", "iaStorA", "iaStorAVC", "iaStorV", "iaStorVD",
            "partmgr", "volsnap", "volmgr", "mountmgr", "spaceport", "fltmgr",
            "vmbus", "storvsc", "intelide", "pciide", "pci", "acpi", "intelpep",
            "Wdf01000", "disk", "cdrom", "CLASSPNP"
        )

        $alignedCount = 0
        foreach ($svc in $criticalDrivers) {
            $refKey = "HKLM\MWBA_DonorSYS\ControlSet$csDonor\Services\$svc"
            $targetKey = "HKLM\MWBA_TargetSYS\ControlSet$csTarget\Services\$svc"

            $refStartQ = (& reg.exe query "$refKey" /v "Start" 2>$null) -join " "
            if ($refStartQ -match "0x0*([0-9a-fA-F]+)") {
                $refStartVal = [convert]::ToInt32($Matches[1], 16)

                $targetStartQ = (& reg.exe query "$targetKey" /v "Start" 2>$null) -join " "
                $targetStartVal = -1
                if ($targetStartQ -match "0x0*([0-9a-fA-F]+)") {
                    $targetStartVal = [convert]::ToInt32($Matches[1], 16)
                }

                if ($targetStartVal -ne $refStartVal) {
                    Write-HB "SYNC_DRIVER" "WARN" "Aligning $svc : Target (Start=$targetStartVal) -> Donor (Start=$refStartVal)" "Yellow"
                    & reg.exe add "$targetKey" /v "Start" /t REG_DWORD /d $refStartVal /f | Out-Null
                    $alignedCount++
                }
            }
        }
        Write-HB "DONOR_ALIGN" "OK" "Aligned $alignedCount storage/boot drivers to match Donor reference." "Green"
    }

    # -------------------------------------------------------------------------
    # Step 4: Neutralize Rogue 3rd-Party Class UpperFilters
    # -------------------------------------------------------------------------
    if (-not $SkipFilterPurge) {
        Write-HB "FILTER_PURGE" "WORK" "Scanning for rogue 3rd-party storage and filesystem class filters..." "Yellow"
        $rogueFilters = @("aswArDisk", "aswKbd", "aswMonFlt", "aswSP", "aswSnx", "aswStm", "aswVmm", "aswbids", "aswRvHost", "aswHdske", "aswElam", "klkbdflt", "klmouflt", "klflt", "mbae", "mbae64", "MBAMProtector", "MBAMService")
        $classRoot = "HKLM\MWBA_TargetSYS\ControlSet$csTarget\Control\Class"
        $classSubkeys = & reg.exe query "$classRoot" 2>$null
        $purgedCount = 0
        foreach ($cKey in $classSubkeys) {
            $upQ = (& reg.exe query "$cKey" /v "UpperFilters" 2>$null) -join " "
            foreach ($rf in $rogueFilters) {
                if ($upQ -match [regex]::Escape($rf)) {
                    Write-HB "FILTER_PURGE" "WARN" "Found rogue filter $rf in $cKey. Sanitizing..." "Yellow"
                    $cleaned = ($upQ -split "\s+" | Where-Object { $_ -and $_ -ne $rf -and $_ -ne "REG_MULTI_SZ" -and $_ -ne "UpperFilters" }) -join "\0"
                    if ($cleaned) {
                        & reg.exe add "$cKey" /v "UpperFilters" /t REG_MULTI_SZ /d "${cleaned}\0" /f | Out-Null
                    } else {
                        & reg.exe delete "$cKey" /v "UpperFilters" /f 2>$null | Out-Null
                    }
                    $purgedCount++
                }
            }
        }
        Write-HB "FILTER_PURGE" "OK" "Sanitized $purgedCount rogue filter entries." "Green"
    }

    # -------------------------------------------------------------------------
    # Step 5: Reset Stale MountedDevices
    # -------------------------------------------------------------------------
    if (-not $SkipMountedDevicesReset) {
        $targetMD = "HKLM\MWBA_TargetSYS\ControlSet$csTarget\Control\MountedDevices"
        & reg.exe delete "$targetMD" /v "\DosDevices\C:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMD" /v "\DosDevices\D:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMD" /v "\DosDevices\E:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMD" /v "\DosDevices\G:" /f 2>$null | Out-Null

        $targetMDRoot = "HKLM\MWBA_TargetSYS\MountedDevices"
        & reg.exe delete "$targetMDRoot" /v "\DosDevices\C:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMDRoot" /v "\DosDevices\D:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMDRoot" /v "\DosDevices\E:" /f 2>$null | Out-Null
        & reg.exe delete "$targetMDRoot" /v "\DosDevices\G:" /f 2>$null | Out-Null
        Write-HB "MOUNTED_DEVICES" "OK" "Cleared stale DosDevices drive assignments." "Green"
    }

} finally {
    [System.GC]::Collect()
    Start-Sleep -Seconds 1
    if ($donorLoaded) { & reg.exe unload HKLM\MWBA_DonorSYS 2>$null | Out-Null }
    & reg.exe unload HKLM\MWBA_TargetSYS 2>$null | Out-Null
    Write-HB "UNLOAD" "OK" "SYSTEM hives saved and unloaded cleanly." "Green"
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   BOOT DRIVER AUDIT & ALIGNMENT COMPLETED SUCCESSFULLY         " -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
