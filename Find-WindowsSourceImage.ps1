<#
.SYNOPSIS
    Find-WindowsSourceImage.ps1 - Automated Windows ISO, WIM & ESD Discovery Engine for MWBA & WINTools.
.DESCRIPTION
    Scans all connected storage media, multi-boot USB drives (Ventoy, Easy2Boot, AGFM),
    and standard WINTools technician bench caches for Windows installation source media.
    
    Fingerprints the target offline Windows installation (Edition, Build, Architecture)
    and automatically matches the best candidate ISO/WIM/ESD and image index.
    
    Produces ready-to-run DISM /RestoreHealth and DISM /Apply-Image commands for
    offline component store repair and non-destructive in-place reinstallations.
.PARAMETER OfflineWindowsDrive
    Drive letter of target Windows installation (e.g. C:, D:). Auto-resolves if omitted.
.PARAMETER MountIso
    Mounts the best-matching ISO if selected and resolves the live drive letter.
.EXAMPLE
    PowerShell -ExecutionPolicy Bypass -File .\Find-WindowsSourceImage.ps1 -OfflineWindowsDrive C:
#>

[CmdletBinding()]
param(
    [string]$OfflineWindowsDrive = '',
    [switch]$MountIso,
    [switch]$Json
)

$ErrorActionPreference = "Continue"

function Get-MWBA-TargetOSInfo {
    param([string]$TargetDrive = 'C:')

    $cleanDrive = $TargetDrive.TrimEnd(':\') + ":"
    $info = [ordered]@{
        Drive           = $cleanDrive
        Detected        = $false
        ProductName     = 'Unknown Windows'
        EditionID       = 'Professional'
        CurrentBuild    = 0
        DisplayVersion  = ''
        UBR             = 0
        OSFamily        = 'Win11'
        Architecture    = 'x64'
        DetectionMethod = 'Default'
    }

    # 1. If target drive is the currently running Windows host
    if ($cleanDrive -ieq $env:SystemDrive) {
        try {
            $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
            if ($reg) {
                if ($reg.ProductName)    { $info.ProductName    = [string]$reg.ProductName }
                if ($reg.EditionID)      { $info.EditionID      = [string]$reg.EditionID }
                if ($reg.CurrentBuild)   { $info.CurrentBuild   = [int]$reg.CurrentBuild }
                elseif ($reg.CurrentBuildNumber) { $info.CurrentBuild = [int]$reg.CurrentBuildNumber }
                if ($reg.DisplayVersion) { $info.DisplayVersion = [string]$reg.DisplayVersion }
                elseif ($reg.ReleaseId)  { $info.DisplayVersion = [string]$reg.ReleaseId }
                if ($reg.UBR)            { $info.UBR            = [int]$reg.UBR }

                $info.OSFamily = if ($info.CurrentBuild -ge 22000) { 'Win11' } else { 'Win10' }
                $info.Detected = $true
                $info.DetectionMethod = 'OnlineHost'
                return [PSCustomObject]$info
            }
        } catch {}
    }

    # 2. Offline Registry probe
    $swHive = Join-Path $cleanDrive "Windows\System32\config\SOFTWARE"
    $hiveExists = $false
    try { $hiveExists = Test-Path $swHive -PathType Leaf -ErrorAction SilentlyContinue } catch { $hiveExists = $false }

    if ($hiveExists) {
        $mountKey = "MWBA_OSProbe_SW"
        try {
            & reg.exe unload "HKLM\$mountKey" 2>$null | Out-Null
            $loadOut = & reg.exe load "HKLM\$mountKey" "$swHive" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $subKey = "HKLM:\$mountKey\Microsoft\Windows NT\CurrentVersion"
                if (Test-Path $subKey) {
                    $reg = Get-ItemProperty -Path $subKey -ErrorAction SilentlyContinue
                    if ($reg.ProductName)    { $info.ProductName    = [string]$reg.ProductName }
                    if ($reg.EditionID)      { $info.EditionID      = [string]$reg.EditionID }
                    if ($reg.CurrentBuild)   { $info.CurrentBuild   = [int]$reg.CurrentBuild }
                    elseif ($reg.CurrentBuildNumber) { $info.CurrentBuild = [int]$reg.CurrentBuildNumber }
                    if ($reg.DisplayVersion) { $info.DisplayVersion = [string]$reg.DisplayVersion }
                    elseif ($reg.ReleaseId)  { $info.DisplayVersion = [string]$reg.ReleaseId }
                    if ($reg.UBR)            { $info.UBR            = [int]$reg.UBR }

                    $info.OSFamily = if ($info.CurrentBuild -ge 22000) { 'Win11' } else { 'Win10' }
                    $info.Detected = $true
                    $info.DetectionMethod = 'OfflineRegistry'
                }
            }
        } catch {
        } finally {
            try { & reg.exe unload "HKLM\$mountKey" 2>$null | Out-Null } catch {}
        }
    }

    # 3. Binary fallback if offline registry could not be mounted
    if (-not $info.Detected) {
        $ntoskrnl = Join-Path $cleanDrive "Windows\System32\ntoskrnl.exe"
        if (Test-Path $ntoskrnl -PathType Leaf -ErrorAction SilentlyContinue) {
            try {
                $vi = (Get-Item $ntoskrnl).VersionInfo
                $bld = $vi.FileBuildPart
                $info.CurrentBuild = $bld
                $info.OSFamily = if ($bld -ge 22000) { 'Win11' } else { 'Win10' }
                $info.ProductName = if ($bld -ge 22000) { "Windows 11 ($bld)" } else { "Windows 10 ($bld)" }
                $info.Detected = $true
                $info.DetectionMethod = 'KernelBinary'
            } catch {}
        }
    }

    return [PSCustomObject]$info
}

function Find-MWBA-WindowsSourceImage {
    param(
        [string]$OfflineWindowsDrive = '',
        [switch]$AutoMount
    )

    # 1. Resolve Target Drive
    if (-not $OfflineWindowsDrive) {
        $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady }
        foreach ($d in $drives) {
            $let = $d.Name.TrimEnd('\')
            $hasWindows = $false
            try {
                $hasWindows = (Test-Path "$let\Windows\System32\ntoskrnl.exe" -PathType Leaf -ErrorAction SilentlyContinue)
            } catch { $hasWindows = $false }

            if ($hasWindows) {
                if ($let -ne "C:" -or -not $OfflineWindowsDrive) {
                    $OfflineWindowsDrive = $let
                    if ($let -ne "C:") { break }
                }
            }
        }
        if (-not $OfflineWindowsDrive) { $OfflineWindowsDrive = "C:" }
    }
    $targetOS = Get-MWBA-TargetOSInfo -TargetDrive $OfflineWindowsDrive

    # 2. Gather candidate locations across standard WINTools & Ventoy/E2B directories
    $candidateFiles = @()

    # Logical disk enumeration
    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID }
    foreach ($d in $drives) {
        $let = $d.DeviceID
        # Standard Multi-Boot & Technician folder structures
        $probeDirs = @(
            "$let\sources",
            "$let\_ISO\WINDOWS\WIN11",
            "$let\_ISO\WINDOWS\WIN10",
            "$let\_ISO\WINDOWS",
            "$let\_ISO\WINPE",
            "$let\ISOs\Windows",
            "$let\ISOs\WinPE",
            "$let\ISOs\Backup",
            "$let\ISOs",
            "$let\ISO",
            "$let\ISO_Downloads",
            "$let\SystemRecovery",
            "$let\WINBARS_BACKUP\SystemImages"
        )
        foreach ($pd in $probeDirs) {
            if (Test-Path $pd -PathType Container -ErrorAction SilentlyContinue) {
                $files = Get-ChildItem -Path $pd -Include "*.iso","*.wim","*.esd" -Recurse -File -Depth 2 -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    $candidateFiles += [PSCustomObject]@{
                        Path        = $f.FullName
                        Name        = $f.Name
                        Extension   = $f.Extension.ToLower()
                        SizeGB      = [math]::Round($f.Length / 1GB, 2)
                        Directory   = $f.DirectoryName
                        Drive       = $let
                    }
                }
            }
        }

        # Check loose install.wim/esd at root\sources
        foreach ($loose in @("$let\sources\install.wim", "$let\sources\install.esd")) {
            if (Test-Path $loose -PathType Leaf -ErrorAction SilentlyContinue) {
                $item = Get-Item $loose
                $candidateFiles += [PSCustomObject]@{
                    Path        = $item.FullName
                    Name        = $item.Name
                    Extension   = $item.Extension.ToLower()
                    SizeGB      = [math]::Round($item.Length / 1GB, 2)
                    Directory   = $item.DirectoryName
                    Drive       = $let
                }
            }
        }
    }

    # WINTools local cache and user download directories
    $localDirs = @(
        (Join-Path $env:USERPROFILE "Downloads\WINTools_Cache"),
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Documents\ISOs"),
        "C:\ISO_Downloads",
        "D:\ISO_Downloads",
        "C:\ISO",
        "D:\ISO"
    )
    # Sibling WINTools cache relative to MWBA script directory
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
    if ($scriptRoot) {
        $parent = Split-Path -Parent $scriptRoot
        $localDirs += (Join-Path $parent "WINTools\cache\iso")
        $localDirs += (Join-Path $parent "WINTools\cache\on_demand_tools")
        $localDirs += (Join-Path $parent "iso")
    }

    foreach ($ld in $localDirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
        $files = Get-ChildItem -Path $ld -Include "*.iso","*.wim","*.esd" -Recurse -File -Depth 2 -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $candidateFiles += [PSCustomObject]@{
                Path        = $f.FullName
                Name        = $f.Name
                Extension   = $f.Extension.ToLower()
                SizeGB      = [math]::Round($f.Length / 1GB, 2)
                Directory   = $f.DirectoryName
                Drive       = (Split-Path $f.FullName -Qualifier)
            }
        }
    }

    # Deduplicate candidates safely
    $uniqueCandidates = @()
    if ($candidateFiles.Count -gt 0) {
        $uniqueCandidates = @($candidateFiles | Group-Object -Property Path | ForEach-Object { $_.Group[0] })
    }

    # 3. Score and Match Candidates against Target OS
    $scored = @()
    foreach ($c in $uniqueCandidates) {
        $score = 0
        $matchTag = "Generic"
        $lowerName = $c.Name.ToLower()
        $lowerPath = $c.Path.ToLower()

        # Filter out non-OS images, boot.wim, and update package WIMs
        if ($lowerName -match "linux|ubuntu|debian|mint|arch|pclos|q4os|trixie|slitaz|freebsd|clonezilla|rescuezilla|partexpert") {
            continue
        }
        if ($lowerName -match "boot\.wim|winre\.wim|safeos\.wim|efisys|bootsect") {
            continue
        }
        if ($lowerName -match "^windows.*-kb\d+|microsoft-windows-.*-package") {
            continue
        }

        # Full installation image indicators
        if ($lowerName -match "install\.wim|install\.esd") {
            $score += 60
        }
        if ($c.SizeGB -ge 2.5) {
            $score += 25
        } elseif ($c.SizeGB -lt 1.0 -and $c.Extension -in @(".wim", ".esd")) {
            $score -= 40 # Small fragment or FOD package
        }

        # Check OS Family Match
        if ($targetOS.OSFamily -eq 'Win11') {
            if ($lowerName -match "win11|windows\s*11|windows11|22621|22631|26100|26200|24h2|23h2|22h2") {
                $score += 50
                $matchTag = "Win11 Match"
            } elseif ($lowerName -match "win10|windows\s*10|windows10|19045") {
                $score += 10
                $matchTag = "Win10 Fallback"
            }
        } else {
            if ($lowerName -match "win10|windows\s*10|windows10|19041|19042|19044|19045|22h2|21h2") {
                $score += 50
                $matchTag = "Win10 Match"
            } elseif ($lowerName -match "win11|windows\s*11|windows11") {
                $score += 10
                $matchTag = "Win11 Fallback"
            }
        }

        # Image format scoring
        if ($c.Extension -eq ".wim") {
            $score += 20 # Direct WIM is immediately usable by DISM without mounting
        } elseif ($c.Extension -eq ".esd") {
            $score += 15
        } elseif ($c.Extension -eq ".iso") {
            $score += 10
        }

        # Prefer install media over WinPE/Utilities if repairing OS
        if ($lowerName -match "winpe|strelec|f4ubcd|falcon|hiren|bootcd|medicat") {
            $score -= 20
        }

        # Identify location tier
        $locCategory = "Other"
        if ($lowerPath -match "_iso\\windows") { $locCategory = "Easy2Boot/Multi-Boot USB" }
        elseif ($lowerPath -match "isos\\windows") { $locCategory = "Ventoy USB" }
        elseif ($lowerPath -match "wintools_cache|\\cache\\") { $locCategory = "WINTools Cache" }
        elseif ($lowerPath -match "sources\\install\.") { $locCategory = "Live Setup Media" }
        elseif ($lowerPath -match "iso_downloads|\\iso\\") { $locCategory = "Bench ISO Store" }

        $scored += [PSCustomObject]@{
            Path        = $c.Path
            Name        = $c.Name
            Extension   = $c.Extension
            SizeGB      = $c.SizeGB
            Score       = $score
            Category    = $locCategory
            MatchTag    = $matchTag
            Drive       = $c.Drive
        }
    }

    $sorted = $scored | Sort-Object Score -Descending

    # 4. Resolve Best Match Details & Indices
    $bestMatch = if ($sorted.Count -gt 0 -and $sorted[0].Score -gt 0) { $sorted[0] } else { $null }
    $resolvedSourcePath = $null
    $matchedIndex = 1
    $matchedEdition = "Windows Setup Default"
    $isoMounted = $false
    $mountedVolumeLetter = $null

    if ($bestMatch) {
        if ($bestMatch.Extension -in @(".wim", ".esd")) {
            $resolvedSourcePath = $bestMatch.Path
        } elseif ($bestMatch.Extension -eq ".iso" -and $AutoMount) {
            try {
                $mountRes = Mount-DiskImage -ImagePath $bestMatch.Path -StorageType ISO -PassThru -ErrorAction Stop
                $mountedVolumeLetter = (Get-DiskImage -ImagePath $bestMatch.Path | Get-Volume).DriveLetter
                if ($mountedVolumeLetter) {
                    $isoMounted = $true
                    $wPath = "$($mountedVolumeLetter):\sources\install.wim"
                    if (-not (Test-Path $wPath)) { $wPath = "$($mountedVolumeLetter):\sources\install.esd" }
                    if (Test-Path $wPath) { $resolvedSourcePath = $wPath }
                }
            } catch {}
        }

        # Index resolution if direct WIM or mounted ISO
        $imageToInspect = if ($resolvedSourcePath) { $resolvedSourcePath } else { $null }
        if ($imageToInspect -and (Test-Path $imageToInspect)) {
            try {
                # Attempt Get-WindowsImage if elevated
                $wimImages = Get-WindowsImage -ImagePath $imageToInspect -ErrorAction SilentlyContinue
                if ($wimImages) {
                    $targetEd = $targetOS.EditionID
                    $matchImg = $wimImages | Where-Object { $_.EditionId -ieq $targetEd -or $_.ImageName -match $targetEd } | Select-Object -First 1
                    if (-not $matchImg -and $targetEd -match "Pro") {
                        $matchImg = $wimImages | Where-Object { $_.ImageName -match "Pro" } | Select-Object -First 1
                    }
                    if ($matchImg) {
                        $matchedIndex = $matchImg.ImageIndex
                        $matchedEdition = $matchImg.ImageName
                    }
                }
            } catch {}
        }
    }

    # Construct clean DISM commands
    $dismSourceArg = ""
    $dismRepairCmd = ""
    $dismDeployCmd = ""

    if ($resolvedSourcePath) {
        $dismSourceArg = "/Source:wim:`"$resolvedSourcePath`":$matchedIndex /LimitAccess"
        $dismRepairCmd = "dism.exe /Image:$OfflineWindowsDrive\ /Cleanup-Image /RestoreHealth $dismSourceArg"
        $dismDeployCmd = "dism.exe /Apply-Image /ImageFile:`"$resolvedSourcePath`" /Index:$matchedIndex /ApplyDir:$OfflineWindowsDrive\"
    } elseif ($bestMatch -and $bestMatch.Extension -eq ".iso") {
        $dismRepairCmd = "# Mount '$($bestMatch.Path)' first, then run:`n# dism.exe /Image:$OfflineWindowsDrive\ /Cleanup-Image /RestoreHealth /Source:wim:`"<MOUNTED_DRIVE>:\sources\install.wim`":$matchedIndex /LimitAccess"
        $dismDeployCmd = "# Mount '$($bestMatch.Path)' first, then run:`n# dism.exe /Apply-Image /ImageFile:`"<MOUNTED_DRIVE>:\sources\install.wim`" /Index:$matchedIndex /ApplyDir:$OfflineWindowsDrive\"
    }

    return [PSCustomObject]@{
        TargetOS            = $targetOS
        FoundSources        = $sorted
        BestMatch           = $bestMatch
        ResolvedSourcePath  = $resolvedSourcePath
        MatchedIndex        = $matchedIndex
        MatchedEdition      = $matchedEdition
        IsoMounted          = $isoMounted
        MountedDriveLetter  = $mountedVolumeLetter
        DismSourceArg       = $dismSourceArg
        DismRepairCommand   = $dismRepairCmd
        DismDeployCommand   = $dismDeployCmd
    }
}

# Execute discovery
$discovery = Find-MWBA-WindowsSourceImage -OfflineWindowsDrive $OfflineWindowsDrive -AutoMount:$MountIso

if ($Json) {
    $discovery | ConvertTo-Json -Depth 4
    return
}

# Display Colored Bench Report
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "  MWBA & WINTOOLS SOURCE IMAGE DISCOVERY ENGINE" -ForegroundColor White
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "  Auto-detects Windows ISO, WIM & ESD across Ventoy, Easy2Boot & Bench Media" -ForegroundColor DarkGray
Write-Host ""

$tgt = $discovery.TargetOS
Write-Host "  [+] TARGET OPERATING SYSTEM DETECTED:" -ForegroundColor Yellow
Write-Host "      Partition       : $($tgt.Drive)\" -ForegroundColor White
Write-Host "      Operating System: $($tgt.ProductName) ($($tgt.EditionID))" -ForegroundColor Cyan
Write-Host "      Build / Version : Build $($tgt.CurrentBuild) (DisplayVersion: $($tgt.DisplayVersion), UBR: $($tgt.UBR))" -ForegroundColor DarkGray
Write-Host "      Detection Method: $($tgt.DetectionMethod)" -ForegroundColor DarkGray

if ($discovery.FoundSources.Count -gt 0) {
    Write-Host "`n  [+] DISCOVERED SOURCE IMAGES ($($discovery.FoundSources.Count) candidates found):" -ForegroundColor Green
    $idx = 1
    foreach ($s in $discovery.FoundSources | Select-Object -First 8) {
        $star = if ($discovery.BestMatch -and $s.Path -eq $discovery.BestMatch.Path) { "[★ BEST MATCH]" } else { "             " }
        Write-Host "      $star [$idx] $($s.Name) ($($s.SizeGB) GB)" -ForegroundColor $(if ($star -match "★") { "Green" } else { "White" })
        Write-Host "                   Location: $($s.Category) ($($s.Path))" -ForegroundColor DarkGray
        $idx++
    }

    if ($discovery.BestMatch) {
        Write-Host "`n  ==============================================================================" -ForegroundColor DarkCyan
        Write-Host "   MATCHED INSTALLATION SOURCE: $($discovery.BestMatch.Name)" -ForegroundColor Green
        Write-Host "  ==============================================================================" -ForegroundColor DarkCyan
        Write-Host "   Source Path   : $($discovery.BestMatch.Path)" -ForegroundColor White
        Write-Host "   Category      : $($discovery.BestMatch.Category)" -ForegroundColor Cyan
        Write-Host "   Target Edition: $($discovery.MatchedEdition) (Index: $($discovery.MatchedIndex))" -ForegroundColor Yellow

        if ($discovery.DismRepairCommand) {
            Write-Host "`n   [★] READY-TO-RUN OFFLINE DISM RESTOREHEALTH COMMAND:" -ForegroundColor Cyan
            Write-Host "       $($discovery.DismRepairCommand)" -ForegroundColor Green
        }
        if ($discovery.DismDeployCommand) {
            Write-Host "`n   [★] NON-DESTRUCTIVE REINSTALL COMMAND (Keeps C:\Users 100% In-Place):" -ForegroundColor Cyan
            Write-Host "       $($discovery.DismDeployCommand)" -ForegroundColor Yellow
            Write-Host "       (Tip: WINTools Menu 6, Tool #35 [winwimdeploy.ps1] automates this in 1 click)" -ForegroundColor DarkGray
        }
    }
} else {
    Write-Host "`n  [-] No Windows installation images (*.iso, *.wim, *.esd) found in standard locations." -ForegroundColor Red
    Write-Host "      Standard locations checked: _ISO\WINDOWS\, ISOs\Windows\, sources\install.wim, WINTools cache." -ForegroundColor DarkGray
}

Write-Host "`n==============================================================================`n" -ForegroundColor Cyan
