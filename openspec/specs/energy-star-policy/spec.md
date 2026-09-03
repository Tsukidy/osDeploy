# energy-star-policy Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Technician-overridable Energy Star decision

The detected Energy Star requirement MUST remain technician-overridable. Apply MUST be the default for matched states, Do Not Apply MUST require a warning, and the effective choice MUST be cached for the machine (Q20).

#### Scenario: Default applies for matched states

- **WHEN** the machine's state is on the regulated list and detection matches
- **THEN** Apply is the default and the technician may override

#### Scenario: Override warns and caches

- **WHEN** the technician chooses Do Not Apply
- **THEN** a warning is required and the effective choice is cached in the factory profile

### Requirement: Regulated-state power behavior

California MMC systems MUST receive Energy Star settings without the persistent choice popup; California EZT systems MUST receive Energy Star settings and the persistent popup; non-regulated systems MUST use High Performance with display sleep after 60 minutes and system sleep disabled (Q22).

#### Scenario: California MMC

- **WHEN** the saved state is California and the workflow is MMC
- **THEN** Energy Star settings apply with no persistent popup

#### Scenario: California EZT

- **WHEN** the saved state is California and the workflow is EZT
- **THEN** Energy Star settings apply and the persistent choice popup appears on the delivered desktop

#### Scenario: Non-regulated system

- **WHEN** the state is not on the regulated list
- **THEN** High Performance applies with display sleep at 60 minutes and system sleep disabled

### Requirement: Deployment-time evaluation persisted in the profile

The configurable regulated-state list MUST be evaluated only at deployment time, with the resulting policy saved in `FactoryProfile.json`. Deployed systems MUST NOT phone home for state policy, and later server-side list changes MUST affect new deployments only (Q23).

#### Scenario: Later list changes do not reach deployed systems

- **WHEN** the central regulated-state list changes after a system is deployed
- **THEN** the deployed system's saved policy is unchanged and no check-in occurs

### Requirement: Recovery reapplies the saved decision

Factory Recovery MUST reapply the saved Energy Star decision from the local factory profile and MUST ask again only when the saved decision is missing or invalid (Q21).

#### Scenario: Saved decision is reapplied silently

- **WHEN** Factory Recovery runs with a valid saved decision
- **THEN** the saved policy applies without asking

#### Scenario: Missing decision asks again

- **WHEN** the saved decision is missing or invalid
- **THEN** the decision is requested again
