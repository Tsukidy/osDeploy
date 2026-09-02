# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A design-phase project: a technician-operated OSDeploy/OSDCloud/PXE deployment suite for custom desktop PCs (Windows 11 Home/Pro, EZT and MMC factory profiles, customer-side Factory Recovery). **No scripts or implementation exist yet** — there is no build, lint, or test command. The entire repository is two Markdown deliverables in `source/` whose content is produced through a structured question-and-answer interview with the user:

- `source/OSDeploy_PXE_Workflow_Questions_and_Answers.md` — the numbered decision record (Questions 1–94 recorded; Question 95 is next). Append-only history of each question and its confirmed answer.
- `source/OSDeploy_PXE_Workflow_Working_Context.md` — the derived architecture summary that connects confirmed decisions, lists unresolved conflicts, and tracks terminology. Updated separately whenever a confirmed answer changes the system model.

A third file, `OSDeploy_PXE_Workflow_Consolidated_Decision_Record.docx`, is referenced but not stored here; it is historical background only.

## Source authority (controls every edit)

When sources disagree, apply this precedence:

1. The user's confirmed answers in the current conversation.
2. The numbered Q&A file.
3. The Working Context file.
4. The consolidated DOCX (may be outdated even when its filename/date looks newer).
5. Earlier implementation guides and recommendations.

Additional rules that govern how decisions are recorded:

- A **higher-numbered confirmed answer supersedes** conflicting portions of earlier answers; earlier answers stay visible as history but do not control implementation. (Example: Q91 supersedes the DeploymentShare emergency-image portions of Q52–55.)
- Text labeled `My Recommendation` is **not** a user decision unless the user explicitly confirms it.
- Never infer a file is current from its name, attachment order, metadata, or date — inspect content.
- Never mark an item pending/confirmed/superseded/verified without checking the controlling source.
- Never create a numbered question from a withdrawn or invalid premise.

## Documentation protocol

- Add each question **and** its answer together to the Q&A file — never save only the resolution.
- Update the Q&A file only after the user confirms or revises an answer; then update the Working Context file when the answer affects the system model. The two files are maintained independently.
- The next question number is the highest existing number plus one (verify in the Q&A file; it was 94 → 95 at last update, 2026-09-02).
- Do not rewrite or re-export the consolidated DOCX unless specifically asked.

## Architecture: the load-bearing model

Three execution stages, in order (full detail and confirmed defaults live in the Working Context file):

1. **PXE bootstrap** (customized OSDeploy WinPE, read-only `\\Deployment\DeploymentShare`): technician enters order number → one read-only MySQL lookup caches order values → editable EZT/MMC and Home/Pro defaults → disk/removable-media confirmation → creates and stages the persistent **OSDCloud Deployment Partition** → runs the automatic **Deployment Partition Ready gate** (size + SHA-256 inventory of every staged file, writability, space checks) → atomically writes `DeploymentPartitionReady.json` → configures a **one-time** boot into the partition → reboots. The bootstrap does not perform the main deployment.
2. **OSDCloud Deployment Partition**: the persistent, bootable local environment that is the **primary deployment environment** (not merely recovery storage). Runs the shared EZT/MMC engine, acquires/validates/caches the multi-index Windows image (Microsoft direct when online, validated local cache otherwise), and later performs Factory Recovery.
3. **Installed-Windows orchestrator** (`C:\ProgramData\OSDeploy\Orchestrator`, SYSTEM startup Scheduled Task): idempotent phases, authoritative atomic `DeploymentState.json` checkpoint on the partition, reboot-safe resume, three automatic attempts per checkpoint then blocking Technician Review.

Key invariants any future implementation must preserve:

- **Connectivity boundary**: once execution begins on the OSDCloud Deployment Partition it must never probe, map, authenticate to, retrieve from, or upload to DeploymentShare or any deployment server — the PXE bootstrap must stage and validate everything first. Standalone means server-independent; Microsoft access through OSDCloud remains allowed. Factory Recovery never contacts the server for anything (including logs).
- **Run types**: InitialDeployment and PXE Full Factory Rebuild are technician-controlled and server-assisted; FactoryRecovery is fully local and preserves the partition (erases only the Windows-related area, never touches secondary drives).
- **Fail-closed**: readiness-record/disk-identity revalidation failure after the partition boots stops before any destructive work — no Ignore/Continue Anyway. Invalid `FactoryProfile.json` (active and last-known-good both bad) stops without guessing a workflow.
- **Disk safety**: full-disk Deployment Erase only on the confirmed, revalidated primary target; removable USB storage blocks destructive work unless the acknowledged Emergency Bypass is used; "Deployment Erase" is not forensic sanitization and warnings must not claim it.
- **Terminology**: "OSDCloud Deployment Partition" is the canonical term for the persistent partition; "PXE bootstrap" refers only to the initial staging stage.
