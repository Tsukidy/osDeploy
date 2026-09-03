## ADDED Requirements

### Requirement: Central configuration schema

The central configuration MUST be a single JSON file with the sections `OrderDatabase` (host, port, database, username, password, table, and a `ColumnMap` for order number, company, edition default, and regulated state per Q98), `Deployment` (`RecoveryPartitionSizeMB` 32768, `WindowsReToolsPartitionSizeMB` 1024, `RecommendedPrimaryDriveSizeMB` 122070, `TimeZone`), `Logging` (`LocalLogHistoryMaxMB` 1024), `WindowsUpdate` (`MaxCycles` 3), `RegulatedStates` (default `["CA"]`), and `CompanyWorkflowMap`. Size values MUST be expressed in whole binary MB (Q78).

#### Scenario: Valid configuration resolves completely

- **WHEN** a configuration file containing all sections with valid values is loaded
- **THEN** every setting resolves to the file's value and no fallback is recorded for it

#### Scenario: Unknown keys do not break loading

- **WHEN** the configuration contains keys outside the known schema
- **THEN** loading still succeeds and the unknown keys are ignored with a recorded warning

### Requirement: Hard-coded defaults and validated fallbacks

Every configurable value MUST have a hard-coded default, and a missing or invalid value MUST fall back to that default with the fallback recorded (Q83).

#### Scenario: Missing value falls back

- **WHEN** a setting is absent from the configuration file
- **THEN** the hard-coded default is applied and the key is listed in the fallback record with reason `missing`

#### Scenario: Invalid value falls back

- **WHEN** a setting is present but fails type or range validation (for example a non-positive partition size)
- **THEN** the hard-coded default is applied and the key is listed in the fallback record with reason `invalid`

### Requirement: Effective-configuration snapshot

After validation, the fully resolved effective configuration MUST be saved locally as a versioned snapshot containing the resolved values, the configuration version, the source, and an explicit list of keys that fell back with reasons (Q84).

#### Scenario: Snapshot records provenance and fallbacks

- **WHEN** a run saves the effective-configuration snapshot
- **THEN** the snapshot contains the resolved value for every setting, the configuration version and source, and each fallen-back key with its reason

### Requirement: Factory Recovery uses only the snapshot

FactoryRecovery MUST load configuration exclusively from the saved local snapshot and hard-coded safe fallbacks, and MUST NOT read central configuration (Q84).

#### Scenario: Recovery never reads central configuration

- **WHEN** the configuration loader is invoked for a FactoryRecovery run
- **THEN** it reads only the local snapshot path and applies safe fallbacks for missing snapshot values, and no central-configuration path is accessed

### Requirement: Configuration provenance is logged

Every run MUST log the configuration source, version, effective values, and fallbacks (Q84).

#### Scenario: Provenance appears in the run log

- **WHEN** a run starts with a loaded configuration
- **THEN** the run log records the source, the version, the effective value of every setting, and every fallback applied
