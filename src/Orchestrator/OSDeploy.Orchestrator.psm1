Set-StrictMode -Version Latest

# Dependency loading (5.1-compatible choice, same pattern as OSDeploy.Config):
# '#Requires -Modules' resolves only through PSModulePath, but the shared
# modules live in sibling directories of this source tree, so they are
# imported by path relative to the module root. Import-Module is idempotent
# when the caller already loaded them.
Import-Module (Join-Path $PSScriptRoot '..\Shared\OSDeploy.State\OSDeploy.State.psd1')
Import-Module (Join-Path $PSScriptRoot '..\Shared\OSDeploy.Logging\OSDeploy.Logging.psd1')
# OSDeploy.Util supplies the integrity primitives (New-FileInventory,
# Get-BundleHash) used by the Q90/Q92 record/recheck/repair functions.
Import-Module (Join-Path $PSScriptRoot '..\Shared\OSDeploy.Util\OSDeploy.Util.psd1')

# ---------------------------------------------------------------------------
# Process-wide single-instance state (Q35/Q36: the orchestrator is
# single-instance; a concurrent second launch exits without work and without
# state mutation)
# ---------------------------------------------------------------------------

# Non-null once THIS process has entered the orchestrator and still holds the
# single-instance lock. The scheduled-task host starts one entry per process,
# so a non-null value on re-entry IS a second launch.
$script:OrchestratorMutex = $null

# Internal: record the one event a second launch is allowed to emit. This is
# the ONLY second-launch side effect: no state read, no state write, no phase
# work (Q35/Q36).
function Write-SecondInstanceExit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PartitionRoot)
    $log = New-RunLog -Root (Join-Path $PartitionRoot 'Logs') -RunType 'InitialDeployment'
    Add-LogEvent -Log $log -Event 'SecondInstanceExit'
}

# Internal: give up the single-instance lock. Used on the fatal entry-failure
# path so a failed entry cannot poison the process. Test teardown releases
# through Get-OrchestratorMutex instead.
function Clear-OrchestratorLock {
    [CmdletBinding()]
    param()
    if ($null -eq $script:OrchestratorMutex) { return }
    try { $script:OrchestratorMutex.ReleaseMutex() } catch { }
    try { $script:OrchestratorMutex.Dispose() } catch { }
    $script:OrchestratorMutex = $null
}

function Get-OrchestratorMutex {
    <#
        .SYNOPSIS
        Returns the single-instance mutex this process holds, or $null.

        .DESCRIPTION
        Exists so callers (and test teardown) can release the lock explicitly:
        $m = Get-OrchestratorMutex; if ($null -ne $m) { $m.ReleaseMutex(); $m.Dispose() }
    #>
    [CmdletBinding()]
    param()
    return $script:OrchestratorMutex
}

function Enter-Orchestrator {
    <#
        .SYNOPSIS
        Single-instance orchestrator entry. Loads the authoritative checkpoint.

        .DESCRIPTION
        Acquires the machine-wide mutex 'Global\OSDeploy.Orchestrator'. When a
        second launch detects the lock held (by this process or any other), it
        only writes the SecondInstanceExit event to the partition log and
        returns @{ Ran = $false } without touching any state file. The first
        launch holds the mutex for the process lifetime and returns the state
        loaded from <PartitionRoot>\State\DeploymentState.json. A missing or
        contract-invalid file is a caller/staging error and throws; state is
        never invented or defaulted (Q87/Q89).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PartitionRoot
    )
    # Second-instance check 1: this process already entered. A named mutex is
    # reentrant per THREAD, so a second WaitOne(0) on the same thread would
    # succeed even while the lock is held (probed on pwsh 7.4.2; identical on
    # Windows). The process-level marker closes that hole and makes in-process
    # re-entry behave exactly like a second process.
    if ($null -ne $script:OrchestratorMutex) {
        Write-SecondInstanceExit -PartitionRoot $PartitionRoot
        return @{ Ran = $false }
    }
    # Second-instance check 2: another process or thread on this machine holds
    # the kernel mutex. The mutex NAME is the cross-process contract - never
    # generated or randomized.
    $mutex = New-Object System.Threading.Mutex($false, 'Global\OSDeploy.Orchestrator')
    if (-not $mutex.WaitOne(0)) {
        $mutex.Dispose()
        Write-SecondInstanceExit -PartitionRoot $PartitionRoot
        return @{ Ran = $false }
    }
    $script:OrchestratorMutex = $mutex
    # Authoritative checkpoint load. The file ON THE PARTITION is the only
    # state source; missing or invalid means staging failed, so fail closed
    # and give the lock back rather than poison this process.
    try {
        $statePath = Join-Path $PartitionRoot 'State\DeploymentState.json'
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw ("DeploymentState.json not found at '{0}'. The orchestrator never invents state; verify partition staging." -f $statePath)
        }
        $state = Read-JsonFile -Path $statePath
        $validation = Test-DeploymentState -Record $state
        if (-not $validation.Valid) {
            throw ("DeploymentState.json at '{0}' failed its contract: {1}" -f $statePath, ($validation.Errors -join '; '))
        }
    }
    catch {
        Clear-OrchestratorLock
        throw
    }
    # Bind the orchestration context so the phase engine (Invoke-Phase,
    # Invoke-WithAttempts, Resume-AfterReboot) operates on the partition
    # checkpoint this entry loaded. No file write happens here.
    Set-OrchestrationContext -State $state -CheckpointPath $statePath
    return @{ Ran = $true; State = $state; PartitionRoot = $PartitionRoot }
}

function New-Checkpoint {
    <#
        .SYNOPSIS
        Validates and atomically writes a full DeploymentState contract object.

        .DESCRIPTION
        Validates the record with Test-DeploymentState FIRST and throws when
        it is invalid - an invalid checkpoint must never reach the partition
        (Q35: the on-partition file is authoritative). The validated record is
        stamped with the current UTC time as an ISO 8601 string and written
        with Write-AtomicJson so a reader never observes a partial document.
        Returns the written state object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Path
    )
    $validation = Test-DeploymentState -Record $State
    if (-not $validation.Valid) {
        throw ("New-Checkpoint refuses to write a state that fails Test-DeploymentState: {0}" -f ($validation.Errors -join '; '))
    }
    # Stamp the checkpoint time as an ISO 8601 UTC string. Both hashtable and
    # PSCustomObject records accept property assignment here because the
    # validator has already proven the TimestampUtc field exists.
    $State.TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-AtomicJson -Path $Path -Value $State
    return $State
}

function Get-ResumePoint {
    <#
        .SYNOPSIS
        Reads a checkpoint and projects the fields the resume engine needs.

        .DESCRIPTION
        Throws when the file is missing or unparseable. CompletedPhases is
        coerced with @() so single- and zero-element lists stay arrays on
        every reader platform.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Checkpoint file not found at '{0}'." -f $Path)
    }
    try {
        $state = Read-JsonFile -Path $Path
    }
    catch {
        throw ("Checkpoint file at '{0}' could not be parsed: {1}" -f $Path, $_.Exception.Message)
    }
    $completed = $state.CompletedPhases
    if ($null -eq $completed) { $completed = @() }
    return @{
        Phase           = $state.Phase
        Attempt         = $state.Attempt
        CompletedPhases = @($completed)
        RebootPending   = $state.RebootPending
    }
}

# ---------------------------------------------------------------------------
# Attempt policy, idempotent resume, reboot handling (Q35/Q36)
# ---------------------------------------------------------------------------

# The context the phase engine operates on: the in-memory State plus the
# checkpoint file every mutation is written to. Bound by Enter-Orchestrator on
# a successful entry, or explicitly by Set-OrchestrationContext (the phase
# engine and the tests use the setter to rebuild a context from a checkpoint
# FILE after a process restart - the file is the only state source).
$script:OrchestrationContext = $null

# Restart-request flag (Q35). An action that needs a reboot calls
# Set-OrchestrationRestartRequested, which is EXPORTED so a foreign
# scriptblock (test or phase code authored outside this module) can signal
# reliably no matter which session state it was created in - a plain
# $script:RequestRestart assignment inside such a scriptblock would hit the
# CALLER's script scope, not this module's. Actions authored INSIDE this
# module may assign $script:RequestRestart directly: same variable.
$script:RequestRestart = $false

function Set-OrchestrationContext {
    <#
        .SYNOPSIS
        Binds the module's orchestration context (State + checkpoint path).

        .DESCRIPTION
        Validates the State against Test-DeploymentState first and throws on
        failure - identity and structure are never defaulted (Q87/Q89), so an
        invalid state can never become the engine's working context.
        Enter-Orchestrator calls this internally after loading the partition
        checkpoint; the phase engine and tests call it directly to rebuild a
        context from a checkpoint file after a process restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$CheckpointPath
    )
    $validation = Test-DeploymentState -Record $State
    if (-not $validation.Valid) {
        throw ("Set-OrchestrationContext refuses a state that fails Test-DeploymentState: {0}" -f ($validation.Errors -join '; '))
    }
    $script:OrchestrationContext = @{ State = $State; CheckpointPath = $CheckpointPath }
}

function Set-OrchestrationRestartRequested {
    <#
        .SYNOPSIS
        Action-side restart signal: the running phase needs a reboot.

        .DESCRIPTION
        Sets the flag Invoke-Phase reads after the action completes. Invoke-Phase
        checkpoints RebootPending = $true BEFORE delegating the action, so the
        marker is already durable when this is called.
    #>
    [CmdletBinding()]
    param()
    $script:RequestRestart = $true
}

# Internal: read one field from a record that may be a hashtable (in-memory)
# or a PSCustomObject (from ConvertFrom-Json). Returns $null when the field
# is missing; callers decide whether that is fatal. Mirrors the State
# module's Get-RecordField, which is not exported.
function Get-OrchestratorField {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# Internal: CompletedPhases as a flat, null-tolerant array.
function Get-CompletedPhases {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    $completed = Get-OrchestratorField -Record $State -Name 'CompletedPhases'
    if ($null -eq $completed) { return @() }
    return @($completed)
}

# Internal: every engine function needs a bound context; missing one is a
# caller error and fails closed.
function Get-RequiredContext {
    [CmdletBinding()]
    param()
    if ($null -eq $script:OrchestrationContext) {
        throw 'No orchestration context is bound. Call Enter-Orchestrator or Set-OrchestrationContext first.'
    }
    return $script:OrchestrationContext
}

function Invoke-WithAttempts {
    <#
        .SYNOPSIS
        Q36 attempt policy: up to three automatic attempts per phase, then a
        blocking Technician Review.

        .DESCRIPTION
        Failure contract: an action FAILS by throwing (or by writing exactly
        boolean $false); anything else is success. Attempt is incremented and
        checkpointed BEFORE each try, so the file always records the attempt
        in flight and a crash mid-try resumes at the right attempt number:
        when this phase is neither completed nor exhausted, the loop resumes
        at the recorded Attempt + 1 (the crashed attempt is consumed, keeping
        the total at MaxAttempts across process restarts).

        Outcomes:
        - Phase already in CompletedPhases: @{ Outcome = 'Skipped' } without
          invoking the action (idempotent resume - a completed phase's action
          is never re-invoked, Q35).
        - Success on attempt n: the phase is recorded in CompletedPhases,
          Attempt resets to 0, checkpointed, @{ Outcome = 'Complete';
          Attempts = n }. The counter reset also applies across successes.
        - Exhaustion after the MaxAttempts-th failure: Attempt is set to
          MaxAttempts + 1 (4 with the default) and checkpointed, then
          $OnFailure - the blocking Technician Review hook - runs EXACTLY
          ONCE with -Phase and -Attempts, and the result is
          @{ Outcome = 'TechnicianReview'; Attempts = 4 }.

        Re-entering a phase whose recorded Attempt is already past
        MaxAttempts (crash between the third failure and the review hook, or
        a caller retry after review) goes straight to the exhaustion path: no
        further action invocations, and the review hook fires again because
        the previous hook may never have run. The blocking gate is the
        caller's: after TechnicianReview the sequence must stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [int]$MaxAttempts = 3,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$OnFailure
    )
    if ($MaxAttempts -lt 1) {
        throw ("MaxAttempts must be at least 1, got {0}." -f $MaxAttempts)
    }
    $context = Get-RequiredContext
    $state = $context.State

    if ((Get-CompletedPhases -State $state) -contains $Phase) {
        return @{ Outcome = 'Skipped' }
    }

    # Resume accounting: an in-flight recorded attempt for THIS phase means
    # the try was checkpointed but never finished (crash); it is consumed.
    $start = 1
    if (([string](Get-OrchestratorField -Record $state -Name 'Phase')) -eq $Phase) {
        $recorded = Get-OrchestratorField -Record $state -Name 'Attempt'
        if ($null -ne $recorded -and $recorded -ge 1) { $start = [int]$recorded + 1 }
    }

    for ($attempt = $start; $attempt -le $MaxAttempts; $attempt++) {
        $state.Phase = $Phase
        $state.Attempt = $attempt
        $null = New-Checkpoint -State $state -Path $context.CheckpointPath
        $failed = $false
        $output = $null
        try { $output = & $Action }
        catch { $failed = $true }
        if (-not $failed -and $output -is [bool] -and $output -eq $false) {
            $failed = $true
        }
        if (-not $failed) {
            # Success: the phase is never re-run (Q35 idempotence) and the
            # attempt counter resets for the next phase.
            $state.CompletedPhases = @(Get-CompletedPhases -State $state) + $Phase
            $state.Attempt = 0
            $null = New-Checkpoint -State $state -Path $context.CheckpointPath
            return @{ Outcome = 'Complete'; Attempts = $attempt }
        }
    }
    # Exhaustion: record Attempt = MaxAttempts + 1, then hand off to the
    # blocking Technician Review hook exactly once (Q36: three automatic
    # attempts, the fourth failure is a person).
    $state.Phase = $Phase
    $state.Attempt = $MaxAttempts + 1
    $null = New-Checkpoint -State $state -Path $context.CheckpointPath
    $null = & $OnFailure -Phase $Phase -Attempts ($MaxAttempts + 1)
    return @{ Outcome = 'TechnicianReview'; Attempts = $MaxAttempts + 1 }
}

function Invoke-Phase {
    <#
        .SYNOPSIS
        Phase wrapper: pre-marks RebootPending, applies the Q36 attempt
        policy, and converts a restart request into a RebootPending outcome.

        .DESCRIPTION
        Order of operations (Q35: RebootPending is saved BEFORE the restart
        is outstanding):
        1. A phase already in CompletedPhases returns @{ Outcome = 'Skipped' }
           with no checkpoint and no invocation (idempotent resume).
        2. RebootPending = $true is checkpointed BEFORE the action is
           delegated, so the file already carries the marker while the action
           - and the restart it may request - is in flight; a crash anywhere
           in that window forces the Resume-AfterReboot identity gate.
        3. The attempt policy runs (delegated to Invoke-WithAttempts): up to
           three tries with Attempt checkpointed before each, Technician
           Review on exhaustion.
        4. After the action: a requested restart keeps RebootPending = $true
           and returns @{ Outcome = 'RebootPending'; Attempts = n }. The
           phase itself is COMPLETE at that point (its action finished
           without failing), and the completion checkpoint written by
           Invoke-WithAttempts already carries the pre-delegation marker, so
           resume skips the phase and continues the sequence. With no
           restart request RebootPending is cleared and checkpointed. On
           TechnicianReview the marker is cleared too: no restart was
           requested and the machine must stop for review.

        The action signals a restart with Set-OrchestrationRestartRequested
        (module-internal actions may assign $script:RequestRestart directly).
        -OnFailure is optional here; when omitted, a no-op hook stands in and
        the caller still receives the TechnicianReview outcome to block on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$OnFailure
    )
    $context = Get-RequiredContext
    $state = $context.State
    $script:RequestRestart = $false
    if ((Get-CompletedPhases -State $state) -contains $Phase) {
        return @{ Outcome = 'Skipped' }
    }
    # Q35: the pending-reboot marker is durable BEFORE the action runs.
    $state.RebootPending = $true
    $null = New-Checkpoint -State $state -Path $context.CheckpointPath
    $hook = $OnFailure
    if ($null -eq $hook) { $hook = { param($Phase, $Attempts) } }
    $result = Invoke-WithAttempts -Phase $Phase -Action $Action -OnFailure $hook
    if ($result.Outcome -eq 'Complete' -and $script:RequestRestart) {
        # The action finished (phase complete) and asked for a reboot. The
        # completion checkpoint from Invoke-WithAttempts already persists
        # RebootPending = $true from the pre-delegation mark, so nothing more
        # needs to be written before the caller restarts the machine.
        return @{ Outcome = 'RebootPending'; Attempts = $result.Attempts }
    }
    if ($result.Outcome -eq 'Complete' -or $result.Outcome -eq 'TechnicianReview') {
        # No restart was requested (or the run stopped for review): clear the
        # pre-delegation marker and persist before returning.
        $state.RebootPending = $false
        $null = New-Checkpoint -State $state -Path $context.CheckpointPath
    }
    return $result
}

function Resume-AfterReboot {
    <#
        .SYNOPSIS
        Post-restart identity gate: validates machine/disk identity before
        any further phase work.

        .DESCRIPTION
        Q35: identity is validated on return. Both MachineId AND DiskId must
        positively match -Expected (case-insensitive string equality, the
        same tolerance Compare-DiskIdentity applies to serial numbers; a
        null, empty, or missing field on either side is a mismatch, never a
        pass - identity is established positively or not at all).

        A mismatch returns @{ Outcome = 'IdentityMismatch' } with ZERO phase
        work and ZERO state mutation: no checkpoint is written, and
        CompletedPhases is never cleared or altered. The caller must stop -
        there is no Ignore/Continue-Anyway path.

        A match clears RebootPending, checkpoints through New-Checkpoint, and
        returns @{ Outcome = 'Ready'; State } so the caller continues the
        sequence from the first incomplete phase. Calling this when no reboot
        is outstanding is safe: identity is still validated and the outcome
        is Ready.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Expected
    )
    $context = Get-RequiredContext
    $state = $context.State
    $stateMachine = [string](Get-OrchestratorField -Record $state -Name 'MachineId')
    $stateDisk = [string](Get-OrchestratorField -Record $state -Name 'DiskId')
    $expectedMachine = [string](Get-OrchestratorField -Record $Expected -Name 'MachineId')
    $expectedDisk = [string](Get-OrchestratorField -Record $Expected -Name 'DiskId')
    $machineOk = (-not [string]::IsNullOrEmpty($stateMachine)) -and
        (-not [string]::IsNullOrEmpty($expectedMachine)) -and
        ($stateMachine -eq $expectedMachine)
    $diskOk = (-not [string]::IsNullOrEmpty($stateDisk)) -and
        (-not [string]::IsNullOrEmpty($expectedDisk)) -and
        ($stateDisk -eq $expectedDisk)
    if (-not ($machineOk -and $diskOk)) {
        return @{ Outcome = 'IdentityMismatch' }
    }
    $state.RebootPending = $false
    $null = New-Checkpoint -State $state -Path $context.CheckpointPath
    return @{ Outcome = 'Ready'; State = $state }
}

# ---------------------------------------------------------------------------
# Integrity: hash record, recheck, local-only repair (Q90/Q92; Q91 boundary)
# ---------------------------------------------------------------------------

# Q91 IS the parameter list. None of these functions accepts a share, UNC,
# server, or SMB path in any form: repair recopies ONLY from a local partition
# directory the caller names, so nothing in these signatures can even express
# a DeploymentShare or deployment-server destination. The boundary is enforced
# structurally and locked by a parameter-name regex test.

function New-IntegrityRecord {
    <#
        .SYNOPSIS
        Generates and atomically stores the SHA-256 integrity record for a
        staged directory.

        .DESCRIPTION
        Q90/Q92: hashes are GENERATED at staging time from the staged tree -
        there is no manual manifest to trust. Builds the file inventory
        (New-FileInventory: relative path, size, SHA-256 per file) and the
        bundle hash over that inventory (Get-BundleHash), then persists the
        record with Write-AtomicJson so a reader never observes a partial
        document.

        DESIGN CHOICE: the destination is an explicit -RecordPath parameter
        rather than a derived '<parent of Directory>\State\IntegrityRecord.json'.
        The caller owns the partition layout (the bootstrap and the
        orchestrator write into <PartitionRoot>\State\IntegrityRecord.json),
        and an explicit parameter keeps this function from guessing paths the
        same way the state engine never invents content. The parent directory
        of RecordPath must already exist (a staged partition's State does); a
        missing one is a staging error that throws through Write-AtomicJson
        instead of being silently created.

        Returns the record object that was written:
        @{ FileHashes = <inventory>; BundleHash = <bundle hash> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$RecordPath
    )
    $inventory = Get-FlatInventory -Path $Directory
    if (@($inventory).Count -eq 0) {
        # An empty tree has nothing to attest: refuse rather than invent a
        # record whose bundle would describe no files (staging error).
        throw ("New-IntegrityRecord refuses an empty directory at '{0}'; the staged tree must contain the files to hash." -f $Directory)
    }
    $record = @{
        FileHashes = $inventory
        BundleHash = Get-BundleHash -Inventory $inventory
    }
    Write-AtomicJson -Path $RecordPath -Value $record
    return $record
}

# Internal: index one side of the integrity comparison by relative path.
# Entries may be PSCustomObjects (New-FileInventory output, or IntegrityRecord
# read back through Read-JsonFile) or hashtables; Get-OrchestratorField
# tolerates both. Returns a hashtable of Path -> Sha256.
function Get-InventoryIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Entries
    )
    $index = @{}
    foreach ($entry in @($Entries)) {
        $path = [string](Get-OrchestratorField -Record $entry -Name 'Path')
        $index[$path] = [string](Get-OrchestratorField -Record $entry -Name 'Sha256')
    }
    return $index
}

# Internal: New-FileInventory as an always-flat object[] (-NoEnumerate makes a
# naive @() wrap double-nest its output, and an empty directory produces no
# pipeline output at all; both normalize here).
function Get-FlatInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $inventory = New-FileInventory -Path $Path
    if ($null -eq $inventory) { return @() }
    return @($inventory)
}

function Test-Integrity {
    <#
        .SYNOPSIS
        Rechecks a directory against a stored integrity record.

        .DESCRIPTION
        Q90/Q92: the recheck recomputes the full inventory and bundle hash
        and compares them against the record - nothing is trusted from the
        previous pass. Ok is $true ONLY when every per-file hash matches AND
        the derived bundle hash matches.

        Mismatches is an array of @{ Path; Reason } entries:
        - Reason 'Changed': the file exists but its SHA-256 differs.
        - Reason 'Missing': the record lists the file and the directory no
          longer has it (a deleted directory reports every recorded file as
          Missing - fail closed, never an exception).
        - Reason 'Extra': the directory holds a file the record never listed.
        - Reason 'BundleHash' (Path = $null): the files may match but the
          derived bundle does not - only possible when the RECORD itself is
          inconsistent with its own inventory.
        - Reason 'InvalidRecord' (Path = $null): the record lacks its
          FileHashes or BundleHash field and can never verify.

        Record may be the in-memory hashtable New-IntegrityRecord returned or
        the PSCustomObject read back from IntegrityRecord.json after a
        restart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]$Record
    )
    $mismatches = @()
    $recordHashes = Get-OrchestratorField -Record $Record -Name 'FileHashes'
    $recordBundle = Get-OrchestratorField -Record $Record -Name 'BundleHash'
    if ($null -eq $recordHashes -or $null -eq $recordBundle) {
        # Fail closed: an incomplete record is never defaulted into shape.
        $mismatches += @{ Path = $null; Reason = 'InvalidRecord' }
        return @{ Ok = $false; Mismatches = @($mismatches) }
    }
    $inventory = @()
    if (Test-Path -LiteralPath $Directory) {
        $inventory = Get-FlatInventory -Path $Directory
    }
    $current = Get-InventoryIndex -Entries $inventory
    $recorded = Get-InventoryIndex -Entries $recordHashes
    foreach ($path in @($recorded.Keys | Sort-Object)) {
        if (-not $current.Contains($path)) {
            $mismatches += @{ Path = $path; Reason = 'Missing' }
            continue
        }
        if ($current[$path] -cne $recorded[$path]) {
            $mismatches += @{ Path = $path; Reason = 'Changed' }
        }
    }
    foreach ($path in @($current.Keys | Sort-Object)) {
        if (-not $recorded.Contains($path)) {
            $mismatches += @{ Path = $path; Reason = 'Extra' }
        }
    }
    # Bundle gate: a non-empty current tree recomputes and compares; an empty
    # current tree cannot match a non-empty record (already reported Missing),
    # and two empty trees are trivially consistent.
    if (@($inventory).Count -gt 0) {
        if ((Get-BundleHash -Inventory $inventory) -cne [string]$recordBundle) {
            $mismatches += @{ Path = $null; Reason = 'BundleHash' }
        }
    }
    elseif (@($recordHashes).Count -gt 0) {
        $mismatches += @{ Path = $null; Reason = 'BundleHash' }
    }
    return @{ Ok = ($mismatches.Count -eq 0); Mismatches = @($mismatches) }
}

function Repair-FromLocalSource {
    <#
        .SYNOPSIS
        Recopies a damaged directory from the LOCAL partition repair source
        and revalidates it against the SAME integrity record.

        .DESCRIPTION
        Q92 failure handling: on a failed recheck the only permitted remedy
        is a recopy from the partition's own repair source (Q91: never a
        server path - the parameter list cannot express one). The repair
        removes the directory's content and copies the RepairSource content
        over it, so foreign files vanish and missing files return. It then
        re-runs Test-Integrity with the SAME record: repair never re-records,
        because the record is the staging-time truth the directory must be
        restored TO.

        Outcomes:
        - @{ Repaired = $true } when the recheck passes.
        - @{ Repaired = $false; Outcome = 'TechnicianReview' } when the
          recopy still fails validation (the repair source itself is damaged
          or missing) - the second failure stops at a blocking Technician
          Review; there is no Ignore/Continue-Anyway path.

        A missing RepairSource returns the failure outcome without touching
        the directory: it cannot restore anything, so second-failure
        semantics apply unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$RepairSource,
        [Parameter(Mandatory)]$Record
    )
    if (-not (Test-Path -LiteralPath $RepairSource)) {
        return @{ Repaired = $false; Outcome = 'TechnicianReview' }
    }
    # Recopy OVER the directory: recreate the target if it was deleted, drop
    # everything it currently holds, then copy every repair-source child in.
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $RepairSource -Force |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Directory -Recurse -Force }
    $check = Test-Integrity -Directory $Directory -Record $Record
    if ($check.Ok) {
        return @{ Repaired = $true }
    }
    return @{ Repaired = $false; Outcome = 'TechnicianReview' }
}
