## ADDED Requirements

### Requirement: Disk inventory and presentation

The engine MUST present disk number, model, serial number, interface, and capacity for every candidate disk before any erasure, and MUST use the Windows disk number as the active-run target identifier (Q4).

#### Scenario: Candidate disks are fully described

- **WHEN** disk selection is shown to the technician
- **THEN** every candidate displays disk number, model, serial number, interface, and capacity

### Requirement: Primary-disk selection rules

The engine MUST prefer eligible internal NVMe drives, MUST auto-select a sole eligible NVMe while still displaying it before erasure, MUST require manual selection when several eligible NVMe drives exist, and MUST include eligible internal SATA candidates only when no NVMe exists (Q4).

#### Scenario: Sole NVMe auto-selects but is still shown

- **WHEN** exactly one eligible internal NVMe drive exists
- **THEN** it is auto-selected as the default target and displayed for confirmation before any erasure

#### Scenario: Multiple NVMe drives require selection

- **WHEN** more than one eligible NVMe drive exists
- **THEN** no target is auto-selected and the technician must choose one

#### Scenario: SATA included only without NVMe

- **WHEN** no eligible NVMe drive exists and eligible internal SATA drives do
- **THEN** the SATA drives appear as candidates

### Requirement: Removable storage blocks destructive work

All usable removable storage MUST block destructive work until removed, unless the approved Emergency Bypass is used. Ordinary non-storage USB peripherals MUST NOT block (Q5).

#### Scenario: Removable storage present

- **WHEN** usable removable USB storage is attached and destructive work is requested
- **THEN** the flow asks for removal, confirmation, and a fresh rescan instead of proceeding

#### Scenario: Emergency Bypass requirements

- **WHEN** the technician uses Emergency Bypass
- **THEN** a secondary warning, acknowledgement checkbox, Yes-or-Cancel confirmation, and target-disk revalidation are all required, an audit event is recorded, and no reason dropdown is presented (Q6)

#### Scenario: Non-storage peripherals do not block

- **WHEN** only non-storage USB peripherals (keyboard, mouse) are attached
- **THEN** destructive work is not blocked

### Requirement: Identity revalidation at time of use

Physical disk identity MUST be revalidated immediately before destructive work on the confirmed target (Q4, Q12).

#### Scenario: Changed identity stops destructive work

- **WHEN** the selected disk's identity no longer matches at the moment destructive work begins
- **THEN** the destructive work does not proceed

### Requirement: Deployment Erase scope by run type

Deployment Erase MUST remove or format only the area permitted by the run type: full-disk erase of the confirmed primary target for InitialDeployment and PXE Full Factory Rebuild, the Windows-related target area only for FactoryRecovery, and the confirmed GPT quick-format process for explicitly selected secondary drives. Warnings MUST NOT claim forensic or certified secure data destruction (Q85).

#### Scenario: Recovery erases only the Windows-related area

- **WHEN** FactoryRecovery performs Deployment Erase
- **THEN** only the Windows-related target area is erased and the OSDCloud Deployment Partition is preserved

#### Scenario: Warnings do not overstate erasure

- **WHEN** any erasure warning text is generated
- **THEN** it does not describe the operation as secure, forensic, or certified sanitization

### Requirement: Secondary-drive preparation

Secondary-drive preparation MUST be offered only during InitialDeployment with Skip Secondary Drives as the default, every drive beginning unselected, and only explicitly selected drives prepared as GPT with one full-size NTFS partition, automatic letters from D:, and collision-safe Data/Data-2/Data-3 labels. Drive-letter mappings MUST NOT be saved or restored (Q58–Q61).

#### Scenario: Skip is the default

- **WHEN** the secondary-drive screen appears
- **THEN** no drive is selected and the default action is Skip Secondary Drives

#### Scenario: Selected drives get the standard layout

- **WHEN** the technician selects secondary drives and confirms
- **THEN** each is prepared as GPT with one full-size NTFS partition, assigned the next available letter from D:, and labeled Data/Data-2/Data-3 without collisions

#### Scenario: Retry or skip on failure

- **WHEN** a secondary drive fails preparation
- **THEN** the technician may Retry Secondary Drive (revalidating identity and restarting only that drive) or Skip Failed Drive and Continue, and primary deployment is not blocked (Q63, Q64)

#### Scenario: Skipped partial drive stays offline

- **WHEN** a partially modified drive is skipped
- **THEN** it remains offline and is noted for manual service, in installed Windows and during recovery (Q65, Q66)

#### Scenario: Mount verification only

- **WHEN** Windows has assigned letters to recognized secondary volumes
- **THEN** the engine only verifies the volumes mount and warns if not; it does not fail, repair, relabel, compare inventory, or restore letters (Q62)

### Requirement: Undersized primary-drive warning

A primary drive below `RecommendedPrimaryDriveSizeMB` MUST produce a warning whose continuation requires an explicit capacity-risk acknowledgement, and only physically impossible layouts MUST be blocked outright. The warning and override MUST NOT receive special logging beyond normal drive-size records (Q79–Q82).

#### Scenario: Acknowledgement gates Continue Anyway

- **WHEN** the confirmed primary drive is smaller than the recommended size
- **THEN** Continue Anyway is disabled until the technician checks the capacity-risk acknowledgement

#### Scenario: Impossible layout is blocked

- **WHEN** the requested layout cannot physically fit the drive
- **THEN** the deployment is blocked regardless of acknowledgement
