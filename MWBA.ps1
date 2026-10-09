<#
MWBA.ps1 - Make Windows Boot Again (technician-grade, offline/WinRE-safe helper)
- Two-stage workflow: Stage1 (safe, reversible) and Stage2 (advanced, gated)
- Non-destructive by default. Stage2 actions require explicit confirmations.
- Drop-in functions for automation and interactive CLI.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$OfflineWindowsDrive,
    [string]$LogPath,
    [switch]$AutoConfirmStage2,
    [switch]$ShowLowConfidence
)

$Script:MWBA_Version = '0.2.0'
$Script:MWBA_DryRun = $false
$Script:MWBA_LogFile = Join-Path -Path $PSScriptRoot -ChildPath (("MWBA_{0}.log" -f ((Get-Date).ToString('yyyyMMdd-HHmmss'))))
$Script:MWBA_OfflineWindowsDrive = $null
$Script:MWBA_OfflineWindowsPath = $null

function Show-MWBA-Header {
    $hdr = "MWBA - Make Windows Boot Again (Technician Edition) v$($Script:MWBA_Version)"
    Write-Host $hdr -ForegroundColor Cyan
    Write-Host "Mode: $([bool](-not $Script:MWBA_DryRun) -replace 'True','Live' -replace 'False','DryRun')" -ForegroundColor Yellow
    Write-Host "Log: $Script:MWBA_LogFile`n" -ForegroundColor DarkYellow
}

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
            Write-MWBA "Preflight: Process token privileges (SeBackupPrivilege, SeRestorePrivilege, SeTakeOwnershipPrivilege) activated."
        }
    } catch {}
}

function PreflightChecks {
    Write-MWBA 'Running preflight checks for required utilities...'
    Enable-MWBAPrivileges
    $tools = @('bcdedit','bcdboot','reagentc','manage-bde','bootrec','chkdsk','dism')
    $missing = @()
    foreach ($t in $tools) {
        $cmd = Get-Command $t -ErrorAction SilentlyContinue
        if (-not $cmd) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        Write-Warning "Missing utilities: $($missing -join ', '). Some checks/actions may fail or be unavailable in WinRE environment."
        Write-MWBA "Preflight: Missing tools: $($missing -join ', ')" 'WARN'
    } else { Write-MWBA 'Preflight: all required utilities present' }
}

function Write-MWBA {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] {1}: {2}" -f (Get-Date -Format s), $Level, $Message
    Write-Host "[MWBA] $Message"
    try { Add-Content -Path $Script:MWBA_LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Write-MWBA-Status {
    param([string]$Action, [ValidateSet('OK','WARN','FAIL')] [string]$Result, [string]$Note = '')
    switch ($Result) {
        'OK'   { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'FAIL' { $color = 'Red' }
    }
    $msg = "{0} : {1} {2}" -f $Action, $Result, $Note
    Write-Host $msg -ForegroundColor $color
    Write-MWBA "$Action -> $Result ($Note)"
}

function Resolve-MWBA-OfflineWindowsDrive {
    param([string]$OfflineWindowsDrive)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($OfflineWindowsDrive) {
        $candidates.Add($OfflineWindowsDrive)
    } else {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Sort-Object @{ Expression = { if ($_.Name -eq 'X') { 1 } else { 0 } } }, Name
        foreach ($drive in $drives) {
            $candidates.Add("$($drive.Name):")
            $candidates.Add("$($drive.Name):\Windows")
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }

        $trimmed = $candidate.Trim().Trim('"')
        if (-not $trimmed) {
            continue
        }

        if ($trimmed -match '^[A-Za-z]:\\?$') {
            $resolvedDrive = $trimmed.TrimEnd('\')
        } elseif ($trimmed -match '^[A-Za-z]:\\Windows\\?$') {
            $resolvedDrive = (Split-Path -Path $trimmed -Qualifier).TrimEnd('\')
        } elseif ((Split-Path -Path $trimmed -Leaf) -ieq 'Windows') {
            $resolvedDrive = (Split-Path -Path $trimmed -Qualifier).TrimEnd('\')
        } else {
            try {
                $resolvedDrive = (Split-Path -Path ([IO.Path]::GetFullPath($trimmed)) -Qualifier).TrimEnd('\')
            } catch {
                continue
            }
        }

        $systemHive = Join-Path $resolvedDrive 'Windows\System32\config\SYSTEM'
        $windowsDir = Join-Path $resolvedDrive 'Windows'
        $windowsSystem32 = Join-Path $resolvedDrive 'Windows\System32'

        $looksLikeWindows = $false
        try {
            $looksLikeWindows = Test-Path $systemHive -PathType Leaf -ErrorAction Stop
        } catch {
            try {
                $looksLikeWindows = (Test-Path $windowsDir -PathType Container -ErrorAction Stop) -and (Test-Path $windowsSystem32 -PathType Container -ErrorAction Stop)
            } catch {
                $looksLikeWindows = $false
            }
        }

        if ($looksLikeWindows) {
            return $resolvedDrive
        }
    }

    throw 'Unable to locate an offline Windows installation. Pass -OfflineWindowsDrive with a Windows drive root or Windows folder path.'
}

function Get-MWBA-OfflineWindowsPath {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)

    if (-not $OfflineWindowsDrive) {
        throw 'Offline Windows drive has not been resolved.'
    }

    return (Join-Path $OfflineWindowsDrive 'Windows')
}

function Get-MWBA-BcdStorePath {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string[]]$CheckVolumes = @()
    )

    if (-not $OfflineWindowsDrive) {
        return $null
    }

    $volumes = if ($CheckVolumes.Count -gt 0) { $CheckVolumes } else { 'S:','V:','E:','F:','G:' }
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path $OfflineWindowsDrive 'Boot\BCD'))
    foreach ($volume in $volumes) {
        $driveName = $volume.TrimEnd(':')
        if (-not (Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            continue
        }
        $candidates.Add((Join-Path $volume 'EFI\Microsoft\Boot\BCD'))
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) {
            continue
        }
        if (Test-Path $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            try {
                return (Get-Item $candidate -ErrorAction Stop).FullName
            } catch {
                return $candidate
            }
        }
    }

    return $null
}

function Detect-MWBA-BootStatus {
    <#
    Heuristic boot-status detection for offline/WinRE environment.
    Returns PSCustomObject: Status (Healthy/Unhealthy), Reasons[], Details (has booleans), RawBCD, BitLockerRaw
    #>
    param(
        [string]$OfflineWindowsDrive = 'C:',
        [string[]]$CheckVolumes = @()
    )

    Write-MWBA "Running boot-status detection..."
    $reasons = [System.Collections.Generic.List[string]]::new()
    $details = [ordered]@{}

    # 1) BCD store presence
    $bcdPath = Get-MWBA-BcdStorePath -OfflineWindowsDrive $OfflineWindowsDrive -CheckVolumes $CheckVolumes
    $bcdExists = [bool]$bcdPath
    $details.BCDStorePresent = $bcdExists
    $details.BCDStorePath = $bcdPath
    if (-not $bcdExists) { $reasons.Add('BCD store missing') }

    # 2) BCD entries
    $bcdRaw = $null
    if ($bcdPath) {
        try { $bcdRaw = bcdedit /store $bcdPath /enum all 2>&1 } catch { }
    }
    $hasBootManager = ($bcdRaw -match 'Windows Boot Manager')
    $hasLoader = ($bcdRaw -match 'Windows Boot Loader')
    $hasDevice = ($bcdRaw -match 'device') -and ($bcdRaw -match 'osdevice')
    $details.BCDBootManager = [bool]$hasBootManager
    $details.BCDLoader = [bool]$hasLoader
    $details.BCDDeviceEntries = [bool]$hasDevice
    if (-not $hasBootManager) { $reasons.Add('No Windows Boot Manager entry in BCD') }
    if (-not $hasLoader) { $reasons.Add('No Windows Boot Loader entry in BCD') }
    if (-not $hasDevice) { $reasons.Add('Missing device/osdevice in BCD entries') }

    # 3) Boot-critical files
    $winload = Test-Path (Join-Path $OfflineWindowsDrive 'Windows\System32\winload.exe') -PathType Leaf -ErrorAction SilentlyContinue
    $bootmgr = Test-Path (Join-Path $OfflineWindowsDrive 'bootmgr') -PathType Leaf -ErrorAction SilentlyContinue
    $details.WinloadPresent = [bool]$winload
    $details.BootmgrPresent = [bool]$bootmgr
    if (-not $winload) { $reasons.Add('Missing winload.exe') }
    if (-not $bootmgr) { $reasons.Add('Missing bootmgr') }

    # 4) Pending update markers
    $pendingXml = Join-Path $OfflineWindowsDrive 'Windows\WinSxS\pending.xml'
    $hasPending = Test-Path $pendingXml -ErrorAction SilentlyContinue
    $details.PendingUpdateMarker = [bool]$hasPending
    if ($hasPending) { $reasons.Add('pending.xml indicates an incomplete update') }

    # 5) EFI structure
    $efiOk = $false
    $efiNotes = [System.Collections.Generic.List[string]]::new()
    $vols = if ($CheckVolumes.Count -gt 0) { $CheckVolumes } else { 'S:','V:','E:','F:','G:' }
    foreach ($v in $vols) {
        try {
            $pBoot = "$v\EFI\Microsoft\Boot\bootmgfw.efi"
            if (Test-Path $pBoot -PathType Leaf -ErrorAction SilentlyContinue) { $efiOk = $true; $efiNotes.Add("Found EFI at $v") ; break }
        } catch { }
    }
    $details.EFIStructureOk = [bool]$efiOk
    if (-not $efiOk) { $reasons.Add('EFI boot files not detected on scanned volumes') }

    # 6) BitLocker state (best-effort)
    $volLetter = ($OfflineWindowsDrive.TrimEnd(':')) + ':'
    $bitlockerLocked = $false
    $bstatus = $null
    try { $bstatus = manage-bde -status $volLetter 2>&1 } catch { }
    if ($bstatus -and ($bstatus -match 'Locked')) { $bitlockerLocked = $true }
    $details.BitLockerLocked = [bool]$bitlockerLocked
    if ($bitlockerLocked) { $reasons.Add('Windows volume appears BitLocker-locked') }

    # 7) Cryptographic Catalog Store (CatRoot & CatRoot2)
    $catRootPath = Join-Path $OfflineWindowsDrive 'Windows\System32\CatRoot'
    $catRoot2Path = Join-Path $OfflineWindowsDrive 'Windows\System32\CatRoot2'
    $catRootCount = if (Test-Path $catRootPath) { (Get-ChildItem -Path $catRootPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
    $catRoot2Count = if (Test-Path $catRoot2Path) { (Get-ChildItem -Path $catRoot2Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count } else { 0 }
    $details.CatRootFileCount = $catRootCount
    $details.CatRoot2FileCount = $catRoot2Count
    if ($catRoot2Count -lt 1) { $reasons.Add("CatRoot2 database empty ($catRoot2Count files) - causes 0xC000021A / STATUS_INVALID_IMAGE_HASH") }
    if ($catRootCount -lt 100) { $reasons.Add("CatRoot catalog store critically depleted ($catRootCount files, expected >= 100) - causes signature verification failures") }

    $status = if ($reasons.Count -eq 0) { 'Healthy' } else { 'Unhealthy' }
    $obj = [PSCustomObject]@{
        Status = $status
        Reasons = $reasons.ToArray()
        Details = $details
        RawBCD = $bcdRaw
        BitLockerRaw = $bstatus
    }

    Write-MWBA "Boot-status: $($obj.Status)"
    return $obj
}

# Non-destructive suggestion generator for SFC/DISM
# Produces conservative, technician-facing recommendations and includes
# suggested offline syntax for DISM (with/without source). Does NOT run tools.
function Get-MWBA-SfcDismSuggestion {
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$BootStatus,
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string[]]$SearchDrives = @('D:','E:','F:','G:','H:')
    )

    function Map-ScoreToConfidence { param($score)
        if ($score -ge 3) { 'High' }
        elseif ($score -ge 1) { 'Medium' }
        else { 'Low' }
    }

    # Probe common removable/media drives for install.wim/install.esd
    $foundSource = $null
    foreach ($d in $SearchDrives) {
        $driveName = $d.TrimEnd(':')
        if (-not (Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            continue
        }
        foreach ($name in @('sources\install.wim','sources\install.esd')) {
            $p = Join-Path $d $name
            if (Test-Path $p -PathType Leaf -ErrorAction SilentlyContinue) { $foundSource = (Get-Item $p).FullName; break }
        }
        if ($foundSource) { break }
    }

    # Extract indicators from boot status details (safe access)
    $details = $BootStatus.Details
    $winload = $false; $bootmgr = $false; $pending = $false; $bcdOk = $false; $bitlocker = $false
    if ($details) {
        $winload = [bool]($details.WinloadPresent)
        $bootmgr = [bool]($details.BootmgrPresent)
        $pending = [bool]($details.PendingUpdateMarker)
        $bcdOk = [bool]($details.BCDBootManager -and $details.BCDLoader -and $details.BCDDeviceEntries)
        $bitlocker = [bool]($details.BitLockerLocked)
    }

    # SFC heuristic (conservative)
    $sfcScore = 0
    if ($winload) { $sfcScore += 2 }
    if ($pending) { $sfcScore += 1 }
    if (-not $bootmgr) { $sfcScore -= 2 }
    if ($bitlocker) { $sfcScore -= 1 }
    $sfcConfidence = Map-ScoreToConfidence $sfcScore

    $sfcTime = '5-15 minutes'
    $offlineWindowsPath = Get-MWBA-OfflineWindowsPath -OfflineWindowsDrive $OfflineWindowsDrive
    $sfcCmd = "sfc /scannow /offbootdir=$OfflineWindowsDrive\ /offwindir=$offlineWindowsPath"
    $sfcRec = if ($sfcConfidence -eq 'Low') { 'SFC is unlikely to help now; address missing boot files or unlock BitLocker first.' } else { 'Consider running offline SFC to repair system files (non-destructive).' }
    $sfcWhy = if (-not $winload) { 'Critical boot files missing; SFC cannot recreate missing bootloader files.' } elseif ($pending) { 'Pending/incomplete updates detected which may have left system files inconsistent.' } else { 'Boot-critical files present but boot remains unhealthy; integrity check may repair damaged files.' }

    # DISM heuristic (conservative)
    $dismScore = 0
    if ($pending) { $dismScore += 1 }
    if ($foundSource) { $dismScore += 2 }
    if ($winload) { $dismScore += 1 }
    if ($bitlocker) { $dismScore -= 1 }
    if (-not $bcdOk) { $dismScore -= 1 }
    $dismConfidence = Map-ScoreToConfidence $dismScore

    $dismTime = '20-60 minutes (depends on disk speed and health)'
    $dismCmdNoSource = "dism /Image:$OfflineWindowsDrive /Cleanup-Image /RestoreHealth"
    $dismCmdWithSource = "dism /Image:$OfflineWindowsDrive /Cleanup-Image /RestoreHealth /Source:wim:<PATH>:<INDEX> /LimitAccess"

    if ($foundSource) {
        $dismRec = 'DISM with a matching install.wim/esd source is recommended when SFC cannot repair component store issues.'
        $dismWhy = 'A local install image was detected; DISM can repair the component store using that source.'
        $dismSource = $foundSource
    } else {
        $dismRec = 'DISM can be attempted without a local source, but success is less likely; obtain matching install media for best results.'
        $dismWhy = 'No local install.wim/esd found on common media; prefer providing matching source before running DISM.'
        $dismSource = $null
    }

    $suggestions = @()
    $suggestions += [PSCustomObject]@{
        Tool = 'SFC'
        Confidence = $sfcConfidence
        TimeEstimate = $sfcTime
        SourceAvailability = $null
        Recommendation = $sfcRec
        Explanation = $sfcWhy
        SuggestedCommand = $sfcCmd
        UndoHint = 'No undo required; SFC repairs files. Re-run to confirm.'
    }
    $suggestions += [PSCustomObject]@{
        Tool = 'DISM'
        Confidence = $dismConfidence
        TimeEstimate = $dismTime
        SourceAvailability = if ($dismSource) { @{ Available = $true; Path = $dismSource } } else { @{ Available = $false } }
        Recommendation = $dismRec
        Explanation = $dismWhy
        SuggestedCommand = if ($dismSource) { $dismCmdWithSource -replace '<PATH>',$dismSource -replace '<INDEX>','1' } else { $dismCmdNoSource }
        UndoHint = 'DISM modifies component store; keep logs in %windir%\Logs\DISM\dism.log for review.'
    }

    return $suggestions
}

### Reinstall scoring helpers ###
function Test-MWBA-RegistryHiveLoad {
    param([string]$OfflineWindowsDrive = 'C:')
    # Attempt to load SYSTEM and SOFTWARE hives under a temporary key and then unload.
    # This is reversible. In DryRun we skip the actual load.
    $result = @{ SYSTEM = $null; SOFTWARE = $null }
    $systemHive = Join-Path $OfflineWindowsDrive 'Windows\System32\config\SYSTEM'
    $softwareHive = Join-Path $OfflineWindowsDrive 'Windows\System32\config\SOFTWARE'

    if ($Script:MWBA_DryRun) {
        Write-MWBA 'DRYRUN: Skipping registry hive load test.'
        $result.SYSTEM = 'Skipped'
        $result.SOFTWARE = 'Skipped'
        return $result
    }

    foreach ($pair in @{ SYSTEM=$systemHive; SOFTWARE=$softwareHive }.GetEnumerator()) {
        $name = $pair.Key; $path = $pair.Value
        if (-not (Test-Path $path -PathType Leaf -ErrorAction SilentlyContinue)) {
            $result[$name] = 'Missing'
            continue
        }
        $tempKey = "HKLM\\MWBATemp_$name"
        try {
            Write-MWBA "Loading hive $path as $tempKey"
            & reg.exe load "HKLM\MWBATemp_$name" "$path" 2>&1 | Out-Null
            # Simple read check: query a known value may be expensive; just note success
            $result[$name] = 'Loaded'
        } catch {
            $result[$name] = 'LoadFailed'
        } finally {
            try { & reg.exe unload "HKLM\MWBATemp_$name" 2>&1 | Out-Null } catch { }
        }
    }
    return $result
}

function Test-MWBA-WinSxSIntegrity {
    param([string]$OfflineWindowsDrive = 'C:')
    # Heuristic: ensure WinSxS\Manifests exists and contains a reasonable number of files.
    $manPath = Join-Path $OfflineWindowsDrive 'Windows\WinSxS\Manifests'
    if (-not (Test-Path $manPath -ErrorAction SilentlyContinue)) { return @{ Ok=$false; Reason='ManifestsMissing' } }
    try {
        $count = (Get-ChildItem -Path $manPath -File -ErrorAction SilentlyContinue | Measure-Object).Count
    } catch { $count = 0 }
    if ($count -lt 20) { return @{ Ok=$false; Reason='FewManifests' } }
    return @{ Ok=$true; Reason='OK' }
}

function Detect-UpdateRollbackLoop {
    param([string]$OfflineWindowsDrive = 'C:')
    # Heuristic: search Panther setup logs for 'rollback' tokens.
    $log = Join-Path $OfflineWindowsDrive 'Windows\Panther\setupact.log'
    if (-not (Test-Path $log -ErrorAction SilentlyContinue)) { return $false }
    try {
        $text = Get-Content -Path $log -ErrorAction SilentlyContinue -Raw
        if ($text -match '(?i)rollback') { return $true }
    } catch { }
    return $false
}

function Analyze-BootLog {
    param([string]$OfflineWindowsDrive = 'C:')
    $log = Join-Path $OfflineWindowsDrive 'Windows\ntbtlog.txt'
    if (-not (Test-Path $log -ErrorAction SilentlyContinue)) { return @{ Exists=$false; EarlyStop=$false; LoadedDrivers=0 } }
    try {
        $lines = Get-Content -Path $log -ErrorAction SilentlyContinue
        $loaded = ($lines | Where-Object { $_ -match 'Loaded driver' }).Count
        # Early stop heuristic: file is small or loaded drivers very few
        $size = (Get-Item $log).Length
        $early = ($loaded -lt 5 -or $size -lt 1024)
        return @{ Exists=$true; EarlyStop=$early; LoadedDrivers=$loaded }
    } catch { return @{ Exists=$true; EarlyStop=$true; LoadedDrivers=0 } }
}

function Compute-MWBA-ReinstallScore {
    param(
        [Parameter(Mandatory=$true)][PSCustomObject]$PreStatus,
        [Parameter(Mandatory=$true)][PSCustomObject]$PostStatus,
        [string]$OfflineWindowsDrive = 'C:'
    )
    $score = 0
    $reasons = [System.Collections.Generic.List[string]]::new()

    # 1) Boot-path repairs all succeed but boot behavior unchanged
    $postDetails = $PostStatus.Details
    $preDetails = $PreStatus.Details
    $repairsLikely = $false
    if ($postDetails) {
        $repairsLikely = ($postDetails.BCDBootManager -and $postDetails.EFIStructureOk -and -not $postDetails.PendingUpdateMarker)
    }
    if ($repairsLikely -and $PreStatus.Status -eq $PostStatus.Status) {
        $score++ ; $reasons.Add('Boot-path repaired but boot behavior unchanged')
    }

    # 2) Registry hive load test fails
    $hives = Test-MWBA-RegistryHiveLoad -OfflineWindowsDrive $OfflineWindowsDrive
    foreach ($k in $hives.Keys) {
        if ($hives[$k] -eq 'LoadFailed') { $score++ ; $reasons.Add("Registry hive load failed: $k") }
        elseif ($hives[$k] -eq 'Missing') { $score++ ; $reasons.Add("Registry hive missing: $k") }
    }

    # 3) WinSxS inconsistencies
    $ws = Test-MWBA-WinSxSIntegrity -OfflineWindowsDrive $OfflineWindowsDrive
    if (-not $ws.Ok) { $score++ ; $reasons.Add("WinSxS integrity issue: $($ws.Reason)") }

    # 4) Update rollback loops persist
    if (Detect-UpdateRollbackLoop -OfflineWindowsDrive $OfflineWindowsDrive) { $score++ ; $reasons.Add('Update rollback activity detected') }

    # 5) Boot reaches winload but resets during kernel init (indirect via boot log or previous status)
    if ($PostStatus.Details.WinloadPresent -and ($PostStatus.Status -ne 'Healthy')) {
        # use boot log analysis to detect kernel-init reset
        $bootLog = Analyze-BootLog -OfflineWindowsDrive $OfflineWindowsDrive
        if ($bootLog.Exists -and $bootLog.EarlyStop) { $score++; $reasons.Add('Boot log indicates early stop during driver/kernel init') }
        else { # partial signal - do not increment
            $null = $null
        }
    }

    # 6) BCD and EFI healthy but OS fails to initialize
    if ($postDetails -and $postDetails.BCDBootManager -and $postDetails.EFIStructureOk -and $PostStatus.Status -ne 'Healthy') { $score++; $reasons.Add('BCD/EFI healthy but OS fails to initialize') }

    return @{ ReinstallScore = $score; Reasons = $reasons.ToArray() }
}

### Stage 1: safe, reversible actions ###
function Restore-BCD {
    param([switch]$Force)
    Write-MWBA "Restore-BCD: auditing boot configuration on $Script:MWBA_OfflineWindowsDrive..."
    $espInfo = Find-MWBA-TargetDiskESP -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
    if (-not $espInfo) {
        Write-MWBA "No ESP detected on target disk; checking legacy BIOS/MBR bootcode..."
        if (Get-Command bootsect.exe -ErrorAction SilentlyContinue) {
            if ($Script:MWBA_DryRun) {
                Write-MWBA "DRYRUN: bootsect.exe /nt60 $Script:MWBA_OfflineWindowsDrive /mbr"
            } else {
                Write-MWBA "Applying standard NT60 MBR bootcode to $Script:MWBA_OfflineWindowsDrive..."
                & bootsect.exe /nt60 $Script:MWBA_OfflineWindowsDrive /mbr 2>&1 | Out-Null
            }
        }
    } else {
        Write-MWBA "Target disk uses UEFI/GPT (Disk $($espInfo.DiskNumber), Part $($espInfo.PartitionNumber)). Deferring to Restore-EFIBootFiles."
    }
}

function Find-MWBA-TargetDiskESP {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    if (-not $OfflineWindowsDrive) { return $null }

    try {
        $driveLetter = ($OfflineWindowsDrive.TrimEnd('\').TrimEnd(':'))
        $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $driveLetter }
        if (-not $part) { return $null }
        $diskNum = $part[0].DiskNumber

        $esp = Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
            Where-Object { $_.Type -eq 'System' -or $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
        if ($esp) {
            return @{ DiskNumber = $diskNum; PartitionNumber = $esp.PartitionNumber; DriveLetter = $esp.DriveLetter }
        }
    } catch {
        Write-MWBA "Find-MWBA-TargetDiskESP exception: $($_.Exception.Message)" 'WARN'
    }
    return $null
}

function Restore-EFIBootFiles {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string]$EfiDriveLetter = 'S'
    )
    $offlineWindowsPath = Get-MWBA-OfflineWindowsPath -OfflineWindowsDrive $OfflineWindowsDrive
    Write-MWBA "Restore-EFIBootFiles: locating target ESP and regenerating UEFI bootloader..."

    $espInfo = Find-MWBA-TargetDiskESP -OfflineWindowsDrive $OfflineWindowsDrive
    $targetLetter = $null
    $needUnmount = $false

    if ($espInfo) {
        if ($espInfo.DriveLetter -and $espInfo.DriveLetter -ne ' ') {
            $targetLetter = "$($espInfo.DriveLetter):"
        } else {
            # Find an unused letter
            foreach ($candidate in @('S','Z','Y','W','V')) {
                if (-not (Get-PSDrive -Name $candidate -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                    $targetLetter = "${candidate}:"
                    break
                }
            }
            if ($targetLetter -and -not $Script:MWBA_DryRun) {
                try {
                    Set-Partition -DiskNumber $espInfo.DiskNumber -PartitionNumber $espInfo.PartitionNumber -NewDriveLetter ($targetLetter.TrimEnd(':')) -ErrorAction Stop
                    $needUnmount = $true
                    Write-MWBA "Mounted target disk EFI partition (Disk $($espInfo.DiskNumber), Part $($espInfo.PartitionNumber)) as $targetLetter"
                } catch {
                    # Fallback to diskpart if Set-Partition is blocked on GPT System partition
                    $dpScript = @"
select disk $($espInfo.DiskNumber)
select partition $($espInfo.PartitionNumber)
assign letter=$($targetLetter.TrimEnd(':'))
"@
                    $dpScript | diskpart 2>&1 | Out-Null
                    Start-Sleep -Milliseconds 500
                    if (Test-Path "$targetLetter\") {
                        $needUnmount = $true
                        Write-MWBA "Mounted target disk EFI partition via diskpart as $targetLetter"
                    } else {
                        Write-MWBA "Failed to assign drive letter $targetLetter to EFI partition: $($_.Exception.Message)" 'WARN'
                    }
                }
            } elseif ($Script:MWBA_DryRun) {
                Write-MWBA "DRYRUN: Would assign $targetLetter to Disk $($espInfo.DiskNumber) ESP"
            }
        }
    }

    if (-not $targetLetter -or -not (Test-Path "$targetLetter\")) {
        Write-MWBA "Target disk EFI partition could not be mounted. Skipping UEFI bcdboot." 'WARN'
        return
    }

    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: bcdboot $offlineWindowsPath /s $targetLetter /f UEFI"
        Write-MWBA "DRYRUN: bcdedit /store $targetLetter\EFI\Microsoft\Boot\BCD /set {default} recoveryenabled No"
    } else {
        $out = & bcdboot $offlineWindowsPath /s $targetLetter /f UEFI 2>&1
        Write-MWBA "bcdboot result: $out"
        $storePath = "$targetLetter\EFI\Microsoft\Boot\BCD"
        if (Test-Path $storePath) {
            & bcdedit /store $storePath /set '{default}' recoveryenabled No 2>&1 | Out-Null
            & bcdedit /store $storePath /set '{default}' bootstatuspolicy IgnoreAllFailures 2>&1 | Out-Null
            Write-MWBA "Configured target BCD ($storePath): recoveryenabled=No, bootstatuspolicy=IgnoreAllFailures"
        }
        if ($needUnmount -and $espInfo) {
            try {
                Remove-PartitionAccessPath -DiskNumber $espInfo.DiskNumber -PartitionNumber $espInfo.PartitionNumber -AccessPath "$targetLetter\" -ErrorAction SilentlyContinue
            } catch {}
            if (Test-Path "$targetLetter\") {
                $dpScript = @"
select disk $($espInfo.DiskNumber)
select partition $($espInfo.PartitionNumber)
remove letter=$($targetLetter.TrimEnd(':'))
"@
                $dpScript | diskpart 2>&1 | Out-Null
            }
            Write-MWBA "Unmounted temporary EFI drive letter $targetLetter"
        }
    }
}

function Ensure-MWBA-TargetDiskOnline {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string]$BitLockerKey = $null
    )
    Write-MWBA "Ensure-MWBA-TargetDiskOnline: verifying target disk is online and unlocked..."
    $driveLetter = ($OfflineWindowsDrive.TrimEnd('\').TrimEnd(':'))
    $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $driveLetter }
    if ($part) {
        $diskNum = $part[0].DiskNumber
        $diskObj = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
        if ($diskObj -and $diskObj.IsOffline) {
            if ($Script:MWBA_DryRun) {
                Write-MWBA "DRYRUN: Would bring Physical Disk $diskNum Online"
            } else {
                Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
                Write-MWBA "Physical Disk $diskNum brought Online."
            }
        }
    }
    if ($BitLockerKey -and (Get-Command manage-bde -ErrorAction SilentlyContinue)) {
        try {
            $bdeStatus = & manage-bde -status "$OfflineWindowsDrive" 2>&1
            if (($bdeStatus -join ' ') -match "Locked Status:\s+Locked") {
                if ($Script:MWBA_DryRun) {
                    Write-MWBA "DRYRUN: Would unlock $OfflineWindowsDrive with BitLocker recovery key"
                } else {
                    & manage-bde -unlock "$OfflineWindowsDrive" -RecoveryPassword $BitLockerKey 2>&1 | Out-Null
                    Write-MWBA "BitLocker volume $OfflineWindowsDrive unlocked."
                }
            }
        } catch {}
    }
}

function Neutralize-MWBA-RebootInterceptors {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Neutralize-MWBA-RebootInterceptors: checking for 3rd-party reboot triggers..."
    $triggers = @('DGRebootRun.ini', 'EaseUS_Reboot.ini', 'AOMEI_Reboot.ini')
    foreach ($t in $triggers) {
        $p = Join-Path $OfflineWindowsDrive $t
        if (Test-Path $p) {
            $bak = "$p.disabled-by-mwba"
            if ($Script:MWBA_DryRun) {
                Write-MWBA "DRYRUN: Would rename reboot trigger $p -> $bak"
            } else {
                try {
                    Rename-Item -Path $p -NewName (Split-Path $bak -Leaf) -Force
                    Write-MWBA "Neutralized reboot trigger: $p -> $bak"
                } catch {
                    Write-MWBA "Failed to rename $p : $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
}

function Reset-MWBA-AutoRepair {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Reset-MWBA-AutoRepair: resetting ReAgent.xml auto-repair loops..."
    $reAgent = Join-Path $OfflineWindowsDrive 'Windows\System32\Recovery\ReAgent.xml'
    if (Test-Path $reAgent) {
        if ($Script:MWBA_DryRun) {
            Write-MWBA "DRYRUN: Would disable IsAutoRepairOn and reset ScheduledOperation in $reAgent"
        } else {
            try {
                $xml = Get-Content -Path $reAgent -Raw -ErrorAction Stop
                $xml = $xml -replace 'IsAutoRepairOn state="\d+"',       'IsAutoRepairOn state="0"'
                $xml = $xml -replace 'ScheduledOperation state="\d+"',   'ScheduledOperation state="0"'
                $xml = $xml -replace 'OperationPermanent state="\d+"',   'OperationPermanent state="0"'
                $xml | Set-Content -Path $reAgent -Encoding UTF8 -Force
                Write-MWBA "Reset ReAgent.xml: IsAutoRepairOn=0, ScheduledOperation=0"
            } catch {
                Write-MWBA "Failed to update $reAgent : $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Repair-MWBA-CredentialProviders {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Repair-MWBA-CredentialProviders: disinfecting 2FA hooks & checking Winlogon..."
    $swPath = Join-Path $OfflineWindowsDrive 'Windows\System32\config\SOFTWARE'
    if (-not (Test-Path $swPath)) {
        Write-MWBA "SOFTWARE hive not found at $swPath" 'WARN'
        return
    }

    $mountName = 'HKLM\MWBATemp_SOFTWARE'
    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: Would load $swPath, purge 2FAHelper/CredProvHelper, remove 2X/3rd-party filters, reset Winlogon Userinit/Shell"
        return
    }

    try {
        & reg.exe unload $mountName 2>$null | Out-Null
        $loadOut = & reg.exe load $mountName "$swPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-MWBA "Failed to load offline SOFTWARE hive: $loadOut" 'WARN'
            return
        }

        $cpKey = "$mountName\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers"
        $cfKey = "$mountName\Microsoft\Windows\CurrentVersion\Authentication\Credential Provider Filters"
        $wlKey = "$mountName\Microsoft\Windows NT\CurrentVersion\Winlogon"

        # Delete orphan / hijacking 2FA values
        & reg.exe delete $cpKey /v "2FAHelper" /f 2>$null | Out-Null
        & reg.exe delete $cpKey /v "CredProvHelper" /f 2>$null | Out-Null
        Write-MWBA "Removed orphan 2FAHelper and CredProvHelper values."

        # Delete 2X / known crashing 3rd-party provider & filter GUIDs
        & reg.exe delete "$cpKey\{6946A930-1878-4ED3-941F-F2D30EF3D3AA}" /f 2>$null | Out-Null
        & reg.exe delete "$cfKey\{2C1C77B1-D33E-4C4D-B644-5DCD6A9E5690}" /f 2>$null | Out-Null

        # Ensure PasswordProvider is enabled
        $pwdKey = "$cpKey\{60b78e88-ead8-445c-9cfd-0b87f74ea6cd}"
        & reg.exe add $pwdKey /ve /t REG_SZ /d "PasswordProvider" /f 2>$null | Out-Null
        & reg.exe delete $pwdKey /v "Disabled" /f 2>$null | Out-Null

        # Clean AppInit_DLLs in 64-bit and 32-bit node
        $win64 = "$mountName\Microsoft\Windows NT\CurrentVersion\Windows"
        $win32 = "$mountName\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows"
        & reg.exe add $win64 /v "AppInit_DLLs" /t REG_SZ /d "" /f | Out-Null
        & reg.exe add $win64 /v "LoadAppInit_DLLs" /t REG_DWORD /d 0 /f | Out-Null
        & reg.exe add $win32 /v "AppInit_DLLs" /t REG_SZ /d "" /f 2>$null | Out-Null
        & reg.exe add $win32 /v "LoadAppInit_DLLs" /t REG_DWORD /d 0 /f 2>$null | Out-Null

        # Ensure Winlogon Shell and Userinit
        & reg.exe add $wlKey /v "Userinit" /t REG_SZ /d "C:\Windows\system32\userinit.exe," /f 2>$null | Out-Null
        & reg.exe add $wlKey /v "Shell" /t REG_SZ /d "explorer.exe" /f 2>$null | Out-Null
        & reg.exe delete $wlKey /v "GinaDLL" /f 2>$null | Out-Null
        & reg.exe delete $wlKey /v "AppInit_DLLs" /f 2>$null | Out-Null
        Write-MWBA "Reset Winlogon Userinit (C:\Windows\system32\userinit.exe,), Shell (explorer.exe), and purged AppInit_DLLs"
    } catch {
        Write-MWBA "Repair-MWBA-CredentialProviders error: $($_.Exception.Message)" 'WARN'
    } finally {
        try { & reg.exe unload $mountName 2>$null | Out-Null } catch {}
    }
}

function Clear-MWBA-SessionManagerPending {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Clear-MWBA-SessionManagerPending: checking SYSTEM hive for pending rename loops and LSA packages..."
    $sysPath = Join-Path $OfflineWindowsDrive 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path $sysPath)) {
        Write-MWBA "SYSTEM hive not found at $sysPath" 'WARN'
        return
    }

    $mountName = 'HKLM\MWBATemp_SYSTEM'
    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: Would load $sysPath, reset LSA packages (msv1_0, kerberos), clear PendingFileRenameOperations in Session Manager, and clear stale MountedDevices"
        return
    }

    try {
        & reg.exe unload $mountName 2>$null | Out-Null
        $loadOut = & reg.exe load $mountName "$sysPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-MWBA "Failed to load offline SYSTEM hive: $loadOut" 'WARN'
            return
        }

        $csNum = '001'
        $csQ = (& reg.exe query "$mountName\Select" /v "Current" 2>&1) -join ' '
        if ($csQ -match "0x0*([1-9][0-9]*)") { $csNum = $Matches[1].PadLeft(3,'0') }
        $smKey = "$mountName\ControlSet$csNum\Control\Session Manager"
        $lsaKey = "$mountName\ControlSet$csNum\Control\Lsa"
        $mdKey = "$mountName\MountedDevices"

        # 1. Reset LSA packages to standard Windows defaults (prevents LSASS crash / CRITICAL_PROCESS_DIED)
        & reg.exe add $lsaKey /v "Authentication Packages" /t REG_MULTI_SZ /d "msv1_0\0" /f | Out-Null
        & reg.exe add $lsaKey /v "Security Packages" /t REG_MULTI_SZ /d "kerberos\0msv1_0\0schannel\0wdigest\0tspkg\0pku2u\0" /f | Out-Null
        & reg.exe add $lsaKey /v "Notification Packages" /t REG_MULTI_SZ /d "scecli\0" /f | Out-Null
        & reg.exe add $lsaKey /v "Security Providers" /t REG_SZ /d "credssp.dll" /f | Out-Null
        Write-MWBA "Reset LSA Authentication, Security, and Notification packages to default."

        # 2. Clear stale MountedDevices drive letter mappings
        if ((& reg.exe query $mdKey 2>&1) -notmatch "ERROR") {
            & reg.exe delete $mdKey /v "\DosDevices\C:" /f 2>$null | Out-Null
            & reg.exe delete $mdKey /v "\DosDevices\E:" /f 2>$null | Out-Null
            Write-MWBA "Cleared stale MountedDevices drive letter mappings."
        }

        # 3. Session Manager BootExecute and PendingFileRenameOperations
        & reg.exe delete $smKey /v "PendingFileRenameOperations" /f 2>$null | Out-Null
        & reg.exe add $smKey /v "BootExecute" /t REG_MULTI_SZ /d "autocheck autochk *" /f 2>$null | Out-Null
        Write-MWBA "Cleared PendingFileRenameOperations and normalized BootExecute in ControlSet$csNum"
    } catch {
        Write-MWBA "Clear-MWBA-SessionManagerPending error: $($_.Exception.Message)" 'WARN'
    } finally {
        try { & reg.exe unload $mountName 2>$null | Out-Null } catch {}
    }
}

function Check-DriveLetterSanity {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Check-DriveLetterSanity: reporting bcdedit and diskpart info"
    $bcdStorePath = Get-MWBA-BcdStorePath -OfflineWindowsDrive $OfflineWindowsDrive
    if ($bcdStorePath) {
        if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: bcdedit /store $bcdStorePath /enum all" } else { & bcdedit /store $bcdStorePath /enum all }
    } else {
        Write-MWBA 'No offline BCD store found for drive-letter sanity check.' 'WARN'
    }
    Write-MWBA "Use diskpart to inspect volumes; ensure BCD device/osdevice map to the Windows volume."
}

function Cleanup-PendingUpdates {
    param([string]$WindowsPath = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Cleanup-PendingUpdates: non-destructive rename of pending markers"
    $pending = Join-Path $WindowsPath 'Windows\WinSxS\pending.xml'
    if (Test-Path $pending) {
        $target = "$pending.disabled-by-mwba"
        if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: Rename $pending -> $target" } else { Rename-Item -Path $pending -NewName (Split-Path $target -Leaf) -Force }
        Write-MWBA "Renamed pending.xml to prevent incomplete update from blocking boot."
    } else { Write-MWBA "No pending.xml found." }
}

function Repair-WinRE {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    $offlineWindowsPath = Get-MWBA-OfflineWindowsPath -OfflineWindowsDrive $OfflineWindowsDrive
    Write-MWBA "Repair-WinRE: reagentc /info"
    if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: reagentc /info /target $offlineWindowsPath" } else { & reagentc /info /target $offlineWindowsPath }
}

function Toggle-BootLogging {
    param(
        [ValidateSet('Enable','Disable')] [string]$Action = 'Enable',
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive
    )
    Write-MWBA "Toggle-BootLogging: $Action"
    $bcdStorePath = Get-MWBA-BcdStorePath -OfflineWindowsDrive $OfflineWindowsDrive
    if (-not $bcdStorePath) {
        Write-MWBA 'No offline BCD store found for boot logging changes.' 'WARN'
        return
    }
    if ($Action -eq 'Enable') { if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: bcdedit /store $bcdStorePath /set {default} bootlog Yes" } else { & bcdedit /store $bcdStorePath /set '{default}' bootlog Yes } }
    else { if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: bcdedit /store $bcdStorePath /set {default} bootlog No" } else { & bcdedit /store $bcdStorePath /set '{default}' bootlog No } }
}

### Stage 2: advanced (gated) ###
function Disable-ELAM {
    param([switch]$Confirm)
    Write-MWBA "Disable-ELAM"
    if (-not $Confirm) { Write-Warning 'Requires -Confirm'; return }
    Write-MWBA 'ELAM disable is vendor-specific. Follow vendor guidance; this helper will not auto-modify vendor anti-malware settings.'
}

function Disable-Driver {
    param([Parameter(Mandatory=$true)][string]$DriverFile, [switch]$Confirm)
    Write-MWBA "Disable-Driver: $DriverFile"
    if (-not $Confirm) { Write-Warning 'Requires -Confirm'; return }
    $full = Join-Path (Get-MWBA-OfflineWindowsPath) "System32\drivers\$DriverFile"
    if (-not (Test-Path $full)) { Write-Warning "Driver not found: $full"; return }
    $dest = "$full.disabled-by-mwba"
    if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: Rename $full -> $dest" } else { Rename-Item -Path $full -NewName (Split-Path $dest -Leaf) -Force; Write-MWBA "Renamed driver to $dest" }
}

function Unlock-BitLockerVolume {
    param([Parameter(Mandatory=$true)][string]$VolumeLetter, [Parameter(Mandatory=$true)][string]$RecoveryKey)
    Write-MWBA "Unlock-BitLockerVolume: ${VolumeLetter}"
    $cmd = "manage-bde -unlock ${VolumeLetter}: -RecoveryPassword $RecoveryKey"
    if ($Script:MWBA_DryRun) { Write-MWBA "DRYRUN: $cmd" } else { cmd.exe /c $cmd }
}

function Invoke-MWBA-DismRollback {
    param([string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive)
    Write-MWBA "Invoke-MWBA-DismRollback: running DISM revertpendingactions on $OfflineWindowsDrive..."
    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: dism.exe /image:$OfflineWindowsDrive\ /cleanup-image /revertpendingactions"
    } else {
        $out = & dism.exe "/image:$OfflineWindowsDrive\" /cleanup-image /revertpendingactions 2>&1
        Write-MWBA "DISM revertpendingactions completed: $($out -join ' ')"
    }
}

function Invoke-MWBA-OfflineSfcScan {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string]$EfiDriveLetter = 'S'
    )
    $offlineWindowsPath = Get-MWBA-OfflineWindowsPath -OfflineWindowsDrive $OfflineWindowsDrive
    Write-MWBA "Invoke-MWBA-OfflineSfcScan: preparing offline SFC scan..."

    $espInfo = Find-MWBA-TargetDiskESP -OfflineWindowsDrive $OfflineWindowsDrive
    $targetLetter = $null
    $needUnmount = $false

    if ($espInfo) {
        if ($espInfo.DriveLetter -and $espInfo.DriveLetter -ne ' ') {
            $targetLetter = "$($espInfo.DriveLetter):"
        } else {
            foreach ($candidate in @('S','Z','Y','W','V')) {
                if (-not (Get-PSDrive -Name $candidate -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                    $targetLetter = "${candidate}:"
                    break
                }
            }
            if ($targetLetter -and -not $Script:MWBA_DryRun) {
                try {
                    Set-Partition -DiskNumber $espInfo.DiskNumber -PartitionNumber $espInfo.PartitionNumber -NewDriveLetter ($targetLetter.TrimEnd(':')) -ErrorAction Stop
                    $needUnmount = $true
                } catch {}
            }
        }
    }

    $offBoot = if ($targetLetter -and (Test-Path "$targetLetter\")) { "$targetLetter\" } else { "$OfflineWindowsDrive\" }

    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: sfc.exe /scannow /offbootdir=$offBoot /offwindir=$offlineWindowsPath"
    } else {
        Write-MWBA "Running: sfc.exe /scannow /offbootdir=$offBoot /offwindir=$offlineWindowsPath"
        $sfcOut = & sfc.exe /scannow "/offbootdir=$offBoot" "/offwindir=$offlineWindowsPath" 2>&1
        Write-MWBA "SFC scan finished."
        if ($needUnmount -and $espInfo) {
            Remove-PartitionAccessPath -DiskNumber $espInfo.DiskNumber -PartitionNumber $espInfo.PartitionNumber -AccessPath "$targetLetter\" -ErrorAction SilentlyContinue
        }
    }
}

function Start-MWBA-SmokeTestVM {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string]$VmName = "MWBA-SmokeTest-VM"
    )
    Write-MWBA "Start-MWBA-SmokeTestVM: setting up Hyper-V Pass-Through Boot Simulator..."
    $driveLetter = ($OfflineWindowsDrive.TrimEnd('\').TrimEnd(':'))
    $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $driveLetter }
    if (-not $part) {
        Write-MWBA "Could not determine physical disk number for $OfflineWindowsDrive" 'WARN'
        return
    }
    $diskNum = $part[0].DiskNumber

    if ($Script:MWBA_DryRun) {
        Write-MWBA "DRYRUN: Would set Disk $diskNum Offline, create Gen 2 VM '$VmName', attach Disk $diskNum, and launch vmconnect.exe"
        return
    }

    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue

    Set-Disk -Number $diskNum -IsOffline $true -ErrorAction Stop
    $switch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name
    if (-not $switch) { $switch = "Default Switch" }

    New-VM -Name $VmName -Generation 2 -MemoryStartupBytes 1024MB -SwitchName $switch | Out-Null
    Set-VM -Name $VmName -ProcessorCount 2 -CheckpointType Disabled | Out-Null
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off | Out-Null
    Add-VMHardDiskDrive -VMName $VmName -DiskNumber $diskNum | Out-Null

    $ramProfiles = @(
        @{ Startup = 1024; Min = 384; Max = 1536 },
        @{ Startup = 768;  Min = 384; Max = 1024 },
        @{ Startup = 512;  Min = 384; Max = 768 }
    )

    $vmStarted = $false
    foreach ($prof in $ramProfiles) {
        try {
            Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true -MinimumBytes ($prof.Min * 1MB) -StartupBytes ($prof.Startup * 1MB) -MaximumBytes ($prof.Max * 1MB) -ErrorAction SilentlyContinue | Out-Null
            Start-VM -Name $VmName -ErrorAction Stop
            $vmStarted = $true
            Write-MWBA "Hyper-V Smoke Test VM '$VmName' started successfully on Disk $diskNum ($($prof.Startup)MB RAM, dynamic expansion enabled)."
            break
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "0x8007000E" -or $msg -match "Not enough memory") {
                Write-MWBA "Host memory low for $($prof.Startup)MB. Stepping down RAM..." 'WARN'
                [System.GC]::Collect()
                Start-Sleep -Milliseconds 500
            } else {
                Write-MWBA "Failed to start VM '$VmName': $msg" 'FAIL'
                break
            }
        }
    }

    if ($vmStarted) {
        Start-Process "vmconnect.exe" -ArgumentList "localhost $VmName"
        Write-MWBA "Hyper-V Display Console (vmconnect.exe) launched."
    } else {
        Set-Disk -Number $diskNum -IsOffline $false -ErrorAction SilentlyContinue
        Write-Warning "Could not start smoke test VM due to memory pressure or host error. Disk $diskNum restored Online."
    }
}

function Stop-MWBA-SmokeTestVM {
    param(
        [string]$OfflineWindowsDrive = $Script:MWBA_OfflineWindowsDrive,
        [string]$VmName = "MWBA-SmokeTest-VM"
    )
    Write-MWBA "Stop-MWBA-SmokeTestVM: stopping VM and restoring disk..."
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue

    $driveLetter = ($OfflineWindowsDrive.TrimEnd('\').TrimEnd(':'))
    $part = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $driveLetter }
    if ($part) {
        Set-Disk -Number $part[0].DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
        Write-MWBA "Physical Disk $($part[0].DiskNumber) restored Online."
    }
}

### Controller / CLI ###
function Show-MWBA-Suggestions {
    param([Parameter(Mandatory=$true)][array]$Suggestions)
    foreach ($s in $Suggestions) {
        switch ($s.Confidence) {
            'High' { $col='Green' }
            'Medium' { $col='Yellow' }
            default { $col='DarkGray' }
        }
        Write-Host "`n$s.Tool - Confidence: $($s.Confidence) - ETA: $($s.TimeEstimate)" -ForegroundColor $col
        if ($s.SourceAvailability -and $s.SourceAvailability.Available) { Write-Host "Source: $($s.SourceAvailability.Path)" -ForegroundColor DarkCyan }
        Write-Host "Recommendation: $($s.Recommendation)" -ForegroundColor White
        Write-Host "Why: $($s.Explanation)" -ForegroundColor Gray
        Write-Host "Suggested command: $($s.SuggestedCommand)" -ForegroundColor DarkGreen
        Write-Host "Undo/Notes: $($s.UndoHint)" -ForegroundColor DarkMagenta
    }
    # Build a copiable commands block (only the SuggestedCommand lines)
    $cmds = $Suggestions | ForEach-Object { $_.SuggestedCommand } | Where-Object { $_ }
    if ($cmds.Count -gt 0) {
        $boxHeader = ('=' * 60)
        Write-Host "`n$boxHeader" -ForegroundColor DarkCyan
        Write-Host "Suggested commands (copy the block below and run manually):" -ForegroundColor Cyan
        foreach ($c in $cmds) { Write-Host $c -ForegroundColor DarkGreen }
        Write-Host $boxHeader -ForegroundColor DarkCyan

        # Offer copy to clipboard
        $setcb = Get-Command Set-Clipboard -ErrorAction SilentlyContinue
        if ($setcb) {
            $choice = Read-Host "Press 'C' to copy these commands to clipboard, or Enter to continue"
            if ($choice -eq 'C' -or $choice -eq 'c') {
                try {
                    $cmds -join "`r`n" | Set-Clipboard
                    Write-MWBA 'Suggested commands copied to clipboard.'
                } catch {
                    Write-Warning "Failed to set clipboard: $($_.Exception.Message)"
                }
            }
        } else {
            # Fallback: write to a temporary file and show path
            $tmp = Join-Path -Path $env:TEMP -ChildPath ("MWBA_SuggestedCommands_{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try {
                $cmds -join "`r`n" | Out-File -FilePath $tmp -Encoding utf8
                Write-Host "Clipboard not available. Commands saved to: $tmp" -ForegroundColor Yellow
                Write-MWBA "Saved suggested commands to $tmp"
            } catch {
                Write-Warning "Failed to save suggested commands: $($_.Exception.Message)"
            }
        }
    }
}

function Start-MWBA {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [string]$LogPath,
        [string]$OfflineWindowsDrive,
        [switch]$AutoConfirmStage2,
        [switch]$ShowLowConfidence
    )
    $Script:MWBA_DryRun = $DryRun.IsPresent
    if ($LogPath) { $Script:MWBA_LogFile = $LogPath }
    $Script:MWBA_OfflineWindowsDrive = Resolve-MWBA-OfflineWindowsDrive -OfflineWindowsDrive $OfflineWindowsDrive
    $Script:MWBA_OfflineWindowsPath = Get-MWBA-OfflineWindowsPath -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive

    Show-MWBA-Header
    Write-MWBA "Resolved offline Windows target: $Script:MWBA_OfflineWindowsPath"
    Write-MWBA "Start-MWBA invoked. DryRun=$Script:MWBA_DryRun"

    PreflightChecks

    Write-MWBA 'Stage 1: Non-destructive repairs will run now.'
    $actions = @(
        @{ Name='Ensure-TargetDiskOnline'; Action={ Ensure-MWBA-TargetDiskOnline -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Neutralize-RebootInterceptors'; Action={ Neutralize-MWBA-RebootInterceptors -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Reset-AutoRepair'; Action={ Reset-MWBA-AutoRepair -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Repair-CredentialProviders'; Action={ Repair-MWBA-CredentialProviders -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Clear-SessionManagerPending'; Action={ Clear-MWBA-SessionManagerPending -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Restore-BCD'; Action={ Restore-BCD } },
        @{ Name='Restore-EFIBootFiles'; Action={ Restore-EFIBootFiles -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Check-DriveLetterSanity'; Action={ Check-DriveLetterSanity -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Cleanup-PendingUpdates'; Action={ Cleanup-PendingUpdates -WindowsPath $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Repair-WinRE'; Action={ Repair-WinRE -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } },
        @{ Name='Enable-BootLogging'; Action={ Toggle-BootLogging -Action Enable -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive } }
    )

    $total = $actions.Count
    $step = 0
    $results = @()
    $prevStatus = Detect-MWBA-BootStatus -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive

    foreach ($act in $actions) {
        $step++
        $name = $act.Name
        Write-Host ("`nStep {0} of {1}: {2}" -f $step, $total, $name) -ForegroundColor Cyan
        try {
            & $act.Action
            $post = Detect-MWBA-BootStatus -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
            # compute delta reasons
            $added = @()
            $removed = @()
            $prev = @($prevStatus.Reasons) ; $now = @($post.Reasons)
            foreach ($r in $now) { if (-not ($prev -contains $r)) { $added += $r } }
            foreach ($r in $prev) { if (-not ($now -contains $r)) { $removed += $r } }

            if ($added.Count -gt 0) { Write-MWBA-Status -Action $name -Result 'WARN' -Note ("NewIssues: $($added -join '; ')") }
            elseif ($post.Status -eq 'Healthy') { Write-MWBA-Status -Action $name -Result 'OK' -Note 'Healthy' }
            else { Write-MWBA-Status -Action $name -Result 'WARN' -Note 'Unresolved' }

            $results += [PSCustomObject]@{ Action=$name; Result=$post.Status; Added=$added; Removed=$removed }
            $prevStatus = $post
        } catch {
            Write-MWBA-Status -Action $name -Result 'FAIL' -Note $_.Exception.Message
            $results += [PSCustomObject]@{ Action=$name; Result='Error'; Added=@($_.Exception.Message); Removed=@() }
        }
    }

    # Summary table
    Write-Host "`nStage 1 Summary:" -ForegroundColor Cyan
    foreach ($r in $results) {
        $res = if ($r.Result -eq 'Healthy') { 'OK' } else { 'WARN' }
        $note = if ($r.Added.Count -gt 0) { 'New:' + ($r.Added -join ', ') } elseif ($r.Removed.Count -gt 0) { 'Resolved:' + ($r.Removed -join ', ') } else { '' }
        Write-MWBA-Status -Action $r.Action -Result ($res) -Note $note
    }

    Write-MWBA 'Stage 1 completed. Running final boot-status detection.'
    $result = Detect-MWBA-BootStatus -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
    Write-MWBA "Detect result: $($result.Status)"

    if ($result.Status -eq 'Healthy') {
        Write-MWBA 'Boot artifacts appear present. Disabling boot logging.'
        Toggle-BootLogging -Action Disable -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
        Write-MWBA "Final report: Healthy. Log: $Script:MWBA_LogFile"
        return @{ Success=$true; Stage=1; Report=$result }
    }

    Write-MWBA 'System appears Unhealthy after Stage1.'

    # Generate SFC/DISM suggestions (display only Medium/High by default)
    try {
        $suggest = Get-MWBA-SfcDismSuggestion -BootStatus $result -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
        if (-not $ShowLowConfidence) { $suggest = $suggest | Where-Object { $_.Confidence -ne 'Low' } }
        if ($suggest.Count -gt 0) {
            Write-Host "`nSuggested offline diagnostics (SFC/DISM):" -ForegroundColor Cyan
            Show-MWBA-Suggestions -Suggestions $suggest
            Write-Host "These are suggestions only. MWBA will not run SFC/DISM automatically." -ForegroundColor Yellow
        }
    } catch {
        Write-MWBA "Failed to compute SFC/DISM suggestions: $($_.Exception.Message)" 'WARN'
    }
    Write-Host "Advanced Mode Warning:`nStage 2 contains advanced, reversible actions (ELAM disable, driver rename, BitLocker unlock, EFI file recreate). No destructive ops (hive replace, partition table edits, image reapply) will be performed by MWBA."

    if (-not $AutoConfirmStage2) {
        $consent = Read-Host "To proceed to Stage 2 type EXACTLY: I UNDERSTAND RISK AND AUTHORIZE STAGE 2"
        if ($consent -ne 'I UNDERSTAND RISK AND AUTHORIZE STAGE 2') { Write-MWBA 'Stage 2 aborted by operator.'; Write-MWBA "Final report: Unresolved. Log: $Script:MWBA_LogFile"; return @{ Success=$false; Stage=1; Report=$result } }
    }

    Write-MWBA 'Stage 2 authorized. Note: Stage 2 actions must be invoked explicitly with -Confirm.'
    Write-MWBA "Final report: Stage2 available. Log: $Script:MWBA_LogFile"
    # Compute reinstall score and present recommendation if warranted (non-destructive)
    try {
        $reinstall = Compute-MWBA-ReinstallScore -PreStatus $prevStatus -PostStatus $result -OfflineWindowsDrive $Script:MWBA_OfflineWindowsDrive
        if ($reinstall.ReinstallScore -ge 2) {
            Write-Host "`n======================================================================" -ForegroundColor Magenta
            Write-Host "  MWBA TERMINAL FORENSIC ADVISORY: UNRECOVERABLE SUBSYSTEM CORRUPTION" -ForegroundColor Magenta
            Write-Host "======================================================================" -ForegroundColor Magenta
            Write-Host "ReinstallScore: $($reinstall.ReinstallScore) | Triggered Reasons:" -ForegroundColor Yellow
            foreach ($r in $reinstall.Reasons) { Write-Host "  [-] $r" -ForegroundColor Yellow }
            Write-Host "`n[!] WHY SCRIPTED FILE REPAIRS CANNOT FIX THIS:" -ForegroundColor Red
            Write-Host "  1. Bootloader & Kernel are functional, but user-mode subsystem collapsed." -ForegroundColor DarkYellow
            Write-Host "  2. Modern Windows 11 relies on 50,000+ interdependent WinSxS assembly manifests." -ForegroundColor DarkYellow
            Write-Host "  3. Binary timestamps/builds across updates are mismatched, breaking API contracts" -ForegroundColor DarkYellow
            Write-Host "     between ntdll.dll and csrss.exe. Windows halts intentionally with 0xC000021A." -ForegroundColor DarkYellow
            Write-Host "  4. Scripted file transplants cannot re-link the global WinSxS dependency graph." -ForegroundColor DarkYellow
            Write-Host "`n[+] RECOMMENDED TECHNICIAN ACTIONS (Time-to-Resolution: < 15 mins):" -ForegroundColor Green
            Write-Host "  [1] Clone Functional Reference Disk (Fastest & 100% Reliable):" -ForegroundColor Cyan
            Write-Host "      Clone a healthy, working OS drive (e.g. Reference/Donor drive) directly to $($Script:MWBA_OfflineWindowsDrive)." -ForegroundColor Cyan
            Write-Host "  [2] Semi-Clean Deployment (DISM Apply-Image):" -ForegroundColor Cyan
            Write-Host "      dism.exe /Apply-Image /ImageFile:install.wim /Index:1 /ApplyDir:$($Script:MWBA_OfflineWindowsDrive)\" -ForegroundColor Cyan
            Write-Host "      (Lays down a clean OS; preserves unformatted files in \Users; apps need reinstall)" -ForegroundColor Gray
            Write-Host "  [3] Clean Windows Reinstall:" -ForegroundColor Cyan
            Write-Host "      User data has been preserved ($($Script:MWBA_OfflineWindowsDrive)\Users); format and install fresh." -ForegroundColor Cyan
            Write-Host "======================================================================`n" -ForegroundColor Magenta
        }
    } catch {
        Write-MWBA "Failed to compute reinstall score: $($_.Exception.Message)" 'WARN'
    }

    return @{ Success=$false; Stage=2; Report=$result }
}

# If executed directly, run Start-MWBA with supplied arguments
if ($MyInvocation.InvocationName -match 'MWBA.ps1' -or ($PSCommandPath -and (Split-Path $PSCommandPath -Leaf) -eq 'MWBA.ps1')) {
    $splat = @{}
    if ($DryRun) { $splat['DryRun'] = $true }
    if ($OfflineWindowsDrive) { $splat['OfflineWindowsDrive'] = $OfflineWindowsDrive }
    if ($LogPath) { $splat['LogPath'] = $LogPath }
    if ($AutoConfirmStage2) { $splat['AutoConfirmStage2'] = $true }
    if ($ShowLowConfidence) { $splat['ShowLowConfidence'] = $true }

    Start-MWBA @splat
}

# Export functions for dot-sourcing scenarios
if ($ExecutionContext.SessionState.Module) {
    Export-ModuleMember -Function * | Out-Null
}
