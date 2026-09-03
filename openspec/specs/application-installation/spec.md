# application-installation Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Workflow-fixed application sets

Application selection MUST be fixed by the chosen EZT or MMC workflow rather than chosen application-by-application, and the resolved manifest and installers MUST be included in local staged content (Q25).

#### Scenario: Workflow determines the set

- **WHEN** a workflow is confirmed for a run
- **THEN** exactly that workflow's application manifest set is staged and installed, with no per-application selection step

### Requirement: Manifest-driven execution

Application installation MUST be driven by the workflow's manifest entries (`Id`, `Name`, `Installer`, `Type`, `SilentArgs`, `SuccessCodes`, `RetryCount`, `TimeoutMinutes`, `Required`), executing silently and respecting per-entry retry counts and timeouts (Q25, Q26).

#### Scenario: Retries follow the manifest

- **WHEN** an installer exits with a non-success code within its `RetryCount`
- **THEN** the entry is retried up to its configured count before it is treated as failed

#### Scenario: Timeout is enforced

- **WHEN** an installer exceeds its `TimeoutMinutes`
- **THEN** it is treated as failed and handled by the failure path

### Requirement: Acknowledge-and-continue failure handling

After manifest retries are exhausted, a failed application MUST present an Acknowledge and Continue modal showing program, status, error or exit code, and log location. Acknowledged continuation MUST record the deployment as Completed with Warnings and retain the failure for final review (Q26).

#### Scenario: Failed app is acknowledged and retained

- **WHEN** an application fails after its retries and the technician acknowledges
- **THEN** deployment continues, the result is Completed with Warnings, and the failure remains in the final review data

### Requirement: Near-zero-touch execution

After review and confirmation, application execution MUST proceed without per-application prompts (Q25).

#### Scenario: No mid-run app prompts

- **WHEN** the application phase runs after confirmation
- **THEN** no per-application interaction is required for successful entries
