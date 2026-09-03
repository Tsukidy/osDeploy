## ADDED Requirements

### Requirement: Single-instance SYSTEM startup execution

The orchestrator MUST run as a single-instance startup Scheduled Task as SYSTEM without requiring user sign-in, and a second concurrent launch MUST exit without duplicating work (Q89).

#### Scenario: Concurrent launch exits

- **WHEN** the orchestrator is launched while another instance holds the single-instance lock
- **THEN** the second launch exits without performing phase work or mutating state

### Requirement: Atomic checkpoint on every phase transition

Every phase transition MUST atomically write the authoritative `DeploymentState.json` on the OSDCloud Deployment Partition with run id, machine identity, disk identity, workflow, edition, phase, attempt, reboot state, configuration version, and timestamp (Q89).

#### Scenario: Checkpoint precedes phase work

- **WHEN** the orchestrator enters a phase
- **THEN** the checkpoint reflects that phase before the phase's work begins

### Requirement: Idempotent resume from the last incomplete phase

Every phase MUST be idempotent. After a restart or power loss the orchestrator MUST automatically resume from the last incomplete phase, MUST NOT re-enter completed destructive work, and MUST restore the active configuration and log context (Q35, Q89).

#### Scenario: Resume after power loss

- **WHEN** the machine restarts mid-phase with a checkpoint showing an incomplete phase
- **THEN** execution resumes that phase without repeating completed destructive work

#### Scenario: Re-running a completed phase is a no-op

- **WHEN** a phase re-executes work it already completed
- **THEN** the result is unchanged and no destructive operation repeats

### Requirement: Three automatic attempts then blocking Technician Review

Each checkpoint MUST allow up to three automatic attempts; a fourth failure MUST stop automation and open blocking Technician Review with stage history, errors, log locations, manual retry, and safe-checkpoint rollback options (Q36, Q89).

#### Scenario: Fourth failure opens review

- **WHEN** a phase fails for the fourth consecutive time at the same checkpoint
- **THEN** automation stops and blocking Technician Review presents stage history, errors, logs, manual retry, and rollback options

#### Scenario: Attempt counter is per checkpoint

- **WHEN** a phase fails twice and then succeeds
- **THEN** the attempt counter resets for the next checkpoint

### Requirement: RebootPending handling

Before any required restart the orchestrator MUST save `RebootPending`, and on return it MUST validate machine and disk identity before resuming (Q89).

#### Scenario: Reboot round-trip resumes safely

- **WHEN** a phase requests a restart after saving `RebootPending`
- **THEN** on the next boot the orchestrator validates identity and resumes the pending phase

### Requirement: Completion gating

Completion MUST be recorded only after required work, cleanup, final-log verification, and the correct EZT or MMC handoff succeed. Cleanup failure MUST block completion (Q89).

#### Scenario: Cleanup failure blocks completion

- **WHEN** cleanup fails during finalization
- **THEN** the run is not recorded complete and the failure is surfaced for technician action

#### Scenario: Restart after completion runs cleanup only

- **WHEN** the machine restarts after completion was recorded
- **THEN** the orchestrator performs cleanup only and does not re-enter deployment phases

### Requirement: Cleanup scope

Cleanup MUST remove the startup task and deployment-only artifacts while retaining recovery content, factory configuration, and logs (Q89).

#### Scenario: Recovery content survives cleanup

- **WHEN** cleanup completes
- **THEN** the partition's engine, image cache, factory profile, configuration snapshot, and logs remain intact
