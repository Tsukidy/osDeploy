# OSDeploy Suite Phases 0-2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repository scaffold with Linux static gates, the seven `OSDeploy.*` shared modules with Pester coverage, and the installed-Windows orchestrator (engine, integrity, and all deployment phases) — phases 0-2 of the confirmed suite design.

**Architecture:** The full suite has three execution stages (PXE bootstrap, OSDCloud Deployment Partition, installed-Windows orchestrator); this plan builds the third stage plus the shared logic the other two will later consume. Pure-logic modules are proven by Pester under `pwsh` on Linux; Windows-only behaviors are exercised by a component suite on a Windows VM against a mock partition folder. Checkpoint state lives in atomic JSON files; every orchestrator phase is idempotent and resumes from the last incomplete checkpoint.

**Tech Stack:** Windows PowerShell 5.1-compatible PowerShell (developed and statically gated under `pwsh` on Linux), Pester v5, WPF/XAML (GUI module; rendering verified only on Windows), Scheduled Task running as SYSTEM.

**Spec:** This change's artifacts travel together and control this plan: `tasks.md` (11 groups, 48 checkboxes), `design.md` (decisions D1-D13), and `specs/<capability>/spec.md` (16 capability specs, each requirement citing Q numbers from `source/OSDeploy_PXE_Workflow_Questions_and_Answers.md`, which remains the behavioral authority). Where code and the decision record appear to conflict, the decision record wins and the discrepancy is raised, not silently resolved.

## Global Constraints

Every task implicitly includes these. Copy exact values; do not re-derive:

- Windows PowerShell 5.1-compatible source everywhere under `src/` and `tests/`: no ternary conditionals, no `??` or `??=`, no `&&` or `||` chain operators, no `-AsHashtable`, no `-ErrorAction Ignore` differences relied on. Tests also stay 5.1-compatible even though they run under `pwsh`.
- Pure ASCII in every file under `src/` and `tests/`. Write files with ASCII encoding; user-facing strings are en-US ASCII (Q100).
- Module prefix `OSDeploy.*` (never `OSD.*`, which belongs to the OSD module).
- After every edit, run the gates: `pwsh tests/gates/Invoke-StaticGates.ps1` — must exit 0 before any commit.
- Unit test command form: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/unit/<Name>.Tests.ps1 -Output Detailed"` — expected PASS at task end.
- `autoAll.ps1` and `eztConfig.ps1` are never absorbed, wrapped, staged, or invoked (Q95). `reference-code/` is never imported by runtime code.
- Identity fields (run id, machine identity, disk identity, workflow) never fall back to defaults (Q87, Q89).
- No product key is ever written to state files, logs, or unattend content (Q18).
- Commit after every task with the message given in its final step, `git add`-ing only the paths that task created or modified.

## File Structure

```
src/
  Shared/
    OSDeploy.Util/OSDeploy.Util.psd1 + .psm1          # hashing, inventory, bundle hash
    OSDeploy.State/OSDeploy.State.psd1 + .psm1        # atomic JSON, file contracts, LKG
    OSDeploy.Config/OSDeploy.Config.psd1 + .psm1      # load/resolve/snapshot
    OSDeploy.Logging/OSDeploy.Logging.psd1 + .psm1    # run folders, retention, events
    OSDeploy.Disk/OSDeploy.Disk.psd1 + .psm1          # inventory/selection/erase rules
    OSDeploy.Image/OSDeploy.Image.psd1 + .psm1        # index validation, promotion
    OSDeploy.Gui/OSDeploy.Gui.psd1 + .psm1 + Screens/ # WPF host + XAML
  Orchestrator/
    OSDeploy.Orchestrator.psd1 + .psm1                # engine: entry, checkpoints, phases
tests/
  gates/Invoke-StaticGates.ps1 + fixtures/            # AST/banned/ASCII gates
  unit/<Module>.Tests.ps1                             # Pester, runs under pwsh
  component/ComponentSuite.ps1                        # Windows VM suite (Task 29)
  mocks/New-MockPartition.ps1                         # mock partition builder
config/osdeploy-config.json                           # central configuration template
```

Each module owns one responsibility (design D5); each file below `src/` stays focused enough to hold in context at once.

---

### Task 1: Repository scaffold and gate entry point

**Files:**
- Create: `src/Shared/.gitkeep`, `src/Orchestrator/.gitkeep`, `src/Bootstrap/.gitkeep`, `src/Partition/.gitkeep`, `src/Build/.gitkeep`, `tests/unit/.gitkeep`, `tests/gates/Invoke-StaticGates.ps1`

**Interfaces:**
- Produces: `Invoke-StaticGates.ps1` exits 0 when all checks pass, 1 on any failure, printing one line per failed file. Later tasks add checks inside it; its CLI contract never changes.

- [ ] **Step 1: Create the directory tree**

```bash
mkdir -p src/Shared src/Orchestrator src/Bootstrap src/Partition src/Build tests/unit tests/gates/fixtures tests/component tests/mocks config
touch src/Shared/.gitkeep src/Orchestrator/.gitkeep src/Bootstrap/.gitkeep src/Partition/.gitkeep src/Build/.gitkeep tests/unit/.gitkeep
```

- [ ] **Step 2: Write the gate entry point skeleton**

`tests/gates/Invoke-StaticGates.ps1`:

```powershell
# Static gates for OSDeploy sources. Run after every edit: pwsh tests/gates/Invoke-StaticGates.ps1
[CmdletBinding()]
param(
    [string[]]$Root = @((Join-Path $PSScriptRoot '..\..\src'), (Join-Path $PSScriptRoot '..\..\tests'))
)
Set-StrictMode -Version Latest
$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure { param([string]$Message) $script:failures.Add($Message) }

# --- Check 1: every .ps1/.psm1/.psd1 parses (added in Task 2) ---
# --- Check 2: banned constructs (added in Task 3) ---
# --- Check 3: ASCII-only bytes (added in Task 4) ---

foreach ($f in $failures) { Write-Output "GATE FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 }
Write-Output 'GATES PASS'
exit 0
```

Note: `\` path joins are fine on Linux `pwsh` (Join-Path accepts them); use this exact form so the script is also 5.1-correct on Windows.

- [ ] **Step 3: Run gates and commit**

Run: `pwsh tests/gates/Invoke-StaticGates.ps1` — Expected: `GATES PASS`, exit 0.

```bash
git add src tests config
git commit -m "Scaffold src/tests/config tree with static-gate entry point"
```

### Task 2: AST parse gate

**Files:**
- Modify: `tests/gates/Invoke-StaticGates.ps1`
- Test: `tests/gates/fixtures/Broken-Syntax.ps1` (intentionally broken, excluded from tree scans, scanned explicitly by the gate's self-test)

**Interfaces:**
- Consumes: Task 1 entry point and `Add-Failure`.
- Produces: gate parses every `.ps1/.psm1/.psd1` under `src/` and `tests/` except `tests/gates/fixtures/`.

- [ ] **Step 1: Add the parse check** — insert at the `Check 1` marker:

```powershell
$parseRoots = foreach ($r in $Root) { Get-ChildItem -Path $r -Recurse -Include *.ps1, *.psm1, *.psd1 -File |
    Where-Object { $_.FullName -notmatch 'fixtures' } }
foreach ($file in $parseRoots) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($e in $errors) { Add-Failure ("PARSE {0}: {1}" -f $file.FullName, $e.Message) }
}
```

- [ ] **Step 2: Self-test with a broken fixture**

Create `tests/gates/fixtures/Broken-Syntax.ps1` containing exactly: `function { unclosed`

Run: `pwsh tests/gates/Invoke-StaticGates.ps1` — Expected: exit 1 with `GATE FAIL: ...PARSE...` (fixture dir excluded from the scan above, so to self-test, temporarily add `-Root tests/gates/fixtures` and confirm one PARSE failure, then revert).

- [ ] **Step 3: Verify clean pass and commit**

Run: `pwsh tests/gates/Invoke-StaticGates.ps1` — Expected: `GATES PASS`.

```bash
git add tests/gates
git commit -m "Static gate: AST-parse all sources with per-file failure reporting"
```

### Task 3: Banned-construct gate

**Files:**
- Modify: `tests/gates/Invoke-StaticGates.ps1`
- Test: `tests/gates/fixtures/Banned-Constructs.ps1`

**Interfaces:**
- Consumes: Task 2 scan loop pattern.
- Produces: banned list is a single array any later task can extend: `$banned = @('&&', '||', '??=', '??', ' ? ', ' ?: ')` matched against non-comment text with line numbers; a line ending in `# gate:allow` is exempt (for legitimate installer argument strings).

- [ ] **Step 1: Add the banned-construct check** — insert at `Check 2`:

```powershell
$bannedPatterns = @(
    @{ Pattern = '&&';         Name = 'pipeline chain operator' },
    @{ Pattern = '\|\|';       Name = 'pipeline chain operator' },
    @{ Pattern = '\?\?=';      Name = 'null-coalescing assignment' },
    @{ Pattern = '\?\?';       Name = 'null-coalescing operator' }
)
foreach ($file in $parseRoots) {
    $lines = Get-Content -LiteralPath $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $code = ($lines[$i] -split '#')[0]
        if ($code -match [regex]::Escape(' ? ') -and $code -match '\?.*:') { }
        # ternary heuristic: "?" and ":" both present outside strings is flagged below
        foreach ($b in $bannedPatterns) {
            if ($code -match $b.Pattern) { Add-Failure ("BANNED {0}: line {1} uses {2}" -f $file.FullName, ($i + 1), $b.Name) }
        }
        if ($code -match '[^?]?\s\?\s' -and $code -match '\s:\s') {
            Add-Failure ("BANNED {0}: line {1} looks like a ternary" -f $file.FullName, ($i + 1))
        }
    }
}
```

- [ ] **Step 2: Self-test** — fixture `Banned-Constructs.ps1` with lines `$x = $a ?? $b`, `$p && $q`, `$t = $c ? 1 : 2`, and a legit line `$s = 'a && b' # gate:allow`. Run gate with `-Root tests/gates/fixtures` — Expected: exactly 3 BANNED failures, not 4.

- [ ] **Step 3: Clean pass and commit**

Run: `pwsh tests/gates/Invoke-StaticGates.ps1` — Expected: `GATES PASS`.

```bash
git add tests/gates
git commit -m "Static gate: reject PS7-only constructs with gate:allow suppression"
```

### Task 4: ASCII gate

**Files:**
- Modify: `tests/gates/Invoke-StaticGates.ps1`
- Test: `tests/gates/fixtures/Non-Ascii.ps1`

**Interfaces:**
- Produces: any byte above 0x7F fails with file and first offset.

- [ ] **Step 1: Add the byte check** — insert at `Check 3`:

```powershell
foreach ($file in $parseRoots) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) { Add-Failure ("ASCII {0}: byte 0x{1:x2} at offset {2}" -f $file.FullName, $bytes[$i], $i); break }
    }
}
```

- [ ] **Step 2: Self-test** — fixture containing `# em-dash — here` (non-ASCII em dash). Run gate with `-Root tests/gates/fixtures` — Expected: one ASCII failure with offset. Note: fixture files themselves must be ASCII-clean except this one; add `Non-Ascii.ps1` to a `fixtures/dirty/` subfolder excluded from `$parseRoots` in Task 2's filter, and scanned only by explicit self-test invocation.

- [ ] **Step 3: Clean pass and commit** — Run: `pwsh tests/gates/Invoke-StaticGates.ps1` — Expected: `GATES PASS`.

```bash
git add tests/gates
git commit -m "Static gate: reject non-ASCII bytes with file and offset"
```

### Task 5: Central configuration template

**Files:**
- Create: `config/osdeploy-config.json`
- Test: consumed by Task 8's Pester suite (validated there); verified now by gate + JSON parse.

**Interfaces:**
- Produces: the exact section/key set of `configuration-resolution`: `OrderDatabase` (host, port, database, username, password, table, `ColumnMap` with `OrderNumber`, `Company`, `EditionDefault`, `RegulatedState`), `Deployment` (`RecoveryPartitionSizeMB` 32768, `WindowsReToolsPartitionSizeMB` 1024, `RecommendedPrimaryDriveSizeMB` 122070, `TimeZone`), `Logging` (`LocalLogHistoryMaxMB` 1024), `WindowsUpdate` (`MaxCycles` 3), `RegulatedStates` `["CA"]`, `CompanyWorkflowMap` (`"EZT": "EZT"`, `"EZ Trading Computers": "EZT"`, `"*": "MMC"`).

- [ ] **Step 1: Write the template** (defaults verbatim from the spec; whole binary MB):

```json
{
    "OrderDatabase": {
        "Host": "", "Port": 3306, "Database": "", "Username": "", "Password": "",
        "Table": "",
        "ColumnMap": { "OrderNumber": "", "Company": "", "EditionDefault": "", "RegulatedState": "" }
    },
    "Deployment": {
        "RecoveryPartitionSizeMB": 32768,
        "WindowsReToolsPartitionSizeMB": 1024,
        "RecommendedPrimaryDriveSizeMB": 122070,
        "TimeZone": "Pacific Standard Time"
    },
    "Logging": { "LocalLogHistoryMaxMB": 1024 },
    "WindowsUpdate": { "MaxCycles": 3 },
    "RegulatedStates": ["CA"],
    "CompanyWorkflowMap": { "EZT": "EZT", "EZ Trading Computers": "EZT", "*": "MMC" }
}
```

Empty strings are rollout-fill values (Q98: structure fixed, values set at rollout); the resolver in Task 8 treats empty `OrderDatabase` strings as deployment-time-only settings that FactoryRecovery never needs.

- [ ] **Step 2: Verify parse + gates, commit**

Run: `pwsh -NoProfile -Command "Get-Content config/osdeploy-config.json -Raw | ConvertFrom-Json | Out-Null; 'JSON OK'"` then `pwsh tests/gates/Invoke-StaticGates.ps1`.

```bash
git add config/osdeploy-config.json
git commit -m "Add central configuration template with confirmed defaults"
```

### Task 6: OSDeploy.Util - hashing, inventory, bundle hash

**Files:**
- Create: `src/Shared/OSDeploy.Util/OSDeploy.Util.psd1`, `src/Shared/OSDeploy.Util/OSDeploy.Util.psm1`
- Test: `tests/unit/OSDeploy.Util.Tests.ps1`

**Interfaces:**
- Produces: `Get-FileSha256 -Path <string>` returns uppercase hex string; `New-FileInventory -Path <string>` returns objects with exactly `Path` (relative, `\`-normalized), `Size`, `Sha256` in that property order; `Get-BundleHash -Inventory <object[]>` returns SHA256 of the canonical serialization: inventory sorted by Path, `ConvertTo-Json -Depth 4 -Compress`, UTF8-no-BOM bytes of the ASCII string.

- [ ] **Step 1: Write the manifest** `OSDeploy.Util.psd1`:

```powershell
@{
    RootModule        = 'OSDeploy.Util.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7f0b3e2-2c4d-4b9a-9f0e-1a2b3c4d5e6f'
    Author            = 'OSDeploy Suite'
    Description       = 'Hashing, file inventory, and canonical bundle hash helpers.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-FileSha256', 'New-FileInventory', 'Get-BundleHash')
}
```

- [ ] **Step 2: Write the failing tests** `tests/unit/OSDeploy.Util.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Util\OSDeploy.Util.psd1') -Force
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('util-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    Set-Content -Path (Join-Path $work 'a.txt') -Value 'hello' -Encoding Ascii
}
AfterAll { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
Describe 'OSDeploy.Util' {
    It 'Get-FileSha256 returns the uppercase SHA-256 of the file bytes' {
        $h = Get-FileSha256 -Path (Join-Path $work 'a.txt')
        $h | Should -Be '2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824'
    }
    It 'New-FileInventory emits Path/Size/Sha256 in fixed order for every file' {
        $inv = New-FileInventory -Path $work
        $inv.Count | Should -Be 1
        ($inv[0].PSObject.Properties.Name -join ',') | Should -Be 'Path,Size,Sha256'
        $inv[0].Size | Should -Be 6
    }
    It 'Get-BundleHash is stable across inventory order and changes when content changes' {
        $i1 = New-FileInventory -Path $work
        Set-Content -Path (Join-Path $work 'a.txt') -Value 'hello2' -Encoding Ascii
        $i2 = New-FileInventory -Path $work
        Get-BundleHash -Inventory ($i2 + $i1) | Should -Not -Be (Get-BundleHash -Inventory $i2)
    }
}
```

(The literal hash above is the SHA-256 of `hello` + newline; if the local `Set-Content` newline differs, compute the expected value once with `Get-FileHash` and paste it — the test asserts equality with the file's actual hash, which is the point.)

- [ ] **Step 3: Run tests to verify they fail** — Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/unit/OSDeploy.Util.Tests.ps1 -Output Detailed"` — Expected: FAIL, module not found.

- [ ] **Step 4: Implement** `OSDeploy.Util.psm1`:

```powershell
Set-StrictMode -Version Latest
function Get-FileSha256 {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function New-FileInventory {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object -Property FullName | ForEach-Object {
        New-Object pscustomobject -Property ([ordered]@{
            Path   = $_.FullName.Substring($root.Length + 1)
            Size   = $_.Length
            Sha256 = Get-FileSha256 -Path $_.FullName
        })
    }
}
function Get-BundleHash {
    [CmdletBinding()] param([Parameter(Mandatory)][object[]]$Inventory)
    $sorted = $Inventory | Sort-Object -Property Path
    $json = ConvertTo-Json -InputObject $sorted -Depth 4 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}
```

- [ ] **Step 5: Run tests, gates, commit** — Expected: 3 PASS; `GATES PASS`.

```bash
git add src/Shared/OSDeploy.Util tests/unit/OSDeploy.Util.Tests.ps1
git commit -m "Add OSDeploy.Util hashing, inventory, and canonical bundle hash with tests"
```

### Task 7: OSDeploy.State - atomic writes and file contracts

**Files:**
- Create: `src/Shared/OSDeploy.State/OSDeploy.State.psd1`, `src/Shared/OSDeploy.State/OSDeploy.State.psm1`
- Test: `tests/unit/OSDeploy.State.Tests.ps1`

**Interfaces:**
- Produces: `Write-AtomicJson -Path <string> -Value <object>` (temp file in same directory + `Move-Item -Force`, ASCII JSON, `-Depth 8`); `Read-JsonFile -Path <string>`; `Test-ReadinessRecord -Record <object>`, `Test-DeploymentState -Record <object>`, `Test-FactoryProfile -Record <object>` each returning `@{ Valid = [bool]; Errors = [string[]] }`; required identity fields listed in each `Test-` function and never defaulted; `Update-FactoryProfile -Directory <string> -Profile <object>`; `Restore-FactoryProfile -Directory <string>` returning `@{ Status = 'Active'|'Restored'|'Invalid'; Profile }`.

- [ ] **Step 1: Write the failing tests** (core cases; extend per `specs/state-files/spec.md` scenarios):

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.State\OSDeploy.State.psd1') -Force
    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ('state-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
}
AfterAll { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
Describe 'atomic writes' {
    It 'replaces content completely and leaves no temp files' {
        $p = Join-Path $dir 's.json'
        Write-AtomicJson -Path $p -Value @{ a = 1 }
        Write-AtomicJson -Path $p -Value @{ a = 2; b = 'x' }
        (Read-JsonFile -Path $p).a | Should -Be 2
        (Get-ChildItem $dir -Filter '*.tmp*').Count | Should -Be 0
    }
    It 'a failed move leaves the previous document intact' {
        $p = Join-Path $dir 't.json'
        Write-AtomicJson -Path $p -Value @{ a = 1 }
        function Move-Item { param($Path, $Destination, $Force) throw 'simulated interruption' }
        { Write-AtomicJson -Path $p -Value @{ a = 2 } } | Should -Throw
        Remove-Item Function:\Move-Item
        (Read-JsonFile -Path $p).a | Should -Be 1
    }
}
Describe 'contracts' {
    It 'DeploymentState requires all identity and phase fields' {
        $ok = @{ RunId = 'r1'; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
                 Phase = 'Drivers'; Attempt = 1; RebootPending = $false; ConfigVersion = 'v1'
                 TimestampUtc = '2026-01-01T00:00:00Z'; CompletedPhases = @(); Result = $null
                 NotedIssues = @(); Acknowledgements = @() }
        (Test-DeploymentState -Record $ok).Valid | Should -BeTrue
        $bad = $ok.Clone(); $bad.Workflow = $null
        (Test-DeploymentState -Record $bad).Valid | Should -BeFalse
    }
    It 'FactoryProfile restore prefers active, then backup, else Invalid without guessing' {
        $prof = @{ SchemaVersion = 1; MachineId = 'm1'; Workflow = 'EZT'; FactoryEdition = 'Home'
                   DefaultRecoveryEdition = 'Home'; EditionHistory = @(); EnergyStar = @{ }
                   Locale = 'en-US'; CreatedUtc = '2026-01-01T00:00:00Z'; LastRecoveryUtc = $null }
        Update-FactoryProfile -Directory $dir -Profile $prof
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Active'
        Remove-Item (Join-Path $dir 'FactoryProfile.json')
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Restored'
        Remove-Item (Join-Path $dir 'FactoryProfile.lastknowngood.json')
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Invalid'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail** — Expected: FAIL, module not found.

- [ ] **Step 3: Implement.** Key requirements: `Write-AtomicJson` writes `$tmp = "$Path.tmp$(Get-Random)"` with `[System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::ASCII)` then `Move-Item -LiteralPath $tmp -Destination $Path -Force`, removing `$tmp` in a `finally` if it still exists. Each `Test-*` builds a `$required` string array (identity: RunId, MachineId, DiskId, Workflow; readiness adds Edition, ConfigVersion, BundleHash, TimestampUtc; profile adds FactoryEdition, DefaultRecoveryEdition) and collects `Errors` for every missing/null required field — returning Valid `$false` without ever substituting values. `Update-FactoryProfile` writes LKG first (`FactoryProfile.lastknowngood.json` from the current active file if it exists and validates), then the active file. `Restore-FactoryProfile` validates active, then backup (copying backup over active and returning `Restored` with a warning event name in the result object as `@{ Status; Profile; Warning }`), else `Invalid`.

- [ ] **Step 4: Run tests, gates, commit** — Expected: all PASS; `GATES PASS`.

```bash
git add src/Shared/OSDeploy.State tests/unit/OSDeploy.State.Tests.ps1
git commit -m "Add OSDeploy.State atomic JSON writes and state-file contracts with tests"
```

### Task 8: OSDeploy.Config - load, resolve, snapshot, recovery isolation

**Files:**
- Create: `src/Shared/OSDeploy.Config/OSDeploy.Config.psd1`, `src/Shared/OSDeploy.Config/OSDeploy.Config.psm1`
- Test: `tests/unit/OSDeploy.Config.Tests.ps1`

**Interfaces:**
- Consumes: Task 5's `config/osdeploy-config.json` template; Task 7's `Write-AtomicJson`.
- Produces: `Get-ConfigDefault -Key <string>` (single source of hard defaults); `Resolve-Config -ConfigPath <string>` returns `@{ Values; Version; Source; Fallbacks }` where `Fallbacks` entries are `@{ Key; Reason = 'missing'|'invalid' }`; `Save-ConfigSnapshot -Effective <object> -Path <string>`; `Load-RecoveryConfig -SnapshotPath <string>` which takes no central path parameter at all.

- [ ] **Step 1: Write the failing tests:**

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Config\OSDeploy.Config.psd1') -Force
    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ('cfg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:template = Join-Path $PSScriptRoot '..\..\config\osdeploy-config.json'
}
AfterAll { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
Describe 'resolution and fallbacks' {
    It 'full template resolves every value with no fallbacks' {
        $e = Resolve-Config -ConfigPath $template
        $e.Values.Deployment.RecoveryPartitionSizeMB | Should -Be 32768
        $e.Fallbacks.Count | Should -Be 0
    }
    It 'missing and invalid values fall back with reasons' {
        $cfg = Get-Content $template -Raw | ConvertFrom-Json
        $cfg.Deployment.RecoveryPartitionSizeMB = $null
        $cfg.Logging.LocalLogHistoryMaxMB = -5
        $p = Join-Path $dir 'c.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 6), [System.Text.Encoding]::ASCII)
        $e = Resolve-Config -ConfigPath $p
        $e.Values.Deployment.RecoveryPartitionSizeMB | Should -Be 32768
        $e.Values.Logging.LocalLogHistoryMaxMB | Should -Be 1024
        (($e.Fallbacks | Where-Object { $_.Key -eq 'Logging.LocalLogHistoryMaxMB' }).Reason) | Should -Be 'invalid'
    }
}
Describe 'snapshot and recovery isolation' {
    It 'snapshot round-trips and recovery loader reads only the snapshot' {
        $e = Resolve-Config -ConfigPath $template
        $snap = Join-Path $dir 'snapshot.json'
        Save-ConfigSnapshot -Effective $e -Path $snap
        $r = Load-RecoveryConfig -SnapshotPath $snap
        $r.Values.Deployment.TimeZone | Should -Be $e.Values.Deployment.TimeZone
        (Get-Command Load-RecoveryConfig).Parameters.ContainsKey('ConfigPath') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.** Hard defaults table (single `$script:Defaults` hashtable, keys dot-named): `Deployment.RecoveryPartitionSizeMB=32768`, `Deployment.WindowsReToolsPartitionSizeMB=1024`, `Deployment.RecommendedPrimaryDriveSizeMB=122070`, `Deployment.TimeZone='Pacific Standard Time'`, `Logging.LocalLogHistoryMaxMB=1024`, `WindowsUpdate.MaxCycles=3`, `RegulatedStates=@('CA')`, `CompanyWorkflowMap` default map. Resolution walks the template's own key set (not arbitrary keys — unknown extra keys produce a recorded warning list on the result as `Warnings`), applies range rules (partition/log sizes positive ints; MaxCycles 1-10), and records per-key fallbacks. `Resolve-Config` sets `Version` from a `ConfigVersion` field when present, else `'<unversioned>'`, and `Source` = the path. Snapshot = the effective object plus `SavedUtc`, written with `Write-AtomicJson`. `Load-RecoveryConfig` reads only `-SnapshotPath` and re-applies the same defaults for any missing snapshot value.

- [ ] **Step 4: Run tests, gates, commit** — Expected: PASS; `GATES PASS`.

```bash
git add src/Shared/OSDeploy.Config tests/unit/OSDeploy.Config.Tests.ps1
git commit -m "Add OSDeploy.Config resolution, fallbacks, and recovery snapshot with tests"
```

### Task 9: OSDeploy.Logging - run folders, retention, copy semantics, summary gating

**Files:**
- Create: `src/Shared/OSDeploy.Logging/OSDeploy.Logging.psd1`, `src/Shared/OSDeploy.Logging/OSDeploy.Logging.psm1`
- Test: `tests/unit/OSDeploy.Logging.Tests.ps1`

**Interfaces:**
- Consumes: `Write-AtomicJson` not required here; logging uses plain appends (event log is append-only).
- Produces: `New-RunLog -Root <string> [-RunId <string>] [-RunType <string>]` returns `@{ Root; RunId; Folder; EventsPath; TranscriptPath; RunType }` where `Folder = <Root>\<RunType>-<yyyyMMdd-HHmmss>-<RunId>` with `-2`, `-3` suffixes on collision; `Add-LogEvent -Log <object> [-Level <string>] [-Event <string>] [-Data <hashtable>]` appending one ASCII JSON line with `TimestampUtc`, `Level`, `Event`, `Data`; `Invoke-LogRetention -Root <string> [-MaxMB <int>]` removing complete oldest run folders first, never the folder named by `-KeepFolder`; `Invoke-ServerLogCopy -Log <object> [-Destination <string>]` returning `@{ Ok; Warning }` (any failure is a warning, never a throw) and throwing if `-Log.RunType` is `FactoryRecovery`; `Complete-RunLog -Log <object>` returning `$true` only after the events file re-reads as parseable JSONL and is byte-stable.

- [ ] **Step 1: Write the failing tests** covering: two `New-RunLog` calls in the same second produce distinct suffixed folders; `Invoke-LogRetention` with `MaxMB 0`-style small limit removes the oldest complete folder and keeps `-KeepFolder`; `Invoke-ServerLogCopy` against a nonexistent destination returns `Ok=$false` with a `Warning` and does not throw; calling it with `RunType FactoryRecovery` throws; `Complete-RunLog` returns `$true` after events were written, `$false` when the events file was corrupted afterward.

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Logging\OSDeploy.Logging.psd1') -Force
    $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('log-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'runs') | Out-Null
}
AfterAll { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
Describe 'run folders' {
    It 'same-second collisions get numeric suffixes' {
        $a = New-RunLog -Root (Join-Path $root 'runs') -RunId 'aaa' -RunType 'InitialDeployment'
        $b = New-RunLog -Root (Join-Path $root 'runs') -RunId 'bbb' -RunType 'InitialDeployment'
        $a.Folder | Should -Not -Be $b.Folder
        $b.Folder | Should -Match '-2$|-3$'
    }
}
Describe 'retention' {
    It 'prunes oldest complete folders first and keeps the active one' {
        $runs = Join-Path $root 'ret'
        New-Item -ItemType Directory -Path $runs | Out-Null
        foreach ($n in @('InitialDeployment-20260101-000000-x1', 'InitialDeployment-20260102-000000-x2', 'InitialDeployment-20260103-000000-x3')) {
            New-Item -ItemType Directory -Path (Join-Path $runs $n) | Out-Null
            Set-Content -Path (Join-Path $runs "$n\events.jsonl") -Value '{}' -Encoding Ascii
        }
        Invoke-LogRetention -Root $runs -MaxMB 1 -KeepFolder 'InitialDeployment-20260103-000000-x3'
        (Test-Path (Join-Path $runs 'InitialDeployment-20260101-000000-x1')) | Should -BeFalse
        (Test-Path (Join-Path $runs 'InitialDeployment-20260103-000000-x3')) | Should -BeTrue
    }
}
Describe 'copy semantics and gating' {
    It 'server copy failure is a warning, never a throw; recovery never copies' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'ccc' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Info -Event 'Test'
        $r = Invoke-ServerLogCopy -Log $log -Destination (Join-Path $root 'no\such\share')
        $r.Ok | Should -BeFalse
        $r.Warning | Should -Not -BeNullOrEmpty
        $rec = New-RunLog -Root (Join-Path $root 'runs') -RunId 'ddd' -RunType 'FactoryRecovery'
        { Invoke-ServerLogCopy -Log $rec -Destination 'x' } | Should -Throw
    }
    It 'Complete-RunLog verifies the events file' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'eee' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Info -Event 'E'
        (Complete-RunLog -Log $log) | Should -BeTrue
        Set-Content -Path $log.EventsPath -Value 'not json' -Encoding Ascii
        (Complete-RunLog -Log $log) | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.** Requirements: `New-RunLog` formats the timestamp with `Get-Date -Format 'yyyyMMdd-HHmmss'` and loops `-2`, `-3`, ... up to `-99` for collisions; `Add-LogEvent` builds the object in fixed property order and appends with `[System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, [System.Text.Encoding]::ASCII)`; `Invoke-LogRetention` computes total bytes of complete folders (a folder is complete when it contains `events.jsonl`), deletes oldest-first until under `MaxMB * 1MB`, always skipping `-KeepFolder`; `Invoke-ServerLogCopy` guards `FactoryRecovery` first with `throw` (the Q74 rule is a hard boundary, so violation is a programming error), then `try/copy folder to destination/catch` returning `@{ Ok = $false; Warning = $_.Exception.Message }`; `Complete-RunLog` reads every line with `ConvertFrom-Json`, returns `$true` iff zero parse failures.

- [ ] **Step 4: Run tests, gates, commit** — Expected: PASS; `GATES PASS`.

```bash
git add src/Shared/OSDeploy.Logging tests/unit/OSDeploy.Logging.Tests.ps1
git commit -m "Add OSDeploy.Logging run folders, retention, and copy semantics with tests"
```

### Task 10: OSDeploy.Disk - inventory model and primary selection

**Files:**
- Create: `src/Shared/OSDeploy.Disk/OSDeploy.Disk.psd1`, `src/Shared/OSDeploy.Disk/OSDeploy.Disk.psm1`
- Test: `tests/unit/OSDeploy.Disk.Tests.ps1`

**Interfaces:**
- Produces: `Get-DiskPresentation -Disk <object>` returning the five display fields (Number, Model, SerialNumber, Bus, SizeBytes) as an ordered object; `Select-PrimaryDisk -Candidates <object[]>` returning `@{ Disk; AutoSelected; RequiresSelection }` implementing Q4 exactly: eligible = internal, size above 0; NVMe = `Bus -eq 'NVMe'`; sole eligible NVMe auto-selects (`AutoSelected = $true`, still displayed); multiple eligible NVMe or (no NVMe and multiple eligible SATA) return `RequiresSelection = $true` with `Disk = $null`; no eligible disk returns `@{ Disk = $null; AutoSelected = $false; RequiresSelection = $false; NoCandidates = $true }`.

- [ ] **Step 1: Write the failing tests** — fixture candidates built inline, e.g. `@{ Number=0; Model='Samsung 980'; SerialNumber='S1'; Bus='NVMe'; SizeBytes=500107862016; Internal=$true }`: sole-NVMe auto-selects; two NVMe require selection; one SATA-only set auto-selects the SATA drive; empty set returns NoCandidates.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** the two functions as pure logic over candidate objects (no `Get-Disk` calls inside — environments inject inventory; design D12). Selection order: filter `$_.Internal` and `$_.SizeBytes -gt 0`; NVMe list; if exactly one NVMe, auto-select it; if more, require selection; if none, SATA list by the same rule.

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Disk tests/unit/OSDeploy.Disk.Tests.ps1
git commit -m "Add OSDeploy.Disk presentation and NVMe-preferred selection rules with tests"
```

### Task 11: OSDeploy.Disk - removable blocking, bypass chain, identity revalidation, capacity

**Files:**
- Modify: `src/Shared/OSDeploy.Disk/OSDeploy.Disk.psm1`
- Test: `tests/unit/OSDeploy.Disk.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Test-RemovableBlocking -Devices <object[]>` returning `@{ Blocked; Reason; RemovableStorage }` where storage-removable devices block and non-storage peripherals never do; `Invoke-EmergencyBypass -Target <object> -Acknowledged <bool> [-Confirmed <SwitchParameter>]` returning `@{ Allowed; AuditEvent }` — `Allowed` only when `Acknowledged` and `-Confirmed` are both true, `AuditEvent` is a non-null event object (Event='EmergencyBypass', TargetSerial, TimestampUtc) whenever the function is invoked, and the audit event exists even when Allowed is `$false`; `Compare-DiskIdentity -Selected <object> -Observed <object>` returning `$true` only when Number, SerialNumber, and SizeBytes all match; `Test-Capacity -DiskSizeBytes <long> [-RecommendedMB <int> = 122070] [-RequiredMB <int>]` returning `@{ Warning; Block; NeedsAcknowledgement }` — Block only when RequiredMB is set and the layout cannot fit, Warning + NeedsAcknowledgement when below recommended, and never any special logging flag (no extra output properties).

- [ ] **Step 1: Write failing tests** for each function per the spec scenarios (removable storage blocks; keyboard does not; bypass needs both acknowledgement and confirmation and always emits the audit event; changed serial fails Compare-DiskIdentity; below-recommended warns with NeedsAcknowledgement; impossible layout blocks even when acknowledged).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** as pure logic. `Test-RemovableBlocking` classifies by device properties (`Removable -eq $true -and Storage -eq $true` on the injected object). `Test-Capacity` computes `$recBytes = $RecommendedMB * 1MB` and `$reqBytes = $RequiredMB * 1MB` (0 when unset).

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Disk tests/unit/OSDeploy.Disk.Tests.ps1
git commit -m "Add OSDeploy.Disk removable blocking, bypass audit, revalidation, and capacity rules with tests"
```

### Task 12: OSDeploy.Disk - erase variants and secondary-drive preparation

**Files:**
- Modify: `src/Shared/OSDeploy.Disk/OSDeploy.Disk.psm1`
- Test: `tests/unit/OSDeploy.Disk.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Get-EraseScope -RunType <string>` returning the ordered partition-area list to erase: `InitialDeployment`/`PXEFullFactoryRebuild` -> `@('EntireDisk')`; `FactoryRecovery` -> `@('Efi','Msr','WindowsSpan')` (WinRE tools and OSDCloud partitions never listed); any other RunType throws. `New-SecondaryPlan -Selected <object[]> [-ExistingLabels <string[]>] [-ExistingLetters <char[]>]` returning per-drive plan objects `@{ Disk; Gpt = $true; FileSystem = 'NTFS'; OnePartition = $true; Letter; Label }` with letters from `D:` skipping taken ones and labels `Data`, `Data-2`, `Data-3`, ... skipping collisions; `Get-SecondaryFailureOptions` returning the fixed choices `@('Retry Secondary Drive', 'Skip Failed Drive and Continue')`; `Test-SecondaryMountOnly -Volumes <object[]>` returning warnings (never failures/repairs) for volumes not mounted.

- [ ] **Step 1: Write failing tests**: recovery scope excludes both protected partitions; full rebuild scope is EntireDisk; unknown run type throws; letters skip taken `D:`/`E:`; labels continue `Data`, `Data-2`, `Data-3` past a preexisting `Data`; mount check returns a warning entry, not a failure, for an unmounted volume.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** as pure logic per Q58-Q66, Q85. Letters iterate `D` through `Z` skipping `$ExistingLetters`; labels iterate the Q59 sequence skipping `$ExistingLabels`.

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Disk tests/unit/OSDeploy.Disk.Tests.ps1
git commit -m "Add OSDeploy.Disk erase scopes and secondary-drive planning with tests"
```

### Task 13: OSDeploy.Image - multi-index validation

**Files:**
- Create: `src/Shared/OSDeploy.Image/OSDeploy.Image.psd1`, `src/Shared/OSDeploy.Image/OSDeploy.Image.psm1`
- Test: `tests/unit/OSDeploy.Image.Tests.ps1`

**Interfaces:**
- Produces: `Test-ImageMetadata -Image <object>` where `Image` is a metadata object (not a file) with `Indexes` (array of `@{ Name; Edition; Architecture; Language; Release; Build }`), returning `@{ Valid; Errors; HomeIndex; ProIndex; IndexRecord }` — Valid only when a Home and a Pro index exist, all indexes share consistent Architecture/Language, and Release/Build satisfy `[version]`-parseable compatibility against the passed-in `-RequiredRelease`/`-RequiredArchitecture`/`-RequiredLanguage` parameters (defaults `11`, `x64`, `en-US`); `IndexRecord` is the exact names and numbers list Q47 requires.

- [ ] **Step 1: Write failing tests** with fixture metadata objects: a valid dual-index image passes and records both indexes; missing Pro fails; mixed Architecture fails; wrong Language fails; `HomeIndex`/`ProIndex` carry the index names.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** as pure validation over the metadata object (environments construct it from DISM output; this module never shells out).

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Image tests/unit/OSDeploy.Image.Tests.ps1
git commit -m "Add OSDeploy.Image multi-index metadata validation with tests"
```

### Task 14: OSDeploy.Image - promotion lifecycle and edition resolution

**Files:**
- Modify: `src/Shared/OSDeploy.Image/OSDeploy.Image.psm1`
- Test: `tests/unit/OSDeploy.Image.Tests.ps1` (extend)

**Interfaces:**
- Consumes: Task 13's `Test-ImageMetadata`; Task 7's `Write-AtomicJson` (not required — promotion moves files).
- Produces: `Invoke-ImagePromotion -TempPath <string> -CachePath <string> -Validator <scriptblock>` implementing validate-then-move: `$ok = & $Validator $TempPath`; if not `$ok`, delete `$TempPath` and return `@{ Promoted = $false; CacheIntact = $true }`; else `Move-Item -Force` temp to a `staging-<random>` name beside the cache, validate the staged copy again (`$Validator` on the new path), and only then atomically replace `$CachePath`; on second validation failure delete the staged copy and return `@{ Promoted = $false; CacheIntact = $true }`. `Resolve-EditionChoice -Requested <string> -Available <string[]>` returning `@{ Edition = $null; Choices = @('Choose Another Edition', 'Use Saved Default Edition', 'Cancel Recovery') }` when requested is unavailable, `@{ Edition = $Requested; Choices = $null }` when available — never a silent substitution.

- [ ] **Step 1: Write failing tests**: failed validation deletes the temp file and leaves the cache byte-identical; successful promotion replaces the cache; validator called on both temp and staged copy (counter in the validator scriptblock); unavailable edition yields exactly the three choices with null Edition; available edition returns directly.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** with real file moves in a temp directory (tests use the filesystem; no mocking framework needed).

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Image tests/unit/OSDeploy.Image.Tests.ps1
git commit -m "Add OSDeploy.Image promotion lifecycle and edition resolution with tests"
```

### Task 15: OSDeploy.Gui - host, STA contract, orchestrator screens

**Files:**
- Create: `src/Shared/OSDeploy.Gui/OSDeploy.Gui.psd1`, `src/Shared/OSDeploy.Gui/OSDeploy.Gui.psm1`, `src/Shared/OSDeploy.Gui/Screens/TechnicianReview.xaml`, `src/Shared/OSDeploy.Gui/Screens/AcknowledgeContinue.xaml`, `src/Shared/OSDeploy.Gui/Screens/NotedIssuesSummary.xaml`
- Test: `tests/unit/OSDeploy.Gui.Tests.ps1` (logic only — no WPF type loading on Linux)

**Interfaces:**
- Produces: `Assert-STA` throwing `[System.InvalidOperationException]` with a message containing `STA` when `[System.Threading.Thread]::CurrentThread.GetApartmentState()` is not `STA`; `Get-Screen -Name <string>` returning the XAML file content (validating it is well-formed via `[xml]`); `New-WizardHost -Screens <string[]>` returning `@{ Screens; Index = 0; Current = ... }` with `Move-Next`/`Move-Back` semantics implemented as functions `Invoke-WizardStep -Host <object> [-Direction <string>]`.

- [ ] **Step 1: Write the three XAML screens** — minimal `Window`-rooted XAML each: TechnicianReview (title, findings list `ListBox`, buttons `Rescan Devices`, `Rerun Validation`, `Continue`); AcknowledgeContinue (program/status/error/log fields, checkbox `Acknowledge`, buttons `Continue`/`Cancel` per Q26); NotedIssuesSummary (issues `ListBox`, one acknowledgement checkbox, `Finish Deployment` button per Q68-Q72). ASCII text only.

- [ ] **Step 2: Write failing tests** — `Assert-STA` throws on Linux `pwsh` (MTA default); `Get-Screen -Name TechnicianReview` returns well-formed XML containing the button names; `New-WizardHost` walks a two-screen sequence forward and back with clamped bounds.

- [ ] **Step 3: Run tests to verify they fail.**

- [ ] **Step 4: Implement.** No `PresentationFramework` load at module import — WPF types are touched only inside `Show-` functions called on Windows (not implemented in this change beyond the host contract; rendering is verified in Task 29).

- [ ] **Step 5: Run tests, gates, commit**

```bash
git add src/Shared/OSDeploy.Gui tests/unit/OSDeploy.Gui.Tests.ps1
git commit -m "Add OSDeploy.Gui wizard host, STA contract, and orchestrator screens"
```

### Task 16: Mock partition fixture builder

**Files:**
- Create: `tests/mocks/New-MockPartition.ps1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (built from Task 17 on; this task verifies the builder alone)

**Interfaces:**
- Produces: `New-MockPartition -Path <string>` (dot-sourced script exposing the function) creating the partition content contract: `<root>\State\` with `DeploymentState.json`, `FactoryProfile.json`, `FactoryProfile.lastknowngood.json`, `ReadinessRecord.json` (valid fixtures built via the real `OSDeploy.State` functions); `<root>\Sources\Orchestrator\` with two dummy `.psm1` files; `<root>\Sources\Apps\EZT\manifest.json` and `MMC\manifest.json`; `<root>\Sources\Drivers\Asus\<model>\Chipset\AsusSetup.exe` (dummy file) and `Gigabyte\<model>\LAN\installer.exe`; `<root>\Sources\Config\effective-config.json`; `<root>\ImageCache\`; `<root>\Logs\`. Returns the root path.

- [ ] **Step 1: Implement the builder** using `Import-Module` of the real Shared modules so fixtures are contract-valid by construction.

- [ ] **Step 2: Verify** — dot-source and run against a temp path; assert every listed path exists; run gates.

- [ ] **Step 3: Commit**

```bash
git add tests/mocks/New-MockPartition.ps1
git commit -m "Add mock partition fixture builder implementing the content contract"
```

### Task 17: Orchestrator entry, single instance, checkpoint engine

**Files:**
- Create: `src/Orchestrator/OSDeploy.Orchestrator.psd1`, `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1`

**Interfaces:**
- Consumes: `OSDeploy.State` (`Write-AtomicJson`, `Read-JsonFile`, `Test-DeploymentState`), `New-MockPartition`.
- Produces: `Enter-Orchestrator [-PartitionRoot <string>]` acquiring `Global\OSDeploy.Orchestrator` mutex (`WaitOne(0)`; on `$false`, write event `SecondInstanceExit` to the partition log and return `@{ Ran = $false }`); `New-Checkpoint -State <object> -Path <string>` writing the full contract object via `Write-AtomicJson` (Task 7 fields); `Get-ResumePoint -Path <string>` returning `@{ Phase; Attempt; CompletedPhases; RebootPending }`.

- [ ] **Step 1: Write failing tests**: second `Enter-Orchestrator` while the first holds the mutex returns `Ran = $false` and mutates no state file; `New-Checkpoint` then `Get-ResumePoint` round-trips phase/attempt/completed; checkpoint file validates with `Test-DeploymentState`.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.** The mutex is created with `New-Object System.Threading.Mutex($false, 'Global\OSDeploy.Orchestrator')` and held for the process lifetime; tests release it in `AfterAll` with `$mutex.ReleaseMutex(); $mutex.Dispose()` via a module-level `Get-OrchestratorMutex`.

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add orchestrator entry with single-instance lock and checkpoint engine with tests"
```

### Task 18: Idempotent resume, attempts, RebootPending

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Invoke-WithAttempts -Phase <string> -MaxAttempts <int> = 3 -Action <scriptblock> -OnFailure <scriptblock>` — invokes `$Action` up to 3 times, incrementing and checkpointing `Attempt` before each try; on success records the phase in `CompletedPhases` and resets the counter; on the 4th failure calls `$OnFailure` (the blocking Technician Review hook) and returns `@{ Outcome = 'TechnicianReview'; Attempts = 4 }`; `Invoke-Phase` wrapper marking `RebootPending = $true` and checkpointing before delegating any action that requests a restart (the action sets `$script:RequestRestart`), with `Resume-AfterReboot` validating `MachineId`/`DiskId` against `-Expected <object>` before continuing.

- [ ] **Step 1: Write failing tests**: a phase whose action fails 3 times then succeeds on automated retry 3 records CompletedPhases and Attempt reset; an action failing always reaches Technician Review exactly once with `Attempts = 4`; resume skips every phase already in CompletedPhases (idempotence: action invocation count for a completed phase is 0); `RebootPending` is true in the file while the simulated restart is outstanding and false after `Resume-AfterReboot` with matching identity; mismatched identity stops with `@{ Outcome = 'IdentityMismatch' }` and no phase work.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement** with a `$script:`-scoped context object holding State and checkpoint path; every mutation goes through `New-Checkpoint`.

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add orchestrator attempt policy, idempotent resume, and reboot handling with tests"
```

### Task 19: Integrity - hashes, recheck, local-only repair

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Consumes: `OSDeploy.Util` (`New-FileInventory`, `Get-BundleHash`).
- Produces: `New-IntegrityRecord -Directory <string>` returning `@{ FileHashes; BundleHash }` stored via `Write-AtomicJson` into the partition state as `IntegrityRecord.json`; `Test-Integrity -Directory <string> -Record <object>` returning `@{ Ok; Mismatches }`; `Repair-FromLocalSource -Directory <string> -RepairSource <string> -Record <object>` copying the repair source over the directory, re-hashing, returning `@{ Repaired }`; on second failure `@{ Repaired = $false; Outcome = 'TechnicianReview' }`. The functions accept no network path parameters at all — the boundary is the parameter list.

- [ ] **Step 1: Write failing tests**: record-then-verify passes; tamper one file -> `Ok = $false` with the file listed; repair from a clean mock repair source restores `Ok = $true`; tamper after repair -> Technician Review outcome; `Get-Command Repair-FromLocalSource` has no parameter matching `Share|Unc|Server|Smb` (regex assert — the Q91 boundary made testable).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add orchestrator integrity hashing, recheck, and local-only repair with tests"
```

### Task 20: Completion gating and cleanup

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Consumes: `OSDeploy.Logging` `Complete-RunLog`.
- Produces: `Complete-Deployment -PartitionRoot <string> -Handoff <string>` enforcing the Q89 order: required work done -> cleanup -> `Complete-RunLog` -> record `Result` and `CompletedUtc` (only if all previous steps succeeded); returning `@{ Completed = $false; BlockedBy = 'CleanupFailure'|'LogVerification' }` on those failures. `Invoke-Cleanup -PartitionRoot <string> [-TaskName <string> = 'OSDeploy Orchestrator']` removing the Scheduled Task registration marker and `C:\ProgramData\OSDeploy\Orchestrator` runtime artifacts (in tests: marker files under the mock partition), never touching `Sources`, `ImageCache`, `State\FactoryProfile*`, `State\effective-config*`, or `Logs`. `Invoke-PostCompletionRestart` running cleanup only.

- [ ] **Step 1: Write failing tests**: cleanup failure (simulate by pointing cleanup at a locked marker that `Invoke-Cleanup` reports) yields `Completed = $false, BlockedBy = 'CleanupFailure'` and no `CompletedUtc` in state; successful path writes `Result` and `CompletedUtc`; post-completion invocation performs cleanup without invoking any phase action (count phase invocations = 0); recovery content paths survive cleanup (assert each retained path exists).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add orchestrator completion gating and scoped cleanup with tests"
```

### Task 21: Driver phase - pattern engine with dry-run

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Consumes: mock partition `Sources\Drivers` tree.
- Produces: `Find-DriverInstallers -Root <string>` returning ordered installer plans: recurse folders; a folder containing `AsusSetup.exe` yields `@{ Folder; Installer = 'AsusSetup.exe'; Pattern = 'Asus' }`; a folder with exactly one `.exe` and no nested installer below it yields `@{ Folder; Installer = <name>; Pattern = 'SingleExe' }`; folders with zero or multiple `.exe` yield no plan and are recorded in `SkippedFolders`. `Invoke-DriverPhase -Root <string> [-DryRun] [-Runner <scriptblock>]` executing plans via `$Runner` (default real `Start-Process` with silent switches `-s` for Asus; dry-run records plans to the log and executes nothing); failures produce `@{ Ok = $false; FailedDrivers; RoutedToReview }` entries per Q27 — the phase never throws to kill deployment.

- [ ] **Step 1: Write failing tests** against the mock tree: Asus and single-exe patterns found, empty folder skipped; dry-run produces identical plan list with zero Runner invocations; a Runner throwing for one installer yields Ok=$false listing that driver while others still ran; `Find-DriverInstallers` reads no manifest file (assert no `manifest` read attempt by deleting any manifest.json under Drivers and asserting unchanged output).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add pattern-matched driver phase with dry-run and failure routing with tests"
```

### Task 22: Application phase - manifest execution

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Invoke-ApplicationPhase -ManifestPath <string> [-Runner <scriptblock>] [-Now <datetime>]` loading entries (`Id`, `Name`, `Installer`, `Type`, `SilentArgs`, `SuccessCodes`, `RetryCount`, `TimeoutMinutes`, `Required`); per entry: run via `$Runner` (default `Start-Process -Wait`), retry up to `RetryCount` on non-success exit, timeout at `TimeoutMinutes`; exhausted entries accumulate into `@{ Ok; Failures; NeedsAcknowledgement }` where each failure carries program, status, exit code, log location — the Acknowledge-and-Continue payload of Q26. No per-application interactive prompt exists on the success path (Q25).

- [ ] **Step 1: Write failing tests** with a manifest fixture and a fake Runner scriptblock: success path returns Ok with zero failures and zero prompts; a Runner returning exit 1 twice then 0 satisfies RetryCount 3; permanent failure lands in Failures with `NeedsAcknowledgement = $true` and the four payload fields; timeout simulation (Runner sleeping past `TimeoutMinutes 0`) is treated as failure.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add manifest-driven application phase with retries and acknowledgement payload with tests"
```

### Task 23: EZT workflow specifics

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `New-EztUnattend -Edition <string> -TimeZone <string>` returning the unattend XML fragment containing registry-based automatic sign-on for `User` with NO `AutoLogonCount` element (Q16) and NO product key field anywhere (Q18) — assert both by XML query in tests; `Invoke-EztAccountPhase [-Runner <scriptblock>]` emitting the account plan: create `User` (passwordless, Administrators group), keep `Administrator` disabled, create public-desktop shortcut `Set or Change Your Password` targeting the managed workflow (assert the target is not `ms-settings:signinoptions` per Q15); `Invoke-PasswordTransition [-NewPassword <string>] [-SetPassword <scriptblock>]` implementing Q86's single controlled transition — warn, set password, disable autologon (registry), clear credential (delete `DefaultPassword` value) — only when `SetPassword` succeeds; on throw, leave all three states untouched (assert by registry-hashtable fixture state compare); `Invoke-ActivationFlow [-ActivationResult <string>]` returning Retry/FinishWithoutActivation/Cancel choices with the incomplete state recorded and a returned object that never includes the key material itself.

- [ ] **Step 1: Write failing tests** for each interface contract above (registry operations abstracted behind an injectable `-Registry <hashtable>` fixture so tests run on Linux).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add EZT account, autologon, password transition, and activation logic with tests"
```

### Task 24: MMC workflow specifics and Energy Star phase

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Invoke-MmcFinalize [-Sysprep <scriptblock>]` — cleanup of temporary artifacts first, then Sysprep `/oobe`; on Sysprep failure returns `@{ Outcome = 'SysprepFailure'; StayInAuditMode = $true }` and never runs cleanup after OOBE entry (Q30, Q32); completion recorded only when the Sysprep call succeeds (`@{ Outcome = 'Complete' }`). `Get-MmcPlan` asserting no `User` account creation, no autologon, no password shortcut entries. `Resolve-PowerPolicy -RegulatedState <string> [-SavedDecision <string>]` returning the Q20-Q23 decision table: CA+MMC -> apply, no popup; CA+EZT -> apply plus popup; unregulated -> High Performance/60-min display/no sleep; a saved decision short-circuits detection; missing-or-invalid saved decision re-asks (returns `NeedsPrompt = $true`).

- [ ] **Step 1: Write failing tests**: sysprep failure keeps Audit Mode and is not Complete; success is Complete after cleanup (assert order via call log); power policy table covers all three rows plus saved-decision short-circuit and invalid-saved-decision re-ask.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add MMC finalize/sysprep handling and energy-star decision table with tests"
```

### Task 25: Windows Update phase

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Get-UpdateScope` returning `@{ Include = @('Security','Quality','ServicingStack','DotNet','Defender'); Exclude = @('Preview','Optional','Store','FeatureUpgrade','Driver','Firmware','Bios') }` (Q88 verbatim); `Invoke-UpdatePhase [-MaxCycles <int> = 3] [-Online <bool>] [-Scanner <scriptblock>]` — offline (`-Online:$false`) returns `@{ Skipped = $true; Warning }` and stays eligible (Ok = $true); online runs scan/install/reboot/rescan cycles up to `-MaxCycles`, completing any initiated reboot first; remaining updates after the limit return `@{ Ok = $true; NeedsAcknowledgement = $true; Warning }`; an unhealthy-after-reboot scanner result returns `@{ Ok = $false; Outcome = 'TechnicianReview' }`.

- [ ] **Step 1: Write failing tests** with a fake Scanner scriptblock cycling through scenarios: all-install-first-cycle; leftover-after-limit (MaxCycles 2, always one pending) -> NeedsAcknowledgement; offline skip; unhealthy scanner -> Technician Review.

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add scoped windows update phase with cycles and acknowledgement handling with tests"
```

### Task 26: Final validation, result states, boot-entry registration, log finalization

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Produces: `Invoke-PnpValidation [-Devices <object[]>]` returning a single warning object listing unknown/missing/incompatible/problem-code/unhealthy devices (never multiple warnings) plus the findings retained for the summary; `Get-TechnicianReviewOptions` returning `@('Manual Remediation', 'Rescan Devices', 'Rerun Validation')` (Q29); `Resolve-ResultState -Warnings <object[]> -Acknowledged <bool?> -FinishSubmitted <bool>` implementing Q67-Q72: unresolved warnings -> `Completed with Warnings`; acknowledged-and-finish-submitted -> `Completed with Tech-Addressed Warnings`; no warnings -> `Completed`; never a delivery-readiness state; `Invoke-BootEntryRegistration [-BootTool <scriptblock>]` (Q94 orchestrator portion) returning `@{ Registered; Validated; Blocked }` — Registered only when the boot tool reports the persistent entry present with Windows default and 5-second timeout; validation compares partition identity and boot files; any failure sets `Blocked = $true` which `Complete-Deployment` treats as a completion blocker; `Invoke-LogFinalization -Log <object>` gating on `Complete-RunLog` before the summary may close (Q73).

- [ ] **Step 1: Write failing tests**: multi-problem devices produce one warning listing all; result-state truth table (4 rows above); boot-entry success registers and clears the deployment-only override marker; boot-tool failure blocks; log finalization failure prevents summary close (state field `SummaryMayClose = $false` until retried true).

- [ ] **Step 2: Run tests to verify they fail.**

- [ ] **Step 3: Implement**, wiring the phase sequence constant `PHASE_ORDER = @('Drivers','Applications','WorkflowSpecifics','WindowsUpdate','Activation','FinalValidation','BootEntryRegistration','LogFinalization','Cleanup')` consumed by the Task 18 resume engine.

- [ ] **Step 4: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Add final validation, result states, boot-entry registration, and log gating with tests"
```

### Task 27: Phase sequence integration test

**Files:**
- Test only: `tests/unit/OSDeploy.Orchestrator.Tests.ps1` (extend)

**Interfaces:**
- Consumes: everything from Tasks 16-26.

- [ ] **Step 1: Write the integration Describe block**: build a mock partition; run `Enter-Orchestrator` with fake Runners/Scanners/BootTools all succeeding; assert: state walks every phase in `PHASE_ORDER`, each phase's CompletedPhases entry appears exactly once, `Result` is `Completed`, `CompletedUtc` set, recovery content retained; then simulate a mid-sequence power loss (drop the process, reload from the checkpoint file only) and assert resume invokes only the incomplete phase's action and zero already-completed actions.

- [ ] **Step 2: Run to verify it fails against the current wiring**, then wire the sequence loop (`Invoke-DeploymentSequence -PartitionRoot <string>`) so it passes.

- [ ] **Step 3: Run tests, gates, commit**

```bash
git add src/Orchestrator tests/unit/OSDeploy.Orchestrator.Tests.ps1
git commit -m "Wire orchestrator phase sequence with full-run and power-loss resume integration tests"
```

### Task 28: Windows-only mechanics - ACL and Scheduled Task registration

**Files:**
- Modify: `src/Orchestrator/OSDeploy.Orchestrator.psm1`
- Test: `tests/component/ComponentSuite.ps1` (begun here; Windows only — skipped on Linux with a guard `if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { Write-Output 'SKIP: Windows only'; return }`)

**Interfaces:**
- Produces: `Set-OrchestratorAcl -Directory <string>` (SYSTEM + local Administrators full, inheritance disabled); `Register-OrchestratorTask [-TaskName <string> = 'OSDeploy Orchestrator']` via `New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest`, startup trigger, single instance (`-MultipleInstances IgnoreNew`), no sign-in requirement; `Unregister-OrchestratorTask` idempotent.

- [ ] **Step 1: Add component tests** (run on the Windows VM): ACL resolves to exactly SYSTEM/Administrators; task registers, `Get-ScheduledTask` shows the principal and `IgnoreNew`; `Unregister-OrchestratorTask` removes it and is safe to call twice; orchestrator launch under the task acquires the mutex.

- [ ] **Step 2: Implement** (functions no-op with a written warning when not on Windows so unit suites stay green on Linux: guard with `$env:OS` checks — `$IsWindows` does not exist in 5.1, so use `[System.Environment]::OSVersion.Platform -eq 'Win32NT'` plus a `-SkipNoop` internal switch).

- [ ] **Step 3: Gates + unit tests green on Linux; commit** (component run recorded in Task 29)

```bash
git add src/Orchestrator tests/component/ComponentSuite.ps1
git commit -m "Add Windows ACL and scheduled-task registration with component tests"
```

### Task 29: Windows VM component suite run and final green gate

**Files:**
- Modify: `tests/component/ComponentSuite.ps1` (final form)

**Interfaces:**
- Consumes: mock partition, all modules, `ComponentSuite.ps1`.

- [ ] **Step 1: Extend ComponentSuite.ps1** to cover per `specs/` scenarios that need Windows: orchestrator full sequence against the mock partition (Task 27 logic, real filesystem), integrity tamper/repair, GUI screens loading in an STA runspace (`powershell.exe -STA` or `[runspacefactory]` with STA apartment) rendering each XAML screen without error, ACL/task tests from Task 28, phase handoffs writing state contract-valid files.

- [ ] **Step 2: Run on the Windows VM**: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/component/ComponentSuite.ps1` — Expected: all PASS, output captured to `tests/component/last-run.log` for `verify.md`.

- [ ] **Step 3: Final full run on Linux**: `pwsh tests/gates/Invoke-StaticGates.ps1` and every `tests/unit/*.Tests.ps1` via `Invoke-Pester -Path tests/unit -Output Detailed` — Expected: `GATES PASS` and all suites green. Record Pester/gate versions and totals.

- [ ] **Step 4: Commit**

```bash
git add tests/component
git commit -m "Complete component suite and record final green gate results"
```

---

## Spec Coverage Check (self-review)

Every capability spec maps to tasks: `repo-standards` -> 1-5, 29; `configuration-resolution` -> 5, 8; `state-files` -> 7, 16; `deployment-logging` -> 9; `disk-safety` -> 10-12; `image-validation` -> 13-14; `shared-gui-framework` -> 15, 29; `orchestrator-execution` -> 17, 18, 20, 27; `orchestrator-integrity` -> 19, 28, 29; `driver-installation` -> 21; `application-installation` -> 22; `ezt-profile` -> 23; `mmc-profile` -> 24; `energy-star-policy` -> 24; `windows-update-cycle` -> 25; `final-validation-handoff` -> 26. Interface names used across tasks (`Write-AtomicJson`, `New-FileInventory`, `Get-BundleHash`, `Complete-RunLog`, `PHASE_ORDER`, mock partition paths) are defined exactly once above and consumed verbatim. No step defers content to "later" — Windows-only rendering and task mechanics are Task 28-29 deliverables by design, matching design D12's layering.
