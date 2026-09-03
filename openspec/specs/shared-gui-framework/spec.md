# shared-gui-framework Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: One shared GUI module

All technician- and user-facing screens across the bootstrap controller, partition deployment and recovery, and orchestrator review dialogs MUST come from one shared WPF/XAML GUI module (`OSDeploy.Gui`) (Q99).

#### Scenario: Environments share screen definitions

- **WHEN** two environments need the same kind of screen (for example a confirmation dialog)
- **THEN** both consume the same XAML definition from the shared module rather than duplicate implementations

### Requirement: Declarative wizard composition

Screens MUST be composed declaratively as XAML with a shared wizard host handling navigation, so layout is data rather than imperative UI code.

#### Scenario: Wizard navigation is host-driven

- **WHEN** a wizard sequence runs
- **THEN** screen order and navigation are driven by the wizard host from declarative definitions

### Requirement: STA threading contract

The GUI host MUST run on an STA thread. The module MUST detect a non-STA apartment and fail fast with guidance to relaunch through an STA host, and the WinPE launcher MUST invoke an STA PowerShell host because the WinPE default can be MTA (Q99).

#### Scenario: Non-STA invocation fails fast

- **WHEN** the GUI host is started on an MTA thread
- **THEN** it stops before creating any WPF control and reports the STA relaunch requirement

### Requirement: Consistent appearance

All screens MUST apply the module's shared style resources so every environment presents a consistent appearance.

#### Scenario: Shared theme is applied

- **WHEN** screens render in any environment
- **THEN** they draw fonts, colors, and control styling from the shared resources
