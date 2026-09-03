## ADDED Requirements

### Requirement: Pattern-matched installer discovery

Driver installation MUST NOT use driver manifests. The engine MUST discover installers by pattern matching the standardized naming manufacturers already use — for example ASUS driver folders containing `AsusSetup.exe` and Gigabyte driver folders containing a single installer executable — recursively across the staged driver folders (Q96).

#### Scenario: ASUS pattern matches

- **WHEN** a staged driver tree contains ASUS folders with `AsusSetup.exe`
- **THEN** the engine selects those installers for silent installation

#### Scenario: Gigabyte pattern matches

- **WHEN** a staged driver folder for a Gigabyte-style layout contains exactly one installer executable
- **THEN** the engine selects that installer for silent installation

#### Scenario: No manifest is consulted

- **WHEN** driver discovery runs
- **THEN** selection comes solely from folder and installer naming patterns; no per-driver manifest is required or read

### Requirement: Silent recursive manufacturer-installer and PnP installation

The engine MUST silently and recursively install from the staged driver folders using the manufacturer installers and PnP (Q96).

#### Scenario: Silent install without prompts

- **WHEN** the driver phase executes against staged folders
- **THEN** manufacturer installers run with silent switches and PnP completes device binding without technician interaction

### Requirement: Driver failures never kill the deployment

A driver installation failure MUST NOT automatically terminate Windows deployment. The engine MUST report failed drivers clearly, preserve diagnostics, and route unresolved or functionally important failures to Technician Review before final handoff (Q27).

#### Scenario: Failure is reported and routed

- **WHEN** a driver installer fails
- **THEN** the deployment continues, the failure is clearly reported with diagnostics preserved, and unresolved or functionally important failures reach Technician Review

### Requirement: Sibling scripts are not consumed

The driver engine MUST NOT absorb, wrap, stage, or invoke `autoAll.ps1` or `eztConfig.ps1`; specific techniques such as silent-install switch patterns MAY be reimplemented from them as references only (Q95).

#### Scenario: Fresh implementation with reference techniques

- **WHEN** the driver engine needs a silent-install switch pattern
- **THEN** the pattern is implemented in suite code and no reference to or invocation of the sibling scripts exists

### Requirement: Dry-run mode

The driver engine MUST provide a dry-run mode that records the installers it would invoke and the folders it would traverse without executing anything, for component testing.

#### Scenario: Dry-run records the plan

- **WHEN** the engine runs in dry-run mode against a staged tree
- **THEN** the planned installer invocations are recorded and no installer executes
