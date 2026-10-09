#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Test-BootInVM.ps1 -- Hyper-V Pass-Through VM Smoke Test Harness
.DESCRIPTION
    Spins up a temporary Hyper-V Generation 2 virtual machine with UEFI Secure Boot
    to test booting a physical repaired disk directly on the technician bench host
    without having to physically remount the drive into the customer's machine.
    
    Automatically takes the disk offline for host access, attaches it to the VM,
    launches the vmconnect display console, and upon closing tears down the VM
    and brings the disk safely back online for the host.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [int]$DiskNumber,
    
    [string]$VmName = "MWBA-BootTest-VM",
    [int]$RamMB = 4096,
    [string]$TargetVolumeToUnlock = "",
    [string]$BitLockerKey = ""
)

$ErrorActionPreference = "Continue"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: HYPER-V PASS-THROUGH DISK BOOT SMOKE TEST              " -ForegroundColor Cyan
Write-Host "   Target Physical Disk : $DiskNumber                           " -ForegroundColor Cyan
Write-Host "   Virtual Machine Name : $VmName                               " -ForegroundColor Cyan
Write-Host "   Allocated Memory     : $RamMB MB                             " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# 0. Safety Guard: Do not allow taking the host OS boot drive offline!
$hostBootDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue).DiskNumber
if ($DiskNumber -eq $hostBootDisk) {
    Write-Host "[-] SAFETY HALT: Physical Disk $DiskNumber is the live host system drive ($env:SystemDrive)." -ForegroundColor Red
    Write-Host "    Cannot take the running host operating system drive offline!" -ForegroundColor Red
    exit 1
}

# 1. Clean previous VM instance if exists
$oldVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($oldVm) {
    Write-Host "[*] Removing previous VM instance $VmName..." -ForegroundColor Gray
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
}

# 2. Set target physical disk offline for Hyper-V pass-through
Write-Host "[>] Setting Physical Disk $DiskNumber to Offline for VM pass-through..." -ForegroundColor Yellow
try {
    Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
    Write-Host "[+] Disk $DiskNumber is now Offline for host OS." -ForegroundColor Green
} catch {
    Write-Host "[-] Failed to set Disk $DiskNumber offline: $_" -ForegroundColor Red
    exit 1
}

try {
    # 3. Create Gen 2 VM
    Write-Host "[>] Creating Generation 2 Virtual Machine..." -ForegroundColor Yellow
    $switch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name
    if (-not $switch) { $switch = "Default Switch" }

    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($RamMB * 1MB) -SwitchName $switch | Out-Null
    Set-VM -Name $VmName -ProcessorCount 2 -CheckpointType Disabled | Out-Null
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false | Out-Null
    $hdd = Add-VMHardDiskDrive -VMName $VmName -DiskNumber $DiskNumber -Passthru
    try {
        Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows" -FirstBootDevice $hdd | Out-Null
        Write-Host "[+] Gen 2 VM created with physical disk pass-through and Secure Boot ON." -ForegroundColor Green
    } catch {
        Set-VMFirmware -VMName $VmName -EnableSecureBoot Off -FirstBootDevice $hdd -ErrorAction SilentlyContinue | Out-Null
        Write-Host "[!] Secure Boot template not supported by host. Secure Boot disabled." -ForegroundColor Yellow
    }

    # 4. Start VM & vmconnect console
    Write-Host "[>] Starting Virtual Machine..." -ForegroundColor Yellow
    Start-VM -Name $VmName -ErrorAction Stop
    Write-Host "[+] VM $VmName is RUNNING and booting from Disk $DiskNumber!" -ForegroundColor Green

    Write-Host "[*] Opening Hyper-V VM Console (vmconnect)..." -ForegroundColor Cyan
    $vmcProc = Start-Process "vmconnect.exe" -ArgumentList "localhost $VmName" -PassThru

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Green
    Write-Host "   SMOKE TEST IS LIVE!                                           " -ForegroundColor Green
    Write-Host "   Close the VM Console window when you are done testing.        " -ForegroundColor Yellow
    Write-Host "   The VM will automatically be cleaned up and disk restored!    " -ForegroundColor Yellow
    Write-Host "=================================================================" -ForegroundColor Green

    if ($vmcProc) {
        $vmcProc.WaitForExit()
        Write-Host "`n[*] VM Console closed. Cleaning up VM and restoring host access..." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[-] Hyper-V Smoke Test error: $_" -ForegroundColor Red
} finally {
    # 5. Cleanup VM & restore disk online
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue

    Write-Host "[>] Restoring Physical Disk $DiskNumber to Online on host..." -ForegroundColor Yellow
    Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
    Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    if ($TargetVolumeToUnlock -and $BitLockerKey) {
        try {
            & manage-bde -unlock "$TargetVolumeToUnlock" -RecoveryPassword $BitLockerKey 2>&1 | Out-Null
            & manage-bde -autounlock -enable "$TargetVolumeToUnlock" 2>&1 | Out-Null
            Write-Host "[+] BitLocker unlocked on $TargetVolumeToUnlock." -ForegroundColor Green
        } catch {}
    }

    Write-Host "[+] Physical Disk $DiskNumber is now back Online for the technician host." -ForegroundColor Green
    Write-Host ""
}
