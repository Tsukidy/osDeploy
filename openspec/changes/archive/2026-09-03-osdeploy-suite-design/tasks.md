# Tasks — osdeploy-suite-design

Phases 0–2 per `design.md` (Migration Plan, D12). Each task names the capability spec it satisfies. Run the static gates after every edit (task 1.5).

## 1. Phase 0 — Scaffold and static gates (`repo-standards`)

- [x] 1.1 Create the repository scaffold: `src/Shared`, `src/Orchestrator`, reserved `src/Bootstrap`, `src/Partition`, `src/Build`, `config/`, `tests/`
- [x] 1.2 Static gate: AST-parse every `.ps1`/`.psm1`/`.psd1` under `src/` and `tests/` under `pwsh`, reporting failures per file
- [x] 1.3 Static gate: reject banned PowerShell 7-only constructs (ternary, `??`, `??=`, `&&`/`||` chain operators)
- [x] 1.4 Static gate: reject any non-ASCII byte, reporting file and first offending offset
- [x] 1.5 Gate entry point wired for after-every-edit runs; gates green on the clean tree; invocation documented in `tests/`
- [x] 1.6 `config/osdeploy-config.json` template with all sections and defaults exactly per `configuration-resolution`

## 2. Phase 1 — `OSDeploy.Util` and `OSDeploy.State` (`state-files`)

- [x] 2.1 `OSDeploy.Util`: SHA-256 file hashing, generated size+hash inventory, canonical serialization and bundle hash — with Pester coverage
- [x] 2.2 `OSDeploy.State`: atomic temp-file-plus-move JSON writes, including an interrupted-write test proving the previous document survives
- [x] 2.3 `OSDeploy.State`: `ReadinessRecord.json`, `DeploymentState.json`, `FactoryProfile.json` contracts with schema validation and never-falling-back identity fields — with Pester coverage
- [x] 2.4 `OSDeploy.State`: FactoryProfile active/last-known-good update order, restore-from-backup on invalid active, and both-invalid stop — with Pester coverage

## 3. Phase 1 — `OSDeploy.Config` (`configuration-resolution`)

- [x] 3.1 Central-config load and section/key validation with unknown-key warning
- [x] 3.2 Per-setting hard-coded defaults with missing/invalid fallback detection and fallback-record entries (reason `missing`/`invalid`)
- [x] 3.3 Versioned effective-configuration snapshot save/load: resolved values, version, source, explicit fallback list
- [x] 3.4 FactoryRecovery configuration loader that reads only the local snapshot and safe fallbacks, never a central path
- [x] 3.5 Pester suite: full resolution, every default, fallback paths, snapshot round-trip, recovery isolation, provenance logging fields

## 4. Phase 1 — `OSDeploy.Logging` (`deployment-logging`)

- [x] 4.1 Collision-safe timestamped run-folder creation with structured events plus transcript
- [x] 4.2 Oldest-first retention at `LocalLogHistoryMaxMB` that never removes the active run folder
- [x] 4.3 Secondary server-copy attempt as non-blocking warning; FactoryRecovery guard proving no server path is touched
- [x] 4.4 Final local-log update verification API used to gate the final summary, preserving acknowledgement across retries
- [x] 4.5 Pester suite: folders, collisions, retention pruning, copy-failure non-blocking, summary gating

## 5. Phase 1 — `OSDeploy.Disk` (`disk-safety`)

- [x] 5.1 Disk inventory and presentation model (disk number, model, serial, interface, capacity) as pure logic over inventory objects
- [x] 5.2 Selection rules: NVMe preferred, sole-NVMe auto-select flag, multiple-candidates require selection, SATA only when no NVMe
- [x] 5.3 Removable-storage detection/blocking rules and the Emergency Bypass chain (secondary warning, checkbox, Yes-or-Cancel, revalidation, audit event, no reason dropdown) as evaluatable state
- [x] 5.4 Identity revalidation-at-time-of-use contract comparing selection-time and use-time identity
- [x] 5.5 Deployment Erase scope variants per run type, and secondary-drive preparation rules (explicit selection only, GPT single NTFS, letters from D:, Data/Data-2/Data-3 labels, retry/skip outcomes, offline preservation, mount-verify only)
- [x] 5.6 Capacity logic: recommended-size warning, acknowledgement gating, impossible-layout hard block, no special logging
- [x] 5.7 Pester suite covering every rule above against fixture inventory objects

## 6. Phase 1 — `OSDeploy.Image` (`image-validation`)

- [x] 6.1 Multi-index validation logic: Home and Pro index presence, architecture/language/release/build consistency, index name/number recording
- [x] 6.2 Temp-download, validate, atomic-promote, reopen-and-revalidate lifecycle as composable operations
- [x] 6.3 Cache-retention rule on failed validation and edition-availability resolution returning the established choices without substitution
- [x] 6.4 Pester suite against fixture WIM metadata (no real downloads)

## 7. Phase 1 — `OSDeploy.Gui` (`shared-gui-framework`)

- [x] 7.1 Wizard host and XAML screen loader with shared style resources, testable on the logic level under `pwsh`
- [x] 7.2 STA apartment detection with fail-fast and relaunch guidance
- [x] 7.3 Screen definitions needed by the orchestrator (Technician Review, Acknowledge-and-Continue, noted-issues summary), rendering verified later on the Windows VM

## 8. Phase 2 — Mock partition fixture and orchestrator engine (`orchestrator-execution`)

- [x] 8.1 Mock partition folder builder implementing the partition content contract: state files, orchestrator repair source, apps, drivers, config snapshot, log folders
- [x] 8.2 Orchestrator entry point with single-instance lock; concurrent second launch exits without work or state mutation
- [x] 8.3 Checkpoint engine writing the full atomic `DeploymentState.json` context before each phase's work begins
- [x] 8.4 Idempotent resume: last incomplete phase only, no destructive re-entry, configuration and log context restored
- [x] 8.5 Attempt policy: three automatic attempts per checkpoint, fourth failure opens blocking Technician Review with history, errors, logs, manual retry, rollback; counter resets on success
- [x] 8.6 `RebootPending` save before restarts and machine/disk identity validation on return
- [x] 8.7 Completion gating and cleanup: record completion only after work, cleanup, final-log verification, and correct handoff; cleanup failure blocks; restart after completion runs cleanup only; recovery content retained
- [x] 8.8 Pester suite for 8.2–8.7 against the mock partition fixture

## 9. Phase 2 — Orchestrator integrity (`orchestrator-integrity`)

- [x] 9.1 Staging-time per-file SHA-256 and complete bundle hash generation stored with deployment state, no manual manifests
- [x] 9.2 NTFS ACL application restricting the orchestrator directory to SYSTEM and local Administrators
- [x] 9.3 Hash revalidation before first execution and after restarts
- [x] 9.4 Local-only repair from the partition repair source with revalidation, second-failure stop at Technician Review, and a guard proving no server path is accessed
- [x] 9.5 Integrity and refresh events recorded in the authoritative local log
- [x] 9.6 Single-instance SYSTEM startup Scheduled Task registration and validation mechanics (Windows component test)

## 10. Phase 2 — Orchestrator phases (`driver-installation`, `application-installation`, `ezt-profile`, `mmc-profile`, `energy-star-policy`, `windows-update-cycle`, `final-validation-handoff`)

- [x] 10.1 Driver phase: pattern engine for manufacturer installer naming (ASUS `AsusSetup.exe`, single-installer folders), recursive silent execution via manufacturer installers and PnP, dry-run mode, failure reporting and Technician Review routing — with pattern-engine Pester coverage
- [x] 10.2 Application phase: workflow manifest loading, silent execution with `SuccessCodes`/`RetryCount`/`TimeoutMinutes`, Acknowledge-and-Continue modal, Completed-with-Warnings retention — with manifest-logic Pester coverage
- [x] 10.3 EZT workflow specifics: passwordless `User` administrator, Administrator stays disabled, registry-based unlimited automatic sign-in, password-transition shortcut and managed workflow with the atomic password/autologon/credential transition, activation flow with keys never stored or logged
- [x] 10.4 MMC workflow specifics: Audit Mode finalize, temporary-artifact cleanup then Sysprep to OOBE, Sysprep-failure blocking error, no-EZT-account guard
- [x] 10.5 Energy Star phase: deployment-time regulated-state evaluation, the three power behaviors (CA MMC, CA EZT, non-regulated), profile caching, recovery reapply-else-ask
- [x] 10.6 Windows Update phase: scope filters, configurable cycles from effective configuration, required-reboot completion, warn-and-acknowledge completion, offline recovery skip
- [x] 10.7 Final validation: PnP rescan and single acknowledged warning, Technician Review with Rescan/Rerun, result states, noted-issues acknowledgement, Tech-Addressed transition on Finish Deployment
- [x] 10.8 Boot-entry registration: persistent Factory Recovery entry with Windows default and five-second timeout, partition-identity and boot-file validation, deployment-only override clearing, failure blocks completion
- [x] 10.9 Log finalization gating the summary close before cleanup runs
- [x] 10.10 Pester coverage for all phase logic runnable under `pwsh` (state transitions, attempt counting, result states, decision tables)

## 11. Component verification on Windows VM (`repo-standards`, all capabilities)

- [ ] 11.1 Windows VM component suite: orchestrator engine and phases against the mock partition fixture, including Scheduled Task registration, integrity revalidation, GUI screens, and phase handoffs
- [x] 11.2 Full run: static gates and all Pester suites green on the Linux dev box; record versions and results for `verify.md`
