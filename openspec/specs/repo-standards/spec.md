# repo-standards Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Windows PowerShell 5.1 compatibility

All PowerShell source files under `src/` MUST be Windows PowerShell 5.1-compatible. Source MUST NOT use PowerShell 7-only constructs, including ternary conditionals, null-coalescing operators (`??`, `??=`), and pipeline chain operators (`&&`, `||`).

#### Scenario: PS7-only construct is rejected

- **WHEN** a source file contains a ternary conditional, `??`, or `&&`/`||` chain operator and the static gates run
- **THEN** the gate fails, naming the file and construct, and no artifact of the run is accepted as green

#### Scenario: Clean tree passes

- **WHEN** the static gates run against a checkout whose sources contain only 5.1-compatible syntax
- **THEN** the gates exit successfully

### Requirement: ASCII-only source

Every file under `src/` and `tests/` MUST contain only ASCII bytes.

#### Scenario: Non-ASCII byte is rejected

- **WHEN** a source file contains any byte outside ASCII and the static gates run
- **THEN** the gate fails, naming the file and the offset of the first non-ASCII byte

### Requirement: Static gates parse every source file

The static gates MUST parse every `.ps1`, `.psm1`, and `.psd1` file under `src/` and `tests/` using the PowerShell AST, MUST run under `pwsh` on the Linux development box, and MUST be runnable after every edit without Windows.

#### Scenario: Parse failure is reported per file

- **WHEN** a source file has a syntax error and the gates run
- **THEN** the gates fail with the file path and parse error

#### Scenario: Gates run on Linux without Windows

- **WHEN** the gate entry point is invoked on the Linux development box
- **THEN** it completes using only `pwsh` and the repository tree, reporting pass or fail without contacting any Windows machine

### Requirement: OSDeploy module namespace

Every runtime module MUST be named with the `OSDeploy.` prefix so it cannot collide with the OSD module's namespace.

#### Scenario: Module manifest naming

- **WHEN** a module manifest is created under `src/`
- **THEN** its name matches the `OSDeploy.<Component>` pattern and does not shadow any `OSD.*` module name

### Requirement: Repository layout

The repository MUST provide `src/Shared`, `src/Orchestrator`, `config/`, and `tests/`, with `src/Bootstrap`, `src/Partition`, and `src/Build` reserved for later changes. Each component MUST place its files only in its own directory.

#### Scenario: Scaffold directories exist

- **WHEN** the repository scaffold is created
- **THEN** the shared modules live under `src/Shared`, the orchestrator under `src/Orchestrator`, the central-configuration template under `config/`, and the gates and Pester suites under `tests/`

### Requirement: Reference scripts are never consumed

The suite MUST NOT absorb, wrap, stage, or invoke `autoAll.ps1` or `eztConfig.ps1`; they are technique references only (Q95).

#### Scenario: No reference or invocation of the sibling scripts

- **WHEN** the source tree is searched for references to `autoAll` or `eztConfig`
- **THEN** no file loads, invokes, stages, or embeds either script
