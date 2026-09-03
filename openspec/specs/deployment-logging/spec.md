# deployment-logging Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Timestamped per-run log folders

Every run MUST create its own collision-safe timestamped folder on the OSDCloud Deployment Partition as the authoritative log location, containing structured events and a transcript (Q8, Q76).

#### Scenario: Each run gets a separate folder

- **WHEN** two runs log on the same machine
- **THEN** each run's events and transcript live in their own timestamped folder and no run writes into another run's folder

#### Scenario: Collision-safe naming

- **WHEN** a folder for the current timestamp already exists
- **THEN** a collision-safe unique name is generated instead of overwriting

### Requirement: Local copy is authoritative

The local partition log MUST be verified as written before any secondary copy is attempted. A failed server copy MUST be recorded as a non-blocking warning and MUST NOT invalidate the verified local log (Q8, Q74).

#### Scenario: Server copy failure does not block

- **WHEN** the InitialDeployment secondary copy to the log share fails
- **THEN** the run records a warning and continues, and the local log remains the authoritative copy

### Requirement: Factory Recovery never uploads logs

A FactoryRecovery run MUST NOT attempt any server log copy and MUST NOT contact the deployment server for logging (Q74).

#### Scenario: Recovery logging stays local

- **WHEN** a FactoryRecovery run finalizes its log
- **THEN** no network path to a deployment server is accessed

### Requirement: Oldest-first retention

Retained log history MUST enforce the `LocalLogHistoryMaxMB` limit (default 1024) by removing complete oldest run folders first, and MUST NOT remove the active run's folder (Q77, Q78).

#### Scenario: Limit exceeded prunes oldest complete folders

- **WHEN** total log history exceeds the configured limit
- **THEN** complete run folders are removed oldest-first until the total is within the limit, and the active run folder remains

### Requirement: Final summary waits for the final local log update

The final summary MUST NOT close until the final local log update succeeds, and the acknowledgement state MUST be preserved across retries (Q73).

#### Scenario: Failed final log update keeps the summary open

- **WHEN** the final local log update fails
- **THEN** the summary remains open with its acknowledgement state preserved until a retry succeeds
