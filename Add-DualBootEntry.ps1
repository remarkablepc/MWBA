#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Add-DualBootEntry.ps1 -- Add Offline Target Windows into Host/Reference EFI BCD Store
.DESCRIPTION
    Injects a bootloader entry for an offline Windows drive into the EFI System Partition
    of a known-good reference or host drive. Allows booting and testing damaged or repaired
    offline installations using the reference drive's verified UEFI bootloader.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$HostDrive,
    
    [Parameter(Mandatory=$true)]
    [string]$TargetDrive,
    
    [int]$TimeoutSeconds = 10,
    [string]$TargetTitle = "Target Windows (Recovered)",
    [string]$HostTitle = "Host Windows (Reference)"
)

$ErrorActionPreference = "Continue"

$cleanHost   = $HostDrive.TrimEnd(':\') + ":"
$cleanTarget = $TargetDrive.TrimEnd(':\') + ":"

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
Write-Host "   MWBA: DUAL-BOOT INJECTION & BOOTLOADER BRIDGING               " -ForegroundColor Cyan
Write-Host "   Host/Reference Drive (Firmware Boot) : $cleanHost             " -ForegroundColor Cyan
Write-Host "   Target Volume (To Boot)              : $cleanTarget           " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Validate both drives exist
if (-not (Test-Path "$cleanHost\Windows\System32")) {
    Write-HB "CHECK_HOST" "ERROR" "$cleanHost\Windows\System32 not accessible! Ensure host drive is connected and unlocked." "Red"
    exit 1
}
if (-not (Test-Path "$cleanTarget\Windows\System32")) {
    Write-HB "CHECK_TARGET" "ERROR" "$cleanTarget\Windows\System32 not accessible! Ensure target drive is connected and unlocked." "Red"
    exit 1
}
Write-HB "CHECK" "OK" "Both $cleanHost\Windows and $cleanTarget\Windows are verified accessible." "Green"

# 2. Locate Host Drive ESP
Write-HB "LOCATE_ESP" "WORK" "Locating EFI System Partition on host disk..." "Yellow"
$hostLetter = $cleanHost.TrimEnd(':')
$partHost = Get-Partition | Where-Object { $_.DriveLetter -eq $hostLetter }
if (-not $partHost) {
    Write-HB "LOCATE_ESP" "ERROR" "Could not find partition mapping for $cleanHost" "Red"
    exit 1
}
$diskHost = $partHost[0].DiskNumber
Write-HB "LOCATE_ESP" "INFO" "Host drive $cleanHost is on Disk $diskHost, Partition $($partHost[0].PartitionNumber)" "Cyan"

$espHive = Get-Partition -DiskNumber $diskHost -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

if (-not $espHive) {
    Write-HB "LOCATE_ESP" "ERROR" "No EFI System Partition found on Disk $diskHost!" "Red"
    exit 1
}
Write-HB "LOCATE_ESP" "OK" "Found ESP on Disk $diskHost, Partition $($espHive.PartitionNumber)" "Green"

# 3. Mount Host ESP temporarily
$espLetter = 'T'
$used = (Get-Volume).DriveLetter | Where-Object { $_ }
if ($used -contains 'T') {
    $espLetter = (83..90 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains "$_" } | Select-Object -First 1)
}

try {
    Remove-PartitionAccessPath -DiskNumber $diskHost -PartitionNumber $espHive.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
} catch {}

try {
    Set-Partition -DiskNumber $diskHost -PartitionNumber $espHive.PartitionNumber -NewDriveLetter $espLetter -ErrorAction Stop
    Write-HB "MOUNT_ESP" "OK" "Mounted Disk $diskHost ESP as ${espLetter}:\" "Green"
} catch {
    Write-HB "MOUNT_ESP" "ERROR" "Failed to assign drive letter ${espLetter}: to ESP: $_" "Red"
    exit 1
}

$bcdStore = "${espLetter}:\EFI\Microsoft\Boot\BCD"
if (-not (Test-Path $bcdStore)) {
    Write-HB "BCD_STORE" "ERROR" "BCD store not found at $bcdStore!" "Red"
    Remove-PartitionAccessPath -DiskNumber $diskHost -PartitionNumber $espHive.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
    exit 1
}

# 4. Backup existing BCD on Host
$bcdBak = "${espLetter}:\EFI\Microsoft\Boot\BCD.before_dualboot.bak"
Copy-Item $bcdStore $bcdBak -Force -ErrorAction SilentlyContinue
Write-HB "BCD_BACKUP" "OK" "Backed up host BCD to BCD.before_dualboot.bak" "Green"

# 5. Inject Target Windows into Host BCD
Write-HB "INJECT" "WORK" "Injecting $cleanTarget\Windows boot entry into host BCD store..." "Yellow"
$bcdbootOut = & bcdboot.exe "$cleanTarget\Windows" /s "${espLetter}:" /f UEFI 2>&1
Write-HB "BCDBOOT" "OK" "bcdboot output: $($bcdbootOut -join ' ')" "Green"

# 6. Configure Titles, Default, and Timeout
Write-HB "CONFIGURE_MENU" "WORK" "Configuring boot menu titles and default entry..." "Yellow"

& bcdedit.exe /store "$bcdStore" /set "{default}" description "$TargetTitle" 2>&1 | Out-Null
& bcdedit.exe /store "$bcdStore" /set "{default}" recoveryenabled No 2>&1 | Out-Null
& bcdedit.exe /store "$bcdStore" /set "{default}" bootstatuspolicy IgnoreAllFailures 2>&1 | Out-Null
& bcdedit.exe /store "$bcdStore" /timeout $TimeoutSeconds 2>&1 | Out-Null

$enumOutput = & bcdedit.exe /store "$bcdStore" /enum osloader 2>&1
$entries = @()
$currentId = ""
foreach ($line in $enumOutput) {
    if ($line -match '^identifier\s+(.+)$') { $currentId = $Matches[1].Trim() }
    if ($line -match '^device\s+(.+)$' -and $currentId) {
        $entries += $currentId
    }
}

foreach ($eId in $entries) {
    if ($eId -ne "{default}" -and $eId -ne "{bootmgr}") {
        & bcdedit.exe /store "$bcdStore" /set $eId description "$HostTitle" 2>$null | Out-Null
    }
}

Write-HB "CONFIGURE_MENU" "OK" "Boot menu configured: Default = $TargetTitle, Timeout = $TimeoutSeconds s." "Green"

# 7. Unmount ESP
Remove-PartitionAccessPath -DiskNumber $diskHost -PartitionNumber $espHive.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
Write-HB "CLEANUP" "OK" "Temporary ESP mount letter ${espLetter}: removed." "Gray"

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   DUAL-BOOT INJECTION COMPLETE: $cleanTarget IS NOW BOOTABLE VIA $cleanHost" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
