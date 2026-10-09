<#
.SYNOPSIS
    Restore-OfflineRegistry.ps1 - Restore Windows Registry Hives from Volume Shadow Copies (VSS) Offline.
.DESCRIPTION
    This script is designed for offline Windows repair. It runs on a technician PC, targets a mounted
    offline customer drive (e.g., F:), lists available Volume Shadow Copies on that drive, mounts a selected
    shadow copy using a symbolic link, backs up the current offline registry hives, and replaces them
    with the hives from the shadow copy.
.PARAMETER OfflineDrive
    The drive letter of the offline Windows volume (e.g., F:).
.EXAMPLE
    PowerShell -ExecutionPolicy Bypass -File .\Restore-OfflineRegistry.ps1 -OfflineDrive F:
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$OfflineDrive = ''
)

# Clear screen and show header
Clear-Host
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Offline Windows Registry Restore from VSS Snapshot v1.1" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

# 1. Administrator Preflight Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] This script MUST be run as Administrator." -ForegroundColor Red
    Write-Host "Please re-open PowerShell as Administrator and run the script again." -ForegroundColor Yellow
    Exit 1
}

# 2. Dynamic Target Resolution
if (-not $OfflineDrive) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and (Test-Path "$($drive.RootDirectory.FullName)Windows\System32\config\SYSTEM")) {
            if ($drive.RootDirectory.FullName -notmatch "^C:\\" -or -not $OfflineDrive) {
                $OfflineDrive = $drive.Name.TrimEnd('\')
                if ($drive.RootDirectory.FullName -notmatch "^C:\\") { break }
            }
        }
    }
    if (-not $OfflineDrive) { $OfflineDrive = "E:" }
}

$OfflineDrive = $OfflineDrive.TrimEnd('\').TrimEnd(':') + ":"
Write-Host "[INFO] Target offline drive: $OfflineDrive" -ForegroundColor Gray

if (-not (Get-PSDrive -Name $OfflineDrive.TrimEnd(':') -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Target drive $OfflineDrive is not mounted or not accessible." -ForegroundColor Red
    $drives = Get-PSDrive -PSProvider FileSystem | Sort-Object Name
    Write-Host "Available drives: $([string]::Join(', ', ($drives | ForEach-Object { $_.Name + ':' })))" -ForegroundColor Yellow
    Exit 1
}

$systemHivePath = Join-Path $OfflineDrive "Windows\System32\config\SYSTEM"
if (-not (Test-Path $systemHivePath)) {
    Write-Host "[ERROR] Could not find Windows installation on $OfflineDrive." -ForegroundColor Red
    Write-Host "Ensure the drive is mapped correctly and $OfflineDrive\Windows\System32\config\SYSTEM exists." -ForegroundColor Yellow
    Exit 1
}
Write-Host "[OK] Located Windows installation on $OfflineDrive." -ForegroundColor Green

# 3. Query VSS Shadow Copies on Offline Drive
Write-Host "[INFO] Querying Volume Shadow Copies for $OfflineDrive..." -ForegroundColor Gray
$rawShadows = vssadmin list shadows /for="$OfflineDrive" 2>&1 | Out-String

# Parse shadows using regex
$shadowList = @()
$blocks = $rawShadows -split "(?=Contents of Shadow Copy ID:)"
foreach ($block in $blocks) {
    if ($block -match 'Shadow Copy Volume: (\\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy\d+)' -and $block -match 'Creation Time: (.*)') {
        $shadowList += [PSCustomObject]@{
            Volume = $Matches[1]
            CreationTime = $Matches[2].Trim()
        }
    }
}

if ($shadowList.Count -eq 0) {
    Write-Host "[WARN] No Volume Shadow Copies found for $OfflineDrive." -ForegroundColor Yellow
    Write-Host "Make sure the VSS service is running, and that the drive contains restore points." -ForegroundColor Yellow
    Write-Host "Note: If the drive was reformatted or has no snapshots, manual VSS restore is not possible." -ForegroundColor Yellow
    Exit 1
}

# 4. Display Shadow Copies & Prompt Selection
Write-Host "`nAvailable Shadow Copies / Restore Points on $OfflineDrive`:" -ForegroundColor Cyan
Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
for ($i = 0; $i -lt $shadowList.Count; $i++) {
    Write-Host "[$i] Date/Time: $($shadowList[$i].CreationTime)" -ForegroundColor White
    Write-Host "    Volume Path: $($shadowList[$i].Volume)" -ForegroundColor Gray
}
Write-Host "--------------------------------------------------------" -ForegroundColor Cyan

$selectedIndex = -1
while ($selectedIndex -lt 0 -or $selectedIndex -ge $shadowList.Count) {
    $input = Read-Host "Select a snapshot to restore (0-$($shadowList.Count - 1))"
    if ($input -match '^\d+$') {
        $selectedIndex = [int]$input
    } else {
        Write-Host "Invalid input. Please enter a number." -ForegroundColor Yellow
    }
}

$selectedShadow = $shadowList[$selectedIndex]
Write-Host "`n[OK] Selected snapshot from $($selectedShadow.CreationTime)" -ForegroundColor Green

# 5. Create Mount Point
$mountPoint = Join-Path $OfflineDrive "ShadowCopy_Mount"
if (Test-Path $mountPoint) {
    Write-Host "[INFO] Cleaning up existing temporary mount folder..." -ForegroundColor Gray
    # Try to remove standard way
    try {
        Remove-Item -Path $mountPoint -Force -Recurse -ErrorAction SilentlyContinue
    } catch {}
    if (Test-Path $mountPoint) {
        cmd.exe /c rmdir "$mountPoint" 2>$null | Out-Null
    }
}

Write-Host "[INFO] Creating temporary link $mountPoint -> $($selectedShadow.Volume)\" -ForegroundColor Gray
# mklink /d expects globalroot paths with a trailing backslash to mount the volume root
cmd.exe /c mklink /d "$mountPoint" "$($selectedShadow.Volume)\" 2>&1 | Out-String

if (-not (Test-Path $mountPoint)) {
    Write-Host "[ERROR] Failed to mount shadow copy volume. Ensure cmd.exe has admin rights." -ForegroundColor Red
    Exit 1
}

# 6. Validate Source Files inside Shadow Copy
$srcConfig = Join-Path $mountPoint "Windows\System32\config"
$hives = @("SYSTEM", "SOFTWARE", "SAM", "SECURITY", "DEFAULT")
$missingHives = @()

foreach ($h in $hives) {
    $p = Join-Path $srcConfig $h
    if (-not (Test-Path $p)) {
        $missingHives += $h
    }
}

if ($missingHives.Count -gt 0) {
    Write-Host "[ERROR] The selected shadow copy is incomplete. Missing registry hives: $($missingHives -join ', ')." -ForegroundColor Red
    Write-Host "Cleaning up mount point..." -ForegroundColor Gray
    cmd.exe /c rmdir "$mountPoint"
    Exit 1
}
Write-Host "[OK] Verified registry hives exist in shadow copy." -ForegroundColor Green

# 7. Backup Current Registry Hives
$destConfig = Join-Path $OfflineDrive "Windows\System32\config"
$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$backupFolder = Join-Path $destConfig "Backup_Before_VSS_Restore_$timestamp"

Write-Host "[INFO] Creating registry backup folder: $backupFolder" -ForegroundColor Gray
New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

foreach ($h in $hives) {
    $srcFile = Join-Path $destConfig $h
    $destFile = Join-Path $backupFolder $h
    if (Test-Path $srcFile) {
        Write-Host "   Backing up current $h..." -ForegroundColor Gray
        Copy-Item -Path $srcFile -Destination $destFile -Force
    }
}
Write-Host "[OK] Current registry hives backed up successfully." -ForegroundColor Green

# 8. Restore Registry Hives
Write-Host "`n[WARNING] You are about to replace the active registry hives on $OfflineDrive with the selected backup hives." -ForegroundColor Yellow
Write-Host "This operation will overwrite the current SYSTEM, SOFTWARE, SAM, SECURITY, and DEFAULT hives." -ForegroundColor Yellow
$confirm = Read-Host "Type 'YES' to proceed"
if ($confirm -ne 'YES') {
    Write-Host "[INFO] Restore aborted by user. Cleaning up mount..." -ForegroundColor Yellow
    cmd.exe /c rmdir "$mountPoint"
    Exit 0
}

Write-Host "[INFO] Restoring hives..." -ForegroundColor White
$success = $true
foreach ($h in $hives) {
    $srcFile = Join-Path $srcConfig $h
    $destFile = Join-Path $destConfig $h
    try {
        Write-Host "   Restoring $h..." -ForegroundColor White
        Copy-Item -Path $srcFile -Destination $destFile -Force
    } catch {
        Write-Host "[ERROR] Failed to restore hive ${h}: $($_.Exception.Message)" -ForegroundColor Red
        $success = $false
    }
}

# 9. Cleanup Mount
Write-Host "[INFO] Cleaning up temporary mount link..." -ForegroundColor Gray
cmd.exe /c rmdir "$mountPoint" 2>$null | Out-Null
if (Test-Path $mountPoint) {
    Remove-Item -Path $mountPoint -Force -Recurse -ErrorAction SilentlyContinue
}

# 10. Final Status and Guide
if ($success) {
    Write-Host "`n==============================================================" -ForegroundColor Green
    Write-Host "  REGISTRY RESTORE COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host "The registry hives have been reverted to: $($selectedShadow.CreationTime)" -ForegroundColor White
    Write-Host "A backup of your previous hives was saved to:" -ForegroundColor Gray
    Write-Host "  $backupFolder" -ForegroundColor Gray
    Write-Host "`nTo rollback if needed, run as Admin:" -ForegroundColor Yellow
    foreach ($h in $hives) {
        Write-Host "  Copy-Item -Path '$backupFolder\$h' -Destination '$destConfig\$h' -Force" -ForegroundColor Yellow
    }
    Write-Host "`nNext Steps:" -ForegroundColor White
    Write-Host "1. Run 'Sync-BootDrivers.ps1 -TargetDrive $OfflineDrive' to verify boot driver start values." -ForegroundColor White
    Write-Host "2. Run 'MWBA.bat' or test booting the disk using 'Test-BootInVM.ps1'." -ForegroundColor White
} else {
    Write-Host "[ERROR] Registry restore finished with errors. Please check the logs." -ForegroundColor Red
}
