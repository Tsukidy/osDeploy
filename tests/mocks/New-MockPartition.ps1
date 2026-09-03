# Mock OSDeploy Deployment Partition fixture builder (Task 16).
#
# This is a DOT-SOURCED script, not a module:
#     . (Join-Path $PSScriptRoot '..\mocks\New-MockPartition.ps1')
#     $root = New-MockPartition -Path <fresh temp path>
#
# It builds the partition CONTENT CONTRACT that every orchestrator test suite
# (Tasks 17-27) runs against and that the Phase 3 real partition engine must
# satisfy:
#
#   State\DeploymentState.json                 Write-AtomicJson; passes Test-DeploymentState
#   State\FactoryProfile.json                  Update-FactoryProfile (active copy)
#   State\FactoryProfile.lastknowngood.json    Update-FactoryProfile (backup copy)
#   State\ReadinessRecord.json                 Write-AtomicJson; passes Test-ReadinessRecord
#   State\IntegrityRecord.json                 New-IntegrityRecord over OrchestratorRuntime
#                                               (the Q90 orchestrator integrity record)
#   Sources\Orchestrator\Part1.psm1, Part2.psm1    dummy orchestrator repair source
#   Sources\Apps\EZT\manifest.json             one-entry app manifest array
#   Sources\Apps\MMC\manifest.json             one-entry app manifest array
#   Sources\Drivers\Asus\PRIME\Chipset\AsusSetup.exe    dummy payload
#   Sources\Drivers\Gigabyte\B650\LAN\installer.exe     dummy payload
#   Sources\Config\effective-config.json       Save-ConfigSnapshot of Resolve-Config run
#                                               on the repository config\osdeploy-config.json
#   OrchestratorRuntime\Part1.psm1, Part2.psm1 the staged orchestrator copy (the
#                                               suite stand-in for the deployed
#                                               C:\ProgramData\OSDeploy\Orchestrator;
#                                               exact-copy validated by the Q90 entry
#                                               gate, repaired only from Sources\Orchestrator)
#   ImageCache\                                empty directory
#   Logs\                                      empty directory
#
# Ordering contract: Sources is staged BEFORE the readiness BundleHash is
# computed (Get-BundleHash over New-FileInventory of the staged Sources tree)
# so the recorded hash is internally consistent with the tree it describes.
# OrchestratorRuntime is staged with the SAME two files as the repair source
# and its integrity record is computed AFTER both copies exist, so the record
# is internally consistent with the exact staged copy it attests (Q90).
#
# Fixture choices (documented per the task brief):
#   - Identity values are GUID-shaped FIXED test strings, so assertions are
#     deterministic across runs while keeping a realistic shape.
#   - EnergyStar carries RegulatedState 'CA' (matches the RegulatedStates hard
#     default), giving recovery-edition tests a realistic profile to read; the
#     field itself is optional for Test-FactoryProfile.
#   - effective-config.json is produced with the REAL Resolve-Config +
#     Save-ConfigSnapshot functions (the repository template exists, so the
#     real path is practical). Its Source and SavedUtc fields vary per machine
#     and run, which changes the bundle hash value but never its consistency.
#   - Rebuilding over an existing fixture path is supported: stale Factory
#     Profile copies and leftovers in ImageCache\Logs are cleared so the two
#     must-be-empty directories and the profile pair are deterministic.
#
# Windows PowerShell 5.1 compatible: no ternary, no ?? / ??= / && / ||.

# Real shared modules, so every state file is contract-valid by construction
# (never hand-written JSON).
Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.State\OSDeploy.State.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Util\OSDeploy.Util.psd1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Config\OSDeploy.Config.psd1') -Force

function New-MockPartition {
    <#
        .SYNOPSIS
        Builds the mock OSDeploy Deployment Partition content contract.

        .DESCRIPTION
        Creates the full partition fixture layout (State, Sources, ImageCache,
        Logs) using the real Shared-module functions and returns the root path.
        The path may be a directory that does not exist yet; it is created.

        .OUTPUTS
        System.String. Full path of the partition root that was created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $root = (New-Item -ItemType Directory -Path $Path -Force).FullName

    # --- Directory layout --------------------------------------------------
    $stateDir        = Join-Path $root 'State'
    $sourcesDir      = Join-Path $root 'Sources'
    $orchestratorDir = Join-Path $sourcesDir 'Orchestrator'
    $appsEztDir      = Join-Path $sourcesDir 'Apps\EZT'
    $appsMmcDir      = Join-Path $sourcesDir 'Apps\MMC'
    $asusChipsetDir  = Join-Path $sourcesDir 'Drivers\Asus\PRIME\Chipset'
    $gigabyteLanDir  = Join-Path $sourcesDir 'Drivers\Gigabyte\B650\LAN'
    $configDir       = Join-Path $sourcesDir 'Config'
    $runtimeDir      = Join-Path $root 'OrchestratorRuntime'
    $imageCacheDir   = Join-Path $root 'ImageCache'
    $logsDir         = Join-Path $root 'Logs'
    foreach ($dir in @($stateDir, $orchestratorDir, $appsEztDir, $appsMmcDir,
                       $asusChipsetDir, $gigabyteLanDir, $configDir,
                       $runtimeDir, $imageCacheDir, $logsDir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Rebuild determinism: ImageCache and Logs must be EMPTY directories, so
    # any leftover content from a previous build at this path is removed. The
    # staged orchestrator copy is cleared the same way so the Q90 integrity
    # record computed below always attests exactly the freshly staged files.
    foreach ($dir in @($imageCacheDir, $logsDir, $runtimeDir)) {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force
    }

    # --- Sources: orchestrator repair source (two dummy modules) -----------
    [System.IO.File]::WriteAllText((Join-Path $orchestratorDir 'Part1.psm1'),
        "# Dummy orchestrator module part 1 (repair-source fixture).`r`n")
    [System.IO.File]::WriteAllText((Join-Path $orchestratorDir 'Part2.psm1'),
        "# Dummy orchestrator module part 2 (repair-source fixture).`r`n")

    # --- Sources: app manifests (minimal one-entry arrays) -----------------
    # Placeholder values only; Task 22 app tests stage their own fixtures, but
    # the partition contract requires these files to exist with this shape.
    $eztApp = @{
        Id             = 'ezt-app-1'
        Name           = 'EZT Sample Utility'
        Installer      = 'EZTSetup.exe'
        Type           = 'Exe'
        SilentArgs     = '/S /norestart'
        SuccessCodes   = @(0)
        RetryCount     = 2
        TimeoutMinutes = 10
        Required       = $true
    }
    $mmcApp = @{
        Id             = 'mmc-app-1'
        Name           = 'MMC Sample Utility'
        Installer      = 'MMCSetup.exe'
        Type           = 'Exe'
        SilentArgs     = '/S /norestart'
        SuccessCodes   = @(0)
        RetryCount     = 2
        TimeoutMinutes = 10
        Required       = $true
    }
    Write-AtomicJson -Path (Join-Path $appsEztDir 'manifest.json') -Value @($eztApp)
    Write-AtomicJson -Path (Join-Path $appsMmcDir 'manifest.json') -Value @($mmcApp)

    # --- Sources: driver installers (dummy payloads) -----------------------
    [System.IO.File]::WriteAllText((Join-Path $asusChipsetDir 'AsusSetup.exe'), 'dummy')
    [System.IO.File]::WriteAllText((Join-Path $gigabyteLanDir 'installer.exe'), 'dummy')

    # --- Sources: effective-config snapshot (real resolver path) -----------
    $repoRoot   = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $configPath = Join-Path $repoRoot 'config\osdeploy-config.json'
    $effective  = Resolve-Config -ConfigPath $configPath
    Save-ConfigSnapshot -Effective $effective -Path (Join-Path $configDir 'effective-config.json')

    # --- State: DeploymentState.json (initial checkpoint) ------------------
    $now = [datetime]::UtcNow.ToString('o')
    $deploymentState = @{
        RunId            = '11111111-1111-1111-1111-111111111111'
        MachineId        = '22222222-2222-2222-2222-222222222222'
        DiskId           = '33333333-3333-3333-3333-333333333333'
        Workflow         = 'EZT'
        Edition          = 'Pro'
        Phase            = 'Drivers'
        Attempt          = 0
        RebootPending    = $false
        ConfigVersion    = 'test-v1'
        TimestampUtc     = $now
        CompletedPhases  = @()
        Result           = $null
        NotedIssues      = @()
        Acknowledgements = @()
    }
    Write-AtomicJson -Path (Join-Path $stateDir 'DeploymentState.json') -Value $deploymentState

    # --- State: FactoryProfile active + last-known-good --------------------
    $factoryProfile = @{
        SchemaVersion          = 1
        MachineId              = $deploymentState['MachineId']
        Workflow               = 'EZT'
        FactoryEdition         = 'Home'
        DefaultRecoveryEdition = 'Home'
        EditionHistory         = @()
        EnergyStar             = @{ RegulatedState = 'CA' }
        Locale                 = 'en-US'
        CreatedUtc             = $now
        LastRecoveryUtc        = $null
    }
    # Update-FactoryProfile copies the currently valid active copy into the
    # backup before committing the new profile; a stale active file from an
    # earlier build at this path would leak into the backup. Remove any
    # pre-existing pair so both copies are seeded from this profile.
    foreach ($name in @('FactoryProfile.json', 'FactoryProfile.lastknowngood.json')) {
        $stale = Join-Path $stateDir $name
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }
    Update-FactoryProfile -Directory $stateDir -Profile $factoryProfile

    # --- Orchestrator home + State: Q90 integrity record --------------------
    # The bootstrap stages the orchestrator into its deployed location (the
    # suite stand-in is <root>\OrchestratorRuntime, the simulated
    # C:\ProgramData\OSDeploy\Orchestrator) and records the automatically
    # computed SHA-256 inventory on the partition State (Q90). The repair
    # source stays Sources\Orchestrator (Q91: local partition only). The
    # record is computed AFTER the copy exists so it attests exactly the
    # staged content.
    Copy-Item -LiteralPath (Join-Path $orchestratorDir 'Part1.psm1') -Destination $runtimeDir -Force
    Copy-Item -LiteralPath (Join-Path $orchestratorDir 'Part2.psm1') -Destination $runtimeDir -Force
    # Same @{ FileHashes; BundleHash } shape New-IntegrityRecord writes,
    # computed with the Util primitives directly so this FIXTURE never needs
    # to import the module under test. The assign-then-@() unwrap mirrors
    # Get-FlatInventory exactly: New-FileInventory ends in Write-Output
    # -NoEnumerate, so the assigned value may still wear its PSObject
    # wrapper - Windows PowerShell 5.1's ConvertTo-Json serializes that
    # wrapper as { "value": [...], "Count": n } instead of an array, while
    # pwsh unwraps it silently (why every Linux run was green). @() re-wraps
    # into a plain object[] on every engine, matching the module path that
    # the Windows component run already proved correct.
    $runtimeInventory = New-FileInventory -Path $runtimeDir
    $runtimeInventory = @($runtimeInventory)
    Write-AtomicJson -Path (Join-Path $stateDir 'IntegrityRecord.json') -Value @{
        FileHashes = $runtimeInventory
        BundleHash = (Get-BundleHash -Inventory $runtimeInventory)
    }

    # --- State: ReadinessRecord.json ----------------------------------------
    # BundleHash is computed from the ALREADY-STAGED Sources tree so the
    # record is internally consistent (the readiness gate would recompute and
    # compare exactly this way after the partition boots).
    $inventory  = New-FileInventory -Path $sourcesDir
    $bundleHash = Get-BundleHash -Inventory $inventory
    $readinessRecord = @{
        RunId         = $deploymentState['RunId']
        MachineId     = $deploymentState['MachineId']
        DiskId        = $deploymentState['DiskId']
        Workflow      = 'EZT'
        Edition       = 'Pro'
        ConfigVersion = 'test-v1'
        BundleHash    = $bundleHash
        TimestampUtc  = $now
    }
    Write-AtomicJson -Path (Join-Path $stateDir 'ReadinessRecord.json') -Value $readinessRecord

    return $root
}
