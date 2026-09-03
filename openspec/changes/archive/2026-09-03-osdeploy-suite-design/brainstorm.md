# Brainstorm — osdeploy-suite-design

Raw capture of the brainstorming session for change `osdeploy-suite-design`, 2026-09-02.
Format: decision log (background → decision chain → trade-offs → session decisions → open items).

Sources captured here:

- `source/OSDeploy_PXE_Workflow_Questions_and_Answers.md` — Questions 1–102 (authoritative for behavior; higher numbers supersede conflicting earlier portions).
- `source/OSDeploy_PXE_Workflow_Working_Context.md` — architecture summary current through Q102.
- `docs/superpowers/specs/2026-09-02-osdeploy-suite-design.md` — the approved implementation design produced by the earlier design sessions (commit 516bf91). Captured as reference and **retired** by this change per session decision S1; its content migrates into this change's artifact chain (see "Migration map").

## Background

A technician-operated deployment suite for custom desktop PCs built on OSDeploy, OSDCloud, PXE, and a persistent OSDCloud Deployment Partition. It deploys Windows 11 Home or Pro, applies the EZT or MMC factory profile, installs drivers and applications, keeps authoritative local deployment/recovery/logging state on the partition, and supports customer-side Factory Recovery with no dependence on the deployment server.

Three execution stages, in order:

1. **PXE bootstrap** — customized OSDeploy WinPE, read-only `\\Deployment\DeploymentShare`. Technician enters the order number; one read-only MySQL lookup caches order values; editable EZT/MMC and Home/Pro defaults; disk and removable-media confirmation; creates and stages the persistent OSDCloud Deployment Partition; runs the Deployment Partition Ready gate; atomically writes `ReadinessRecord.json`; configures a one-time boot; reboots. The bootstrap does not perform the main deployment.
2. **OSDCloud Deployment Partition** — persistent, bootable, local environment that is the primary deployment environment (not merely recovery storage). Runs the shared EZT/MMC engine, acquires/validates/caches the multi-index Windows image (Microsoft direct when online, validated local cache otherwise), and later performs Factory Recovery.
3. **Installed-Windows orchestrator** — `C:\ProgramData\OSDeploy\Orchestrator`, SYSTEM startup Scheduled Task. Idempotent phases, authoritative atomic `DeploymentState.json` checkpoint on the partition, reboot-safe resume, three automatic attempts per checkpoint then blocking Technician Review.

No implementation exists yet. The repository is a design-phase record; the confirmed decisions below are the behavior contract any implementation must satisfy.

## Decision chain (Questions 1–102, grouped by theme)

### Bootstrap, order lookup, and UI

- Q1: Overall flow — PXE boot into OSDCloud, order number entry, MySQL-derived defaults, removable-media checks, deploy to the primary internal drive, minimal interaction to the required endpoint.
- Q2: Order data supplies editable defaults; graphical manual selector for missing required values.
- Q3: MySQL access strictly read-only; corrections never written back.
- Q9: Lookup failure offers Retry Order Lookup, Select Workflow Manually, or Cancel Deployment.
- Q10: Workflow identities are exactly EZT and MMC; Home/Pro is a separate runtime selection; adapter and workflow schema validated against the pinned installed OSDeploy/OSDCloud version.
- Q11: Company mapping — exact `EZT` / `EZ Trading Computers` → EZT (case-insensitive, trimmed); any other named company → MMC; missing value requires manual selection; technician may override.
- Q98: Order-DB connection details, credentials, and semantic field mapping live in central configuration on the share; the existing order-database account is reused.
- Q99: GUI framework is WPF with XAML — one shared GUI module serving bootstrap controller and partition-side screens.

### Disk safety and layout

- Q4: Windows disk number as target identifier; sole-eligible-NVMe auto-select still displayed; SATA included only when no NVMe; identity revalidated immediately before destructive work.
- Q5: Usable removable storage blocks destructive work unless Emergency Bypass is used; nonstorage USB peripherals do not block.
- Q6: Emergency Bypass requires secondary warning, acknowledgement checkbox, Yes-or-Cancel, target revalidation, audit event; no reason dropdown.
- Q12: Final pre-erasure summary with OK and CANCEL only; disk revalidated at time of use; selections durably recorded.
- Q37: Staged local-partition architecture — PXE stages, partition deploys (the load-bearing architecture decision).
- Q38 → Q41: Original 16 GB no-image partition superseded; 32 GB baseline (`RecoveryPartitionSizeMB` = 32768) holds the validated image cache.
- Q101: Dedicated Windows RE tools partition (default 1024 MB via `WindowsReToolsPartitionSizeMB`); `winre.wim` staged and enabled with `reagentc` during specialize; coexists with Factory Recovery.
- Q79–Q82: No granular pre-download capacity modeling; simple warning below `RecommendedPrimaryDriveSizeMB` (default 122070); continuation requires an "I understand the capacity risk" acknowledgement; no special logging.
- Q85: "Deployment Erase" = workflow disk preparation, not forensic sanitization; scope varies by run type; warnings must not claim secure erasure.

### Secondary drives

- Q58: Inventory all internal drives; exactly one confirmed primary; optional per-drive secondary preparation with Skip as default; Factory Recovery never modifies secondary drives.
- Q59–Q66: GPT, one full-size NTFS partition, automatic letters from D:, collision-safe Data/Data-2/Data-3 labels; no mapping save/restore (Q61 rejected as bloat); mount-verify only after Windows assigns letters; Retry or Skip-and-Continue on failure; skipped partial drives stay offline; failed drives stay offline in Windows and during recovery.

### Workflow profiles and handoff

- Q13: No automated computer naming.
- Q14: MMC completes at Windows OOBE; EZT completes its account/settings/apps/key work and reaches the configured desktop.
- Q15: EZT creates passwordless local-admin `User` plus a desktop shortcut launching the managed password transition (Q86), not Sign-in options directly. MMC creates no such account.
- Q16 / Q24: Persistent automatic sign-in for the passwordless `User` until the owner sets a password through the managed workflow (supersedes the earlier temporary-autologon answer); built-in Administrator stays disabled.
- Q86: The managed password workflow warns, then changes password, disables automatic sign-in, and clears the stored credential as one controlled transition; cancel/failure leaves both states unchanged; Factory Recovery restores the passwordless state.
- Q17: Factory Recovery restores the profile-specific factory configuration with two-stage destructive confirmation.
- Q30: MMC uses Audit Mode for staging, then Finalize/Return-to-OOBE removes artifacts and runs Sysprep; endpoint is powered-on OOBE.
- Q31: Successful deployments finish powered on.
- Q32–Q34: MMC completes when cleanup succeeds and Sysprep initiates the OOBE reboot (Sysprep failure = blocking technician error in Audit Mode); EZT completes when the final reboot to the configured desktop successfully begins.
- Q67–Q72: Result states — Completed, Completed with Warnings, Completed with Tech-Addressed Warnings; one acknowledgement covers the noted-issues list, shown only when issues exist; result changes only when the checked acknowledgement is submitted with Finish Deployment.
- Q100: Locale/region/keyboard follow the validated en-US image; timezone from central configuration with hard-coded default; MMC ends at OOBE (customer adjusts), EZT ends at the configured desktop with staged values applied.

### Activation and Energy Star

- Q18 / Q19: Digital-license/firmware-key activation first; illustrated product-key dialog with sticker guidance only when needed; keys never stored or logged; incomplete activation may finish after warning.
- Q20–Q23: Energy Star technician-overridable, cached per machine, revalidated from the profile during recovery; California MMC = settings without popup; California EZT = settings plus persistent popup; non-California = High Performance, display sleep 60 min, system sleep disabled; regulated-state list evaluated only at deployment time and persisted in `FactoryProfile.json`.

### Partition readiness, boot entries, and connectivity boundary

- Q42: Persistent Factory Recovery entry in Windows Boot Manager, Windows default, five-second timeout, plus in-Windows shortcut; entering recovery is non-destructive.
- Q43: Recovery needs no PIN/password; data-loss consequences clearly explained.
- Q44–Q46: Recovery cannot change workflow; edition change allowed with activation warning; technician-selected edition becomes future default after success; unavailable edition offers Choose Another Edition / Use Saved Default / Cancel — never silent substitution.
- Q91 (supersedes the DeploymentShare emergency-image portions of Q52–Q55): Once execution begins on the OSDCloud Deployment Partition it must never probe, map, authenticate to, retrieve from, or upload to DeploymentShare or any deployment server. The partition is the primary deployment environment for InitialDeployment and FactoryRecovery; "Use Deployment Server Emergency Image" is removed from Technician Options; PXE Full Factory Rebuild is the technician-controlled service path; "OSDCloud Deployment Partition" is the canonical term.
- Q92: One automatic Deployment Partition Ready gate before the one-time boot — bootability and disk association, presence of engine/workflow/config/profile/apps/drivers/orchestrator-repair/logging components, generated size + SHA-256 inventory of every staged file, network drivers for Microsoft access, writable state/logging locations, sufficient space; then atomic readiness record; failure stays in PXE with Retry Staging or Cancel.
- Q102 (supersedes only the Q92 filename): The readiness record is `ReadinessRecord.json`.
- Q93: Fail-closed on readiness/disk-identity revalidation failure after the partition boots — stop before any destructive work, no Ignore/Continue Anyway; InitialDeployment offers Retry / View Diagnostics / Reboot to PXE for Restaging; FactoryRecovery offers Retry / View Diagnostics / Cancel and Boot Windows; the partition never reconnects to the server to repair itself.
- Q94: One-time deployment boot without making the partition the permanent default; partition may re-select itself for checkpoint reboots; after Windows validates, register the persistent Factory Recovery entry (Windows default, five-second timeout), validate partition identity and boot files, clear deployment-only overrides; registration failure blocks completion; exact mechanism (BootNext, BCD bootsequence, other) verified in lab.

### Image acquisition and cache

- Q39 / Q40: Online-first acquisition with validated local-cache fallback; Ethernet preferred, Wi-Fi supported through staged drivers; source/edition/integrity validated before erasure.
- Q47: One validated multi-index Windows 11 image containing both Home and Pro; reject on missing index or architecture/language/release/build inconsistency.
- Q48–Q51: Check for newer compatible image before destructive work; download to temporary file, validate (hash, integrity, architecture, language, release, both indexes), atomically promote, install only from the promoted cache; retain the existing cache until the replacement validates.
- Q52 (as superseded by Q91): Cache-commit validation failure offers Retry / Redownload / Cancel, never Continue Anyway (the emergency-server path is gone).
- Q53–Q55 (superseded portions per Q91): emergency DeploymentShare image access removed.

### Orchestrator

- Q35 / Q36: Persistent checkpoints; automatic resume after restart or power loss; never repeat completed destructive work; three automatic attempts per checkpoint, fourth failure opens blocking Technician Review.
- Q89: Orchestrator staged under `C:\ProgramData\OSDeploy\Orchestrator`; single-instance SYSTEM startup Scheduled Task without sign-in; authoritative atomic `DeploymentState.json` on the partition (run, machine, disk, workflow, edition, phase, attempt, reboot, configuration-version, timestamp); idempotent phases; `RebootPending` saved before restarts and identity validated on return; completion only after work, cleanup, final-log verification, and correct handoff; restart after completion runs cleanup only; cleanup failure blocks completion.
- Q90: Integrity without a signing system — NTFS restriction to SYSTEM/Administrators, automatically calculated SHA-256 hashes stored with deployment state and rechecked before first execution and after restarts; failure recopies only from local partition content, then stops at Technician Review; the complete bundle hash identifies the staged copy with no manual version maintenance.

### Drivers and applications

- Q25: Application selection fixed by workflow, not per-app; resolved manifest/installers included in local content.
- Q26: App failures retry per manifest, then Acknowledge-and-Continue modal; deployment continues as Completed with Warnings.
- Q27 / Q28: Driver failures never auto-kill deployment; clear reporting, preserved diagnostics, final PnP validation with one acknowledged warning of unknown/problem devices; unresolved or important failures route to Technician Review.
- Q29: Technician Review allows manual remediation, Rescan Devices, Rerun Validation before the final handoff.
- Q95: Neither `autoAll.ps1` nor `eztConfig.ps1` is absorbed or wrapped — technique references only (silent-install switches, registry choreography); driver workflow and EZT post-install implemented fresh.
- Q96: No driver manifests — pattern matching on standardized manufacturer installer naming (e.g., ASUS `AsusSetup.exe`, single-installer Gigabyte folders), silent recursive install using manufacturer installers and PnP.
- Q97: One authoritative live share at `\\Deployment\DeploymentShare` with fixed taxonomy (central configuration; bootstrap/controller; partition/engine payload; applications; driver library; WinPE image); live content is the current version; bundle identity is the staging-generated hash; no manually maintained release manifests; existing driver share migrates into the driver library with creation scripts kept in `reference-code/`.

### Windows Update

- Q88: Windows Update during technician staging when internet is available — security, cumulative, servicing-stack, .NET, Defender; exclude preview/optional/Store/feature-upgrade/driver/firmware/BIOS; up to three configurable cycles (default 3); complete initiated required reboots; leftover updates = warning + acknowledgement + allow completion; unhealthy reboot state stops at Technician Review; offline Factory Recovery skips with a warning and stays eligible.

### Logging and configuration authority

- Q8: Preflight DeploymentShare and DeploymentLogs; collision-safe timestamped run folders; local partition log is authoritative, failed server copy non-blocking.
- Q74–Q78: Local-first verified logs; InitialDeployment may copy to the server (retry only in-workflow, no background uploader); Factory Recovery never contacts the server; partition is the authoritative store with one timestamped folder per run; rebuild preserves logs when possible with oldest-first retention; defaults `LocalLogHistoryMaxMB` = 1024, `RecoveryPartitionSizeMB` = 32768, whole binary MB.
- Q73: The final summary cannot close until the final local log update succeeds.
- Q83 / Q84: Every configurable value has a hard-coded default and validated fallback; InitialDeployment and rebuild load central configuration and save a versioned effective-configuration snapshot locally; Factory Recovery uses only the snapshot and safe fallbacks and never checks central configuration; every run logs source, version, effective values, and fallbacks.

## Trade-offs already made (carried into this change)

- Staged local-partition architecture over monolithic PXE deployment (Q37, Q91): server independence after staging, at the cost of a readiness gate and local staging complexity.
- NTFS end-of-disk partition over the FAT32 split-WIM USB layout: multi-index Home/Pro images exceed 4 GB; boot driven through Windows Boot Manager/BCD rather than firmware-direct FAT32. The USB media (`New-OSDCloudUSB`) remains a structural reference, not a copy.
- One shared WPF/XAML GUI module over per-environment UIs (Q99); bootstrap launcher uses `powershell.exe -STA` because the WinPE host can be MTA.
- Orchestrator implemented before the bootstrap: most logic-dense component, testable without PXE infrastructure.
- Manifest-driven applications (Q25/Q26) vs pattern-matched drivers (Q96) — deliberate asymmetry: app sets are chosen per workflow, drivers follow manufacturer naming conventions.
- Hash-inventory integrity without signing infrastructure (Q90): detects accidental corruption, accepts that a local administrator can replace files and hashes together.
- Generated staging inventory and bundle hash over manually maintained release manifests (Q92, Q97).
- Windows PowerShell 5.1-compatible, pure-ASCII source, static gates (AST parse, banned-construct and non-ASCII rejection) runnable under `pwsh` on the Linux dev box after every edit; runtime validation on Windows.

## Session decisions (2026-09-02)

- **S1 — Formalize via opsx, migrate-and-retire.** This change formalizes the already-approved design into OpenSpec artifacts. The implementation-design spec at `docs/superpowers/specs/2026-09-02-osdeploy-suite-design.md` is the reference for the new artifacts; its content migrates into this change (brainstorm.md = decision log; design.md = structured implementation design; tasks.md/plan.md = phases and steps) and the docs file is retired. Approved approach C over pointer-style (B) and bridge-native-capture-with-spec-kept (A).
- **S2 — Scope: design formalization + implementation phases 0–2.** This change carries the full design formalization plus phases 0–2: repository scaffold and static gates (phase 0), `Shared/` modules with Pester coverage (phase 1), and `Orchestrator/` — checkpoint engine, phases, integrity (phase 2). Phases 3 (Partition engine and recovery UI), 4 (Bootstrap controller, Build/WinPE, WDS publish), and 5 (end-to-end lab drills) become separate later changes.
- **S3 — planned, confirm at proposal/specs step:** this change's delta specs cover the implemented scope only (repo standards, Shared modules, Orchestrator); whole-suite architecture lives in design.md as context, and later changes add the Partition/Bootstrap specs.

## Migration map (retired spec → this change's artifacts)

| Retired spec section | Destination |
| --- | --- |
| Relationship to the Decision Record | brainstorm.md (this file, Sources) |
| Scope | proposal.md |
| Repository Structure and Standards | design.md + specs (phase 0) |
| Shared Modules | design.md + specs (phase 1) |
| PXE Serving | design.md context; resolved in the phase-4 change |
| Primary Disk Layout | design.md context; specs in the phase-3 change |
| OSDCloud Deployment Partition (internal layout, boot-entry lifecycle) | design.md context; specs in the phase-3 change |
| Ready Gate and Readiness Record | design.md context; specs in the phase-3 change |
| Component Designs — Bootstrap Controller | design.md context; specs in the phase-4 change |
| Component Designs — Partition Engine | design.md context; specs in the phase-3 change |
| Component Designs — Orchestrator | design.md + specs (phase 2, this change) |
| Data Contracts | design.md; state/config contracts implemented in phases 1–2 land in this change's specs; image/app/manifest contracts in later changes |
| Build and Publish Flow | design.md context; `Build/` implemented in phase 4 |
| Testing Strategy | design.md + verify.md (this change); later changes extend |
| Implementation Phases | tasks.md (phases 0–2 now; 3–5 noted as later changes) |
| Open Items | carried below; each resolved in its owning phase |

## Open items (deferred, with owner and impact)

- PXE-serving mechanism — WDS standalone is current; iPXE/HTTP boot research open. Owner: phase-4 change. Impact: serving boundary only; the build produces a standard PXE-bootable WIM either way.
- One-time-boot mechanism (BCD `bootsequence` vs UEFI BootNext) — owner: phase-5 lab verification per Q94. Impact: bootstrap boot-configuration code only; lifecycle behavior is already specified.
- Pinned OSDeploy/OSD module version and pinning mechanics — owner: phase 4, recorded at rollout. Impact: adapter/schema validation targets (Q10) and media layout reference.
- Order-DB `ColumnMap` values and `TimeZone` default — owner: rollout. Impact: configuration values only; structure fixed by Q98/Q84.
- WinPE optional-component set for WPF + MySQL — owner: phase-4 image build. Impact: bootstrap image only.

Out of scope for this change: phases 3–5 implementation (Partition engine, Bootstrap/Build/WDS, lab drills) — later changes.

## Promotion-criteria check (bridge)

1. **Scope locked** — formalize the suite design into opsx artifacts and implement phases 0–2 (scaffold + static gates, Shared modules, Orchestrator); phases 3–5 are later changes.
2. **Major design forks resolved** — behavior settled by Q1–Q102 with supersessions applied; artifact approach chosen (S1); remaining TBDs are implementation-time with owner and impact scope (Open items).
3. **Cross-system dependencies mapped** — MySQL order DB: ready, existing account, config-held mapping (Q98). DeploymentShare SMB: ready, taxonomy per Q97. Microsoft endpoints via OSDCloud: external, online-first with validated cache fallback. WDS: ready, swappable boundary, phase 4. Pinned OSD module: genuinely unknown until phase 4, flagged above.
4. **Acceptance criteria stateable** — static gates green under `pwsh` on Linux across all sources; Pester suites for config resolution/fallbacks, atomic state writes, model-name formatting, inventory hashing, and company mapping pass; orchestrator phases idempotent with checkpoint resume, three-attempt limit, and integrity revalidation verified against a mock local partition folder (component tests on a Windows VM).
5. **Conversation converging** — recent turns are confirmations (scope, approach), not new alternatives.
