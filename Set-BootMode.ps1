#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Set-BootMode.ps1 -- Universal BCD Boot Mode Configurator
.DESCRIPTION
    Configures the boot mode of an offline or local Windows installation:
    - Normal: Clears safeboot, test-signing, and integrity check flags for a normal clean boot.
    - SafeNetwork: Configures BCD to boot into Safe Mode with Networking support.
    - SafeMinimal: Configures BCD to boot into minimal Safe Mode.
    - Enables verbose boot logging (sos / bootlog) to generate ntbtlog.txt for post-mortem diagnostics.
#>
[CmdletBinding()]
param(
    [string]$TargetDrive = "",
    [ValidateSet('Normal', 'SafeNetwork', 'SafeMinimal')][string]$Mode = 'Normal',
    [switch]$DisableBootLog
)

$ErrorActionPreference = "Continue"

# Dynamic Target Resolution
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

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: BCD BOOT MODE CONFIGURATOR                             " -ForegroundColor Cyan
Write-Host "   Target Volume : $cleanDrive                                   " -ForegroundColor Cyan
Write-Host "   Selected Mode : $Mode                                         " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path "$cleanDrive\Windows\System32")) {
    Write-Host "[-] Target volume $cleanDrive is not accessible!" -ForegroundColor Red
    exit 1
}

# Locate physical partition & ESP
$partLetter = $cleanDrive.TrimEnd(':')
$partWin = Get-Partition | Where-Object { $_.DriveLetter -eq $partLetter }
if (-not $partWin) {
    Write-Host "[-] Could not find physical partition for $cleanDrive" -ForegroundColor Red
    exit 1
}

$diskNum = $partWin[0].DiskNumber
$espPart = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

if (-not $espPart) {
    Write-Host "[-] No EFI System Partition found on Disk $diskNum (system may be legacy MBR)." -ForegroundColor Yellow
    exit 1
}

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
    } catch {
        Write-Host "[-] Could not assign drive letter to ESP: $_" -ForegroundColor Red
        exit 1
    }
}

$bcdStore = "${espLetter}:\EFI\Microsoft\Boot\BCD"
if (-not (Test-Path $bcdStore)) {
    Write-Host "[-] BCD store not found on ESP at $bcdStore!" -ForegroundColor Red
    if ($mountedHere) { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue }
    exit 1
}

try {
    switch ($Mode) {
        'Normal' {
            Write-Host "[>] Restoring Normal Clean Boot in BCD..." -ForegroundColor Yellow
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" safeboot 2>$null | Out-Null
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" safebootalternateshell 2>$null | Out-Null
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" testsigning 2>$null | Out-Null
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" nointegritychecks 2>$null | Out-Null
            if (-not $DisableBootLog) {
                & bcdedit.exe /store "$bcdStore" /set "{default}" bootlog Yes 2>&1 | Out-Null
                & bcdedit.exe /store "$bcdStore" /set "{default}" sos Yes 2>&1 | Out-Null
            }
            Write-Host "[+] Normal Clean Boot configured successfully." -ForegroundColor Green
        }
        'SafeNetwork' {
            Write-Host "[>] Configuring Safe Mode with Networking in BCD..." -ForegroundColor Yellow
            & bcdedit.exe /store "$bcdStore" /set "{default}" safeboot network 2>&1 | Out-Null
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" safebootalternateshell 2>$null | Out-Null
            if (-not $DisableBootLog) {
                & bcdedit.exe /store "$bcdStore" /set "{default}" bootlog Yes 2>&1 | Out-Null
                & bcdedit.exe /store "$bcdStore" /set "{default}" sos Yes 2>&1 | Out-Null
            }
            Write-Host "[+] Safe Mode (with Networking) configured successfully." -ForegroundColor Green
        }
        'SafeMinimal' {
            Write-Host "[>] Configuring Minimal Safe Mode in BCD..." -ForegroundColor Yellow
            & bcdedit.exe /store "$bcdStore" /set "{default}" safeboot minimal 2>&1 | Out-Null
            & bcdedit.exe /store "$bcdStore" /deletevalue "{default}" safebootalternateshell 2>$null | Out-Null
            if (-not $DisableBootLog) {
                & bcdedit.exe /store "$bcdStore" /set "{default}" bootlog Yes 2>&1 | Out-Null
                & bcdedit.exe /store "$bcdStore" /set "{default}" sos Yes 2>&1 | Out-Null
            }
            Write-Host "[+] Minimal Safe Mode configured successfully." -ForegroundColor Green
        }
    }
} finally {
    if ($mountedHere) {
        Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $espPart.PartitionNumber -AccessPath "${espLetter}:\" -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "   BOOT MODE UPDATE COMPLETE                                    " -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
