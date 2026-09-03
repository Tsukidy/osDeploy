# Retrospective: osdeploy-suite-design

> Written: 2026-09-03 (after verify passed with warnings)
> Commit range: `516bf91..e7705f8`
> Worktree: `.claude/worktrees/osdeploy-suite-design` (branch `worktree-osdeploy-suite-design`, not yet merged)

---

## 0. Evidence

- **Commit range**: `516bf91..e7705f8` (40 commits)
- **Diff size**: +11,844 / -0 lines across 41 files (greenfield)
- **Tasks done**: 59/60 (`grep -cE '^\s*- \[x\]' tasks.md` → 59; the open one is 11.1, the Windows VM component run)
- **Active hours**: ~9 (2026-09-02 19:32 → 2026-09-03 04:32 commit span, continuous execution)
- **Subagent dispatches**: ~77 (29 implementers, 9 fix-round resumes, 29 task reviewers, 8 scoped re-reviews, 2 final-review agents; one comment-only fix verified directly by the controller)
- **New external dependencies**: Pester 5.9.1 (dev-box only, Apache-2.0, user module path — no runtime dependencies, nothing vendored)
- **Bugs encountered post-merge**: none (not yet merged; the review loop caught 9 fix rounds + a 7-finding final wave pre-merge)
- **OpenSpec validate state at archive**: pass (1 item, 0 issues; re-run at archive)
- **Test coverage signal**: unit tree 355 passed / 0 failed / 1 documented skip (Pester 5.9.1, pwsh 7.4.2); static gates GATES PASS; component suite delivered, VM execution outstanding

Commit chain (chronological, abridged):

```
95ce87f Scaffold src/tests/config tree with static-gate entry point
b3e177f Static gate: AST-parse all sources with per-file failure reporting
f08773f Static gate: reject PS7-only constructs with gate:allow suppression
3c6e55e Static gate: reject non-ASCII bytes with file and offset
0987f5f Add central configuration template with confirmed defaults
813277b Add OSDeploy.Util hashing, inventory, and canonical bundle hash
ecf44e9 Normalize inventory paths to backslash for platform-stable bundle hashes
de69a4b Add OSDeploy.State atomic JSON writes and state-file contracts
022d956 Add OSDeploy.Config resolution, fallbacks, and recovery snapshot
8e83cf3 Add OSDeploy.Logging run folders, retention, and copy semantics
55e6dc0 Add OSDeploy.Disk presentation and NVMe-preferred selection rules
ea77939 Add OSDeploy.Disk removable blocking, bypass audit, revalidation, capacity
4aebcc3 Add OSDeploy.Disk erase scopes and secondary-drive planning
b960c1d Add OSDeploy.Image multi-index metadata validation
00a86c6 Add OSDeploy.Image promotion lifecycle and edition resolution
383a84d Add OSDeploy.Gui wizard host, STA contract, and orchestrator screens
9432e43 Make corrupt-XAML test exercise the invalid-XML branch, not name validation
f358abc Add mock partition fixture builder implementing the content contract
7942117 Add orchestrator entry with single-instance lock and checkpoint engine
22cda9e Add orchestrator attempt policy, idempotent resume, and reboot handling
5663fc8 Add orchestrator integrity hashing, recheck, and local-only repair
0a27c96 Normalize empty inventories so integrity checks fail closed without throwing
170f3af Add orchestrator completion gating and scoped cleanup
b8f5fbe Clear stale block fields on successful completion
961b8d1 Add pattern-matched driver phase with dry-run and failure routing
eb652f7 Add manifest-driven application phase with retries and acknowledgement
e04f198 Add EZT account, autologon, password transition, and activation logic
a346bc4 Add MMC finalize/sysprep handling and energy-star decision table
373b858 Add scoped windows update phase with cycles and acknowledgement
fc729fe Add final validation, result states, boot-entry registration, log gating
dbcc68a Extract testable bcdedit parser and fix per-entry field capture order
564d654 Wire orchestrator phase sequence with full-run and power-loss resume tests
38bac38 Trim power-loss teardown stall and document WindowsUpdate resume limitation
37a3c13 Add Windows ACL and scheduled-task registration with component tests
0c157c5 Reject forward-slash UNC paths in Windows-only mechanics guards
952c62f Complete component suite and record final green gate results
27fc3cc Recover from abandoned orchestrator mutex and harden component suite
7f18b03 Correct probe comment to match kernel abandonment semantics
eeb3066 Wire final-review fixes: config shape, integrity recheck, task removal, identity gate
e7705f8 Adjudicate final-review residual minors: stale doc, dead RunId param, repair-cycle note
```

---

## 1. Wins

- [evidence: task-27 tests, `Invoke-DeploymentSequence` Describe] The power-loss resume test is a genuine cross-process SIGKILL against the real sequence on the real filesystem, asserting zero re-invocations of completed phases — not a mocked simulation. It caught its own teardown cost: the implementer's measurement cut the test from 62s to 4.2s (`38bac38`).
- [evidence: final review EVIDENCE block] Zero binding-invariant violations across the whole branch: Q18 no product keys, Q95 no reference-script usage, Q91 parameter boundary incl. both UNC spellings (`0c157c5`), Q85 wording, identity-never-defaulted, no Ignore/Continue-Anyway paths, canonical terminology — verified by the strongest-model final review with probes.
- [evidence: `.superpowers/sdd/plan/progress.md`] The ledger survived a mid-cycle context compaction (during Task 27) with zero re-dispatched work — position recovery came from the ledger + `git log`, exactly its design purpose.
- [evidence: `27fc3cc`, VM check 4.6/4.7] The abandoned-mutex BLOCKER found in review became both a product fix (Q35 crash-resume path would have thrown forever on real Windows) and a deliberate VM check that creates true abandonment via a keeper-handle grandchild probe.
- [evidence: 9 pre-flight rulings in ledger] Pre-flight plan scanning paid for itself: nine plan-snippet defects ruled and recorded before Task 1, zero mid-execution plan stalls.
- [evidence: verify.md §6] No fabrication pressure won: three consecutive artifacts (component suite, verify, tasks.md) preserved the honest "VM run outstanding" state instead of inventing results.

## 2. Misses

- 🟡 [painful | evidence: `eeb3066`, +780/-52] The final whole-branch review found 4 MAJOR composition-layer defects that all 29 per-task reviews missed: the conductor read the wrong config-snapshot shape (probe-proven: configured `MaxCycles` silently ignored), and the Q90 integrity recheck, Q89 task-removal, and Q89 identity-on-return behaviors existed as tested standalone functions but were never wired into the execution spine, plus two logging requirements (Q84/Q90) silently dropped. Fixing them late cost a large wave near the cycle's end.
- 🟡 [painful | evidence: tasks.md 11.1] The Windows VM needed for D12's layer-3 component tests was never available this cycle; the suite is delivered and Linux-verified but unexecuted on Windows, leaving task 11.1 open and Windows-only behavior verified by contract only.
- 📌 [nit | evidence: pre-flight rulings #1-#9] The generated plan contained nine internal contradictions (fixtures self-test, unimplemented gate:allow, attempt-cap semantics, collision-test same-RunId) — pre-flight caught them all, but the plan-writing step should not have produced them.
- 📌 [nit | evidence: session log] Environment friction: no PSGallery access (Pester installed by direct nupkg fetch), the sandbox refusing compound commands (constant decomposition overhead), and 10-minute TaskOutput timeouts leaking truncated transcript tails into controller context.

## 3. Plan deviations

| Plan task | What changed | Why |
|---|---|---|
| tasks.md checkbox updates | Batch-applied at the end via ledger tracking instead of immediately per task | Worktree isolation guard refuses edits to the main checkout; ledger carried the list, applied before verify |
| 28 (interfaces) | `FunctionsToExport` instead of the plan's `CmdletsToExport`; `Register-OrchestratorTask` gained mandatory `-PartitionRoot` and optional `-Execute`/`-Argument` | CmdletsToExport would export nothing (script functions); the Task 24 cleanup contract fixes the marker path this function writes; the mutex-under-task component check needs the execute seam |
| 27 (conductor design) | `GetNewClosure()` abandoned mid-loop for plain module scriptblocks + `$script:SequencePartitionRoot` | Closures re-bind to a dynamic module, breaking `$script:`/module-scope resolution (probed) |
| Final | `Invoke-DeploymentSequence` gained optional `-IdentityProvider` (default deploy-host-only, fail-visible off-Windows) | Final-review finding F4: the identity-on-return gate needed an injection seam to be both Linux-testable and real on Windows |

## 4. Skill / workflow compliance

| Skill                                            | Used |
|--------------------------------------------------|------|
| superpowers:brainstorming                        | ✓ (planning phase; `brainstorm.md` in change dir) |
| superpowers:writing-plans                        | ✓ (planning phase; `plan.md`) |
| superpowers:using-git-worktrees                  | ✓ (isolated worktree for the whole cycle) |
| superpowers:subagent-driven-development          | ✓ (29 tasks through implement→review→fix→re-review; final whole-branch review; rulings ledgered) |
| (transitive) superpowers:test-driven-development | ✓ (RED captured per task and per fix round where Linux-testable) |
| (transitive) superpowers:requesting-code-review  | ✓ (every task reviewed; findings verified with probes) |
| superpowers:finishing-a-development-branch       | scheduled — runs after archive per the bridge flow's ordering, not skipped |

### Deliberately Skipped Skills

> None — no skill was skipped. `finishing-a-development-branch` is sequenced
> after retrospective + archive by the superpowers-bridge schema's own
> instruction ("retrospective BEFORE any PR", archive, then finish), so its
> pending state is compliance, not deviation.

## 5. Surprises

- `Remove-Job -Force` inherits the same ~58s stall as `Stop-Job` on a SIGKILLed child (implicit stop waiting on the dead child's pipe) — the reviewer's suggested fix (drop Stop-Job only) would have saved nothing; the implementer measured both and dropped both (`38bac38`).
- Linux's named-mutex emulation never surfaces `AbandonedMutexException`, so the Q35 crash-resume path was silently untestable on the dev box — the divergence only became visible through the final review's keeper-handle analysis, and the fix's coverage lives entirely in VM check 4.6/4.7 (`27fc3cc`).
- A snapshot-shape drift (`.Values` nesting) survived 341 passing tests because every test either passed `-MaxCycles` explicitly or overrode the phase — probe-based review, not test count, found it.
- The pwsh-7-on-Linux quirk stack (JSON `[long]` ints, 1-entry array unwrapping, `Copy-Item -Recurse` creating destinations, `Join-Path` rejecting drive-qualified paths, Pester Describe-body code running at discovery) each cost a debug cycle once; all are now encoded in tests or comments.

## 6. Promote candidates → long-term learning

- [ ] 🔴 **Multi-task plans building an execution spine need a mid-cycle cross-module composition review, not only per-task reviews plus one final** → **Promote to memory** (type: feedback)
  > **Why**: 29 green per-task reviews still shipped a spine that read the wrong config shape and left three spec'd gates unwired; only the final whole-branch review caught it, as a +780-line wave (`eeb3066`).
  > **How to apply**: when a plan has ≥10 tasks that converge on one orchestrator/entry-point file, dispatch a composition-focused review at the first task that wires the pieces (Task 27 here), checking cross-module shapes and "tested function vs wired function".
- [ ] 🟡 **Reviewer probes beat reviewer reading: require instrumented empirical verification for review findings** → **Promote to memory** (type: feedback)
  > **Why**: the probe-proven findings (MaxCycles 2→3, AbandonedMutexException semantics, Remove-Job 58s) were all confirmed by measurement; prose-only review rounds were where weak findings appeared.
  > **How to apply**: when dispatching reviewers on this project, instruct them to prove any suspected defect with a minimal repro before reporting it.
- [ ] 🟡 **Windows-only code on a Linux dev box: the no-op-guard + `-SkipNoop` fail-visible + VM-check triad** → **Promote to project CLAUDE.md** (repo-standards section)
  > **Why**: the pattern kept Linux suites green while keeping the Windows bodies honest and gave every Windows behavior a designated VM verification point (Tasks 28-29).
  > **How to apply**: any new Windows-only function in `src/` follows the `Win32NT` guard contract and gets a numbered ComponentSuite check; nothing Windows-only ships without one.
- [ ] 📌 **The outstanding Windows VM run is a standing follow-up, not a closed item** → **Promote to memory** (type: project)
  > **Why**: task 11.1 is the only unchecked box; Windows-only behavior (ACL, Scheduled Tasks, bcdedit, WPF, kernel mutex abandonment) is verified by contract, not execution.
  > **How to apply**: the next change touching `src/Orchestrator` or the suite should either run `tests/component/ComponentSuite.ps1` elevated on the VM first, or explicitly restate the gap.
- [ ] 📌 **pwsh-7-on-Linux quirk list for this repo** → **Promote to memory** (type: reference)
  > **Why**: each quirk cost a debug cycle exactly once; they recur for every future PowerShell task here.
  > **How to apply**: consult before debugging surprising Pester/pwsh behavior on the dev box (backslash Join-Path resolution, `-NoEnumerate` double-nesting, Pester discovery-time Describe bodies, `$Host` parameter name unbindable).
