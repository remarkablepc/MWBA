#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Audit-BootDrivers.ps1 -- MWBA Offline Boot Driver & Registry Safety Auditor
.DESCRIPTION
    Comprehensive offline Windows driver and service validator:
    - Mounts offline SYSTEM hive under HKLM\MWBA_OFFLINE_SYSTEM.
    - Audits all BOOT_START (Start=0) and SYSTEM_START (Start=1) drivers.
    - Resolves driver ImagePath entries, checking for missing files and suspicious hooks.
    - Verifies Authenticode signatures on critical boot drivers.
    - Scans DriverStore for candidate replacements when critical driver files are missing.
    - Generates a structured JSON assessment manifest with letter grades (A through F).
    - Creates automatic registry exports and undo .reg files before any changes.
    - In -Apply mode, safely demotes missing or corrupt boot drivers to Start=3 (Manual).
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$Target = '',

    [switch]$Apply,
    [switch]$DryRun,
    [switch]$SxSTrace,
    [string]$BackupPath = $null,
    [string]$ManifestOut = $null,
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   MWBA: OFFLINE BOOT DRIVER & REGISTRY SAFETY AUDITOR           " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# Runtime setup
$RunId = (Get-Date).ToString('yyyyMMddHHmmss')

# -------------------------------------------------------------------------
# Dynamic Target Resolution
# -------------------------------------------------------------------------
if (-not $Target) {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.IsReady -and (Test-Path "$($drive.RootDirectory.FullName)Windows\System32\config\SYSTEM")) {
            if ($drive.RootDirectory.FullName -notmatch "^C:\\" -or -not $Target) {
                $Target = Join-Path $drive.RootDirectory.FullName "Windows"
                if ($drive.RootDirectory.FullName -notmatch "^C:\\") { break }
            }
        }
    }
    if (-not $Target) { $Target = 'C:\Windows' }
}

try {
    $targetFull = [IO.Path]::GetFullPath($Target).TrimEnd('\')
} catch {
    $targetFull = $Target
}

# Safety check for live running OS
$sysRootFull = $null
if ($env:SystemRoot) { $sysRootFull = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\') }
$isLiveTarget = ($sysRootFull -and $targetFull -and ($targetFull -ieq $sysRootFull))
if ($isLiveTarget -and $Apply) {
    throw "Refusing to modify the live running system. Run against an offline volume or WinRE environment."
}

# Determine log and backup folders
if ($BackupPath -and $BackupPath -ne '') {
    $LogFolder = $BackupPath
} else {
    $targetDrive = Split-Path -Path $targetFull -Qualifier
    if (-not $targetDrive) { $targetDrive = "C:" }
    $LogFolder = Join-Path $PSScriptRoot "logs"
}
if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogFolder "DriverAudit_$RunId.log"

if (-not $ManifestOut -or $ManifestOut -eq '') {
    $ManifestOut = Join-Path $LogFolder "DriverAudit.Manifest.json"
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    switch ($Level) {
        'INFO'  { Write-Host $line -ForegroundColor White }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Write-Info { param($m) Write-Log -Level 'INFO' -Message $m }
function Write-Warn { param($m) Write-Log -Level 'WARN' -Message $m }
function Write-Err  { param($m) Write-Log -Level 'ERROR' -Message $m }
function Write-OK   { param($m) Write-Log -Level 'OK' -Message $m }

# Win32 C# Privilege Manager
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

$MountKey = 'HKLM\MWBA_OFFLINE_SYSTEM'
$script:Mounted = $false

function Load-OfflineHive {
    param([Parameter(Mandatory=$true)][string]$WindowsPath)
    $systemHive = Join-Path $WindowsPath 'System32\config\SYSTEM'
    
    Enable-MWBAPrivileges
    if (-not (Test-Path $systemHive -PathType Leaf)) {
        throw "SYSTEM hive not found at $systemHive. Ensure target path is valid."
    }

    # Binary integrity check
    try {
        $stream = [System.IO.File]::Open($systemHive, 'Open', 'Read', 'Read')
        $buf = New-Object byte[] 4
        $stream.Read($buf, 0, 4) | Out-Null
        $sig = [System.Text.Encoding]::ASCII.GetString($buf)
        $len = $stream.Length
        $stream.Close()
        if ($sig -ne 'regf') {
            throw "SYSTEM hive has invalid magic header '$sig' (expected 'regf'). File is corrupted."
        }
        if ($len -lt 51200) {
            Write-Warn "SYSTEM hive size is abnormally small ($len bytes) - possible truncation."
        }
    } catch {
        Write-Warn "Hive binary pre-check note: $($_.Exception.Message)"
    }

    & reg.exe unload "$MountKey" 2>$null | Out-Null
    Write-Info "Loading offline SYSTEM hive -> $MountKey"
    $out = & reg.exe load "$MountKey" "$systemHive" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to load hive: $($out -join ' ')" }
    $script:Mounted = $true
}

function Unload-OfflineHive {
    try {
        if ($script:Mounted) {
            Write-Info "Unloading offline hive $MountKey"
            [System.GC]::Collect()
            Start-Sleep -Seconds 1
            & reg.exe unload "$MountKey" 2>$null | Out-Null
            $script:Mounted = $false
        }
    } catch {
        Write-Warn "Failed to unload hive cleanly: $($_.Exception.Message)"
    }
}

function Get-ControlSetPath {
    $selectPath = "$MountKey\Select"
    $ctrlSets = @()
    try {
        $props = Get-ItemProperty -Path "Registry::$selectPath" -ErrorAction Stop
        if ($props.PSObject.Properties.Name -contains 'Current') {
            $fmt = '{0:000}' -f $props.Current
            $p = "$MountKey\ControlSet$fmt"
            if (Test-Path "Registry::$p") { $ctrlSets += $p }
        }
    } catch {}

    try {
        $all = Get-ChildItem -Path "Registry::$MountKey" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' }
        foreach ($a in $all) {
            $p = "$MountKey\$($a.PSChildName)"
            if ($ctrlSets -notcontains $p) { $ctrlSets += $p }
        }
    } catch {}

    if ($ctrlSets.Count -eq 0) {
        $cset1 = "$MountKey\ControlSet001"
        if (Test-Path "Registry::$cset1") { $ctrlSets += $cset1 }
    }
    return $ctrlSets
}

function Get-AssessmentGrade {
    param([int]$SuspiciousCount, [bool]$ControlSetFound)
    if (-not $ControlSetFound) { return 'U' }
    switch ($true) {
        { $SuspiciousCount -eq 0 }  { return 'A' }
        { $SuspiciousCount -le 2 }  { return 'B' }
        { $SuspiciousCount -le 5 }  { return 'C' }
        { $SuspiciousCount -le 10 } { return 'D' }
        default                     { return 'F' }
    }
}

function Resolve-DriverPath {
    param([string]$ImagePath, [string]$WindowsPath)
    if (-not $ImagePath) { return $null }
    $ipTrim = $ImagePath.Trim().Trim('"')
    $ipTrim = $ipTrim -replace '^(?:\\\\\?\\|\\\\\?\\GLOBALROOT\\)?\\?\??\\?', ''

    if ($ipTrim -match '(?i)SystemRoot') {
        $rel = $ipTrim -replace '(?i).*SystemRoot\\?', ''
        $candidate = Join-Path $WindowsPath $rel
        return $candidate
    }
    if ($ipTrim -notmatch '^[A-Za-z]:\\') {
        return (Join-Path "$WindowsPath\System32\drivers" $ipTrim)
    }
    if ($ipTrim -match '^[A-Za-z]:\\') {
        $rest = $ipTrim.Substring(2).TrimStart('\')
        $candidate = Join-Path $WindowsPath $rest
        if (Test-Path $candidate) { return $candidate }
        return $ipTrim
    }
    return $ipTrim
}

function Verify-DriverSignature {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return @{ Signed = $false; Reason = 'Missing' } }
    try {
        $sig = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction SilentlyContinue
        if ($sig -and $sig.SignerCertificate) {
            $trusted = ($sig.SignerCertificate.Subject -match 'Microsoft')
            return @{ Signed = ($sig.Status -eq 'Valid'); Status = "$($sig.Status)"; TrustedSigner = $trusted; Signer = $sig.SignerCertificate.Subject }
        } else {
            return @{ Signed = $false; Status = "$($sig.Status)"; Reason = 'No signer certificate' }
        }
    } catch {
        return @{ Signed = $false; Reason = $_.Exception.Message }
    }
}

function Find-InDriverStore {
    param([string]$FileName, [string]$WindowsPath)
    $repo = Join-Path $WindowsPath 'System32\DriverStore\FileRepository'
    if (-not (Test-Path $repo)) { return $null }
    try {
        return (Get-ChildItem -Path $repo -Recurse -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1)
    } catch { return $null }
}

function Export-ServiceRegKey {
    param([string]$ControlSet, [string]$ServiceName, [string]$OutFolder, [switch]$DryRun)
    $key = "$ControlSet\Services\$ServiceName"
    $fileName = "$($ServiceName)_$((Get-Date).ToString('yyyyMMddHHmmss')).reg"
    $outPath = Join-Path $OutFolder $fileName
    if ($DryRun) { return "DRYRUN: reg export $key -> $outPath" }
    try {
        if (-not (Test-Path $OutFolder)) { New-Item -Path $OutFolder -ItemType Directory -Force | Out-Null }
        $cmdOut = & reg.exe export "$key" "$outPath" /y 2>&1
        if ($LASTEXITCODE -eq 0) { return $outPath } else { return "ERROR: $($cmdOut -join ' ')" }
    } catch { return "ERROR: $($_.Exception.Message)" }
}

function Analyze-Drivers {
    param([string[]]$ControlSetPaths, [string]$WindowsPath)
    $findings = @()
    foreach ($csp in $ControlSetPaths) {
        Write-Info "Analyzing service drivers under $csp"
        $servicesPath = "$csp\Services"
        $keys = Get-ChildItem -Path "Registry::$servicesPath" -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            $props = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            $start = ($props.Start -as [int])
            if ($start -in @(0, 1)) {
                $img = $props.ImagePath
                $resolved = Resolve-DriverPath -ImagePath $img -WindowsPath $WindowsPath
                $fileExists = $false
                if ($resolved) { $fileExists = Test-Path $resolved }

                $suspicious = @()
                if (-not $resolved) { $suspicious += 'No ImagePath specified' }
                if ($resolved -and -not $fileExists) { $suspicious += 'Driver file missing from disk' }
                if ($img -and ($img -notmatch '\.sys$') -and ($img -notmatch '(?i)\\system32|\\drivers')) {
                    $suspicious += 'Non-standard ImagePath'
                }

                $sigInfo = $null
                if ($resolved -and $fileExists) {
                    $sigInfo = Verify-DriverSignature -FilePath $resolved
                    if ($sigInfo -and -not $sigInfo.Signed) { $suspicious += 'Unsigned driver binary' }
                }

                $risk = if ($suspicious.Count -gt 0) { 'High' } else { 'Low' }

                $entry = [ordered]@{
                    ControlSet        = $csp
                    Name              = $k.PSChildName
                    Start             = $start
                    ImagePath         = $img
                    ResolvedPath      = $resolved
                    FileExists        = $fileExists
                    Signature         = $sigInfo
                    Risk              = $risk
                    SuspiciousReasons = $suspicious
                    ActionTaken       = $null
                }
                $findings += $entry
            }
        }
    }
    return $findings
}

function Apply-DriverChanges {
    param([object[]]$Findings, [switch]$WhatIf)
    $actions = @()
    foreach ($f in $Findings) {
        if ($f.SuspiciousReasons.Count -gt 0) {
            $fullKey = "$($f.ControlSet)\Services\$($f.Name)"
            $cmd = "reg.exe add `"$fullKey`" /v Start /t REG_DWORD /d 3 /f"
            if ($WhatIf) {
                Write-Info "DRYRUN: Would demote $($f.Name) to Start=3 (Manual)"
                $actions += [ordered]@{ Name = $f.Name; Action = 'DemoteStart=3 (DRYRUN)'; Command = $cmd }
            } else {
                Write-Info "Demoting service $($f.Name) to Start=3 (Manual) to prevent boot BSOD..."
                $out = & reg.exe add "$fullKey" /v Start /t REG_DWORD /d 3 /f 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-OK "Demoted $($f.Name) to Start=3 (Manual)"
                    $actions += [ordered]@{ Name = $f.Name; Action = 'SetStart=3'; Result = 'OK' }
                    $f.ActionTaken = 'SetStart=3'
                } else {
                    Write-Warn "Failed to demote $($f.Name): $($out -join ' ')"
                    $actions += [ordered]@{ Name = $f.Name; Action = 'SetStart=3'; Result = "ERROR: $out" }
                    $f.ActionTaken = "ERROR: $out"
                }
            }
        }
    }
    return $actions
}

# -------------------------------------------------------------------------
# Execution Flow
# -------------------------------------------------------------------------
try {
    Write-Info "Target Windows directory: $targetFull"

    if ($isLiveTarget) {
        Write-Warn "Target is the active running host OS. Enforcing read-only DryRun mode."
        $DryRun = $true
        $Apply = $false
    }

    $traceActive = $false
    if ($SxSTrace) {
        $traceDir = Join-Path $LogFolder "sxstrace"
        if (-not (Test-Path $traceDir)) { New-Item -Path $traceDir -ItemType Directory -Force | Out-Null }
        $traceEtl = Join-Path $traceDir "sxstrace.etl"
        $traceTxt = Join-Path $traceDir "sxstrace.txt"
        Write-Info "Starting Side-by-Side assembly trace to $traceEtl..."
        & sxstrace.exe trace -logfile:"$traceEtl" 2>&1 | Out-Null
        $traceActive = $true
    }

    Load-OfflineHive -WindowsPath $targetFull
    Register-EngineEvent PowerShell.Exiting -Action { Unload-OfflineHive } | Out-Null

    $controlSets = Get-ControlSetPath
    $controlSetFound = ($controlSets.Count -gt 0)

    if (-not $controlSetFound) {
        Write-Warn "No ControlSet keys located in offline hive."
        $findings = @()
        $assessment = 'Unknown (missing ControlSet)'
        $grade = 'U'
    } else {
        $findings = Analyze-Drivers -ControlSetPaths $controlSets -WindowsPath $targetFull
        $suspCount = ($findings | Where-Object { $_.SuspiciousReasons.Count -gt 0 }).Count
        $grade = Get-AssessmentGrade -SuspiciousCount $suspCount -ControlSetFound $true
        $assessment = switch ($grade) {
            'A' { 'Healthy (0 suspicious drivers)' }
            'B' { 'Generally Healthy (1-2 suspicious drivers)' }
            'C' { 'Moderate Risk (3-5 suspicious drivers)' }
            'D' { 'High Risk (6-10 suspicious drivers)' }
            'F' { 'Critical Risk (>10 suspicious drivers)' }
            default { 'Unknown' }
        }
    }

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host "   DRIVER AUDIT ASSESSMENT GRADE: [ $grade ] - $assessment       " -ForegroundColor $(switch ($grade) { 'A' {'Green'} 'B' {'Cyan'} 'C' {'Yellow'} default {'Red'} })
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""

    $manifest = [ordered]@{
        GeneratedAt = (Get-Date).ToString('o')
        Target      = $targetFull
        Grade       = $grade
        Assessment  = $assessment
        TotalBootDrivers = $findings.Count
        FlaggedCount     = ($findings | Where-Object { $_.SuspiciousReasons.Count -gt 0 }).Count
        Findings    = $findings
    }

    $backupRoot = Join-Path $LogFolder "DriverAudit_Backup_$RunId"
    $regBackups = Join-Path $backupRoot 'RegBackups'
    $quarantine = Join-Path $backupRoot 'Quarantine'

    if ($manifest.FlaggedCount -gt 0) {
        Write-Warn "Found $($manifest.FlaggedCount) flagged boot-critical driver(s):"
        foreach ($f in ($findings | Where-Object { $_.SuspiciousReasons.Count -gt 0 })) {
            $reasonStr = $f.SuspiciousReasons -join ', '
            Write-Host "  [-] $($f.Name) (Start=$($f.Start)) : $reasonStr" -ForegroundColor Yellow
        }

        if (-not (Test-Path $regBackups)) { New-Item -Path $regBackups -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $quarantine)) { New-Item -Path $quarantine -ItemType Directory -Force | Out-Null }

        $prep = @()
        foreach ($f in $findings) {
            if ($f.SuspiciousReasons.Count -gt 0) {
                $exportRes = Export-ServiceRegKey -ControlSet $f.ControlSet -ServiceName $f.Name -OutFolder $regBackups -DryRun:($DryRun -or -not $Apply)
                $prep += [ordered]@{ Service = $f.Name; ControlSet = $f.ControlSet; OriginalStart = $f.Start; RegExport = $exportRes }
            }
        }
        $manifest.Preparations = $prep

        # Undo reg generation
        $undoRegPath = Join-Path $regBackups 'undo_StartValues.reg'
        $lines = @('Windows Registry Editor Version 5.00', '')
        foreach ($p in $prep) {
            $key = "$($p.ControlSet)\Services\$($p.Service)"
            $lines += "[$key]"
            $hex = '{0:x8}' -f ($p.OriginalStart -as [int])
            $lines += "`"Start`"=dword:$hex"
            $lines += ''
        }
        Set-Content -Path $undoRegPath -Value $lines -Encoding Unicode
        $manifest.UndoReg = $undoRegPath
        Write-OK "Generated rollback registry file: $undoRegPath"

        # Apply changes if requested
        if ($Apply -and -not $DryRun) {
            # Try to restore missing drivers from DriverStore first
            foreach ($f in $findings) {
                if (-not $f.FileExists -and $f.ResolvedPath) {
                    $fileName = Split-Path $f.ResolvedPath -Leaf
                    $candidate = Find-InDriverStore -FileName $fileName -WindowsPath $targetFull
                    if ($candidate) {
                        try {
                            Copy-Item -Path $candidate -Destination $f.ResolvedPath -Force
                            Write-OK "Restored missing driver $fileName from DriverStore: $candidate"
                        } catch {}
                    }
                }
            }
            $actions = Apply-DriverChanges -Findings $findings -WhatIf:$false
            $manifest.ActionsTaken = $actions
        } else {
            Write-Info "Run mode: DryRun / Preview. No changes written to offline registry."
            Write-Info "To apply driver start-type demotions, run: Audit-BootDrivers.ps1 -Apply -Target `"$targetFull`""
        }
    } else {
        Write-OK "All boot-start drivers verified intact and present on disk!"
    }

    # Write manifest
    $json = $manifest | ConvertTo-Json -Depth 6
    Set-Content -Path $ManifestOut -Value $json -Encoding UTF8 -Force
    Write-OK "Full audit manifest saved to: $ManifestOut"

} catch {
    Write-Err "Audit execution failed: $($_.Exception.Message)"
} finally {
    if ($traceActive) {
        Write-Info "Stopping Side-by-Side assembly trace..."
        & sxstrace.exe stoptrace 2>&1 | Out-Null
        & sxstrace.exe parse -logfile:"$traceEtl" -outfile:"$traceTxt" 2>&1 | Out-Null
        Write-OK "SxSTrace diagnostics saved to: $traceTxt"
    }
    Unload-OfflineHive
}

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   AUDIT COMPLETE. Log: $LogFile                                 " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""
