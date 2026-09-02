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
    # Version-proof empty guard: @($null).Count is 1, so the null check must
    # come first; a null or empty tree is refused with THIS clear error
    # rather than a downstream binding exception from Get-BundleHash.
    if ($null -eq $inventory -or @($inventory).Count -eq 0) {
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
    # $null admits here (an existing-but-empty directory reaches this helper
    # as a null inventory): an empty side is a legitimate comparison input,
    # never a binding failure. Without the guard, [AllowEmptyCollection()]
    # still rejects $null and @($null) would fabricate a bogus '' key.
    if ($null -eq $Entries) { return @{} }
    $index = @{}
    foreach ($entry in @($Entries)) {
        $path = [string](Get-OrchestratorField -Record $entry -Name 'Path')
        $index[$path] = [string](Get-OrchestratorField -Record $entry -Name 'Sha256')
    }
    return $index
}

# Internal: New-FileInventory as an always-flat object[] (-NoEnumerate makes a
# naive @() wrap double-nest its output, and an empty directory produces an
# array that plain 'return @()' would enumerate away to NO pipeline objects,
# handing the caller $null; the comma wrapper keeps even the empty array
# intact through the function boundary).
function Get-FlatInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $inventory = New-FileInventory -Path $Path
    if ($null -eq $inventory) { return ,@() }
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
        # Belt and braces for the existing-but-EMPTY directory: any pipeline
        # quirk that yields no objects here must still compare as an empty
        # tree (all files Missing), never throw past this point (the doc
        # contract: fail closed, no exception).
        if ($null -eq $inventory) { $inventory = @() }
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

# ---------------------------------------------------------------------------
# Completion gating and scoped cleanup (Q89)
# ---------------------------------------------------------------------------

# Mock/deployment locations this suite addresses (documented contract):
#   <PartitionRoot>\State\TaskRegistration.json  the Scheduled Task
#       registration MARKER that Task 28's Register-OrchestratorTask writes.
#       Removing the marker is how a finished run retires its startup-task
#       re-entry; the path is defined here, next to its consumer, so
#       registration and cleanup can never drift apart.
#   <PartitionRoot>\OrchestratorRuntime\          the runtime artifacts
#       directory. In the deployed Windows host this represents
#       C:\ProgramData\OSDeploy\Orchestrator; the engine addresses it
#       relative to the partition so the suite stays platform-independent
#       and the tests can stage it as plain files.

# Internal: set one field on a hashtable (in-memory) OR PSCustomObject
# (ConvertFrom-Json) state record. The completion fields Completed, BlockedBy,
# and CompletedUtc do not exist on a record read back from
# DeploymentState.json, and PSCustomObject assignment to a MISSING property
# throws (probed on pwsh 7.4.2: 'The property cannot be found on this
# object'), so new fields are added with Add-Member while existing fields are
# assigned in place.
function Set-OrchestratorField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )
    if ($Record -is [System.Collections.IDictionary]) {
        $Record[$Name] = $Value
        return
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        $prop.Value = $Value
        return
    }
    Add-Member -InputObject $Record -MemberType NoteProperty -Name $Name -Value $Value
}

# Internal: REMOVE one field from a hashtable or PSCustomObject state record.
# Absent fields are a no-op. Used by the completion path so a successfully
# completed checkpoint never carries a stale block record from an earlier
# blocked attempt (fix round 1): success sets Completed = $true and REMOVES
# BlockedBy, rather than nulling it, so a completed document is shape-identical
# whether the run completed first-try or after a blocked retry.
function Remove-OrchestratorField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) {
            $null = $Record.Remove($Name)
        }
        return
    }
    if ($null -ne $Record.PSObject.Properties[$Name]) {
        $null = $Record.PSObject.Properties.Remove($Name)
    }
}

# Internal: locate the CURRENT (newest) run folder under a Logs root. Uses the
# same ordering key Invoke-LogRetention uses: the <yyyyMMdd-HHmmss> timestamp
# embedded in the folder name, LastWriteTime as the fallback for foreign
# names. Returns a log-shaped @{ Folder; EventsPath } object for the newest
# folder, or $null when the root or its set of run folders is empty - the
# caller decides what a missing log means (Task 20: a log-verification block,
# never an invented log).
function Get-CurrentRunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogsRoot
    )
    if (-not (Test-Path -LiteralPath $LogsRoot)) { return $null }
    $folders = @(Get-ChildItem -LiteralPath $LogsRoot -Directory -ErrorAction SilentlyContinue)
    if ($folders.Count -eq 0) { return $null }
    $best = $null
    $bestKey = ''
    foreach ($folder in $folders) {
        $key = $folder.LastWriteTime.ToString('yyyyMMdd-HHmmss')
        $match = [regex]::Match($folder.Name, '(\d{8}-\d{6})')
        if ($match.Success) { $key = $match.Groups[1].Value }
        if ($null -eq $best -or $key -gt $bestKey -or ($key -eq $bestKey -and $folder.Name -gt $best.Name)) {
            $best = $folder
            $bestKey = $key
        }
    }
    return @{
        Folder     = $best.FullName
        EventsPath = (Join-Path $best.FullName 'events.jsonl')
    }
}

function Invoke-Cleanup {
    <#
        .SYNOPSIS
        Q89 scoped cleanup: remove the completion runtime footprint, retain
        all recovery content.

        .DESCRIPTION
        Removes EXACTLY two targets and nothing else:
        1. The Scheduled Task registration marker
           <PartitionRoot>\State\TaskRegistration.json (the file Task 28's
           Register-OrchestratorTask writes).
        2. The orchestrator runtime artifacts directory
           <PartitionRoot>\OrchestratorRuntime\ entirely (the simulated
           C:\ProgramData\OSDeploy\Orchestrator).

        NEVER touched: Sources, ImageCache, State\FactoryProfile*,
        State\effective-config*, Logs, and every other partition path. The
        function never enumerates the partition - it addresses only the two
        named targets - so the retained recovery set is structurally safe
        rather than protected by a filter list.

        Failure contract: a marker path occupied by a DIRECTORY is reported
        as a removal failure instead of recursed into or prompted about.
        The marker is a file artifact; unknown directory content squatting
        on its path is never blindly deleted (probed: Remove-Item without
        -Recurse on a non-empty directory raises an interactive Confirm
        prompt, which is not acceptable in an unattended orchestrator).
        This classification is deterministic on every platform and is how
        the tests simulate an undeletable marker.

        Returns @{ Ok; Failures }: Ok = $true when both removals succeeded
        or were already absent (idempotent - an already-clean partition is
        a success); otherwise $false with one Failures message per failed
        target. Every target is attempted so one failure never hides
        another. TaskName only labels the failure detail; it defaults to
        the same task name Register-OrchestratorTask defaults to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [string]$TaskName = 'OSDeploy Orchestrator'
    )
    $failures = @()
    $markerPath = Join-Path $PartitionRoot 'State\TaskRegistration.json'
    $runtimePath = Join-Path $PartitionRoot 'OrchestratorRuntime'

    if (Test-Path -LiteralPath $markerPath) {
        $markerItem = Get-Item -LiteralPath $markerPath -Force
        if ($markerItem.PSIsContainer) {
            $failures += ("Scheduled Task '{0}' registration marker '{1}' is a directory, not the expected marker file; refusing to remove unknown directory content." -f $TaskName, $markerPath)
        }
        else {
            try {
                Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
            }
            catch {
                $failures += ("Scheduled Task '{0}' registration marker '{1}' could not be removed: {2}" -f $TaskName, $markerPath, $_.Exception.Message)
            }
        }
    }

    if (Test-Path -LiteralPath $runtimePath) {
        try {
            Remove-Item -LiteralPath $runtimePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $failures += ("Orchestrator runtime artifacts '{0}' could not be removed: {1}" -f $runtimePath, $_.Exception.Message)
        }
    }

    return @{ Ok = ($failures.Count -eq 0); Failures = @($failures) }
}

function Complete-Deployment {
    <#
        .SYNOPSIS
        Q89 completion gate: required work -> cleanup -> final-log
        verification -> correct handoff, in exactly that order.

        .DESCRIPTION
        Completion is recorded ONLY after every preceding step succeeds.
        The state file on the partition is the only state source (it is
        read here, not taken from any in-memory context).

        Step 1 - required work. State\DeploymentState.json must exist,
        parse, and pass Test-DeploymentState; a missing or invalid file
        throws (state is never invented - the same fail-closed rule as
        Enter-Orchestrator). When Result is already set the run completed
        earlier and this call is a post-completion restart: it delegates to
        Invoke-PostCompletionRestart and returns that cleanup result
        (@{ Ok; Failures }). With -RequiredPhases bound, every listed phase
        must appear in CompletedPhases or the call returns
        @{ Completed = $false; BlockedBy = 'RequiredWorkIncomplete' }
        BEFORE any destructive step and without a state write; with it
        unbound, the invocation itself is the caller's assertion that the
        required work is done (the checkpoint is still read and validated).

        Step 2 - cleanup. An Invoke-Cleanup failure checkpoints
        Completed = $false and BlockedBy = 'CleanupFailure' (Result stays
        null and NO CompletedUtc is written) and returns the same shape, so
        a restart retries the full order - cleanup is idempotent.

        Step 3 - final-log verification. Complete-RunLog runs on the
        CURRENT run log (the newest run folder under
        <PartitionRoot>\Logs). No run folder at all, an unreadable events
        file, or a failed JSONL parse gate returns
        @{ Completed = $false; BlockedBy = 'LogVerification' } with the
        checkpoint untouched, so the next invocation retries.

        Step 4 - only then: Result = Handoff, Completed = $true, and
        CompletedUtc (an ISO 8601 UTC string) are written through
        New-Checkpoint (validated, atomic) and
        @{ Completed = $true; Result } is returned. Any BlockedBy left by an
        earlier blocked attempt is REMOVED (not nulled) in the same write,
        so the final authoritative document never carries a stale block
        record: a retry-after-block success and a first-try success produce
        shape-identical completed states.

        CompletedUtc is NEVER written on a blocked path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [Parameter(Mandatory)][string]$Handoff,
        [string[]]$RequiredPhases = @()
    )
    $statePath = Join-Path $PartitionRoot 'State\DeploymentState.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw ("DeploymentState.json not found at '{0}'. The orchestrator never invents state; verify partition staging." -f $statePath)
    }
    try {
        $state = Read-JsonFile -Path $statePath
    }
    catch {
        throw ("DeploymentState.json at '{0}' could not be parsed: {1}" -f $statePath, $_.Exception.Message)
    }
    $validation = Test-DeploymentState -Record $state
    if (-not $validation.Valid) {
        throw ("DeploymentState.json at '{0}' failed its contract: {1}" -f $statePath, ($validation.Errors -join '; '))
    }

    # Post-completion: Result already recorded -> cleanup only, nothing else.
    $recordedResult = Get-OrchestratorField -Record $state -Name 'Result'
    $resultIsSet = ($null -ne $recordedResult)
    if ($resultIsSet -and $recordedResult -is [string] -and $recordedResult -eq '') {
        $resultIsSet = $false
    }
    if ($resultIsSet) {
        return (Invoke-PostCompletionRestart -PartitionRoot $PartitionRoot)
    }

    if (@($RequiredPhases).Count -gt 0) {
        $completed = Get-CompletedPhases -State $state
        foreach ($required in $RequiredPhases) {
            if ($completed -notcontains $required) {
                return @{ Completed = $false; BlockedBy = 'RequiredWorkIncomplete' }
            }
        }
    }

    $cleanup = Invoke-Cleanup -PartitionRoot $PartitionRoot
    if (-not $cleanup.Ok) {
        # Durable block record: a restart must see WHY completion never
        # happened. Result stays null so the retry runs the full order again.
        Set-OrchestratorField -Record $state -Name 'Completed' -Value $false
        Set-OrchestratorField -Record $state -Name 'BlockedBy' -Value 'CleanupFailure'
        $null = New-Checkpoint -State $state -Path $statePath
        return @{ Completed = $false; BlockedBy = 'CleanupFailure' }
    }

    $log = Get-CurrentRunLog -LogsRoot (Join-Path $PartitionRoot 'Logs')
    $logOk = $false
    if ($null -ne $log) {
        try {
            $logOk = Complete-RunLog -Log $log
        }
        catch {
            # An unreadable events file is a verification failure, never a
            # thrown exception past the completion gate.
            $logOk = $false
        }
    }
    if (-not $logOk) {
        # Per the Task 20 contract the log-verification block is returned
        # without a state write: the checkpoint is untouched, so the next
        # invocation retries the whole order (cleanup is idempotent).
        return @{ Completed = $false; BlockedBy = 'LogVerification' }
    }

    Set-OrchestratorField -Record $state -Name 'Result' -Value $Handoff
    # Positive completion polarity, and NO stale block record: a run that
    # completes after a blocked attempt must not land on a document that
    # still says BlockedBy = 'CleanupFailure' alongside Result/CompletedUtc.
    Set-OrchestratorField -Record $state -Name 'Completed' -Value $true
    Remove-OrchestratorField -Record $state -Name 'BlockedBy'
    Set-OrchestratorField -Record $state -Name 'CompletedUtc' -Value (Get-Date).ToUniversalTime().ToString('o')
    $null = New-Checkpoint -State $state -Path $statePath
    return @{ Completed = $true; Result = $Handoff }
}

function Invoke-PostCompletionRestart {
    <#
        .SYNOPSIS
        Q89 post-completion restart: cleanup ONLY.

        .DESCRIPTION
        A restart after completion runs CLEANUP ONLY - Q89. No phase action
        is invoked and no state field (Result, CompletedUtc, or any other)
        is read into the engine or rewritten: the function is structurally
        incapable of phase work because it accepts no phase, action, or
        state parameters at all. Returns the Invoke-Cleanup result
        (@{ Ok; Failures }) unchanged, so a cleanup failure on the
        post-completion path surfaces as Ok = $false without inventing a
        completion-shaped answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [string]$TaskName = 'OSDeploy Orchestrator'
    )
    return (Invoke-Cleanup -PartitionRoot $PartitionRoot -TaskName $TaskName)
}

# ---------------------------------------------------------------------------
# Driver phase: pattern-matched discovery and dry-runnable execution (Q96, Q27)
# ---------------------------------------------------------------------------

# Q96 contract: drivers are discovered by PATTERN, never by manifest. The
# staged Sources\Drivers tree is walked folder by folder and classified by
# the standardized installer naming manufacturers already use (ASUS folders
# hold AsusSetup.exe; Gigabyte folders hold a single installer executable).
# No file other than the .exe payloads is ever opened, so a manifest.json
# planted under the tree is invisible to this engine. Q95: the legacy
# autoAll.ps1 / eztConfig.ps1 scripts are never invoked by this phase.

function Find-DriverInstallers {
    <#
        .SYNOPSIS
        Classifies a staged driver tree into ordered installer plans.

        .DESCRIPTION
        Recurses every directory AT OR BELOW -Root (the root itself is a
        candidate, so pointing Root at one driver folder yields exactly
        that folder's plan) and applies the Q96 pattern rules:

        1. AsusSetup.exe directly in the folder (case-insensitive match on
           the full file name; the .exe extension match is case-insensitive
           everywhere) -> @{ Folder; Installer = 'AsusSetup.exe'; Pattern = 'Asus' }.
           The Asus rule wins even when other .exe files sit beside
           AsusSetup.exe: ASUS convention makes AsusSetup.exe THE installer.
        2. Exactly one .exe that is not AsusSetup.exe AND no .exe in any
           subfolder -> @{ Folder; Installer = <name>; Pattern = 'SingleExe' }
           (the Gigabyte single-installer convention).
        3. Any other folder yields NO plan and is recorded in SkippedFolders
           with its reason: 'NoInstaller' (zero .exe - the scanned root and
           plain parent folders land here), 'MultipleInstallers', or
           'NestedInstaller' (one direct .exe with another below it).
           Ambiguous shapes are never guessed into a plan.

        Installer is always the file's ACTUAL staged name (a case-variant
        asussetup.exe stays lowercase) so the execution path resolves on
        case-sensitive filesystems too.

        Plans are ordered by folder path. Returns
        @{ Plans; SkippedFolders }; both fields are always arrays.

        A missing Root, or a Root that is not a directory, throws: the
        pattern engine never invents installers (Invoke-DriverPhase catches
        this and reports it as a failed-driver entry instead of letting it
        escape the phase boundary).

        No manifest file is ever read - discovery inspects file NAMES only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        throw ("Driver root not found at '{0}'. The pattern engine never invents installers." -f $Root)
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer) {
        throw ("Driver root '{0}' is not a directory." -f $Root)
    }
    # Every directory at or below the root is a candidate folder; processing
    # them in FullName order makes the plan list ordered by folder path.
    $folders = @($rootItem) + @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force)
    $plans = @()
    $skipped = @()
    foreach ($folder in ($folders | Sort-Object -Property FullName)) {
        $direct = @(Get-ChildItem -LiteralPath $folder.FullName -File -Force |
            Where-Object { $_.Extension -ieq '.exe' })
        $asus = @($direct | Where-Object { $_.Name -ieq 'AsusSetup.exe' })
        if ($asus.Count -gt 0) {
            $plans += @{ Folder = $folder.FullName; Installer = $asus[0].Name; Pattern = 'Asus' }
            continue
        }
        if ($direct.Count -eq 1) {
            # Single direct installer: a plan only when nothing installable
            # hides below it (the Gigabyte single-exe convention).
            $allBelow = @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -File -Force |
                Where-Object { $_.Extension -ieq '.exe' })
            if ($allBelow.Count -le 1) {
                $plans += @{ Folder = $folder.FullName; Installer = $direct[0].Name; Pattern = 'SingleExe' }
            }
            else {
                $skipped += @{ Folder = $folder.FullName; Reason = 'NestedInstaller' }
            }
            continue
        }
        if ($direct.Count -eq 0) {
            $skipped += @{ Folder = $folder.FullName; Reason = 'NoInstaller' }
        }
        else {
            $skipped += @{ Folder = $folder.FullName; Reason = 'MultipleInstallers' }
        }
    }
    return @{ Plans = @($plans); SkippedFolders = @($skipped) }
}

function Invoke-DriverPhase {
    <#
        .SYNOPSIS
        Executes the pattern-discovered driver installers, with a dry-run
        mode and per-driver failure reporting (Q96/Q27).

        .DESCRIPTION
        Discovery (Find-DriverInstallers) runs first, inside try/catch:
        even a discovery failure - including a missing Root - is REPORTED,
        never thrown past this function (Q27: a driver problem does not
        kill the deployment; the phase never throws).

        -DryRun records the discovered plan list in the result's Plans
        field and executes NOTHING: the Runner is never invoked, and the
        recorded plan list is identical to Find-DriverInstallers output.

        Execution: each plan is handed to the Runner in plan order. The
        Runner receives the PLAN OBJECT (@{ Folder; Installer; Pattern } -
        design choice: the plan carries the pattern, so a runner can pick
        per-vendor behavior) and signals failure by throwing, by returning
        boolean $false (the module-wide action convention), or by returning
        an object with a non-zero ExitCode (the Start-Process -PassThru
        shape; every non-zero code counts - the strict non-zero contract).
        A failed driver NEVER stops the remaining plans: every plan is
        attempted and failures are collected.

        Default Runner (used when -Runner is omitted): real silent
        execution - Start-Process -FilePath <Folder>\<Installer>
        -ArgumentList '-s' -Wait -PassThru - for BOTH patterns. '-s' is the
        ASUS silent switch the plan mandates; real-world per-vendor
        switches arrive with the driver library and will be selected by
        Pattern then. Manufacturer installers run silently over the staged
        folders; the separate recursive PnP pass and final device
        validation are Q28 work, not this phase.

        Returns @{ Ok; DryRun; Plans; Executed; FailedDrivers; SkippedFolders }:
        - Ok = $true only when no driver failed;
        - Plans = the full discovered plan list (the dry-run record);
        - Executed = the plans that ran successfully;
        - FailedDrivers = @{ Folder; Installer; Error } per failed driver
          (a discovery failure is a single entry with Installer = $null);
        - SkippedFolders = the discovery report, carried through;
        - RoutedToReview = $true is added exactly when Ok = $false (Q27:
          unresolved driver failures are routed to Technician Review before
          the final handoff - the phase reports and keeps going; it never
          throws and never aborts the deployment itself).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [switch]$DryRun,
        [scriptblock]$Runner
    )
    $runner = $Runner
    if ($null -eq $runner) {
        $runner = {
            param($Plan)
            $installerPath = Join-Path $Plan.Folder $Plan.Installer
            return (Start-Process -FilePath $installerPath -ArgumentList '-s' -Wait -PassThru)
        }
    }
    try {
        $found = Find-DriverInstallers -Root $Root
    }
    catch {
        # Q27: reported, not thrown - the phase result itself never throws.
        return @{
            Ok             = $false
            DryRun         = [bool]$DryRun
            Plans          = @()
            Executed       = @()
            FailedDrivers  = @(@{ Folder = $Root; Installer = $null; Error = $_.Exception.Message })
            SkippedFolders = @()
            RoutedToReview = $true
        }
    }
    if ($DryRun) {
        return @{
            Ok             = $true
            DryRun         = $true
            Plans          = @($found.Plans)
            Executed       = @()
            FailedDrivers  = @()
            SkippedFolders = @($found.SkippedFolders)
        }
    }
    $executed = @()
    $failed = @()
    foreach ($plan in @($found.Plans)) {
        $runError = $null
        $output = $null
        try { $output = & $runner $plan }
        catch { $runError = $_.Exception.Message }
        if ($null -eq $runError) {
            if ($output -is [bool] -and $output -eq $false) {
                $runError = 'Runner returned $false.'
            }
            elseif ($null -ne $output) {
                $exitProp = $output.PSObject.Properties['ExitCode']
                if ($null -ne $exitProp -and [int]$exitProp.Value -ne 0) {
                    $runError = ('Installer exited with code {0}.' -f $exitProp.Value)
                }
            }
        }
        if ($null -ne $runError) {
            $failed += @{ Folder = $plan.Folder; Installer = $plan.Installer; Error = $runError }
        }
        else {
            $executed += $plan
        }
    }
    $result = @{
        Ok             = (@($failed).Count -eq 0)
        DryRun         = $false
        Plans          = @($found.Plans)
        Executed       = @($executed)
        FailedDrivers  = @($failed)
        SkippedFolders = @($found.SkippedFolders)
    }
    if (@($failed).Count -gt 0) { $result['RoutedToReview'] = $true }
    return $result
}
