# orchestrator-integrity Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Restricted staging directory

The orchestrator directory under `C:\ProgramData\OSDeploy\Orchestrator` MUST be restricted to SYSTEM and local Administrators via NTFS permissions (Q90).

#### Scenario: ACL restricts access

- **WHEN** the orchestrator is staged
- **THEN** the directory's access control grants only SYSTEM and local Administrators

### Requirement: Automatic hash generation on staging

SHA-256 hashes MUST be calculated automatically for the staged orchestrator files after staging, and the hashes plus the complete bundle hash MUST be stored with the authoritative deployment state on the partition. No manually maintained version manifest MUST be introduced (Q90, Q92).

#### Scenario: Hashes recorded with deployment state

- **WHEN** orchestrator staging completes
- **THEN** per-file hashes and the complete bundle hash are stored on the partition with the deployment state, identifying the exact staged copy

### Requirement: Hash revalidation before first execution and after restarts

The orchestrator MUST recheck its hashes before first execution and after every restart (Q90).

#### Scenario: Pre-execution recheck

- **WHEN** the orchestrator starts for the first time on a machine
- **THEN** it validates its files against the stored hashes before performing any phase work

#### Scenario: Post-restart recheck

- **WHEN** the orchestrator resumes after a restart
- **THEN** it validates its files against the stored hashes before resuming phases

### Requirement: Local-only repair with Technician Review stop

On hash validation failure the orchestrator MUST recopy itself only from the local partition repair source and validate again; if the refreshed copy also fails, it MUST stop at blocking Technician Review. It MUST NOT contact, probe, map, or authenticate to DeploymentShare or any deployment server for repair (Q90, Q91).

#### Scenario: Repair from local content

- **WHEN** hash validation fails
- **THEN** the orchestrator recopies from the local repair source on the partition and revalidates

#### Scenario: Repeated failure stops for review

- **WHEN** the refreshed local copy also fails validation
- **THEN** the orchestrator stops at blocking Technician Review rather than executing unvalidated code

#### Scenario: No server repair path

- **WHEN** orchestrator repair is needed
- **THEN** no network path to DeploymentShare or any deployment server is accessed

### Requirement: Validation results are logged

Integrity validation and refresh results MUST be recorded in the authoritative local log (Q90).

#### Scenario: Integrity events appear in the log

- **WHEN** a hash validation or refresh occurs
- **THEN** the local run log records the check, its outcome, and any repair action
