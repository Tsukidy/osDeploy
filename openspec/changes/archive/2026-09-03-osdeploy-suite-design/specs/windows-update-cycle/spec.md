## ADDED Requirements

### Requirement: Scoped update selection

Windows Update MUST install only security, cumulative quality, servicing-stack, .NET, and Microsoft Defender updates, and MUST exclude preview updates, optional updates, Store application updates, feature upgrades, optional drivers, firmware, and BIOS updates. The dedicated driver workflow remains authoritative for drivers (Q88).

#### Scenario: Excluded categories are not installed

- **WHEN** an update scan offers preview, optional, Store, feature-upgrade, driver, firmware, or BIOS updates
- **THEN** none of them is installed by the Windows Update phase

### Requirement: Configurable update cycles

The phase MUST allow up to three configurable update, reboot, and rescan cycles, with three as the hard-coded default, sourced from the effective configuration (Q88).

#### Scenario: Configured limit is honored

- **WHEN** the effective configuration sets `MaxCycles` to 2
- **THEN** at most two update, reboot, and rescan cycles run

### Requirement: Required reboots complete before handoff

Any successfully initiated required reboot MUST be completed before final handoff, and if the machine cannot complete a required reboot or return to a healthy state, the run MUST stop at Technician Review (Q88).

#### Scenario: Unhealthy state stops for review

- **WHEN** the system cannot complete a required reboot or return to a healthy state after an update cycle
- **THEN** the run stops at Technician Review

### Requirement: Remaining updates warn and acknowledge

If Windows Update is unavailable or updates remain after the retry limit, the run MUST record a warning, require technician acknowledgement, and allow completion (Q88).

#### Scenario: Updates remain after the limit

- **WHEN** the cycle limit is reached with updates still pending
- **THEN** a warning with acknowledgement is required and completion remains allowed

### Requirement: Offline recovery skips with a warning

Offline Factory Recovery MUST skip Windows Update with a recorded warning and MUST remain eligible for completion (Q88).

#### Scenario: Offline recovery completes without updates

- **WHEN** Factory Recovery runs without internet access
- **THEN** Windows Update is skipped, the warning is recorded, and the run can still complete
