## ADDED Requirements

### Requirement: Passwordless User administrator account

The EZT workflow MUST create the local account `User` as a passwordless local administrator, MUST keep the built-in Administrator disabled, and MUST add a public desktop shortcut named `Set or Change Your Password` that launches the managed graphical password transition rather than Windows Sign-in options (Q15, Q24).

#### Scenario: Account and shortcut are created

- **WHEN** the EZT workflow specifics phase completes
- **THEN** `User` exists as a passwordless local administrator, the built-in Administrator remains disabled, and the shortcut launches the managed password workflow

### Requirement: Persistent automatic sign-in

The EZT `User` account MUST have persistent automatic sign-in with no logon-count limit, ending only when the owner successfully sets a password through the managed workflow. Unattend generation MUST produce registry-based automatic sign-on without a logon count (Q16, Q24).

#### Scenario: Unattend contains unlimited autologon

- **WHEN** the EZT unattend is generated
- **THEN** automatic sign-on is configured for `User` with no logon-count restriction

### Requirement: Managed password transition

The managed password workflow MUST warn that a successful change disables automatic sign-in, then change the password, disable automatic sign-in, and clear the stored automatic-logon credential as one controlled transition. Cancellation or failure MUST leave both states unchanged. Password-protected automatic sign-in MUST NOT be produced, and Factory Recovery MUST restore the original passwordless automatic-sign-in state (Q86).

#### Scenario: Successful transition is atomic

- **WHEN** the owner completes the managed password change
- **THEN** the password is set, automatic sign-in is disabled, and the stored credential is cleared together

#### Scenario: Cancellation changes nothing

- **WHEN** the owner cancels or the change fails
- **THEN** the passwordless state and automatic sign-in both remain exactly as before

### Requirement: Activation flow

The workflow MUST attempt normal digital-license or firmware-key activation first. When technician input is needed it MUST show the illustrated Windows 11 product-key dialog with sticker-location guidance. Product keys MUST NOT be stored or logged anywhere (Q18).

#### Scenario: Keys never persist

- **WHEN** the activation flow completes in any outcome
- **THEN** no product key appears in state files, logs, or unattend content

### Requirement: Finish without activation

When activation cannot be completed, the workflow MUST offer Retry Activation, Finish Without Activation, or Cancel. Finishing without activation MUST require a warning and MUST record the incomplete activation state without storing the key (Q19).

#### Scenario: Incomplete activation is a warned, recorded state

- **WHEN** the technician finishes without activation
- **THEN** a warning is acknowledged and the result records incomplete activation

### Requirement: EZT completion at the configured desktop

EZT MUST complete all work, validation, logging, and cleanup before final handoff, and completion MUST be recorded when the final reboot to the configured `User` desktop successfully begins. If the final reboot cannot be initiated, the run MUST NOT be marked complete and MUST stay powered on at Technician Review with failure details and a Retry Final Handoff option (Q24, Q31, Q33, Q34).

#### Scenario: Completion recorded at final reboot initiation

- **WHEN** the final reboot to the configured desktop successfully begins
- **THEN** completion is recorded and the machine finishes powered on

#### Scenario: Failed final handoff stays in review

- **WHEN** EZT cannot initiate its final reboot
- **THEN** the run is not complete and remains powered on at Technician Review with failure details and Retry Final Handoff
