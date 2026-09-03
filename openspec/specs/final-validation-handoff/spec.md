# final-validation-handoff Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Final Plug and Play validation

The engine MUST run final Plug and Play validation, rescan current devices, and report unknown, missing, incompatible, problem-code, or unhealthy devices in one acknowledged warning. Unresolved findings MUST remain in the final summary and warning result (Q28).

#### Scenario: Problem devices are reported once

- **WHEN** final PnP validation finds unknown, missing, incompatible, problem-code, or unhealthy devices
- **THEN** a single acknowledged warning lists them and they remain in the final summary

### Requirement: Technician Review before final handoff

After applications, drivers, and validation, Technician Review MUST provide manual remediation plus Rescan Devices and Rerun Validation before the EZT final reboot or the MMC return to OOBE, preserving resolved and unresolved findings in the logs (Q29).

#### Scenario: Rescan and rerun are available

- **WHEN** Technician Review opens before final handoff
- **THEN** manual remediation, Rescan Devices, and Rerun Validation are available and all findings are preserved in the logs

### Requirement: Result states

The suite MUST use the result states Completed, Completed with Warnings, and Completed with Tech-Addressed Warnings, and MUST NOT add a delivery-readiness state (Q67, Q71).

#### Scenario: Warnings produce the warned result

- **WHEN** a deployment finishes with unresolved warnings
- **THEN** the result is Completed with Warnings rather than Completed

### Requirement: Noted-issues acknowledgement

Noted issues MUST be listed in the final summary with a single acknowledgement covering the complete list, shown and required only when noted issues exist (Q68–Q70).

#### Scenario: Acknowledgement appears only with issues

- **WHEN** the final summary is presented with no noted issues
- **THEN** no noted-issues acknowledgement is shown

#### Scenario: One acknowledgement covers the list

- **WHEN** the final summary lists multiple noted issues
- **THEN** a single acknowledgement covers every item on the list

### Requirement: Tech-addressed transition

The result MUST change to Completed with Tech-Addressed Warnings only when the checked acknowledgement is submitted with Finish Deployment (Q71, Q72).

#### Scenario: Result changes at submission

- **WHEN** the technician submits Finish Deployment with the acknowledgement checked
- **THEN** the result becomes Completed with Tech-Addressed Warnings; submitting without the check leaves the result unchanged

### Requirement: Persistent recovery boot-entry registration

After Windows is installed and validated, the orchestrator MUST register the persistent Factory Recovery entry while keeping Windows the default boot target with the five-second menu timeout, MUST validate the entry against its partition identity and boot files, and MUST clear every remaining initial-deployment-only boot override. Failure to register or validate the entry MUST block final completion at Technician Review (Q42, Q94).

#### Scenario: Successful registration preserves Windows as default

- **WHEN** registration and validation succeed
- **THEN** the Factory Recovery entry exists, Windows remains the default target with the five-second timeout, and deployment-only overrides are cleared

#### Scenario: Registration failure blocks completion

- **WHEN** the persistent entry cannot be registered or fails validation
- **THEN** final completion is blocked and Technician Review opens

### Requirement: Final log verification gates the summary

The final summary MUST NOT close until the final local log update has succeeded (Q73).

#### Scenario: Summary waits for log finalization

- **WHEN** the final local log update has not succeeded
- **THEN** the final summary remains open and cannot be dismissed
