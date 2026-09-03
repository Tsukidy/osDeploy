# Proposal — osdeploy-suite-design

## Why

The suite's behavior is fully designed — 102 confirmed decisions in `source/` plus an approved implementation design — but nothing exists as code, and the design record lives in prose documents rather than enforceable artifacts. This change turns that validated design into the OpenSpec artifact chain (proposal, design, specs, tasks, plan) as the single source of truth going forward, and starts implementation at the foundation: repository scaffold with static gates, the shared modules every environment depends on, and the orchestrator — the most logic-dense component, testable without PXE infrastructure, deliberately sequenced before the partition and bootstrap work.

## What Changes

**Design record**
- From: implementation design in `docs/superpowers/specs/2026-09-02-osdeploy-suite-design.md` (now retired; preserved in git history at 516bf91) plus behavioral prose in `source/`.
- To: OpenSpec artifacts under `openspec/changes/osdeploy-suite-design/`; `source/` remains the authoritative behavioral decision record these artifacts derive from.
- Reason: the opsx workflow is now the project's front door; specs become reviewable and enforceable.
- Impact: non-breaking; documentation structure only.

**Implementation (phases 0–2 of the approved plan)**
- New repository scaffold: `src/` (`Shared/`, `Orchestrator/` now; `Bootstrap/`, `Partition/`, `Build/` reserved for later changes), `config/` central-configuration template, `tests/` static gates and Pester suites.
- New static gates runnable on the Linux dev box under `pwsh`: Windows PowerShell 5.1-compatible syntax (AST parse, banned constructs), pure-ASCII source.
- New shared modules (`OSDeploy.Logging`, `OSDeploy.Config`, `OSDeploy.State`, `OSDeploy.Disk`, `OSDeploy.Image`, `OSDeploy.Gui`, `OSDeploy.Util`) with Pester coverage.
- New installed-Windows orchestrator: checkpoint engine (idempotent phases, resume, three-attempt limit, blocking Technician Review), the deployment phases (drivers, applications, EZT/MMC workflow specifics, Windows Update, validation and result states, recovery boot-entry registration, log finalization, cleanup), and integrity protection (SHA-256 hashing, NTFS restriction, local-only repair).

**Out of scope (later changes):** phase 3 (partition engine, recovery UI), phase 4 (bootstrap controller, WinPE build, WDS publish), phase 5 (end-to-end lab drills). Open implementation-time items (PXE-serving choice, one-time-boot mechanism, OSD module pinning, `ColumnMap`/`TimeZone` values, WinPE optional components) carry their phase owners in `brainstorm.md`.

## Capabilities

Scope note (session decision S3): delta specs cover the behavior implemented in this change. Whole-suite architecture is captured in `design.md` as context; later changes add the partition/bootstrap capabilities.

### New Capabilities

- `repo-standards`: repository layout, PowerShell 5.1/ASCII source conventions, and the Linux-runnable static gates that enforce them after every edit.
- `configuration-resolution`: central-config load and schema validation, per-setting hard-coded defaults, effective-config resolution and versioned snapshot, fallback recording (Q83, Q84, Q98 structure).
- `state-files`: atomic JSON writes and the file contracts for `ReadinessRecord.json`, `DeploymentState.json`, and `FactoryProfile.json` with active and last-known-good copies; identity fields never fall back (Q87, Q89, Q92, Q102).
- `deployment-logging`: timestamped per-run folders on the partition as the authoritative log, structured events plus transcript, oldest-first retention, optional non-blocking secondary copy (Q8, Q73–Q78).
- `disk-safety`: disk inventory and presentation, NVMe-preferred selection, removable-storage blocking and Emergency Bypass, identity revalidation at time of use, Deployment Erase variants, secondary-drive preparation (Q4–Q6, Q12, Q58–Q66, Q79–Q82, Q85).
- `image-validation`: multi-index Home/Pro WIM validation and the temporary-download → validate → atomic-promote → reopen-and-revalidate cache lifecycle (Q39–Q40, Q46–Q52).
- `shared-gui-framework`: one WPF/XAML GUI module serving every environment, with the STA launch requirement for WinPE hosts (Q99).
- `orchestrator-execution`: single-instance SYSTEM startup task, idempotent phases resuming from the last incomplete checkpoint, `RebootPending` handling, three automatic attempts then blocking Technician Review, completion and cleanup rules (Q35, Q36, Q89).
- `orchestrator-integrity`: NTFS-restricted staging directory, automatic SHA-256 hashing stored with deployment state and rechecked before first execution and after restarts, local-only repair, stop at Technician Review on repeated failure (Q90).
- `driver-installation`: pattern-matched silent recursive manufacturer-installer and PnP installation with no manifests, failure reporting and Technician Review routing (Q27–Q29, Q95, Q96).
- `application-installation`: workflow-fixed application sets driven by manifests, retry-then-acknowledge failure handling (Q25, Q26).
- `ezt-profile`: passwordless local-admin `User`, persistent automatic sign-in, managed password transition, activation flow, completed-desktop endpoint (Q14–Q16, Q18–Q19, Q24, Q33–Q34, Q86).
- `mmc-profile`: Audit Mode staging, finalize/return-to-OOBE with cleanup and Sysprep, powered-on OOBE endpoint (Q14, Q30, Q32).
- `energy-star-policy`: technician-overridable regulated-state power policy, cached in the factory profile, reapplied on recovery (Q20–Q23).
- `windows-update-cycle`: scoped Windows Update during technician staging with configurable cycles, reboot completion, warning-and-acknowledge completion, offline skip (Q88).
- `final-validation-handoff`: final Plug and Play validation, noted-issues acknowledgement and result states, recovery boot-entry registration as a completion gate, log finalization before summary close (Q28, Q42, Q67–Q73, Q94 orchestrator portion).

### Modified Capabilities

None — no specs exist under `openspec/specs/` yet; this change creates the initial set.

## Impact

- **Code**: all new — `src/Shared/`, `src/Orchestrator/`, `config/` template, `tests/`. No existing runtime code is modified (greenfield). `reference-code/` and `source/` are untouched reference/record material; `autoAll.ps1` and `eztConfig.ps1` are never absorbed, wrapped, staged, or invoked (Q95).
- **Dependencies**: Pester for logic tests on the dev box; a Windows VM for orchestrator component tests against a mock partition folder. No live DeploymentShare, MySQL, WDS, or Microsoft access is required by this change's tests.
- **Systems**: none at runtime — this change deploys nothing and contacts nothing; the orchestrator runs only in component-test contexts until phase 3+ stages it for real.
- **Documentation**: retires `docs/superpowers/specs/2026-09-02-osdeploy-suite-design.md` (already deleted; content migrated per the map in `brainstorm.md`); `source/` Q&A and Working Context remain the authoritative behavioral record, and new behavioral decisions confirmed during implementation continue there as Question 103+.
