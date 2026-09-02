# OSDeploy PXE Workflow Suite — Implementation Design

Date: 2026-09-02
Status: Approved design, pending implementation planning

## Relationship to the Decision Record

The behavioral specification for this system is the Q&A record and Working Context under `source/`. Those files are authoritative for behavior; this document is the implementation design — how the confirmed behavior gets built. Where this document and the decision record appear to conflict, the decision record controls, and higher-numbered confirmed answers supersede earlier ones. Decisions Q95 through Q102 were confirmed during the design sessions that produced this document.

## Scope

A technician-operated deployment suite built from PowerShell: a customized PXE-booted OSDeploy WinPE bootstrap, a persistent OSDCloud Deployment Partition that performs primary deployment and Factory Recovery, and an installed-Windows orchestrator. Targets custom desktop PCs, UEFI/GPT, Windows 11 Home and Pro, EZT and MMC workflow profiles.

## Repository Structure and Standards

```
osDeploy/
├── src/
│   ├── Shared/        # OSDeploy.* modules used by every environment
│   ├── Bootstrap/     # PXE WinPE controller
│   ├── Partition/     # Partition engine + Factory Recovery UI
│   ├── Orchestrator/  # Staged to C:\ProgramData\OSDeploy\Orchestrator
│   └── Build/         # Publish + WinPE builder (run on the Windows build box)
├── config/            # Central configuration template + order-field mapping
├── tests/             # Static gates + Pester logic tests
├── source/            # Behavioral decision record (authoritative)
├── reference-code/    # Driver-share creation scripts (reference only)
└── docs/superpowers/  # This spec and the implementation plan
```

Standards for all runtime code:

- Windows PowerShell 5.1-compatible. No PS7-only syntax (ternaries, `??`, `&&`/`||` chains). Pure ASCII.
- Static gates in `tests/` parse every source file via the AST, reject banned syntax and non-ASCII bytes, and run under `pwsh` on the Linux development box after every edit. Runtime validation happens on Windows.
- WPF with XAML for all screens, one shared GUI module. The bootstrap launcher invokes `powershell.exe -STA` because the WinPE host can be MTA and WPF requires STA.
- Module prefix `OSDeploy.*` to avoid colliding with the OSD module's namespace.
- `autoAll.ps1` and `eztConfig.ps1` are never absorbed, wrapped, staged, or invoked (Q95). They are technique references only. The driver-share creation scripts in `reference-code/` define the library structure.

## Shared Modules

| Module | Responsibility |
| --- | --- |
| `OSDeploy.Logging` | Timestamped run folders on the partition, structured events plus transcript, oldest-first retention at `LocalLogHistoryMaxMB`, optional secondary server copy for Initial Deployment (non-blocking). |
| `OSDeploy.Config` | Central-config load and schema validation, per-setting hard-coded defaults, effective-config resolution, versioned snapshot save/load, fallback recording (Q83, Q84). |
| `OSDeploy.State` | Atomic JSON writes (temp file plus move). Owns `ReadinessRecord.json`, `DeploymentState.json`, `FactoryProfile.json` with active and last-known-good copies. |
| `OSDeploy.Disk` | Disk inventory and presentation, NVMe-preferred selection, removable-storage detection, identity revalidation at time of use, Deployment Erase variants, secondary-drive preparation. |
| `OSDeploy.Image` | Multi-index WIM validation (Home and Pro indexes, architecture, language, release, integrity), temporary-download-then-validate-then-promote lifecycle. |
| `OSDeploy.Gui` | WPF wizard host and XAML screen definitions shared by bootstrap, partition, and recovery environments. |
| `OSDeploy.Util` | SHA-256 inventory generation, canonical bundle hash, hashing helpers. |

## PXE Serving

WDS in standalone mode on the Deployment server is the current mechanism and the phase-4 target. The serving layer is a swappable boundary: `Build/` produces a standard PXE-bootable WIM that any PXE server can serve. Researching alternatives such as iPXE with HTTP boot is an open implementation-time item, not a confirmed architecture change.

## Primary Disk Layout

Created during Initial Deployment and PXE Full Factory Rebuild on the confirmed, revalidated primary disk (GPT):

| Partition | Size | Notes |
| --- | --- | --- |
| EFI System Partition | ~100 MB | Boot files and the BCD store. |
| MSR | 16 MB | Standard reservation. |
| Windows free span | remainder, front of disk | Windows setup carves the Windows partition from this contiguous span. |
| Windows RE tools | `WindowsReToolsPartitionSizeMB`, default 1024 | Dedicated partition; `winre.wim` staged and enabled via `reagentc` during specialize (Q101). |
| OSDCloud Deployment Partition | `RecoveryPartitionSizeMB`, default 32768 | End of disk, NTFS. |

NTFS is deliberate: multi-index Home/Pro images exceed 4 GB, and boot is driven by Windows Boot Manager through the BCD on the EFI System Partition rather than firmware-direct FAT32 boot. This is the intended deviation from the `New-OSDCloudUSB` FAT32-with-split-WIM layout; the USB media remains the reference for the partition's internal structure (Q91 implementation reference, not a copy).

Factory Recovery erases only the EFI/MSR/Windows-span area and preserves the WinRE tools and OSDCloud partitions. PXE Full Factory Rebuild erases the complete disk.

## OSDCloud Deployment Partition

Internal layout, refined at implementation against the pinned OSD module source:

```
<OSDCloud>\boot\                  # local OSDCloud WinPE boot.wim + boot files
<OSDCloud>\Sources\Engine\       # shared EZT/MMC engine
<OSDCloud>\Sources\Orchestrator\ # staging + repair source (Q90)
<OSDCloud>\Sources\Apps\         # resolved application set + installers (Q25)
<OSDCloud>\Sources\Drivers\      # model-matched driver set (Q96, Q97)
<OSDCloud>\Sources\Config\       # versioned effective-config snapshot (Q84)
<OSDCloud>\ImageCache\           # permanent validated image cache + temp staging
<OSDCloud>\State\                # ReadinessRecord.json, DeploymentState.json,
                                 # FactoryProfile.json (+ last-known-good),
                                 # generated inventories + bundle hash
<OSDCloud>\Logs\                 # authoritative timestamped run folders (Q76)
```

Partition size is read during Initial Deployment and PXE Full Factory Rebuild; the staged value is recorded in state, and central changes never resize deployed partitions.

Boot-entry lifecycle (Q94): the PXE one-time boot uses a BCD `bootsequence` entry (candidate mechanism; UEFI BootNext is the alternate — final selection verified in lab against target firmware and the pinned OSDCloud media layout). The partition may re-select itself for checkpoint reboots. After Windows validates, the orchestrator registers the persistent Factory Recovery entry (Windows stays default, five-second timeout), validates it against partition identity and boot files, and clears every deployment-only override. Failure blocks completion at Technician Review.

## Ready Gate and Readiness Record

Before configuring the one-time boot, the bootstrap validates: partition bootable and on the confirmed disk; engine, selected workflow, resolved configuration, factory profile, applications, drivers, orchestrator repair source, and logging components present; every staged file passes the generated size and SHA-256 inventory; network drivers available for Microsoft access; state and logging locations writable; sufficient space remains for image acquisition and the permanent cache (Q92). On success it atomically writes `ReadinessRecord.json` (renamed by Q102): run id, machine identity, disk identity, workflow, edition, configuration version, generated bundle hash, timestamp. On failure it remains in PXE offering Retry Staging or Cancel Deployment.

At every partition boot — initial deployment and Factory Recovery — the environment revalidates the readiness record and primary-disk identity and stops fail-closed before any destructive work with the Q93 screen sets. Ignore and Continue Anyway do not exist.

## Component Designs

### Bootstrap Controller (WinPE, PXE)

1. Launch STA WPF host; preflight `DeploymentShare` and `DeploymentLogs` (Q8).
2. Order number entry; single read-only MySQL query using the staged `MySql.Data.dll` and the config-held connection and field mapping (Q98); cache all order values.
3. Editable defaults: workflow via the company mapping (exact `EZT` or `EZ Trading Computers` to EZT, any other named company to MMC, missing value requires manual selection; Q11), edition Home/Pro. Lookup failure offers Retry Order Lookup, Select Workflow Manually, or Cancel (Q9).
4. Confirmations: workflow, edition, primary disk (NVMe-preferred, sole-candidate auto-select still displayed), removable-media state (blocks destructive work; Emergency Bypass requires secondary warning, acknowledgement checkbox, Yes-or-Cancel, target revalidation, audit event; Q5/Q6), recovery layout, secondary drives (Skip is default, all begin unselected, explicit selection only; Q58).
5. Final pre-erasure summary: OK and CANCEL only, disk revalidated at time of use, selections durably recorded (Q12).
6. Full-disk Deployment Erase; create the primary disk layout; format and stage the OSDCloud Deployment Partition from the share; generate the inventory and bundle hash.
7. Ready gate; on success write `ReadinessRecord.json`, configure the one-time boot, restart. On failure offer Retry Staging or Cancel.
8. Copy the PXE-phase log to `DeploymentLogs` as a secondary, non-blocking copy.

### Partition Engine (primary deployment and Factory Recovery)

1. Revalidate readiness record and disk identity; fail-closed screens per Q93 on failure.
2. Load the effective-config snapshot. Initial deployment writes a new `FactoryProfile.json`; recovery validates the active copy, restores from last-known-good when valid, and stops without guessing when neither is valid (Q87).
3. Image acquisition: check Microsoft for a newer compatible multi-index image when online; download to a temporary file on the partition; validate indexes, architecture, language, release, integrity; atomically promote to `ImageCache`; reopen and revalidate. Fall back to the validated local cache when offline or on failure. If neither source validates for the requested edition, stop before Deployment Erase with the established choices (Q46, Q91).
4. Apply Windows to the Windows free span through the local OSDCloud instance; generate the unattend for the run; create ESP/MSR/Windows partitions.
5. Stage the orchestrator to `C:\ProgramData\OSDeploy\Orchestrator`, register the single-instance SYSTEM startup task, record hashes with the deployment state (Q89, Q90).
6. Checkpoint reboots re-select the partition as needed.
7. Factory Recovery re-enters here through the persistent boot entry: restore the saved profile, optional approved edition change with warning (Q44–Q46), erase only the Windows-related area, never touch secondary drives or the server, offline-capable through the validated cache.

### Orchestrator (installed Windows)

Single-instance SYSTEM startup Scheduled Task, no sign-in required. Authoritative atomic `DeploymentState.json` checkpoint on the partition with run, machine, disk, workflow, edition, phase, attempt, reboot, configuration-version, and timestamp context. Every phase idempotent; resume only the last incomplete phase; never re-enter completed destructive work; `RebootPending` saved before restarts and identity validated on return; three automatic attempts per checkpoint, fourth failure opens blocking Technician Review (Q36, Q89). NTFS-restricted directory, SHA-256 hashes checked before first execution and after restarts, local repair source only (Q90).

Phase order: Drivers (pattern-matched silent recursive install per Q96 with Q27/Q28 failure routing and Plug and Play validation) → Applications (manifest-driven, manifest retries, then Acknowledge-and-Continue; Q25/Q26) → workflow specifics (EZT `User` account, persistent automatic sign-in, managed password transition Q15/Q16/Q86; MMC compliance defaults and Audit Mode to OOBE Q30; Energy Star per saved profile Q20–Q23) → Windows Update cycles (Q88) → EZT activation flow (Q18/Q19) → final validations and result states (Q67–Q72) → persistent boot-entry registration (Q94) → log finalization (Q73) → cleanup. Completion is recorded only after required work, cleanup, final-log verification, and the correct EZT or MMC handoff succeed; a restart after completion runs cleanup only; cleanup failure blocks completion.

## Data Contracts

### Central configuration (`config/osdeploy-config.json` → share `Config\`)

One JSON file, validated with hard-coded defaults per Q83. Sections: `OrderDatabase` (host, port, database, username, password, table, `ColumnMap` for order number, company, edition, state — Q98, existing account); `Deployment` (`RecoveryPartitionSizeMB` 32768, `WindowsReToolsPartitionSizeMB` 1024, `RecommendedPrimaryDriveSizeMB` 122070, `TimeZone`); `Logging` (`LocalLogHistoryMaxMB` 1024); `WindowsUpdate` (`MaxCycles` 3); `RegulatedStates` (default `["CA"]`); `CompanyWorkflowMap` (Q11). The password is stored in the read-only-accessible config by the Q98 decision; exposure is bounded by the read-only share and the read-only account.

### State files

| File | Key fields |
| --- | --- |
| `ReadinessRecord.json` | Run id, machine identity, disk identity, workflow, edition, configuration version, generated bundle hash, timestamp (Q92, Q102). |
| `FactoryProfile.json` (+ last-known-good) | Schema version, machine identity, workflow, factory edition, default recovery edition, edition change history, Energy Star decision and state, locale, created and last-recovery timestamps (Q87). |
| `DeploymentState.json` | Run id, machine and disk identity, workflow, edition, phase, attempt, `RebootPending`, configuration version, completed phases, result, noted issues, acknowledgements (Q89). |

Identity fields never fall back; only noncritical fields use documented fallbacks.

### Effective-config snapshot

Resolved values plus configuration version, source, and an explicit list of keys that fell back with reasons. Factory Recovery runs from this snapshot verbatim and never checks central configuration (Q84).

### Application manifests

One manifest per workflow under `Apps\{EZT,MMC}\manifest.json`: entries of `{ Id, Name, Installer, Type, SilentArgs, SuccessCodes, RetryCount, TimeoutMinutes, Required }` (Q25/Q26). Applications are manifest-driven; drivers are not (Q96).

### Staging inventory

Generated `bundle-inventory.json` — path, size, SHA-256 for every staged file — with the bundle hash computed over its canonical serialization. Never hand-maintained (Q92).

### Unattend generation

Assembled per run by the engine from configuration, workflow, edition, and locale; not static files. EZT receives persistent registry-based automatic sign-on for `User` (no logon-count limit; Q16). MMC receives the Audit Mode and Sysprep `/oobe` path (Q30). Product keys never appear in unattend files or logs (Q18): firmware and digital-license activation first, illustrated dialog only when required.

## Build and Publish Flow

- `Publish-Bundle.ps1` (Windows build box): assembles `src/` and `config/` into the Q97 share taxonomy (Config, Bootstrap, Engine and partition payload, Applications, WinPE). It never manages `Drivers\` content — the library is technician-curated on the share in its migrated structure; publish only ensures the folder skeleton exists.
- `Build-WinPE.ps1` (Windows build box, pinned OSD module): builds the customized WinPE WIM — PXE-bootable, WPF optional components, staged `MySql.Data.dll`, embedded bootstrap launcher — and publishes it to the share's WinPE folder. Phase 4 additionally pushes the WIM into the WDS standalone store.

## Testing Strategy

| Layer | What | Where |
| --- | --- | --- |
| Static gates | 5.1 syntax, banned constructs, ASCII purity across all sources | Linux dev box, `pwsh`, after every edit |
| Logic tests | Pester: config resolution and fallbacks, atomic state writes, model-name formatting, inventory hashing, company mapping | Linux dev box, `pwsh`; Windows spot-check |
| Component | Orchestrator phases against a mock local partition folder; driver pattern engine dry-run mode | Windows VM |
| Integration | Partition layout, local OSDCloud run, image acquire-validate-promote | UEFI Hyper-V generation-2 VM |
| End-to-end | Initial Deployment EZT and MMC, Factory Recovery, PXE Full Factory Rebuild, failure-path drills (ready-gate failure, revalidation failure, invalid profile, update uninstall through WinRE) | Lab |

## Implementation Phases

| Phase | Deliverable |
| --- | --- |
| 0 | Repository scaffold; static gates green on Linux. |
| 1 | `Shared/` modules with Pester coverage. |
| 2 | `Orchestrator/` — checkpoint engine, phases, integrity. |
| 3 | `Partition/` engine and recovery UI. |
| 4 | `Bootstrap/` controller, `Build/` WinPE builder, WDS publish. |
| 5 | End-to-end lab drills and failure paths. |

Orchestrator precedes bootstrap deliberately: it is the most logic-dense component and testable without PXE infrastructure.

## Open Items

- PXE-serving research: WDS versus iPXE/HTTP (current: WDS; boundary remains swappable).
- Exact one-time-boot mechanism: BCD `bootsequence` versus UEFI BootNext — lab-verified against target firmware per Q94.
- Pinned OSDeploy/OSDCloud module version and pinning mechanics (config-recorded at rollout).
- Order-database `ColumnMap` values and `TimeZone` default — environment values set at rollout.
- WinPE optional-component set for WPF plus MySQL — verified in the phase-4 image build.
