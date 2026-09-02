# OSDeploy PXE Workflow Working Context

Last updated: August 20, 2026

## Purpose

This file is the maintained working context for the OSDeploy and OSDCloud PXE Workflow project. It explains how the confirmed decisions fit together, records which sources control, identifies conflicts that still need formal resolution, and preserves enough architectural context to continue the design without reconstructing it from individual questions.

This is not the numbered ADR Q&A record. The Q&A record remains the exact history of each question and confirmed answer. Update this file separately whenever a confirmed answer changes the overall architecture, terminology, source authority, constraints, or unresolved work.

## Source Authority

Use the following precedence when sources disagree:

1. The user's confirmed answers in the project conversation.
2. `OSDeploy_PXE_Workflow_Questions_and_Answers.md`, which records those confirmed questions and answers.
3. This working-context file, which summarizes and connects the confirmed decisions.
4. The consolidated DOCX decision record, which is useful background but may be outdated even when its filename or internal date appears newer.
5. Earlier implementation guides and recommendations, which are historical reference material unless confirmed by a later answer.

Within the numbered Q&A record, a higher-numbered confirmed answer supersedes any conflicting portion of an earlier answer. Earlier answers remain visible for decision history but do not control implementation where a later answer has replaced them.

Do not treat text labeled `My Recommendation` as a user decision unless the user explicitly confirms it. Do not infer that a file is current from its name, attachment order, metadata, or date. Inspect the actual content before describing its state.

## Documentation Rules

- Keep every numbered question and its confirmed answer in `OSDeploy_PXE_Workflow_Questions_and_Answers.md`.
- Include both the question and the answer. Never save only the resolution.
- Update the Q&A record only after the user confirms or revises the answer.
- Update this context file when the answer affects the system model or resolves a listed conflict.
- Do not repeatedly rewrite the consolidated DOCX during the question session.
- Do not mark an item pending, confirmed, superseded, saved, or verified without checking the controlling source.
- Do not create a new numbered question from a withdrawn or invalid premise.
- Continue with Question 95 after recording each confirmed decision in both active Markdown files when it changes the architectural context.

## Project Goal

Build a technician-operated deployment suite for custom desktop PCs using OSDeploy, OSDCloud, PXE, and a persistent OSDCloud Deployment Partition. The suite must deploy Windows 11 Home or Pro, apply the correct EZT or MMC factory profile, install required drivers and applications, preserve authoritative local deployment, recovery, and logging data, and support customer-side Factory Recovery without dependence on the deployment server.

The scripts and complete implementation are not yet being written. The current work defines architecture, behavior, safety rules, recovery boundaries, and implementation requirements.

## Core Architecture

### Initial Deployment

1. A technician PXE-boots the machine into a customized OSDeploy WinPE image.
2. The embedded bootstrap reaches `\\Deployment\DeploymentShare` with read-only access and opens the graphical deployment controller.
3. The technician enters the order number.
4. The controller performs one read-only MySQL query and caches all required order values.
5. Order data supplies editable defaults for EZT or MMC and Windows 11 Home or Pro.
6. The technician confirms the workflow, edition, primary disk, removable-media state, recovery layout, and optional secondary-drive preparation.
7. The PXE-booted WIM creates and configures the persistent OSDCloud Deployment Partition.
8. Before leaving PXE, it pulls and validates every deployment-server resource the partition will require, configures a one-time boot to the partition, and reboots.
9. The OSDCloud Deployment Partition becomes the primary deployment environment and runs the shared EZT or MMC deployment engine without reconnecting to the deployment server.
10. OSDCloud acquires, validates, installs, and retains the current compatible Windows image.
11. Installed-Windows orchestration completes drivers, applications, settings, Windows Update, validation, logging, cleanup, and the correct EZT or MMC handoff.

### OSDCloud Deployment Partition Role

The OSDCloud Deployment Partition is the persistent, bootable, local OSDCloud environment that performs the primary deployment and later Factory Recovery. It is not only a recovery environment, storage partition, or passive Windows-image cache.

It contains or preserves the following deployment and recovery resources:

- The local OSDCloud deployment environment.
- The shared EZT and MMC deployment engine.
- The validated Windows 11 Home and Pro image cache.
- The active `FactoryProfile.json` and last-known-good backup.
- The saved effective configuration snapshot.
- Required applications and application installers.
- Required Windows and recovery-network drivers.
- The local source used to repair the installed-Windows orchestrator.
- `DeploymentState.json` and related checkpoint information.
- Authoritative local logs and retained historical run folders.

The configured OSDCloud Deployment Partition default is 32768 MB. The value is read during Initial Deployment and PXE Full Factory Rebuild. Changing the central setting does not resize an already deployed partition. The previously confirmed configuration key remains `RecoveryPartitionSizeMB` unless a later decision explicitly renames it.

### Deployment Partition Ready Gate

PXE may configure the one-time boot into the OSDCloud Deployment Partition only after one automatic readiness gate succeeds.

The gate verifies:

- The partition is bootable and belongs to the confirmed primary disk.
- The deployment engine and selected EZT or MMC workflow are present.
- The resolved configuration and factory profile are present.
- Required applications, drivers, orchestrator repair source, and logging components are present.
- Every staged file passes the automatically generated size and SHA-256 inventory.
- Required network drivers are available for direct Microsoft access through OSDCloud.
- Deployment-state and logging locations are writable.
- Sufficient partition space remains for Microsoft image acquisition and the permanent Windows cache.

After successful validation, PXE atomically writes `DeploymentPartitionReady.json` with the run, machine, disk, workflow, edition, configuration version, generated bundle hash, and timestamp. The record is generated from the staged content and is not a manually maintained release manifest.

PXE then configures the one-time boot and restarts. If validation fails, it remains in PXE and offers Retry Staging or Cancel Deployment. When the partition boots, it revalidates the readiness record and primary-disk identity before continuing and does not reconnect to the deployment server.

### Readiness Revalidation Failure

If the OSDCloud Deployment Partition fails readiness-record or primary-disk identity revalidation after boot, it stops before Windows installation, Deployment Erase, or any other destructive work. Ignore and Continue Anyway are not available.

During InitialDeployment, the blocking technician screen offers:

- Retry Local Validation.
- View Diagnostic Details and Logs.
- Reboot to PXE for Restaging.

If automatic PXE selection cannot be configured safely, instruct the technician to use the motherboard boot menu.

During FactoryRecovery, preserve the existing Windows installation and offer:

- Retry Local Validation.
- View Diagnostic Details and Logs.
- Cancel Recovery and Boot Windows.

If Windows is not bootable, direct the technician to PXE Full Factory Rebuild. The partition never reconnects to DeploymentShare to repair or restage itself. Any server-assisted restaging begins through a fresh technician-controlled PXE boot.

### OSDCloud Bootable-Media Implementation Reference

Current official OSDCloud materials expose `New-OSDCloudUSB` for creating bootable OSDCloud USB media and `Update-OSDCloudUSB` for updating it. During implementation, inspect the source of these functions in the installed, pinned OSDCloud or OSD module and use their bootable WinPE media layout as a reference when designing the OSDCloud Deployment Partition if useful.

Do not assume the USB implementation can be copied unchanged. The internal partition must integrate with the primary disk's UEFI and Windows Boot Manager layout, support a controlled one-time deployment boot and persistent Factory Recovery entry, preserve the partition during FactoryRecovery, enforce the confirmed disk-safety rules, and avoid reconnecting to the deployment server after PXE staging.

Official references:

- [New-OSDCloudUSB documentation](https://www.osdcloud.com/osdcloud-v1/osdcloud/setup/osdcloud-usb/new-osdcloudusb)
- [Official OSDeploy OSD repository](https://github.com/OSDeploy/OSD)

### Boot-Entry Lifecycle

After the Deployment Partition Ready gate succeeds, the PXE bootstrap creates a one-time boot into the OSDCloud Deployment Partition. This temporary selection does not permanently make the partition the default boot target.

During primary deployment, the partition may restart into itself when required by its deployment checkpoints. After Windows is installed and validated:

- Register the persistent Factory Recovery entry.
- Keep Windows as the default boot target.
- Retain the confirmed five-second boot-menu timeout.
- Validate the persistent entry against the correct partition identity and boot files.
- Clear every remaining initial-deployment-only boot override after successful deployment.

Failure to register or validate the persistent Factory Recovery entry blocks final completion at Technician Review.

Choose the exact supported boot-selection mechanism during implementation and lab testing against the installed current OSDCloud media layout and representative target motherboard firmware. Candidate mechanisms include UEFI BootNext, BCD bootsequence, or another method that satisfies the confirmed lifecycle without altering the persistent Windows default.

### Factory Recovery

Factory Recovery boots from the persistent OSDCloud Deployment Partition and runs its local OSDCloud instance plus the shared deployment engine without PXE.

Factory Recovery:

- Restores the saved EZT or MMC factory profile.
- Uses the saved Windows edition unless an approved Home or Pro change is selected.
- Preserves the OSDCloud Deployment Partition and erases only the Windows-related target area.
- Never modifies, mounts, relabels, formats, brings online, or otherwise writes to secondary physical drives.
- Uses only locally saved configuration and hard-coded safe fallbacks.
- Saves logs locally and never uploads them to the deployment server.
- Requires a validated Windows source before destructive work begins.
- Must still function using the validated local image cache when internet access is unavailable.

### PXE Full Factory Rebuild

PXE Full Factory Rebuild is not a customer-side recovery mode. It re-enters the normal technician-controlled initial deployment workflow through PXE.

It may:

- Perform a fresh order lookup and technician review.
- Load current central configuration and deployment content.
- Erase the complete confirmed primary disk.
- Recreate and restage the OSDCloud Deployment Partition.
- Acquire the current Windows image through OSDCloud.
- Create a new validated `FactoryProfile.json`.
- Preserve prior local logs when possible, subject to retention limits.

If the platform cannot safely force the next PXE boot, the interface must instruct the technician to reboot and select PXE from the motherboard boot menu.

## Connectivity Boundaries

The word `standalone` refers to independence from the deployment server and deployment infrastructure. It does not mean that OSDCloud is forbidden from accessing Microsoft.

| Context | DeploymentShare and deployment server | Microsoft through OSDCloud | Local recovery cache |
| --- | --- | --- | --- |
| Initial Deployment | Allowed while technician controlled | Preferred for the current compatible image | Created and validated before installation continues |
| Factory Recovery after customer handoff | Prohibited | Allowed when internet access is available | Required fallback when Microsoft acquisition is unavailable |
| PXE Full Factory Rebuild | Allowed while technician controlled | Preferred for the current compatible image | Recreated and validated |

Once execution begins from the OSDCloud Deployment Partition, it must never probe, map, browse, authenticate to, retrieve content from, or upload data to `DeploymentShare`, `DeploymentLogs`, or another deployment server. The PXE bootstrap must pull and validate every required deployment-server resource before configuring the one-time boot and restarting into the partition. OSDCloud may still contact Microsoft directly for Windows image acquisition.

## Windows Image Acquisition and Cache

- Use a validated multi-index Windows 11 image containing both Home and Pro.
- Validate architecture, language, release compatibility, image integrity, and the exact Home and Pro indexes.
- During the first deployment, PXE stages the OSDCloud Deployment Partition and all required deployment-server resources before the Windows image is acquired.
- OSDCloud then obtains the latest compatible image directly from Microsoft when possible.
- Download into a temporary file on the OSDCloud Deployment Partition.
- Validate the temporary image before promotion.
- Atomically promote it to the permanent cache.
- Reopen and revalidate the promoted image before installation begins.
- Never erase Windows partitions unless a usable image source has already been validated.
- Before later recovery, check Microsoft for a newer compatible image when internet access is available.
- Retain the existing validated cache until the replacement has been fully validated and committed.
- If online acquisition is unavailable or fails, use the existing validated local cache.
- Do not silently substitute an edition or use an image missing either required index.

## Deployment Server Responsibilities

During Initial Deployment and PXE Full Factory Rebuild, the deployment server may provide:

- Central configuration.
- Workflow and controller files.
- Application packages.
- Driver libraries.
- OSDCloud Deployment Partition content and deployment bundle sources.
- Read-only MySQL order data access.
- A secondary destination for Initial Deployment logs.

The complete partition-side deployment and recovery subset must be staged and validated before the PXE environment reboots into the OSDCloud Deployment Partition. Initial deployment from the partition and later Factory Recovery must not depend on the server being reachable.

## Configuration Authority

- Initial Deployment and PXE Full Factory Rebuild load central configuration from `DeploymentShare`.
- Each setting has a hard-coded default and validated fallback behavior.
- After validation, save a versioned snapshot of the fully resolved effective configuration to the OSDCloud Deployment Partition.
- Factory Recovery uses only the saved snapshot and hard-coded safe fallbacks.
- Factory Recovery never checks central configuration for changes.
- Existing systems retain their saved behavior until a deliberate PXE Full Factory Rebuild refreshes it.
- Every run records the configuration source, version, effective values, and fallbacks.

Current defaults include:

| Setting | Default |
| --- | ---: |
| `RecoveryPartitionSizeMB` | 32768 |
| `LocalLogHistoryMaxMB` | 1024 |
| `RecommendedPrimaryDriveSizeMB` | 122070 |

## Workflow Profiles

### EZT

- Create the local administrator account `User` with no password.
- Enable automatic sign-in until the owner successfully sets a password through the managed graphical password workflow.
- After a successful password change, disable automatic sign-in and remove the stored automatic-logon credential.
- Install the approved applications, drivers, and settings.
- Prompt the technician for the Windows product key, with an option to finish without activation after a warning.
- End at the completed `User` desktop after final validation and handoff.
- Factory Recovery restores the original passwordless automatic-sign-in state.

### MMC

- Apply the approved deployment defaults and compliance settings.
- Do not create the EZT automatic-sign-in experience.
- End at Windows OOBE for the customer.

## Disk Safety

- Prefer the primary NVMe SSD. If no NVMe exists, include eligible internal SATA drives.
- Display disk number, model, serial number, interface, and capacity before erasure.
- Revalidate physical identity immediately before destructive work.
- Block normal destructive work while removable USB storage is present unless the approved emergency bypass is explicitly used.
- Initial Deployment and PXE Full Factory Rebuild perform a full-disk Deployment Erase on the confirmed primary target.
- Factory Recovery erases only the Windows-related area and preserves the OSDCloud Deployment Partition.
- Deployment Erase is not secure or forensic sanitization.
- A drive below the recommended capacity produces an acknowledged warning, not an automatic rejection, unless the requested layout is physically impossible.

## Secondary Drives

- Secondary-drive preparation is offered only during Initial Deployment.
- Skip Secondary Drives is the default.
- Every secondary drive begins unselected.
- Only explicitly selected drives may be erased and prepared.
- Selected drives use GPT, one full-size NTFS partition, and collision-safe `Data`, `Data-2`, and later labels.
- Initial Deployment assigns available letters beginning with `D:`.
- Drive-letter mappings are not saved or restored.
- Factory Recovery never writes to a secondary drive.
- A partially prepared drive that the technician skips remains offline for manual service.

## Logging

- The OSDCloud Deployment Partition is the authoritative log location for every run.
- Each run uses a separate timestamped folder.
- Initial Deployment may copy the verified local log to `\\Deployment\DeploymentLogs` as a secondary copy.
- A failed Initial Deployment server copy is a warning and does not invalidate the verified local log.
- Factory Recovery never contacts the server for logging.
- No background uploader, delayed service, or credential-retaining scheduled task is installed.
- Local retained log history defaults to 1024 MB and removes complete oldest run folders first when the limit is exceeded.
- The final summary cannot close until the final local log update has succeeded.

## Installed-Windows Orchestrator

- Stage the orchestrator under `C:\ProgramData\OSDeploy\Orchestrator` before first Windows boot.
- Register a single-instance startup Scheduled Task running as SYSTEM without requiring user sign-in.
- Store the authoritative atomic `DeploymentState.json` checkpoint on the OSDCloud Deployment Partition.
- Include run, machine, disk, workflow, edition, phase, attempt, reboot, configuration-version, and timestamp context.
- Make every phase idempotent and resume only the last incomplete phase.
- Never re-enter completed destructive disk work.
- Save `RebootPending` before a required restart and validate identity after return.
- Allow up to three automatic attempts per checkpoint. A fourth failure opens blocking Technician Review.
- Record completion only after required work, cleanup, final-log verification, and the correct EZT or MMC handoff succeed.
- After recorded completion, a later restart performs cleanup only.
- Cleanup failure blocks completion.

### Orchestrator Integrity

- Restrict the orchestrator directory to SYSTEM and local Administrators with NTFS permissions.
- Automatically calculate SHA-256 hashes after staging.
- Store the hashes with the authoritative deployment state on the OSDCloud Deployment Partition.
- Recheck the hashes before first execution and after a restart.
- This detects accidental corruption or incomplete staging. It is not protection against a local administrator replacing both the files and hashes.
- On validation failure, recopy only from the local recovery content and validate again.
- If the refreshed local copy still fails, stop at blocking Technician Review.
- Do not add signing certificates, pinned public keys, manually maintained release manifests, or a separate signing and release-management system.

## Windows Update Before Handoff

- Run Windows Update during technician staging when internet access is available.
- Include security, cumulative quality, servicing-stack, .NET, and Microsoft Defender updates.
- Exclude preview updates, optional updates, Store application updates, feature upgrades, optional drivers, firmware, and BIOS updates.
- Keep the dedicated driver workflow authoritative.
- Allow up to three configurable update, reboot, and rescan cycles, with three as the hard-coded default.
- Complete any successfully initiated required reboot before handoff.
- If updates remain or Windows Update is unavailable after the limit, record a warning, require technician acknowledgement, and allow completion.
- If the system cannot complete a required reboot or return to a healthy state, stop at Technician Review.
- Offline Factory Recovery skips Windows Update with a warning and remains eligible for completion.

## Resolved DeploymentShare Image Conflict

Questions 52 through 55 incorrectly retained a DeploymentShare emergency-image path. Question 91 corrects the record and formally supersedes those server-fallback portions.

- Question 74 says Factory Recovery stays local and never contacts the server for logging.
- Question 84 says Factory Recovery uses only saved local configuration and never checks the deployment server.
- Question 90 says that after customer handoff the local environment never contacts, probes, maps, authenticates to, or retrieves content from DeploymentShare or any deployment server.
- Question 91 establishes that the PXE WIM pulls and validates all required deployment-server resources before rebooting into the OSDCloud Deployment Partition.
- The OSDCloud Deployment Partition is the primary deployment environment as well as the later Factory Recovery environment.

Active rule: remove Use Deployment Server Emergency Image from Technician Options. Once running from the OSDCloud Deployment Partition, both InitialDeployment and FactoryRecovery are independent of the deployment server. This does not remove OSDCloud access to Microsoft or the validated local Windows image cache. PXE Full Factory Rebuild remains the technician-controlled service path when local deployment cannot proceed.

## Important Terminology

| Term | Meaning |
| --- | --- |
| OSDeploy boot image | Customized WinPE image built and published for PXE boot. |
| OSDCloud | Windows deployment engine used in the PXE bootstrap and the OSDCloud Deployment Partition. |
| OSDCloud Deployment Partition | Persistent, bootable, local OSDCloud environment that performs the primary deployment and later Factory Recovery. |
| PXE bootstrap | Initial OSDCloud WIM stage that performs technician review, configures and stages the OSDCloud Deployment Partition, sets its one-time boot, and reboots. It does not perform the main deployment. |
| Initial Deployment | Technician-controlled PXE factory build. |
| Factory Recovery | Customer-side or technician-invoked recovery run from the OSDCloud Deployment Partition that preserves the partition and never contacts the deployment server. |
| PXE Full Factory Rebuild | Technician-controlled full-disk rebuild that re-enters the PXE bootstrap and recreates the OSDCloud Deployment Partition. |
| Deployment Erase | Workflow disk preparation. It is not certified secure sanitization. |
| Factory profile | Saved EZT or MMC machine-specific recovery intent held in `FactoryProfile.json`. |
| Effective configuration | Fully resolved configuration after central values, validation, and hard-coded fallbacks are applied. |
| Authoritative local state | OSDCloud Deployment Partition copies of deployment state, configuration, profile, image cache, and logs that control deployment and recovery behavior. |

## Current Question State

- Questions 1 through 94 are recorded in the active Markdown Q&A file.
- Questions 88, 89, 90, 91, 92, 93, and 94 are confirmed, not pending.
- Question 91 supersedes the DeploymentShare emergency-image portions of Questions 52 through 55.
- OSDCloud Deployment Partition is the canonical term for the persistent partition that performs the primary deployment and later Factory Recovery.
- Question 92 establishes the automatic Deployment Partition Ready gate before PXE may configure the one-time boot.
- Question 93 establishes fail-closed handling when readiness or disk-identity revalidation fails after the partition boots.
- Current OSDCloud USB-media creation is an implementation reference for the partition's bootable-media design, not a directly reusable internal-disk layout.
- Question 94 separates the initial one-time partition boot from the validated persistent Factory Recovery entry while retaining Windows as the default.
- Question 95 is the next unanswered question.

## Working Files

- Active numbered Q&A: `OSDeploy_PXE_Workflow_Questions_and_Answers.md`
- Active architecture context: `OSDeploy_PXE_Workflow_Working_Context.md`
- Historical consolidated decision record: `OSDeploy_PXE_Workflow_Consolidated_Decision_Record.docx`

During the remaining interview, update the active Q&A and this context file independently. Export or revise the consolidated DOCX only when specifically requested.
