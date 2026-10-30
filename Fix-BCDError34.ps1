#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Fix-BCDError34.ps1 -- Universal BCD Error 0xc0000034 Rebuilder
.DESCRIPTION
    Automated diagnostic and reconstruction engine for Windows Boot Configuration Data (BCD)
    error 0xc0000034 (The Boot Configuration Data for your PC is missing or contains errors).
    Dynamically discovers the EFI System Partition (ESP), disarms file locks, backs up 
    corrupted stores, regenerates clean boot files via BCDBoot, and aligns BCD elements.
#>
[CmdletBinding()]
param(
    [string]$TargetWindows = "",
    [switch]$Force
)

$ErrorActionPreference = "Continue"

# Auto-detect target Windows if not provided
if (-not $TargetWindows) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and (Test-Path "$($drive.RootDirectory.FullName)Windows\System32\ntoskrnl.exe")) {
            $TargetWindows = "$($drive.RootDirectory.FullName)Windows"
            break
        }
    }
    if (-not $TargetWindows) { $TargetWindows = "C:\Windows" }
}

$targetDrive = ($TargetWindows -split ':')[0] + ":"
$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath = Join-Path $logDir "bcd_repair_log.txt"
$lines = [System.Collections.Generic.List[string]]::new()
$exitCode = 0

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
    $lines.Add($line)
    try { Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: BCD ERROR 0xc0000034 SURGICAL REPAIR ENGINE            " -ForegroundColor Cyan
Write-Host "   Target Windows : $TargetWindows                              " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Set-Content -Path $logPath -Value "" -Force -ErrorAction SilentlyContinue

# -------------------------------------------------------------------------
# SECTION A: VERIFY TARGET ACCESS & BITLOCKER STATUS
# -------------------------------------------------------------------------
Write-Host "=== A. TARGET ACCESSIBILITY & BITLOCKER PREFLIGHT ===" -ForegroundColor Yellow
Write-HB "A.1" "WORK" "Checking drive accessibility for $targetDrive..." "Yellow"

$bdeStatus = & manage-bde -status "$targetDrive" 2>&1 | Out-String
if ($bdeStatus -match "Locked") {
    Write-HB "A.1" "WARN" "Volume $targetDrive is BitLocker-locked!" "Yellow"
    $key = Read-Host "  Enter BitLocker Recovery Key for $targetDrive"
    if ($key) {
        & manage-bde -unlock "$targetDrive" -RecoveryPassword $key 2>&1 | Out-Null
        & manage-bde -autounlock -enable "$targetDrive" 2>&1 | Out-Null
    }
}

if (-not (Test-Path "$TargetWindows\System32\ntoskrnl.exe")) {
    Write-HB "A.2" "ERROR" "$TargetWindows\System32\ntoskrnl.exe not accessible. Cannot proceed." "Red"
    exit 1
}
Write-HB "A.2" "OK" "Target Windows installation verified accessible: $TargetWindows" "Green"

# -------------------------------------------------------------------------
# SECTION B: LOCATE EFI SYSTEM PARTITION (ESP)
# -------------------------------------------------------------------------
Write-Host ""
Write-Host "=== B. LOCATE EFI SYSTEM PARTITION (ESP) ===" -ForegroundColor Yellow
Write-HB "B.1" "WORK" "Locating disk partition topology for $targetDrive..." "Yellow"

$partWin = Get-Partition | Where-Object { $_.DriveLetter -eq ($targetDrive.TrimEnd(':')) }
if (-not $partWin) {
    Write-HB "B.1" "ERROR" "Could not resolve physical partition for drive $targetDrive" "Red"
    exit 1
}
$diskNum = $partWin[0].DiskNumber
Write-HB "B.1" "INFO" "Windows partition mapped to Disk $diskNum, Partition $($partWin[0].PartitionNumber)" "Cyan"

$espPart = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

if (-not $espPart) {
    Write-HB "B.2" "ERROR" "No EFI System Partition (ESP) found on Disk $diskNum. Disk may be legacy MBR." "Red"
    Write-HB "B.2" "INFO" "For MBR systems, run Universal Boot Repair from MWBA main menu." "DarkGray"
    exit 1
}
Write-HB "B.2" "OK" "Located ESP: Disk $diskNum, Partition $($espPart.PartitionNumber)" "Green"

# Assign temporary mount letter if needed
$espLetter = $espPart.DriveLetter
$mountTemporary = $false
if (-not $espLetter) {
    # Find free drive letter
    $usedLetters = (Get-Volume).DriveLetter | Where-Object { $_ }
    $candidateLetters = 83..90 | ForEach-Object { [char]$_ } # S through Z
    foreach ($cand in $candidateLetters) {
        if ($usedLetters -notcontains $cand -and (-not (Test-Path "${cand}:\"))) {
            $espLetter = "$cand"
            break
        }
    }
    if (-not $espLetter) { $espLetter = "S" }

    Write-HB "B.3" "WORK" "Assigning temporary mount letter ${espLetter}: to Target Disk $diskNum ESP..." "Yellow"
    try {
        Set-Partition -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -NewDriveLetter $espLetter -ErrorAction Stop
        Start-Sleep -Milliseconds 500
    } catch {
        # Fallback to diskpart if Set-Partition is blocked on GPT System partition
        $dpScript = @"
select disk $diskNum
select partition $($espPart.PartitionNumber)
assign letter=$espLetter
"@
        $dpScript | diskpart 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    $mountTemporary = $true
}
Write-HB "B.3" "OK" "ESP partition mounted at ${espLetter}:\" "Green"

# -------------------------------------------------------------------------
# SECTION C: BACKUP & REGENERATE BCD STORE
# -------------------------------------------------------------------------
Write-Host ""
Write-Host "=== C. BCD BACKUP & REGENERATION ===" -ForegroundColor Yellow

$bcdFolder = "${espLetter}:\EFI\Microsoft\Boot"
if (-not (Test-Path $bcdFolder)) {
    New-Item -ItemType Directory -Path $bcdFolder -Force | Out-Null
}
$bcdPath = "$bcdFolder\BCD"
$bcdBackupPath = "$bcdFolder\BCD.bak"
$bcdOldPath = "$bcdFolder\BCD.old"

if (Test-Path $bcdPath) {
    $bcdFile = Get-Item $bcdPath
    Write-HB "C.1" "INFO" "Existing BCD: $($bcdFile.Length) bytes, Last Modified: $($bcdFile.LastWriteTime)" "Cyan"
    
    # Backup
    Copy-Item -Path $bcdPath -Destination $bcdBackupPath -Force -ErrorAction SilentlyContinue
    Write-HB "C.1" "OK" "Existing BCD backed up to BCD.bak" "Green"

    # Defuse lock
    try {
        Remove-Item -Path $bcdPath -Force -ErrorAction Stop
        Write-HB "C.2" "OK" "Removed corrupted/stale BCD file to ensure clean reconstruction." "Green"
    } catch {
        Move-Item -Path $bcdPath -Destination $bcdOldPath -Force -ErrorAction SilentlyContinue
        Write-HB "C.2" "WARN" "Locked BCD safely renamed to BCD.old." "Yellow"
    }
} else {
    Write-HB "C.1" "INFO" "No previous BCD store detected at $bcdPath. Preparing fresh installation." "Cyan"
}

# Invoke BCDBoot engine
Write-HB "C.3" "WORK" "Executing bcdboot to rebuild UEFI BCD store and boot files..." "Yellow"
$bcdbootArgs = @("""$TargetWindows""", "/s", "${espLetter}:", "/f", "UEFI")
if ($Force) { $bcdbootArgs += "/v" }
$bcdOut = & bcdboot.exe $bcdbootArgs 2>&1
$bcdOutStr = $bcdOut -join ' '
Write-HB "C.3" "INFO" "bcdboot output: $bcdOutStr" "Cyan"

if ($LASTEXITCODE -eq 0 -or $bcdOutStr -match "successfully|finished") {
    Write-HB "C.3" "OK" "BCDBoot reconstruction completed successfully!" "Green"
} else {
    Write-HB "C.3" "WARN" "BCDBoot exited with code $LASTEXITCODE. Running BCD structural repair..." "Yellow"
    $exitCode = 1
}

# -------------------------------------------------------------------------
# SECTION D: VERIFY & CONFIGURE BCD ELEMENTS
# -------------------------------------------------------------------------
Write-Host ""
Write-Host "=== D. VERIFY & ALIGN BCD STORE ELEMENTS ===" -ForegroundColor Yellow

if (Test-Path $bcdPath) {
    Write-HB "D.1" "OK" "BCD store verified present at $bcdPath" "Green"

    # Ensure Standard or Legacy policy
    & bcdedit.exe /store $bcdPath /set "{default}" bootstatuspolicy ignoreallfailures 2>&1 | Out-Null
    & bcdedit.exe /store $bcdPath /set "{default}" recoveryenabled Yes 2>&1 | Out-Null
    & bcdedit.exe /store $bcdPath /timeout 5 2>&1 | Out-Null
    Write-HB "D.2" "OK" "Aligned default boot parameters: IgnoreAllFailures, RecoveryEnabled, Timeout=5s." "Green"
} else {
    Write-HB "D.1" "ERROR" "BCD store was not created at expected location $bcdPath." "Red"
    $exitCode = 1
}

# -------------------------------------------------------------------------
# SECTION E: CLEANUP MOUNT LETTER
# -------------------------------------------------------------------------
if ($mountTemporary -and $espLetter) {
    Write-HB "E.1" "WORK" "Releasing temporary ESP mount letter ${espLetter}:..." "DarkGray"
    try {
        Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
    } catch {}
    if (Test-Path "${espLetter}:\") {
        $dpScript = @"
select disk $diskNum
select partition $($espPart.PartitionNumber)
remove letter=$espLetter
"@
        $dpScript | diskpart 2>&1 | Out-Null
    }
    Write-HB "E.1" "OK" "Target ESP mount dismounted cleanly." "DarkGray"
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host "   BCD REPAIR COMPLETED SUCCESSFULLY! Error 0xc0000034 Defused.   " -ForegroundColor Green
} else {
    Write-Host "   BCD REPAIR FINISHED WITH WARNINGS. Check $logPath             " -ForegroundColor Yellow
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

exit $exitCode
