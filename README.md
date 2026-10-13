# 🏛️ MWBA — Make Windows Bootable Again™
> *"Our Administration will try to keep our sacred promise of Making Windows Bootable Again."*

```text
 __  __ _        ______    _    
|  \/  \ \      / / __ )  / \   
| |\/| |\ \ /\ / /|  _ \ / _ \  
| |  | | \ V  V / | |_) / ___ \ 
|_|  |_|  \_/\_/  |____/_/   \_\
```

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server-blue.svg)](https://microsoft.com)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://microsoft.com/powershell)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Public%20Beta-brightgreen.svg)]()
[![Tools](https://img.shields.io/badge/Explore%20Tools-RemarkablePC-0078D4?logo=github&logoColor=white)](https://github.com/remarkablepc)
[![Say Thanks](https://img.shields.io/badge/Say%20Thanks-PayPal-00457C?logo=paypal&logoColor=white)](https://www.paypal.com/ncp/payment/EKH76RTYHH24S?uhm=MWBA)
[![Sponsor](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-EA4AAA?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/remarkablepc?uhm=MWBA)

**MWBA (Make Windows Bootable Again)** is an automated, technician-grade offline Windows boot repair, forensic verification, and triage platform. It unites offline registry auditing, EFI/BCD reconstruction, filter driver sanitization, cryptographic catalog store repair, donor system transplants, and Hyper-V pass-through VM smoke testing into a single resilient, bipartisan recovery workflow.

---

## 🚨 The Friday 4:55 PM Emergency (The Payroll Crisis)

> *"When a frantic business owner charges through the shop door at 4:55 PM on a Friday sweating through their collar shouting:*  
> **'Windows says INACCESSIBLE_BOOT_DEVICE! I have no backups, payroll runs tomorrow morning, and it’s YOUR FAULT if my employees don't get paid if I don't have this back today!'**  
> *...there are no Democrats or Republicans in the repair bay.*  
> *There is only sheer adrenaline, cold coffee, quiet prayer, and `MWBA.bat`."*

MWBA was engineered specifically for bench technicians, sysadmins, and repair shops facing non-bootable Windows systems where clean reinstallation or data loss is not an option. It systematically isolates the failure layer, performs targeted surgical fixes, and verifies bootability before you hand the machine back across the counter.

---

## ✨ Key Features & Capabilities

* **🛡️ Two-Stage Safe Triage Workflow**:
  * **Stage 1 (Non-Destructive Baseline)**: Audits BCD configuration, tests offline registry hive mountability, inspects WinSxS integrity, detects update rollback loops, and extracts crash forensics without modifying a single byte on the target disk.
  * **Stage 2 (Surgical Repair)**: Confirmation-gated repairs that execute only the specific fixes needed for the diagnosed failure.
* **🔄 Automated UEFI & BCD Reconstruction**:
  * Auto-discovers EFI System Partitions (ESP) across all connected disks.
  * Replaces corrupted `{bootmgr}` entries and reconstructs clean BCD stores using native `bcdboot` injection.
  * Surgically fixes BCD errors `0xc0000034`, `0xc000000e`, and `0xc0000098`.
* **🧹 Rogue Filter Driver & Storage Sanitization (`0x7B`)**:
  * Scans offline `SYSTEM` registry hives for orphaned third-party `UpperFilters` and `LowerFilters` (frequently left behind by uninstalled antivirus, EDR, or disk filter drivers).
  * Automatically demotes missing or disabled critical boot drivers to resolve `INACCESSIBLE_BOOT_DEVICE`.
* **🛑 System Restore Loop Disarmament**:
  * Cleans stalled `DelayedOperations` and `FRStaging` registry locks left behind after an interrupted or crashed Windows System Restore.
  * Resets `RestoreContinuationState` flags in the `SOFTWARE` hive to break endless rollback loops.
* **🔐 Cryptographic Catalog & CatRoot Repair (`0xC000021A`)**:
  * Audits and repairs damaged `CatRoot` and `CatRoot2` databases.
  * Resolves `0xC000021A / STATUS_INVALID_IMAGE_HASH` boot loops caused by desynchronized catalog signatures.
* **🧬 Surgical Donor Drive Transplants**:
  * Allows transplanting verified catalog stores, clean system binaries (`smss.exe`, `winlogon.exe`, `ntoskrnl.exe`), and boot driver hives from a healthy donor/reference drive.
* **📊 Scientific Reinstall Scoring & Stop-Loss Advisory**:
  * Calculates an objective **Reinstall Score (0–100)** based on WinSxS corruption, hive damage, and pending transaction states.
  * Tells technicians honestly when a system is salvageable versus when continuing to troubleshoot will waste shop hours.
* **🖥️ Isolated Hyper-V VM Smoke Testing**:
  * Boots the physical offline customer disk inside a sandboxed Gen 2 Hyper-V virtual machine with Secure Boot enabled.
  * Validates complete OS bootability to the Windows login screen without risking host BSODs or rebooting your bench workstation.
* **🕵️ Pre-Flight Forensic Log Collection**:
  * Exports minidumps, `MEMORY.DMP`, `ntbtlog.txt`, and offline `System.evtx` logs before any repair steps touch the drive.
* **⚡ 100% Native Scripting (Zero AV False Positives)**:
  * Pure PowerShell and Batch. Zero compiled `.exe` binaries, zero third-party wrappers, and zero false-positive alerts from Defender or enterprise EDR.
  * Injects C# P/Invoke routines to acquire `SeBackupPrivilege`, `SeRestorePrivilege`, and `SeTakeOwnershipPrivilege` on the fly.

---

## 🎯 The 3 Failure Zones MWBA Diagnoses

| Zone | Failure Code | Culprit | MWBA Resolution |
| :--- | :--- | :--- | :--- |
| **Zone 1: Bootloader & EFI** | `0xC000000E`<br>`0xC0000034`<br>`0xC0000098` | Corrupt BCD, missing `{bootmgr}`, corrupted ESP partition | Native `bcdboot` injection, clean BCD rebuild, dual-boot entry injection via `Fix-BCDError34.ps1` or `Add-DualBootEntry.ps1`. |
| **Zone 2: Kernel & Storage** | `INACCESSIBLE_BOOT_DEVICE`<br>`(0x0000007B)` | Missing storage controller drivers, rogue disk filter drivers | Filter driver sanitization (`UpperFilters`/`LowerFilters`), driver start alignment from donor via `Sync-BootDrivers.ps1`. |
| **Zone 3: User Subsystem** | `0xC000021A`<br>`STATUS_INVALID_IMAGE_HASH` | Empty CatRoot/CatRoot2, pending restore queue, desynchronized `smss`/`csrss` | `Fix-FailedSystemRestore.ps1` and `Restore-FromDonorDrive.ps1` for cryptographic catalog database restoration. |

---

## 🧰 The MWBA Universal Toolset

| Tool | Purpose | Key Parameters |
| :--- | :--- | :--- |
| **`MWBA.bat` / `MWBA.ps1`** | Master two-stage orchestrator (non-destructive baseline & surgical repair) | `-OfflineWindowsDrive`, `-DryRun`, `-AutoConfirmStage2` |
| **`Fix-BCDError34.ps1`** | Surgical BCD error `0xc0000034` rebuilder (auto-discovers ESP, clears locks, runs `bcdboot`) | `-TargetWindows`, `-Force` |
| **`Fix-FailedSystemRestore.ps1`** | Disarms pending restore queues, cleans SOFTWARE hive restore flags, audits CatRoot2 | `-TargetDrive`, `-Force`, `-LogFile` |
| **`Collect-BootLogs.ps1`** | Post-boot forensic analyzer (minidumps, MEMORY.DMP, ntbtlog.txt, System.evtx, subsystem binaries) | `-TargetDrive`, `-OutputFile`, `-BitLockerKey` |
| **`Collect-BCDDiagnostics.ps1`** | Comprehensive UEFI/ESP & BCD health diagnostics, checks bootloader files & VSS snapshots | `-TargetDrive`, `-OutputFile` |
| **`Restore-FromDonorDrive.ps1`** | Surgical transplant of cryptographic catalogs, system binaries, and hives from reference drive | `-DonorDrive`, `-TargetDrive`, `-ReplaceHives` |
| **`Sync-BootDrivers.ps1`** | Audits boot driver binaries, demotes missing drivers, aligns start types, purges rogue filters | `-TargetDrive`, `-DonorDrive`, `-DemoteMissingDrivers` |
| **`Audit-BootDrivers.ps1`** | Deep driver & registry safety auditor with assessment grading (A-F), undo exports, and native `-SxSTrace` | `-Target`, `-DryRun`, `-Apply`, `-SxSTrace` |
| **`Restore-OfflineRegistry.ps1`** | Restores offline registry hives (SYSTEM, SOFTWARE, etc.) from VSS shadow copy snapshots | `-OfflineDrive` |
| **`Set-BootMode.ps1`** | Configures BCD for Normal clean boot or Safe Mode with Networking (`-Mode Normal` / `SafeNetwork`) | `-TargetDrive`, `-Mode`, `-DisableBootLog` |
| **`Add-DualBootEntry.ps1`** | Bridges target Windows installation into host/reference EFI bootloader menu | `-HostDrive`, `-TargetDrive`, `-TimeoutSeconds` |
| **`Test-BootInVM.ps1`** | Boots physical disk inside an isolated Gen 2 Hyper-V VM with Secure Boot and auto-cleanup | `-DiskNumber`, `-VmName`, `-RamMB` |

---

## 🚀 Quick Start

### 1. Launch via Auto-Elevating Launcher
Double-click or run from an administrative terminal:
```cmd
MWBA.bat
```
*(Automatically requests UAC elevation, enables backup privileges via C# P/Invoke, and launches `MWBA.ps1`)*

### 2. Run in Dry-Run Diagnostic Mode (No Writes)
Audit an attached non-booting drive without modifying any files or registry hives:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\MWBA.ps1 -DryRun
```

### 3. Target a Specific Offline Windows Volume
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\MWBA.ps1 -OfflineWindowsDrive E:
```

### 4. Surgical BCD Rebuild After Error 0xc0000034
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Fix-BCDError34.ps1 -TargetWindows E:\Windows
```

### 5. Disarm a Failed System Restore Bootloop
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Fix-FailedSystemRestore.ps1 -TargetDrive E:
```

### 6. Collect Crash Dumps & Forensics from a Crashing Drive
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Collect-BootLogs.ps1 -TargetDrive E:
```

---

## 🛑 The Bench Stop-Loss Rule: The Honest Technical Reality

MWBA is an engineering scalpel and an objective bench triage platform, not magic snake oil. In modern Windows (10/11), understanding the boundary between repairable and non-repairable failures saves hours of wasted bench time:

### ✅ What MWBA Fixes (High Confidence):
* **Zone 1 (UEFI & BCD)**: Reconstructs corrupted EFI System Partitions, replaces broken `{bootmgr}`, and resolves errors `0xc0000034`, `0xc000000e`, and `0xc0000098`.
* **Zone 2 (Storage & Drivers)**: Sanitizes rogue filter drivers (`UpperFilters`/`LowerFilters` left behind by uninstalled security agents) and demotes missing boot drivers so `INACCESSIBLE_BOOT_DEVICE (0x7B)` halts stop.
* **Restore Loops**: Disarms corrupted `DelayedOperations` queues and `FRStaging` locks from failed Windows System Restores.
* **Forensic Extraction**: Safely exports minidumps, `MEMORY.DMP`, `ntbtlog.txt`, and system event logs before any disk modification.

### ❌ What Cannot Be Repaired Offline (The Physical Limits):
* **Zone 3 (WinSxS Subsystem Collapse & 0xC000021A)**: Modern Windows 11 binds `ntdll.dll`, `csrss.exe`, and `winlogon.exe` to an interdependent graph of 50,000+ WinSxS assembly manifests verified by Code Integrity (CI). If an update fails mid-transaction or hashes desynchronize, Windows kernel deliberately triggers `0xC000021A`. **No offline script on earth can re-link the global WinSxS dependency graph.**
* **The Stop-Loss Mandate**: If MWBA reports a high Reinstall Score, **stop wasting technician hours**. Back up `C:\Users`, apply a clean image via DISM (`/Apply-Image`), or clone a reference disk.

---

## 🛡️ Pure Script Architecture & Zero AV False Positives

MWBA deliberately avoids compiling scripts into `.exe` wrappers:
* **100% Transparent**: Every line of PowerShell is open, readable, and auditable before touching a customer's drive.
* **Zero AV False Positives**: Third-party wrapper executables (e.g. `ps2exe`) frequently trigger false-positive malware alarms in Windows Defender and enterprise EDR.
* **Single Entry Point**: `MWBA.bat` provides full UAC auto-elevation and launches `MWBA.ps1` with a single double-click.

---

## 🔌 WINTools Integration (On-Demand Discovery)

MWBA functions as both an independent repository and an On-Demand module for **[WINTools](https://github.com/remarkablepc/WINTools)**:
* **Sibling Discovery**: If cloned into `..\MWBA` adjacent to `WINTools`, `winbootdoctor.ps1` automatically detects and uses it.
* **Portable USB / On-Demand Cache**: Can be pre-staged in `WINTools\cache\bench_tools\mwba`.
* **Zero Host Pollution**: Adheres to technician bench sterility contracts.

---

## ❓ FAQ & The Official Platform

### ⚖️ Q: Is MWBA Left or Right?
**Neither.** MWBA is proudly fielded by the **Independent Bench Technician Coalition**.

We represent the unsung heroes working under flickering fluorescent shop lights who don't care what side of the aisle you sit on — as long as your NVMe drive initializes at POST.

#### 🗳️ Our Single-Issue Campaign Guarantees:
* **Strict Term Limits on MBR**: Legacy BIOS had an honorable run, but it is high time to step aside for UEFI and GPT.
* **Separation of Antivirus and Kernel**: No third-party filter driver shall infringe upon the storage controller's constitutional right to mount `C:\`.
* **Bipartisan BCD Reconstruction**: Blue Screen of Death or Black Screen of Death, we heal them with equal vigor and zero prejudice.
* **Our Only Special Interest Group**: You. Specifically, you trying to escape the shop and make it home for dinner on a Friday night.

---

### 🗣️ Q: How Do You Say MWBA?
Scholars, bench technicians, and bipartisan IT committees have long debated how to speak its name:
* **"MOO-bah"** (`/ˈmuː.bɑː/`) — Favored in Midwestern repair shops and suburban computer stores.
* **"M-WAH-bah"** (`/əmˈwɑː.bɑː/`) — The sophisticated coastal enterprise consultant dialect.
* **"EM-DUBYA-BEE-AY"** — The formal, C-suite executive briefing cadence.
* **"MAH-wubba"** — What you mumble under fluorescent bench lights at 3:14 AM when Error `0xc0000034` refuses to yield.

*Regardless of how you pronounce it, corrupt BCD hives and orphaned filter drivers fear it all the same.*

---

### 📜 Q: What are The Administration's Five Core Executive Orders?
1. **Executive Order 0x7B — Deportation of Rogue Filter Drivers**:
   Rogue antivirus hooks, corrupted `UpperFilters`, and orphaned `LowerFilters` preventing storage controller initialization (`INACCESSIBLE_BOOT_DEVICE`) are promptly sanitized and quarantined.
2. **The Bipartisan EFI Re-Authorization Act**:
   Reconstructs `{bootmgr}`, reinstalls clean UEFI bootloader files via `bcdboot`, repairs corrupted BCD objects, and resolves errors `0xc000000e` and `0xc0000034`.
3. **The CatRoot Cryptographic Security Accord**:
   Restores cryptographic catalog databases (`CatRoot` & `CatRoot2`) to end `0xC000021A / STATUS_INVALID_IMAGE_HASH` boot loops and sync desynchronized `winlogon`/`smss` subsystems.
4. **The Failed System Restore Disarmament Treaty**:
   Disarms pending `DelayedOperations` queues, `RestoreContinuationState` flags, and `FRStaging` artifacts left behind after an interrupted or corrupted Windows System Restore.
5. **Border Security for the Boot Sector (Hyper-V Smoke Testing)**:
   Never return a customer drive on faith. MWBA boots physical offline drives inside a sandboxed Gen 2 Hyper-V VM with Secure Boot enabled to guarantee bootability without crashing your host bench machine.

---

### 💾 Q: Can I run MWBA from WinPE or a USB drive?
**Yes.** MWBA is designed to run in offline repair environments, WinPE recovery drives, external USB docks, and secondary bench repair systems. It requires only PowerShell 5.1+ and native Windows command-line utilities (`bcdboot`, `bcdedit`, `reg`, `dism`).

---

## 💬 Community & Peer Discussions

Field observations, technician rescue stories, and recovery diagnostics are hosted on GitHub Discussions:
* **[GitHub Discussions](https://github.com/remarkablepc/MWBA/discussions)**

*(Note: MWBA is independent, free open-source software provided as-is without individual, 1-on-1 technical support. Technicians and administrators are encouraged to collaborate and share field notes in the discussion forum).*

---

## ❤️ Community Support & Sponsorship

MWBA is **100% free and open source**.

If this toolkit helped recover an unbootable system, rescued an emergency payroll drive, or saved you hours of manual bench troubleshooting, consider buying a coffee or sponsoring development:

* **[☕ Say Thanks via PayPal](https://www.paypal.com/ncp/payment/EKH76RTYHH24S?uhm=MWBA)**
* **[💖 Sponsor on GitHub Sponsors](https://github.com/sponsors/remarkablepc?uhm=MWBA)**

---

## 📄 License

MWBA is licensed under the [MIT License](LICENSE).  
Copyright (c) 2026 Remarkable PC / J. David Hewitt.

