## ADDED Requirements

### Requirement: Audit Mode staging with finalize to OOBE

The MMC workflow MUST use Audit Mode as the technician staging environment. Finalize and Return to OOBE MUST remove temporary deployment artifacts and then run Sysprep, with the successful final endpoint being powered-on OOBE rather than Audit Mode (Q30, Q31).

#### Scenario: Finalize removes artifacts then syspreps

- **WHEN** the technician chooses Finalize and Return to OOBE
- **THEN** temporary deployment artifacts are removed and Sysprep initiates the reboot into OOBE

### Requirement: MMC completion criteria

MMC MUST be recorded complete when cleanup has succeeded and Sysprep successfully initiates the reboot into OOBE (Q32).

#### Scenario: Completion at Sysprep initiation

- **WHEN** cleanup succeeds and Sysprep initiates the OOBE reboot
- **THEN** the run is recorded complete and the machine presents powered-on OOBE

### Requirement: Sysprep failure is a blocking technician error

If Sysprep fails, the system MUST remain in Audit Mode with a blocking technician error, and no cleanup MUST run after entering OOBE (Q32).

#### Scenario: Sysprep failure keeps Audit Mode

- **WHEN** Sysprep fails to initiate the OOBE reboot
- **THEN** the system stays in Audit Mode with a blocking error and is not recorded complete

### Requirement: No EZT account experience

The MMC workflow MUST NOT create the EZT `User` account, automatic sign-in, or the password-transition shortcut (Q15).

#### Scenario: MMC creates no User account

- **WHEN** the MMC workflow specifics phase completes
- **THEN** no passwordless `User` account, automatic sign-in configuration, or password shortcut exists

### Requirement: Customer-adjustable endpoint

MMC MUST finish at Windows OOBE with mostly default customer-facing setup, where the customer can still adjust region and keyboard (Q14, Q100).

#### Scenario: OOBE remains for the customer

- **WHEN** an MMC deployment hands off
- **THEN** Windows presents OOBE so the customer performs their own region and keyboard choices
