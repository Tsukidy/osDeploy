## ADDED Requirements

### Requirement: Atomic JSON writes

State files MUST be written atomically via a temporary file followed by a move, so a reader never observes a partial document.

#### Scenario: Interrupted write leaves the previous content intact

- **WHEN** a state write is interrupted before the move completes
- **THEN** the destination file still contains the previous complete document

#### Scenario: Successful write is complete

- **WHEN** a state write completes
- **THEN** the destination file contains the full new document and no temporary artifacts remain

### Requirement: ReadinessRecord contract

`ReadinessRecord.json` MUST contain the run id, machine identity, disk identity, workflow, edition, configuration version, generated bundle hash, and timestamp, and MUST be written atomically only after the Deployment Partition Ready gate succeeds (Q92, Q102).

#### Scenario: Record contains every required field

- **WHEN** a readiness record is created
- **THEN** it validates against the contract with all eight field groups present

### Requirement: DeploymentState contract

`DeploymentState.json` MUST contain the run id, machine identity, disk identity, workflow, edition, phase, attempt, reboot state, configuration version, timestamp, completed phases, result, noted issues, and acknowledgements (Q89).

#### Scenario: Checkpoint contains full context

- **WHEN** any phase transition writes a checkpoint
- **THEN** the state file validates against the contract with every field group present

### Requirement: FactoryProfile active and last-known-good copies

`FactoryProfile.json` MUST be maintained as an active copy plus a last-known-good backup updated through atomic writes (Q87).

#### Scenario: Valid update refreshes both copies

- **WHEN** a valid profile update is committed
- **THEN** the last-known-good copy first receives the previously active content, then the active copy receives the new content

#### Scenario: Invalid active copy is restored from backup

- **WHEN** the active copy fails validation and the last-known-good copy is valid
- **THEN** the active copy is restored from the backup, a warning is recorded, and execution continues

#### Scenario: Both copies invalid stops without guessing

- **WHEN** both the active and last-known-good copies fail validation
- **THEN** the run stops before destructive work without guessing a workflow, using a hard-coded profile, or allowing manual workflow selection (Q87)

### Requirement: Identity fields never fall back

Machine identity, disk identity, run id, and workflow fields MUST NOT be substituted with defaults or fallbacks; only documented noncritical fields MAY use field-specific fallbacks (Q87, Q89).

#### Scenario: Missing identity field fails validation

- **WHEN** a state or profile document is missing an identity-required field
- **THEN** validation fails and the document is treated as invalid rather than defaulted
