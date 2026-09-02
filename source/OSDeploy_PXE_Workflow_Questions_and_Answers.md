# OSDeploy PXE Workflow

## Questions and Answers

## Decision Precedence

**Later confirmed questions supersede conflicting parts of earlier questions. When two recorded answers conflict, the higher-numbered confirmed answer controls unless an even later answer explicitly changes it. Earlier answers remain in this file for decision history but must not be implemented where a later answer has replaced them.**

Questions 1 through 94.

## Question 1

**Question:** How should an initial PXE deployment proceed from order lookup through final handoff?

**Answer:** The technician PXE-boots into OSDCloud, enters the order number, receives MySQL-derived company and Home/Pro defaults, clears removable-media checks, deploys to the primary internal drive, and continues with minimal interaction through the required Windows and post-install endpoint.

## Question 2

**Question:** Can technicians correct order-derived workflow and Windows-edition defaults?

**Answer:** Order data supplies editable defaults. Technicians may correct the workflow/company and Windows edition for the current run; missing required values use a graphical manual selector.

## Question 3

**Question:** May technician corrections be written back to the order database?

**Answer:** MySQL access is strictly read-only. Technician corrections affect only the active deployment and are never written back to the order database.

## Question 4

**Question:** How should the primary deployment disk be selected and revalidated?

**Answer:** Use the Windows disk number as the active-run target identifier. Auto-select a sole eligible NVMe but show it before erasure; require selection when several exist; include internal SATA candidates when no NVMe exists; revalidate identity immediately before destructive work.

## Question 5

**Question:** How should removable storage affect destructive deployment work?

**Answer:** All usable removable storage blocks destructive work unless Emergency Bypass is deliberately used. The normal GUI asks for removal, confirmation, and a fresh rescan; ordinary nonstorage USB peripherals do not block.

## Question 6

**Question:** What safeguards are required for Emergency Bypass?

**Answer:** Emergency Bypass requires a secondary warning, acknowledgement checkbox, Yes-or-Cancel confirmation, target-disk revalidation, and an audit event. Do not require a reason dropdown.

## Question 7

**Question:** Should technicians sign in or be personally identified in deployment records?

**Answer:** Do not require technician sign-in or personal attribution. Use the fixed actor value technician while retaining order, machine, run, time, and decision context separately.

## Question 8

**Question:** What must be checked before erasure, and which log copy is authoritative?

**Answer:** Initial PXE deployment preflights DeploymentShare and DeploymentLogs before erasure and creates collision-safe timestamped run folders. Later logging decisions make the verified local recovery-partition log authoritative and a failed server copy nonblocking.

## Question 9

**Question:** What should happen when the MySQL order lookup fails?

**Answer:** If MySQL lookup fails while required deployment content remains available, offer Retry Order Lookup, Select Workflow Manually, or Cancel Deployment. Manual selection chooses EZT or MMC and Home or Pro through the GUI.

## Question 10

**Question:** What are the controlled workflow identities, and how is Windows edition represented?

**Answer:** The controlled workflow identities are exactly EZT and MMC; Home or Pro remains a separate runtime selection. The adapter and workflow schema must be validated against the pinned installed OSDeploy/OSDCloud version.

## Question 11

**Question:** How should order-company names map to EZT or MMC?

**Answer:** Trim and compare company names case-insensitively: exact EZT or EZ Trading Computers maps to EZT, every other named company maps to MMC, and a missing value requires manual selection. The technician may override the default.

## Question 12

**Question:** What must the final pre-erasure confirmation contain?

**Answer:** Before erasure, show a final GUI summary with OK and CANCEL only, revalidate the selected disk at time of use, and durably record the confirmed effective selections.

## Question 13

**Question:** Should deployment automate the Windows computer name?

**Answer:** Do not automate computer naming. Leave the Windows-generated default name unchanged and record the observed name only as an output value.

## Question 14

**Question:** What are the required final endpoints for MMC and EZT?

**Answer:** MMC completes at Windows OOBE with mostly default customer-facing setup. EZT completes its User account, settings, applications, product-key, and state-dependent work and reaches the configured desktop.

## Question 15

**Question:** What local account and password shortcut should EZT create?

**Answer:** EZT creates the local account User as a passwordless local administrator and adds a public desktop shortcut named Set or Change Your Password. The shortcut launches the managed graphical password transition confirmed by Question 86 rather than opening Windows Sign-in options directly. MMC does not create this account.

## Question 16

**Question:** How long should automatic sign-in remain enabled for the EZT User account?

**Answer:** The final EZT design uses persistent automatic sign-in for the passwordless User account. It is not limited to a deployment-time logon count, but it ends when the owner successfully sets a password through the managed workflow. The earlier temporary-autologon/normal-sign-in answer is superseded.

## Question 17

**Question:** What should Local Factory Recovery restore and warn the user about?

**Answer:** Local Factory Recovery restores the profile-specific factory configuration originally supplied for MMC or EZT. It uses two-stage destructive confirmation and clearly states that user files, accounts, applications, and settings will be erased.

## Question 18

**Question:** How should Windows activation and product-key entry be handled?

**Answer:** Attempt normal digital-license or firmware-key activation first. When technician input is needed, show the illustrated Windows 11 product-key dialog and sticker-location guidance; never store or log a product key.

## Question 19

**Question:** What should happen when activation cannot be completed?

**Answer:** If activation cannot be completed, EZT offers Retry Activation, Finish Without Activation, or Cancel. Finishing without activation requires a warning and records the incomplete activation state without storing the key.

## Question 20

**Question:** Can the technician override the detected Energy Star requirement?

**Answer:** The Energy Star decision remains technician-overridable in case the detected requirement is wrong. Apply is the default for matched states; Do Not Apply requires a warning; the effective choice is cached for the machine.

## Question 21

**Question:** How should Factory Recovery handle the saved power-policy decision?

**Answer:** Factory Recovery reapplies the saved Energy Star/power-policy decision from the local factory profile. It asks again only when the saved decision is missing or invalid.

## Question 22

**Question:** Which power behavior applies to California MMC, California EZT, and non-California systems?

**Answer:** California MMC receives Energy Star settings without the persistent choice popup. California EZT receives Energy Star settings and the persistent popup; non-California systems use High Performance with display sleep after 60 minutes and system sleep disabled.

## Question 23

**Question:** When should the regulated-state list be evaluated and persisted?

**Answer:** Evaluate the configurable regulated-state list only at deployment time. Save the resulting policy in FactoryProfile.json; later server-side list changes affect new deployments only, and deployed systems never phone home for state policy.

## Question 24

**Question:** What exact desktop and account state should EZT deliver?

**Answer:** EZT is delivered at the completed User desktop with persistent passwordless automatic sign-in; built-in Administrator remains disabled. Automatic sign-in continues until the owner successfully sets a password through the managed workflow. Applicable persistent power-choice behavior appears on that desktop. The earlier normal-sign-in assumption is superseded.

## Question 25

**Question:** How should applications be selected and included in recovery content?

**Answer:** Application selection is fixed by the chosen EZT or MMC workflow rather than chosen application-by-application. Include the resolved manifest/installers in local recovery content and keep execution as close to zero-touch as possible after review and confirmation.

## Question 26

**Question:** What should happen when an application installation fails?

**Answer:** Application failures retry according to the manifest, then show an Acknowledge and Continue modal with program, status, error or exit code, and log location. Deployment continues as Completed with Warnings and retains the failure for final review.

## Question 27

**Question:** What should happen when a driver installation fails?

**Answer:** Driver failures do not automatically kill the Windows deployment. Report failed drivers clearly, preserve diagnostics, and route unresolved or functionally important failures to Technician Review before the final handoff.

## Question 28

**Question:** What final Plug and Play validation is required?

**Answer:** Run final Plug and Play validation, rescan current devices, and report unknown, missing, incompatible, problem-code, or unhealthy devices in one acknowledged warning. Unresolved findings remain in the final summary and warning result.

## Question 29

**Question:** What actions should Technician Review provide before final handoff?

**Answer:** Provide Technician Review after applications, drivers, and validation. Allow manual remediation plus Rescan Devices or Rerun Validation before EZT's final reboot or MMC's return to OOBE; preserve resolved and unresolved findings in the logs.

## Question 30

**Question:** How should MMC use Audit Mode and return to OOBE?

**Answer:** Use Audit Mode as the MMC technician staging environment, then Finalize and Return to OOBE removes temporary deployment artifacts and runs Sysprep. The successful final endpoint remains powered-on OOBE rather than Audit Mode.

## Question 31

**Question:** Should a successful deployment finish powered on or shut down?

**Answer:** Successful deployments finish powered on so the technician can visually verify the result: MMC at OOBE and EZT at the completed User desktop. Do not automatically shut down a successful system.

## Question 32

**Question:** When is MMC considered complete, and what happens if Sysprep fails?

**Answer:** MMC is recorded complete when cleanup has succeeded and Sysprep successfully initiates the reboot into OOBE. If Sysprep fails, remain in Audit Mode with a blocking technician error; run no cleanup after entering OOBE.

## Question 33

**Question:** When is EZT considered complete?

**Answer:** EZT completes all work, validation, logging, and cleanup before its final handoff. Record completion when the final reboot to the configured User desktop successfully begins; warnings retain the warning result.

## Question 34

**Question:** What happens if EZT cannot initiate its final reboot?

**Answer:** If EZT cannot initiate its final reboot, do not mark it complete. Keep it powered on at Technician Review with failure details and allow Retry Final Handoff or return to review.

## Question 35

**Question:** How should deployment recover from a restart or power loss?

**Answer:** Use persistent checkpoints for EZT and MMC. Automatically resume from the last incomplete stage after restart or power loss, do not repeat completed destructive work, restore the active configuration/log context, and escalate unsafe state to Technician Review.

## Question 36

**Question:** How many automatic resume attempts are allowed at a failed checkpoint?

**Answer:** Allow up to three automatic resume attempts per checkpoint. A fourth failure stops automation and opens blocking Technician Review with stage history, errors, logs, manual retry, and safe-checkpoint rollback options.

## Question 37

**Question:** How should PXE staging and the local recovery environment divide deployment responsibilities?

**Answer:** Adopt the staged local-recovery architecture: PXE performs order lookup, review, recovery-partition provisioning, bundle staging/validation, and a one-time boot; the local recovery environment runs the shared EZT/MMC deployment engine and future Factory Recovery.

## Question 38

**Question:** What became of the original 16 GB recovery-partition design?

**Answer:** The original 16 GB, no-Windows-image recovery partition was replaced after offline image caching became required. The active default is the configurable 32768 MB partition established by later decisions.

## Question 39

**Question:** Must Factory Recovery always be online, or may it use a cached image?

**Answer:** The initial always-online recovery rule was replaced by online-first image acquisition with a validated local cached-image fallback. Confirm connectivity before any attempted online acquisition and never erase without a usable validated source.

## Question 40

**Question:** How should Ethernet, Wi-Fi, and Windows-image source fallback work?

**Answer:** Prefer Ethernet but support Wi-Fi using drivers in each motherboard's normal DeploymentShare driver folder. Try online acquisition first, then allow the validated cached Microsoft image; validate source, edition, and integrity before erasure.

## Question 41

**Question:** What is the recovery-partition size baseline?

**Answer:** Increase the recovery-partition design to a 32 GB baseline so it can hold the validated Windows cache and required recovery payload. Later configuration decisions express the default as RecoveryPartitionSizeMB = 32768.

## Question 42

**Question:** How should users and technicians enter Factory Recovery?

**Answer:** Create a persistent Factory Recovery entry in Windows Boot Manager with Windows as the default and a five-second timeout, plus an in-Windows shortcut. One-time deployment boots do not change the persistent default; merely entering recovery is non-destructive.

## Question 43

**Question:** Does Factory Recovery require a PIN or password?

**Answer:** Factory Recovery is end-user accessible without a PIN or password. Clearly explain data-loss consequences and retain the separate destructive confirmations before erasure.

## Question 44

**Question:** May Factory Recovery change the saved workflow or Windows edition?

**Answer:** Factory Recovery cannot change the saved EZT/MMC workflow. It normally uses the saved edition, but Change Windows Edition may select supported Windows 11 Home or Pro with an activation warning; workflow, applications, settings, and accounts remain unchanged.

## Question 45

**Question:** When does a technician-selected recovery edition become the future default?

**Answer:** After a successful recovery handoff, a technician-selected Home/Pro edition becomes the default for future recovery while retaining the original factory edition and change history. A failed recovery does not replace the prior default.

## Question 46

**Question:** What happens when the requested Windows edition is unavailable in the selected image?

**Answer:** Validate the cached or online image before erasure. If the requested edition is unavailable, never substitute silently; offer Choose Another Edition, Use Saved Default Edition, or Cancel Recovery.

## Question 47

**Question:** What Windows-image structure and index validation are required?

**Answer:** Use one validated multi-index Windows 11 image containing both Home and Pro. Reject it if either index is missing or architecture, language, release, or build compatibility is inconsistent; record exact index names and numbers.

## Question 48

**Question:** How should the locally cached Windows image be refreshed?

**Answer:** Before destructive work, check for a newer compatible Microsoft image. Download and validate it when available, retain the current cache until validation succeeds, then promote and use the replacement without erasing during an incomplete update.

## Question 49

**Question:** How should the first technician deployment acquire and retain a Windows image?

**Answer:** The technician's first deployment should obtain the latest compatible image from Microsoft through OSDCloud when possible, use it, and retain it locally for later recovery. A validated cached-image fallback is allowed when a later update fails.

## Question 50

**Question:** Where does the first local-recovery boot obtain its initial Windows image?

**Answer:** The first local-recovery boot has no cached image. PXE stages the recovery environment, then OSDCloud downloads and validates the current Home/Pro image from Microsoft, installs from it, and retains it; do not default to an older deployment-server image.

## Question 51

**Question:** How should a downloaded Windows image be validated and promoted into the permanent cache?

**Answer:** Download into a temporary recovery-partition file, validate hash, integrity, architecture, language, release, and both indexes, then atomically promote it to the permanent cache. Install only from the promoted cache and remove invalid temporary content.

## Question 52

**Question:** What happens if the permanent image-cache commit cannot be validated?

**Answer:** Initial deployment cannot proceed until the permanent cache commit is reopened and revalidated. Offer Retry Cache Commit, Redownload Image, or Cancel; do not provide Continue Anyway. The later emergency-server fallback remains a separate deliberate path.

## Question 53

**Question:** Which image sources may future Factory Recovery use, including emergency fallback?

**Answer:** For future recovery, use the validated cache and then Microsoft. If both fail and the deployment share is deliberately made available, offer Use Deployment Server Emergency Image, warn that it may be older, and fully stage, validate, commit, reopen, and revalidate it before erasure.

## Question 54

**Question:** When may Factory Recovery access DeploymentShare, and how are credentials handled?

**Answer:** Ordinary Factory Recovery never probes, maps, browses, or authenticates to DeploymentShare. Only explicit emergency-image selection opens a GUI credential prompt; credentials are read-only, session-only, never stored, and disconnected after use.

## Question 55

**Question:** Which service functions belong in Technician Options?

**Answer:** Technician Options contains Use Deployment Server Emergency Image and Full Factory Rebuild. Ordinary recovery preserves the recovery partition; Full Factory Rebuild performs a full-disk Deployment Erase and recreates it.

## Question 56

**Question:** How may a technician start PXE Full Factory Rebuild?

**Answer:** Full Factory Rebuild is PXE-only. If the platform cannot force the next PXE boot safely, do not provide a misleading local rebuild button; instruct the technician to reboot and choose PXE through the motherboard boot menu.

## Question 57

**Question:** Is PXE Full Factory Rebuild a separate workflow or a fresh initial deployment?

**Answer:** PXE Full Factory Rebuild is an entry into the normal first-deployment workflow, not a separate maintenance workflow. Perform fresh order lookup/review, full-disk preparation, recovery provisioning, current payload staging, Microsoft image acquisition, deployment, and a new FactoryProfile.json.

## Question 58

**Question:** How should primary and secondary internal drives be handled by each run type?

**Answer:** During InitialDeployment or Full Factory Rebuild, inventory all internal drives, require exactly one confirmed primary target, and separately offer optional per-drive secondary preparation with Skip Secondary Drives as the default. Factory Recovery never modifies secondary drives.

## Question 59

**Question:** How should selected secondary drives be partitioned, formatted, and labeled?

**Answer:** Selected secondary drives use GPT, one full-size NTFS partition, automatic letters, and collision-safe Data, Data-2, Data-3 labels.

## Question 60

**Question:** How should drive letters be assigned to secondary volumes?

**Answer:** Initial deployment assigns letters beginning with D:. Do not save or restore mappings; recovery leaves secondary drives untouched.

## Question 61

**Question:** Should deployment restore secondary-drive letters when collisions occur?

**Answer:** Drive-letter collision restoration was unnecessary bloat.

## Question 62

**Question:** What verification is allowed for recognized secondary volumes after Windows assigns letters?

**Answer:** Only verify recognized secondary volumes mount after letters are assigned. Warn if not; do not fail, repair, relabel, compare inventory, or restore letters.

## Question 63

**Question:** What options are offered when secondary-drive preparation fails?

**Answer:** On secondary-preparation failure, offer Retry Secondary Drive or Skip Failed Drive and Continue. Primary deployment is nonblocking.

## Question 64

**Question:** What exactly happens when a technician retries secondary-drive preparation?

**Answer:** Retry revalidates physical identity and restarts only that selected drive from the beginning.

## Question 65

**Question:** What happens when a partially modified secondary drive is skipped?

**Answer:** Skipping a partially modified drive leaves it offline and clearly noted for manual service.

## Question 66

**Question:** Should a failed secondary drive remain offline after Windows starts and during recovery?

**Answer:** Preserve the failed secondary disk's offline state in installed Windows and during recovery.

## Question 67

**Question:** Which deployment result should be used when warnings remain?

**Answer:** Use Completed with Warnings, but do not add a delivery-readiness state.

## Question 68

**Question:** How should noted issues affect the final summary and delivery decision?

**Answer:** List noted issues in the final summary and use a technician acknowledgement rather than automated delivery validation.

## Question 69

**Question:** How many acknowledgements are required for the noted-issues list?

**Answer:** One acknowledgement covers the complete noted-issues list.

## Question 70

**Question:** When should the noted-issues acknowledgement be displayed?

**Answer:** Show and require acknowledgement only when noted issues exist.

## Question 71

**Question:** Which result represents warnings that the technician addressed?

**Answer:** Use the distinct result Completed with Tech-Addressed Warnings after acknowledgement is finalized.

## Question 72

**Question:** When may the result change to Completed with Tech-Addressed Warnings?

**Answer:** Change the result only when the checked acknowledgement is submitted with Finish Deployment.

## Question 73

**Question:** May the final summary close before the final local log update succeeds?

**Answer:** Do not close the summary until the final local log update succeeds; preserve acknowledgement during retries.

## Question 74

**Question:** Which log copy is authoritative, and when may a server copy be attempted?

**Answer:** Save and verify locally first. InitialDeployment may copy to the server; FactoryRecovery stays local and never contacts the server.

## Question 75

**Question:** Should failed server-log uploads retry automatically after deployment?

**Answer:** No automatic post-install retry or background uploader. Retry only in the active initial-deployment workflow.

## Question 76

**Question:** How should logs be organized on the recovery partition?

**Answer:** The recovery partition is the authoritative local log store with a separate timestamped folder for every run.

## Question 77

**Question:** How should PXE Full Factory Rebuild preserve and prune prior logs?

**Answer:** Preserve old logs during Full Factory Rebuild when possible, with an oldest-first hard retention limit.

## Question 78

**Question:** What are the default log-history and recovery-partition sizes, and in what units are they configured?

**Answer:** Default log history is 1024 MB; recovery partition is 32768 MB; both are configurable in whole binary MB.

## Question 79

**Question:** How much capacity modeling is required before image download and erasure?

**Answer:** Remove granular pre-download capacity modeling. Use a simple warning below the recommended drive size and block only impossible layouts.

## Question 80

**Question:** What acknowledgement is required to continue with an undersized primary drive?

**Answer:** Undersized-drive continuation requires I understand the capacity risk before Continue Anyway is enabled.

## Question 81

**Question:** Should the undersized-drive warning or override receive special logging?

**Answer:** Do not specially log the capacity warning or override; log drive size normally.

## Question 82

**Question:** What is the configurable recommended primary-drive size?

**Answer:** RecommendedPrimaryDriveSizeMB is configurable and defaults to 122070 MB.

## Question 83

**Question:** What fallback rule applies to every configurable value?

**Answer:** Every configurable value has a hard-coded default and validated fallback behavior.

## Question 84

**Question:** Where does each run type obtain configuration, and how is effective configuration preserved?

**Answer:** InitialDeployment and PXE Full Factory Rebuild load central configuration from DeploymentShare, use per-setting hard-coded defaults for missing or invalid values, and save a versioned snapshot of the fully resolved effective configuration locally. FactoryRecovery uses only that saved snapshot and hard-coded safe fallbacks, never central configuration. Each run logs the source, version, effective values, and fallbacks; existing systems retain their saved behavior until a PXE Full Factory Rebuild deliberately refreshes it.

## Question 85

**Question:** What does Deployment Erase mean, and how does its scope differ by run type?

**Answer:** Use Deployment Erase for normal deployment and recovery preparation. It removes and recreates or formats only the area permitted by the run type and is not certified secure data sanitization. InitialDeployment and PXE Full Factory Rebuild erase the complete confirmed primary target; FactoryRecovery erases only the Windows-related target area and preserves the recovery environment; explicitly selected secondary drives use the confirmed GPT and quick-format process. Full overwrites and hardware sanitize or secure-erase commands are outside this project, and warnings must not claim forensic data destruction.

## Question 86

**Question:** How should setting an EZT password interact with persistent automatic sign-in?

**Answer:** The factory EZT state remains passwordless with persistent automatic sign-in until the owner uses the managed graphical password workflow. The workflow warns that a successful password change disables automatic sign-in, then changes the password, disables automatic sign-in, and clears the stored automatic-logon credential as one controlled transition. Cancellation or failure leaves both states unchanged. Later password changes use Windows Sign-in options; password-protected automatic sign-in is unsupported. Factory Recovery restores the original passwordless automatic-sign-in state.

## Question 87

**Question:** What should Factory Recovery do when FactoryProfile.json is invalid or unavailable?

**Answer:** Treat FactoryProfile.json as recovery-critical and validate its schema, required fields, machine identity, and integrity before destructive confirmation. Maintain an active copy and a last-known-good local backup through atomic updates. If the active copy fails and the backup is valid, restore it, warn, and continue. If neither copy is valid, stop before Deployment Erase without guessing the workflow, using a hard-coded profile, or allowing manual workflow selection. Offer Retry Profile Validation, Technician Diagnostic Details, and Exit to PXE Full Factory Rebuild. Emergency Windows-image selection cannot bypass this stop. Only noncritical fields may use documented field-specific fallbacks; required profile-identity fields have no fallback. A full rebuild performs a fresh order lookup and creates a new profile.

## Question 88

**Question:** What Windows Update scope, retry limit, and failure behavior should apply before final handoff?

**Answer:** Run Windows Update during technician staging whenever internet access is available. Install security, cumulative quality, servicing-stack, .NET, and Microsoft Defender updates. Exclude preview updates, optional updates, Store application updates, feature upgrades, optional drivers, firmware, and BIOS updates. Keep the dedicated driver workflow authoritative. Allow up to three configurable update, reboot, and rescan cycles, with three as the hard-coded default. Complete any successfully initiated required reboot before handoff. If Windows Update is unavailable or updates remain after the retry limit, record a warning, require technician acknowledgement, and allow completion. If the machine cannot complete a required reboot or return to a healthy state, stop at Technician Review. Offline Factory Recovery skips Windows Update with a recorded warning and remains eligible for completion.

## Question 89

**Question:** How should the installed-Windows orchestrator persist, resume, reboot, and clean up across first boot?

**Answer:** Before first Windows boot, stage the orchestrator under C:\ProgramData\OSDeploy\Orchestrator and register a single-instance startup Scheduled Task running as SYSTEM without requiring user sign-in. Keep the authoritative atomic DeploymentState.json checkpoint on the recovery partition with the run, machine, disk, workflow, edition, phase, attempt, reboot, configuration-version, and timestamp context. Every phase is idempotent; resume only the last incomplete phase and never re-enter destructive disk work. Save RebootPending before restarts and validate identity on return. Apply the existing three-attempt limit, with a fourth failure opening blocking Technician Review. Record completion only after work, cleanup, final-log verification, and the correct EZT or MMC handoff succeed. Cleanup removes the task and deployment-only artifacts but retains recovery content, factory configuration, and logs. A restart after recorded completion runs cleanup only; cleanup failure blocks completion.

## Question 90

**Question:** What minimum protection should apply to the installed-Windows orchestrator without introducing a code-signing or release-management system?

**Answer:** Do not implement digital signatures, signing certificates, pinned public keys, or manually maintained release manifests. Stage the orchestrator into C:\ProgramData\OSDeploy\Orchestrator and restrict the directory to SYSTEM and local Administrators using NTFS permissions. Automatically calculate SHA-256 hashes after staging and store them with the authoritative deployment state on the recovery partition. Recheck the hashes before first execution and after a restart. This validation detects accidental corruption or incomplete staging; it is not intended to prevent a local administrator from replacing both the files and hashes. If validation fails, recopy the orchestrator only from the local recovery content and validate it again. After customer handoff, the recovery environment is fully standalone and never contacts, probes, maps, authenticates to, or retrieves content from DeploymentShare or any deployment server. All recovery-side repair sources must be staged locally before handoff. If the refreshed local copy also fails, stop at blocking Technician Review. Record validation and refresh results in the authoritative local log. The automatically calculated complete bundle hash identifies the exact staged copy without manual version maintenance.

## Question 91

**Question:** After customer handoff, what image-source order and failure behavior should Factory Recovery use, what happens to the previously recorded DeploymentShare emergency-image option, and how should the persistent local partition's deployment role be described?

**Answer:** Correct the earlier record and supersede the DeploymentShare emergency-image portions of Questions 52 through 55. The initial PXE-booted OSDCloud WIM is only the bootstrap and configuration stage. It performs the technician review, creates and configures the persistent OSDCloud Deployment Partition, pulls and validates every deployment-server resource that the partition will require, configures a one-time boot to the partition, and reboots. Once execution begins from the OSDCloud Deployment Partition, that partition is the primary deployment environment for both InitialDeployment and future FactoryRecovery. It must never contact, probe, map, browse, authenticate to, or retrieve content from DeploymentShare or any deployment server. Its local OSDCloud instance checks Microsoft directly for a newer compatible multi-index Home/Pro image when internet access is available, fully validates and commits any replacement, and otherwise uses the existing validated local cache. If neither Microsoft nor the local cache provides a validated image for the requested edition, stop before Deployment Erase and offer the established edition-resolution or cancellation choices. Remove Use Deployment Server Emergency Image from Technician Options. PXE Full Factory Rebuild remains the technician-controlled service path when the local deployment cannot proceed. Use OSDCloud Deployment Partition as the canonical term because the partition performs the primary deployment as well as Factory Recovery; do not describe it only as a recovery environment.

## Question 92

**Question:** What readiness validation must the PXE bootstrap complete before rebooting into the OSDCloud Deployment Partition?

**Answer:** Require one automatic Deployment Partition Ready gate. Before configuring the one-time boot, PXE must verify that the partition is bootable and associated with the confirmed primary disk; the deployment engine, selected EZT or MMC workflow, resolved configuration, factory profile, applications, required drivers, orchestrator repair source, and logging components are present; every staged file passes the automatically generated size and SHA-256 inventory; required network drivers are available so local OSDCloud can contact Microsoft when needed; deployment-state and logging locations are writable; and sufficient partition space remains for Microsoft image acquisition and the permanent cache. After validation, atomically write `DeploymentPartitionReady.json` with the run, machine, disk, workflow, edition, configuration version, generated bundle hash, and timestamp. This is an automatically generated staging record, not a manually maintained release manifest. Only then may PXE configure the one-time boot and restart. If validation fails, remain in PXE and offer Retry Staging or Cancel Deployment. When the partition boots, it must revalidate the readiness record and disk identity before continuing, without reconnecting to the deployment server.

## Question 93

**Question:** What should happen if the OSDCloud Deployment Partition fails readiness or disk-identity revalidation after PXE has rebooted into it?

**Answer:** Always stop before Windows installation, Deployment Erase, or any other destructive work, and do not offer Ignore or Continue Anyway. During InitialDeployment, show a blocking technician screen with Retry Local Validation, View Diagnostic Details and Logs, and Reboot to PXE for Restaging. If automatic PXE selection cannot be configured safely, instruct the technician to use the motherboard boot menu. During FactoryRecovery, preserve the existing Windows installation and offer Retry Local Validation, View Diagnostic Details and Logs, and Cancel Recovery and Boot Windows. If Windows is not bootable, direct the technician to PXE Full Factory Rebuild. The OSDCloud Deployment Partition must not reconnect to DeploymentShare to repair or restage itself. Any server-assisted restaging must begin through a fresh technician-controlled PXE boot.

## Question 94

**Question:** How should boot-entry behavior distinguish the initial one-time deployment boot from the permanent Factory Recovery option?

**Answer:** After the Deployment Partition Ready gate succeeds, the PXE bootstrap creates a one-time boot into the OSDCloud Deployment Partition without permanently making the partition the default boot target. During primary deployment, the partition may restart into itself as required by its deployment checkpoints. After Windows is installed and validated, register the persistent Factory Recovery entry while keeping Windows as the default boot target with the confirmed five-second menu timeout. Do not consider the persistent entry successfully installed until its partition identity and boot files have been validated. After successful deployment, clear every remaining initial-deployment-only boot override. Failure to register or validate the persistent Factory Recovery entry blocks final completion at Technician Review. Select the exact supported mechanism, such as UEFI BootNext, BCD bootsequence, or another method, during implementation testing against the current OSDCloud media layout and target motherboard firmware.
