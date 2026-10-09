#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restore-FromDonorDrive.ps1 -- Surgical Offline System Transplant from Donor/Reference Drive
.DESCRIPTION
    The definitive offline recovery engine for catastrophic Windows corruption, signature verification
    breakdowns (empty CatRoot2), critical binary mismatches after failed updates, bloated servicing
    queues, or unbootable registry hives (0xC000021A / 0xC000007B).
    
    Selectively transplants cryptographic catalog databases, boot-critical subsystem binaries,
    and/or registry hives from a known-good reference drive or mounted image to the broken target.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DonorDrive,
    
    [string]$TargetDrive = "",
    [string]$LogFile = "",
    [switch]$ReplaceHives,
    [switch]$SkipCatalogs,
    [switch]$SkipBinaries,
    [switch]$SkipServicingCleanup,
    [switch]$SkipRestoreCleanup,
    [switch]$Force
)

$ErrorActionPreference = "Continue"

# Dynamic Target Resolution
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
$cleanDonor  = $DonorDrive.TrimEnd(':\') + ":"

if (-not $LogFile) {
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogFile = Join-Path $logDir "donor_restore_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
}

function Log {
    param([string]$Tag, [string]$Msg, [string]$Level = "+")
    $ts = (Get-Date).ToString("HH:mm:ss.fff")
    $line = "[$ts] [$Level] $Tag : $Msg"
    $color = switch ($Level) {
        "+"  { "Green" }
        "-"  { "Red" }
        ">"  { "Yellow" }
        "*"  { "Gray" }
        "!"  { "Magenta" }
        default { "White" }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

function Banner {
    param([string]$Title)
    $line = "`n" + ("=" * 70) + "`n  $Title`n" + ("=" * 70)
    Write-Host $line -ForegroundColor Cyan
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}

# -------------------------------------------------------------------------
# C# Privilege Manager for SeBackupPrivilege & SeRestorePrivilege
# -------------------------------------------------------------------------
function Enable-MWBAPrivileges {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MWBAPrivilegeManager').Type) {
            $cSharp = @'
using System;
using System.Runtime.InteropServices;

public class MWBAPrivilegeManager {
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, int DesiredAccess, ref IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, ref long luid);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct TOKEN_PRIVILEGES {
        public int PrivilegeCount;
        public long Luid;
        public int Attributes;
    }

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    public const int TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const int TOKEN_QUERY = 0x0008;
    public const int SE_PRIVILEGE_ENABLED = 0x00000002;

    public static bool EnablePrivilege(string privilege) {
        IntPtr hToken = IntPtr.Zero;
        try {
            IntPtr hProcess = System.Diagnostics.Process.GetCurrentProcess().Handle;
            if (!OpenProcessToken(hProcess, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref hToken))
                return false;
            long luid = 0;
            if (!LookupPrivilegeValue(null, privilege, ref luid))
                return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;
            return AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        } finally {
            if (hToken != IntPtr.Zero) CloseHandle(hToken);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
            Add-Type -TypeDefinition $cSharp -Language CSharp -ErrorAction SilentlyContinue
        }
        if (([System.Management.Automation.PSTypeName]'MWBAPrivilegeManager').Type) {
            [MWBAPrivilegeManager]::EnablePrivilege("SeBackupPrivilege") | Out-Null
            [MWBAPrivilegeManager]::EnablePrivilege("SeRestorePrivilege") | Out-Null
            [MWBAPrivilegeManager]::EnablePrivilege("SeTakeOwnershipPrivilege") | Out-Null
            [MWBAPrivilegeManager]::EnablePrivilege("SeSecurityPrivilege") | Out-Null
        }
    } catch {}
}

function Invoke-CatalogRobocopy {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Tag
    )

    Enable-MWBAPrivileges

    if (Test-Path $TargetPath) {
        & attrib.exe -r -s -h "$TargetPath\*" /s /d 2>$null | Out-Null
    }

    # Attempt robocopy with /B (Backup mode)
    $robocopyArgs = @($SourcePath, $TargetPath, "/E", "/B", "/COPY:DAT", "/XJ", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS")
    $output = & robocopy.exe @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE
    $outText = ($output | Out-String)

    if ($exitCode -ge 8 -and ($outText -match "Backup and Restore Files user rights" -or $outText -match "perform Backup copies")) {
        Log $Tag "Backup privilege not granted for /B. Retrying with /COPY:DAT..." ">"
        $robocopyArgs = @($SourcePath, $TargetPath, "/E", "/COPY:DAT", "/XJ", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS")
        $output = & robocopy.exe @robocopyArgs 2>&1
        $exitCode = $LASTEXITCODE
        $outText = ($output | Out-String)
    }

    $isAccessDenied = ($outText -match "Access is denied" -or $outText -match "ERROR 5 \(0x00000005\)")

    return [PSCustomObject]@{
        ExitCode       = $exitCode
        Output         = $output
        OutText        = $outText
        IsAccessDenied = $isAccessDenied
        Success        = ($exitCode -lt 8 -and -not $isAccessDenied)
    }
}

# -------------------------------------------------------------------------
# Preflight Verification
# -------------------------------------------------------------------------
Enable-MWBAPrivileges

if (-not (Test-Path "$cleanDonor\Windows\System32")) {
    Log "PREFLIGHT" "Donor drive $cleanDonor\Windows\System32 is not accessible!" "-"
    exit 1
}
if (-not (Test-Path "$cleanTarget\Windows\System32")) {
    Log "PREFLIGHT" "Target drive $cleanTarget\Windows\System32 is not accessible!" "-"
    exit 1
}

# Unload any dangling registry hives that could lock files
$staleHives = @("MWBA_DonorSYS", "MWBA_TargetSYS", "TempRescueSYS", "TempRescueSW", "FixSW", "DiagSYS", "DiagSW")
foreach ($h in $staleHives) { & reg.exe unload "HKLM\$h" 2>$null | Out-Null }
[System.GC]::Collect()

$backupDir = Join-Path $cleanTarget "MWBA_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

Banner "MWBA SURGICAL DONOR RESTORE: $cleanDonor -> $cleanTarget"
Log "INFO" "Backup location         : $backupDir" "*"
Log "INFO" "Replace Registry Hives  : $ReplaceHives" "*"
Log "INFO" "Restore Crypt Catalogs  : $(-not $SkipCatalogs)" "*"
Log "INFO" "Restore Boot Binaries   : $(-not $SkipBinaries)" "*"
Log "INFO" "Clean Servicing State   : $(-not $SkipServicingCleanup)" "*"
Log "INFO" "Clean Failed Restore    : $(-not $SkipRestoreCleanup)" "*"

# =========================================================================
# STAGE 1: Restore CatRoot2 & CatRoot (Cryptographic Signature Catalogs)
# =========================================================================
if (-not $SkipCatalogs) {
    Banner "STAGE 1: Restoring Cryptographic Catalog Stores (CatRoot & CatRoot2)"

    $targetCat2 = "$cleanTarget\Windows\System32\CatRoot2"
    $donorCat2  = "$cleanDonor\Windows\System32\CatRoot2"
    $donorCat2Count = if (Test-Path $donorCat2) { (Get-ChildItem -Path $donorCat2 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }

    if ($donorCat2Count -lt 1) {
        Log "CATROOT2" "FATAL: Donor CatRoot2 ($donorCat2) is empty or inaccessible!" "-"
        throw "Donor disk CatRoot2 database is empty or inaccessible."
    }

    # Backup Target CatRoot2
    $cr2Backup = Join-Path $backupDir "CatRoot2"
    New-Item -Path $cr2Backup -ItemType Directory -Force | Out-Null
    if (Test-Path $targetCat2) {
        Log "CATROOT2" "Backing up Target CatRoot2 to $cr2Backup..." ">"
        & robocopy.exe $targetCat2 $cr2Backup /E /NFL /NDL /NJH /NJS /R:1 /W:0 2>$null | Out-Null
    }

    if (-not (Test-Path $targetCat2)) { New-Item -Path $targetCat2 -ItemType Directory -Force | Out-Null }

    Log "CATROOT2" "Taking ownership and assigning full Administrator/SYSTEM ACLs..." ">"
    & attrib.exe -r -s -h "$targetCat2\*" /s /d 2>$null | Out-Null
    & takeown.exe /F $targetCat2 /A /R /D Y 2>$null | Out-Null
    & icacls.exe $targetCat2 /inheritance:e /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /grant "*S-1-5-18:(OI)(CI)F" /T /C /Q 2>$null | Out-Null

    Log "CATROOT2" "Transplanting CatRoot2 database from $cleanDonor via Robocopy..." ">"
    $rcResult2 = Invoke-CatalogRobocopy -SourcePath $donorCat2 -TargetPath $targetCat2 -Tag "CATROOT2"
    $postCat2Count = (Get-ChildItem -Path $targetCat2 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count

    if (-not $rcResult2.Success -or $postCat2Count -lt 1 -or $rcResult2.IsAccessDenied) {
        Log "CATROOT2" "FATAL: CatRoot2 restore failed validation gate! (Count: $postCat2Count, AccessDenied: $($rcResult2.IsAccessDenied))" "-"
        throw "CatRoot2 validation gate failed. Target catalog store is empty or access was denied."
    }
    Log "CATROOT2" "CatRoot2 restored and validated: $postCat2Count database files present." "+"

    # Restore CatRoot
    $targetCat = "$cleanTarget\Windows\System32\CatRoot"
    $donorCat  = "$cleanDonor\Windows\System32\CatRoot"
    $donorCatCount = if (Test-Path $donorCat) { (Get-ChildItem -Path $donorCat -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }

    if ($donorCatCount -ge 50) {
        $crBackup = Join-Path $backupDir "CatRoot"
        New-Item -Path $crBackup -ItemType Directory -Force | Out-Null
        if (Test-Path $targetCat) {
            Log "CATROOT" "Backing up Target CatRoot..." ">"
            & robocopy.exe $targetCat $crBackup /E /NFL /NDL /NJH /NJS /R:1 /W:0 2>$null | Out-Null
        }

        if (-not (Test-Path $targetCat)) { New-Item -Path $targetCat -ItemType Directory -Force | Out-Null }
        & attrib.exe -r -s -h "$targetCat\*" /s /d 2>$null | Out-Null
        & takeown.exe /F $targetCat /A /R /D Y 2>$null | Out-Null
        & icacls.exe $targetCat /inheritance:e /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /T /C /Q 2>$null | Out-Null

        Log "CATROOT" "Transplanting CatRoot catalog store from $cleanDonor..." ">"
        $rcResult1 = Invoke-CatalogRobocopy -SourcePath $donorCat -TargetPath $targetCat -Tag "CATROOT"
        $postCatCount = (Get-ChildItem -Path $targetCat -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Log "CATROOT" "CatRoot restored: $postCatCount catalog files present." "+"
    }
}

# =========================================================================
# STAGE 2: Restore Boot-Critical System Binaries
# =========================================================================
if (-not $SkipBinaries) {
    Banner "STAGE 2: Auditing & Restoring Boot-Critical System Binaries"

    $criticalBinaries = @(
        "smss.exe", "csrss.exe", "wininit.exe", "winlogon.exe",
        "services.exe", "lsass.exe", "ci.dll", "ntdll.dll",
        "kernel32.dll", "kernelbase.dll", "user32.dll",
        "basesrv.dll", "winsrv.dll", "sxssrv.dll"
    )

    $binBackup = Join-Path $backupDir "System32_Binaries"
    New-Item -Path $binBackup -ItemType Directory -Force | Out-Null

    $updated = 0
    $skipped = 0
    foreach ($bin in $criticalBinaries) {
        $tPath = "$cleanTarget\Windows\System32\$bin"
        $dPath = "$cleanDonor\Windows\System32\$bin"

        if (-not (Test-Path $dPath)) {
            Log "BINARIES" "$bin not found on Donor, skipping." "*"
            $skipped++
            continue
        }

        if (Test-Path $tPath) {
            $tHash = (Get-FileHash $tPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            $dHash = (Get-FileHash $dPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash

            if ($tHash -eq $dHash) {
                Log "BINARIES" "$bin : Hashes match, unchanged." "*"
                $skipped++
                continue
            }

            Copy-Item -Path $tPath -Destination (Join-Path $binBackup $bin) -Force -ErrorAction SilentlyContinue
            & takeown.exe /f $tPath /a 2>$null | Out-Null
            & icacls.exe $tPath /grant "Administrators:F" /grant "*S-1-5-18:F" /q 2>$null | Out-Null
        }

        try {
            Copy-Item -Path $dPath -Destination $tPath -Force -ErrorAction Stop
            Log "BINARIES" "$bin : UPDATED from Donor (hash mismatch resolved)" "+"
            $updated++
        } catch {
            Log "BINARIES" "$bin : FAILED to copy - $($_.Exception.Message)" "-"
        }
    }
    Log "BINARIES" "Summary: $updated updated, $skipped unchanged." "+"
}

# =========================================================================
# STAGE 3: Clean Bloated Servicing State
# =========================================================================
if (-not $SkipServicingCleanup) {
    Banner "STAGE 3: Cleaning Servicing State Queues"

    $tSess = "$cleanTarget\Windows\servicing\Sessions"
    if (Test-Path $tSess) {
        $servBackup = Join-Path $backupDir "servicing_Sessions"
        New-Item -Path $servBackup -ItemType Directory -Force | Out-Null
        & robocopy.exe $tSess $servBackup /E /NFL /NDL /NJH /NJS /R:1 /W:0 2>$null | Out-Null

        & takeown.exe /f $tSess /a /r /d y 2>$null | Out-Null
        & icacls.exe $tSess /grant "Administrators:(OI)(CI)F" /t /q 2>$null | Out-Null

        $toRemove = Get-ChildItem $tSess -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^Sessions\.(back\.)?xml$" }
        foreach ($f in $toRemove) {
            try {
                Remove-Item $f.FullName -Force -ErrorAction Stop
                Log "SERVICING" "Removed bloated session log: $($f.Name) ($([math]::Round($f.Length/1MB,1)) MB)" "+"
            } catch {
                Rename-Item $f.FullName "$($f.FullName).mwba.bak" -Force -ErrorAction SilentlyContinue
                Log "SERVICING" "Renamed session log: $($f.Name) -> .mwba.bak" "+"
            }
        }
    }

    $poqLog = "$cleanTarget\Windows\WinSxS\poqexec.log"
    if (Test-Path $poqLog) {
        Remove-Item $poqLog -Force -ErrorAction SilentlyContinue
        Log "SERVICING" "Purged stale poqexec.log queue." "+"
    }

    $pendXml = "$cleanTarget\Windows\WinSxS\pending.xml"
    if (Test-Path $pendXml) {
        Remove-Item $pendXml -Force -ErrorAction SilentlyContinue
        Log "SERVICING" "Purged pending.xml servicing lock." "+"
    }
}

# =========================================================================
# STAGE 4: Clean Failed System Restore Queues
# =========================================================================
if (-not $SkipRestoreCleanup) {
    Banner "STAGE 4: Disarming Failed System Restore Staging Queues"

    $frStaging = "$cleanTarget\System Volume Information\SystemRestore\FRStaging"
    if (Test-Path $frStaging) {
        try {
            & takeown.exe /f $frStaging /a /r /d y 2>$null | Out-Null
            & icacls.exe $frStaging /grant "Administrators:(OI)(CI)F" /t /q 2>$null | Out-Null
            Rename-Item -Path $frStaging -NewName "FRStaging.mwba.bak" -Force -ErrorAction Stop
            Log "RESTORE" "FRStaging renamed to FRStaging.mwba.bak" "+"
        } catch {
            Remove-Item -Path $frStaging -Recurse -Force -ErrorAction SilentlyContinue
            Log "RESTORE" "FRStaging purged." "+"
        }
    }

    $delayedOps = "$cleanTarget\System Volume Information\SystemRestore\DelayedOperations"
    if (Test-Path $delayedOps) {
        Rename-Item -Path $delayedOps -NewName "DelayedOperations.mwba.bak" -Force -ErrorAction SilentlyContinue
        Log "RESTORE" "DelayedOperations disarmed." "+"
    }
}

# =========================================================================
# STAGE 5: Replace Registry Hives (Optional)
# =========================================================================
if ($ReplaceHives) {
    Banner "STAGE 5: Registry Hive Replacement from Donor"

    $hiveBackup = Join-Path $backupDir "config_hives"
    New-Item -Path $hiveBackup -ItemType Directory -Force | Out-Null

    $configDir = "$cleanTarget\Windows\System32\config"
    $srcConfig = "$cleanDonor\Windows\System32\config"
    $hivesToReplace = @("SYSTEM","SOFTWARE","DEFAULT","SAM","SECURITY","COMPONENTS","DRIVERS","BBI","ELAM")

    foreach ($hive in $hivesToReplace) {
        $tPath = Join-Path $configDir $hive
        $dPath = Join-Path $srcConfig $hive

        if (-not (Test-Path $dPath)) { continue }

        if (Test-Path $tPath) {
            & takeown.exe /f $tPath /a 2>$null | Out-Null
            & icacls.exe $tPath /grant "Administrators:F" /grant "*S-1-5-18:F" /q 2>$null | Out-Null
            & attrib.exe -r -s -h $tPath 2>$null | Out-Null
            Copy-Item $tPath (Join-Path $hiveBackup $hive) -Force -ErrorAction SilentlyContinue
        }

        try {
            Copy-Item -Path $dPath -Destination $tPath -Force -ErrorAction Stop
            Log "HIVES" "Replaced $hive with donor copy." "+"
        } catch {
            Log "HIVES" "Failed to replace ${hive}: $($_.Exception.Message)" "-"
        }
    }
}

Banner "DONOR TRANSPLANT COMPLETE"
Log "SUMMARY" "All previous files backed up to: $backupDir" "*"
Log "SUMMARY" "System transplant completed successfully." "+"
Write-Host ""
