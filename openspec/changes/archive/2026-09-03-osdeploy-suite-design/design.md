# Design — osdeploy-suite-design

Technical design for change `osdeploy-suite-design`. Reorganized from `brainstorm.md` (decision log Q1–Q102 + session decisions S1–S3) and the retired implementation-design spec (migration map in `brainstorm.md`). The behavioral authority remains `source/`; where this document and the decision record appear to conflict, the decision record controls and higher-numbered answers supersede.

## Context

A technician-operated OSDeploy/OSDCloud/PXE deployment suite for custom desktop PCs: Windows 11 Home/Pro, EZT and MMC factory profiles, customer-side Factory Recovery. The behavior is fully specified by 102 confirmed decisions in `source/OSDeploy_PXE_Workflow_Questions_and_Answers.md` (Q103 is next; supersessions applied per the precedence rules). No implementation exists. This change formalizes the design into OpenSpec artifacts and implements phases 0–2: repository scaffold and static gates, the shared modules, and the installed-Windows orchestrator.

Development environment: Linux dev box (static gates + Pester logic tests under `pwsh`), Windows VM (orchestrator component tests against a mock partition folder). No live DeploymentShare, MySQL, WDS, or Microsoft access is used by this change's tests.

Surrounding suite architecture this change must fit into (implemented by phases 3–5, later changes; recorded here as context):

- **Three stages**: PXE bootstrap (staging, ready gate, one-time boot) → OSDCloud Deployment Partition (primary deployment environment, later Factory Recovery) → installed-Windows orchestrator. Once execution begins on the partition it never contacts the deployment server; Microsoft access through OSDCloud remains allowed (Q91).
- **Primary disk layout (GPT)**: EFI System Partition ~100 MB, MSR 16 MB, Windows free span (front), Windows RE tools `WindowsReToolsPartitionSizeMB` (1024), OSDCloud Deployment Partition `RecoveryPartitionSizeMB` (32768, NTFS, end of disk) (Q41, Q101).
- **Partition contents**: local OSDCloud environment, shared engine, validated multi-index image cache, `FactoryProfile.json` (+ last-known-good), effective-config snapshot, apps/drivers, orchestrator repair source, `ReadinessRecord.json`, `DeploymentState.json`, authoritative logs (Q89–Q92, Q102).
- **Orchestrator deployment context**: staged by the partition engine (phase 3) to `C:\ProgramData\OSDeploy\Orchestrator` before first Windows boot; this change builds the orchestrator so that staging works.
- **PXE serving**: WDS standalone is current; the serving layer is a swappable boundary producing a standard PXE-bootable WIM (phase 4).

## Goals / Non-Goals

**Goals:**

- Turn the validated design into the OpenSpec artifact chain as the project's single planning source of truth, retiring the docs-based spec (done; git history 516bf91).
- Implement phase 0: repository scaffold (`src/`, `config/`, `tests/`) and Linux-runnable static gates enforcing Windows PowerShell 5.1-compatible, pure-ASCII source.
- Implement phase 1: the seven shared modules (`OSDeploy.Logging`, `Config`, `State`, `Disk`, `Image`, `Gui`, `Util`) with Pester coverage of their logic.
- Implement phase 2: the orchestrator — checkpoint engine, integrity protection, and the deployment phases (drivers, applications, EZT/MMC specifics, Windows Update, final validation and result states, recovery boot-entry registration, log finalization, cleanup) — component-tested against a mock partition folder.
- Keep every implemented behavior traceable to its controlling Q number in the specs.

**Non-Goals:**

- Phases 3–5: partition engine and recovery UI, bootstrap controller, WinPE build, WDS publish, end-to-end lab drills (later changes).
- Any live deployment, server access, or image download in this change's tests.
- Digital signatures, signing certificates, pinned public keys, or manually maintained release manifests (rejected by Q90, Q92, Q97).
- Absorbing, wrapping, staging, or invoking `autoAll.ps1` or `eztConfig.ps1` (Q95).
- Computer naming automation (Q13), drive-letter save/restore (Q61), background log uploaders (Q75), forensic disk sanitization claims (Q85).

## Decisions

### D1: Artifact and scope strategy (S1, S2, S3)

- **Choice**: Formalize the approved design through the opsx artifact chain, migrating and retiring the docs-based spec. This change carries design formalization plus implementation phases 0–2; delta specs cover only the implemented scope.
- **Rationale**: The opsx workflow is the project's front door; specs stay honest if they describe what is actually built; later changes add partition/bootstrap capabilities without spec debt.
- **Alternatives considered**: Pointer-style artifacts referencing the old spec (rejected: non-self-contained, drift risk); keeping the docs spec alongside (rejected by session decision S1); implementing the whole suite in one change (rejected: reviewability).

### D2: Language and runtime constraints

- **Choice**: Windows PowerShell 5.1-compatible source only — no ternaries, `??`, `&&`/`||` chains, or other PS7-only syntax; pure ASCII everywhere; module prefix `OSDeploy.*` to avoid colliding with the OSD module's namespace.
- **Rationale**: WinPE and fresh Windows 11 both run 5.1; ASCII avoids encoding surprises in WinPE and the share; the OSD module owns the `OSD` prefix.
- **Alternatives considered**: PowerShell 7+ with bundled runtime (rejected: WinPE footprint and complexity); mixed versions per environment (rejected: one codebase, one standard).

### D3: Static gates on the Linux dev box

- **Choice**: `tests/` gates parse every source file via the PowerShell AST under `pwsh`, reject banned constructs and any non-ASCII bytes, and run after every edit; runtime validation happens on Windows.
- **Rationale**: The dev box is Linux; catching 5.1-incompatible syntax and encoding issues at edit time keeps every commit Windows-safe without a Windows round-trip.
- **Alternatives considered**: Windows-only CI (rejected: slower feedback, no local enforcement); style-only linting (rejected: the 5.1/ASCII constraints are correctness, not style).
- **Known gap**: `pwsh` 7 AST accepts some constructs 5.1 rejects at runtime — the banned-construct list must be explicit (see Risks).

### D4: Repository structure

- **Choice**: `src/Shared` (modules used by every environment), `src/Orchestrator` (this change), `src/Bootstrap`, `src/Partition`, `src/Build` (reserved, later changes), `config/` (central-configuration template + order-field mapping), `tests/` (static gates + Pester), plus the existing `source/` (decision record), `reference-code/` (driver-share structural reference), `openspec/` (workflow).
- **Rationale**: Environment boundaries mirror the three execution stages; shared logic has one home; later phases slot in without reorganization.
- **Alternatives considered**: Flat script folder (rejected: no boundaries at suite scale); per-component repositories (rejected: one suite, one repo, atomic cross-component changes).

### D5: Shared module decomposition

- **Choice**: Seven modules — `OSDeploy.Logging` (timestamped run folders, structured events + transcript, retention, optional secondary copy), `OSDeploy.Config` (load/validate/resolve/snapshot), `OSDeploy.State` (atomic JSON writes; owns the three state-file contracts), `OSDeploy.Disk` (inventory, selection, revalidation, erase variants, secondary prep), `OSDeploy.Image` (multi-index validation, temp→validate→promote lifecycle), `OSDeploy.Gui` (WPF/XAML host shared by all environments), `OSDeploy.Util` (SHA-256 inventory, canonical bundle hash, helpers).
- **Rationale**: Each has one purpose, an interface testable without its consumers, and can be held in context at once. Disk/Image logic is built now (Pester-tested) even though its runtime consumers arrive in phases 3–4.
- **Alternatives considered**: One monolithic `OSDeploy` module (rejected: god-module); finer per-function modules (rejected: ceremony without benefit).

### D6: State files are atomic JSON with last-known-good copies

- **Choice**: `OSDeploy.State` writes JSON atomically (temp file + move) and owns `ReadinessRecord.json`, `DeploymentState.json`, and `FactoryProfile.json` (active + last-known-good). Identity fields (machine, disk, run, workflow) never fall back; only documented noncritical fields do.
- **Rationale**: Power-loss safety at checkpoints is a confirmed requirement (Q35, Q89); atomic writes make every state file all-or-nothing; last-known-good gives FactoryProfile a recovery path (Q87).
- **Alternatives considered**: Direct writes (rejected: torn files on power loss); registry-based state (rejected: must live on the partition, not in installed Windows); XML (rejected: JSON matches the config and tooling).
- **Field-level contracts** are specified in the `state-files` capability spec, not here.

### D7: Configuration resolution and snapshot

- **Choice**: Central config is one JSON file (`config/osdeploy-config.json` template → share `Config\`) with sections `OrderDatabase` (connection, credentials, `ColumnMap` — Q98), `Deployment` (partition sizes, recommended drive size, timezone), `Logging`, `WindowsUpdate`, `RegulatedStates`, `CompanyWorkflowMap`. Every setting has a hard-coded default and validated fallback; the fully resolved effective configuration is saved as a versioned local snapshot; Factory Recovery uses only the snapshot and safe fallbacks (Q83, Q84).
- **Rationale**: Single authority with bounded drift; the snapshot makes the partition self-sufficient after handoff.
- **Alternatives considered**: Full JSON-Schema validator dependency (rejected: WinPE footprint; hand-rolled validation suffices); no snapshot (rejected: recovery would need the server); INI/XML (rejected).

### D8: Orchestrator execution model

- **Choice**: Single-instance startup Scheduled Task running as SYSTEM without sign-in. Authoritative checkpoint is `DeploymentState.json` on the partition (run, machine, disk, workflow, edition, phase, attempt, reboot, configuration-version, timestamp). Every phase idempotent; resume only the last incomplete phase; never re-enter completed destructive work; `RebootPending` saved before restarts, identity validated on return; three automatic attempts per checkpoint, fourth failure opens blocking Technician Review. Completion is recorded only after required work, cleanup, final-log verification, and the correct handoff; a restart after completion runs cleanup only; cleanup failure blocks completion (Q35, Q36, Q89).
- **Phase order**: Drivers → Applications → workflow specifics (EZT account/sign-in/password transition; MMC Audit Mode finalize and Sysprep; Energy Star per saved profile) → Windows Update cycles → EZT activation flow → final validations and result states → persistent recovery boot-entry registration → log finalization → cleanup.
- **Rationale**: The checkpoint-on-partition model survives Windows reboots and power loss by design; the task requires no sign-in so first-boot automation is untouched.
- **Alternatives considered**: Windows service (rejected: heavier staging, cleanup complexity); per-phase scheduled tasks (rejected: state scatter); interactive agent (rejected: must run before any sign-in).

### D9: Orchestrator integrity without a signing system

- **Choice**: Restrict `C:\ProgramData\OSDeploy\Orchestrator` to SYSTEM and local Administrators (NTFS). Automatically calculate SHA-256 hashes after staging, store them with the deployment state on the partition, recheck before first execution and after restarts. On failure, recopy only from the local partition repair source and revalidate; a second failure stops at blocking Technician Review (Q90).
- **Rationale**: Detects accidental corruption and incomplete staging with zero release-management overhead; the bundle hash identifies the exact staged copy.
- **Alternatives considered**: Authenticode signing (rejected by Q90: no PKI, no value against a local admin); pinned public keys (rejected: same); manual release manifests (rejected: Q92/Q97 established generated hashes).
- **Accepted boundary**: A local administrator can replace files and hashes together; this is corruption detection, not tamper proofing.

### D10: One shared WPF/XAML GUI module

- **Choice**: All screens — bootstrap controller, partition deployment/recovery, orchestrator review dialogs — come from one `OSDeploy.Gui` module of XAML definitions plus a wizard host. Environment launchers own threading: the WinPE launcher (phase 4) invokes `powershell.exe -STA` because the WinPE host can be MTA; installed Windows is STA by default (Q99).
- **Rationale**: Consistent appearance across environments; one place to evolve the wizard; WPF matches what OSDCloud itself uses in WinPE.
- **Alternatives considered**: WinForms (rejected: less declarative, drifts from OSDCloud's stack); per-environment GUIs (rejected: three lookalike codebases); console-only (rejected: technician-facing flows need wizards and modal confirmations).

### D11: Drivers by pattern, applications by manifest

- **Choice**: Drivers install with no manifests — pattern-match standardized manufacturer installer naming (ASUS `AsusSetup.exe`, single-installer Gigabyte folders), silent recursive install using manufacturer installers and PnP (Q96). Applications are workflow-fixed sets driven by per-workflow manifests (`Apps\{EZT,MMC}\manifest.json`; entries `{Id, Name, Installer, Type, SilentArgs, SuccessCodes, RetryCount, TimeoutMinutes, Required}`), retried per manifest, then Acknowledge-and-Continue (Q25, Q26).
- **Rationale**: Driver libraries are technician-curated on the share following manufacturer conventions — manifests would duplicate that and drift; application sets are deliberately chosen per workflow, so a manifest is the right contract.
- **Alternatives considered**: Driver manifests (rejected by Q96); per-app technician selection (rejected by Q25); DISM offline driver injection (rejected: manufacturer installers handle firmware-adjacent software PnP cannot).

### D12: Testing strategy for this change

- **Choice**: Four layers, bottom two built now: (1) static gates on Linux after every edit; (2) Pester logic tests on Linux — config resolution/fallbacks, atomic state writes, model-name formatting (Win32_BaseBoard.Product normalization incl. Micro-Star trailing-six removal), inventory hashing, company mapping; (3) component tests on a Windows VM — orchestrator phases against a mock partition folder, driver pattern engine dry-run; (4) integration/lab (later changes).
- **Rationale**: Every behavior that is pure logic is provable on Linux before Windows is involved; the mock partition folder decouples orchestrator development from phase 3.
- **Alternatives considered**: Lab-first testing (rejected: no PXE infrastructure yet, slow feedback); unit-testing everything (rejected: GUI and disk-adjacent code is exercised meaningfully only in component/lab layers).

### D13: Decision-record continuity

- **Choice**: New behavioral decisions confirmed during implementation continue in `source/` as Question 103+ under the existing documentation protocol; each flows into the affected artifact/spec. The Q&A file and Working Context are updated only after user confirmation.
- **Rationale**: The repo's source-authority rules already govern this; artifacts derive from the record, never the reverse.
- **Alternatives considered**: Recording new decisions only in artifacts (rejected: two competing records); pausing the Q&A protocol (rejected: it is the confirmation mechanism).

## Risks / Trade-offs

- [Risk] `pwsh` 7 on Linux parses constructs that Windows PowerShell 5.1 rejects at runtime → Mitigation: the static gate carries an explicit banned-construct list (ternary, `??`, chain operators, `using namespace` quirks, etc.) plus a Windows spot-check in component tests; treat gate allowlist gaps as bugs in the gate.
- [Risk] Orchestrator phases built against a mock partition may diverge from the real staged layout → Mitigation: the mock folder implements the partition content contract from the specs (state files, repair source, apps, drivers, config snapshot); phase 3 must satisfy the same contract, and phase 5 drills catch residuals.
- [Risk] Windows-only behaviors (Scheduled Task registration, Sysprep, `reagentc`, PnP rescans, unattend application) cannot be exercised on Linux → Mitigation: they are component-tested on the Windows VM and lab-verified in phase 5; logic around them (state transitions, attempt counting, result states) is Pester-tested on Linux.
- [Risk] Two living records (`source/` decision record, openspec artifacts) can drift → Mitigation: D13 precedence — `source/` controls behavior; specs cite Q numbers; new decisions land in the Q&A first. Self-review of artifacts against the record at each artifact step.
- [Risk] WPF availability inside WinPE depends on optional components confirmed only in phase 4 → Mitigation: `OSDeploy.Gui` is environment-agnostic XAML + host; the STA launch pattern is designed now; phase 4 verifies the component set (open item).
- [Trade-off] No signing/integrity against a hostile local administrator → Accepted per Q90: corruption detection is the requirement; tamper-proofing was explicitly rejected as scope.
- [Trade-off] ASCII-only source → Accepted: WinPE/share safety outweighs unicode in code; user-facing strings stay ASCII (en-US per Q100).
- [Trade-off] Building Disk/Image modules before their runtime consumers exist → Accepted: their rules are stable (Q4–Q6, Q47–Q52), Pester proves them now, and phases 3–4 consume them unchanged or via later delta specs.

## Migration Plan

No deployment is involved — this change deploys nothing and contacts nothing (greenfield code plus documentation restructure; the retired docs spec is already deleted, preserved at git 516bf91).

Repository-level sequence (each step leaves the repo green):

1. Phase 0: scaffold `src/`, `config/`, `tests/` with the static gates; gates green on the empty tree.
2. Phase 1: shared modules land module-by-module with their Pester suites; gates re-run after every edit.
3. Phase 2: orchestrator engine, then phases, then integrity; component tests on the Windows VM against the mock partition folder.

Rollback: git revert — nothing is deployed, registered, or staged onto any machine; the only shared-state change (docs spec retirement) is documentation.

Acceptance: static gates green across all sources under `pwsh` on Linux; Pester suites pass; orchestrator component tests pass on the Windows VM (checkpoint resume, three-attempt limit, integrity revalidation, idempotent re-entry); every spec requirement traceable to its Q number.

## Open Questions

Owned implementation-time items (carried from `brainstorm.md`; none block phases 0–2):

- PXE-serving mechanism (WDS current; iPXE/HTTP research) — phase-4 change.
- One-time-boot mechanism (BCD `bootsequence` vs UEFI BootNext) — phase-5 lab verification per Q94.
- Pinned OSDeploy/OSD module version and pinning mechanics — phase 4, recorded at rollout.
- Order-DB `ColumnMap` values and `TimeZone` default — rollout; structure already fixed (Q98, Q84).
- WinPE optional-component set for WPF + MySQL — phase-4 image build.

To resolve during this change's tasks step (not blocking design):

- Mock partition folder's concrete layout and fixture builder (tasks.md).
- Scheduled-task registration mechanics (task XML vs `Register-ScheduledTask`) — Windows component test will settle it.
- Pester version floor on the dev box and how the gate script is invoked (pre-commit hook vs manual) — phase 0 task.
