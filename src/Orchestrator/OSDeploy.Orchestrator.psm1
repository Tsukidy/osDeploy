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
        returns @{ Ran = $false } without touching any state file. An
        ABANDONED mutex (its previous owner died holding it - the Q35
        power-loss shape) is treated as ACQUIRED: on Windows the
        AbandonedMutexException from WaitOne accompanies a successful
        ownership transfer, and the on-disk checkpoint loaded below remains
        the only state authority. The first
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
    # Abandoned-mutex recovery (Q35 crash re-entry): when the previous owner
    # (process or thread) died holding this mutex, a Windows WaitOne(0) on it
    # throws AbandonedMutexException AND transfers ownership to THIS caller -
    # the exception accompanies a successful acquisition, it does not deny
    # one. That is the deployed power-loss re-entry path: a crashed
    # orchestrator's abandoned mutex must never block the next boot task, and
    # the on-disk checkpoint loaded below remains the only state authority.
    # (Non-Windows PowerShell mutex emulation never surfaces this exception,
    # so this branch is unreachable there; the Windows component suite
    # proves it with a deliberate owner-death scenario.)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
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
    <#
        .SYNOPSIS
        Locate the CURRENT (newest) run folder under a Logs root; prefers the
        folder belonging to a named run.

        .DESCRIPTION
        Uses the same ordering key Invoke-LogRetention uses: the
        <yyyyMMdd-HHmmss> timestamp embedded in the folder name,
        LastWriteTime as the fallback for foreign names. Returns a
        log-shaped @{ Folder; EventsPath } object, or $null when the root or
        its set of run folders is empty - the caller decides what a missing
        log means (Task 20: a log-verification block, never an invented
        log).

        -RunId (Q73 fix): when bound and non-empty, run folders whose NAME
        embeds that RunId are preferred over all newer foreign folders, and
        the NEWEST of the matching set wins. Without this preference a
        SECOND INSTANCE's newer folder (Write-SecondInstanceExit creates
        one) would become 'the current log' and the summary gate would
        verify the WRONG run's events. The folder name shape
        <RunType>-<yyyyMMdd-HHmmss>-<RunId> (collision suffixes -2..-99
        append after the RunId) embeds the RunId verbatim, so a plain
        substring match selects the run's own folders; an empty, unbound, or
        unmatched RunId falls back to the plain newest-folder behavior.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogsRoot,
        [string]$RunId = ''
    )
    if (-not (Test-Path -LiteralPath $LogsRoot)) { return $null }
    $folders = @(Get-ChildItem -LiteralPath $LogsRoot -Directory -ErrorAction SilentlyContinue)
    if ($folders.Count -eq 0) { return $null }
    $candidates = @($folders)
    if (-not [string]::IsNullOrEmpty($RunId)) {
        $candidates = @($folders | Where-Object { $_.Name.Contains($RunId) })
        if ($candidates.Count -eq 0) { $candidates = @($folders) }
    }
    $best = $null
    $bestKey = ''
    foreach ($folder in $candidates) {
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
        Q89 scoped cleanup: retire the Scheduled Task, remove the completion
        runtime footprint, retain all recovery content.

        .DESCRIPTION
        Performs EXACTLY three things and nothing else, every target
        attempted so one failure never hides another:
        1. Unregisters the orchestrator's Scheduled Task through
           Unregister-OrchestratorTask (Q89: 'cleanup removes the task').
           The task name comes from the registration MARKER when it is
           readable - the marker written by Register-OrchestratorTask is
           the authority for which task this partition staged - and falls
           back to -TaskName otherwise. On a non-Windows host the
           unregistration is the documented Windows-only no-op (one
           warning, nothing removed), so the unit suites stay green; a
           Windows failure throws inside Unregister-OrchestratorTask and is
           collected as a cleanup failure here.
        2. Removes the Scheduled Task registration marker
           <PartitionRoot>\State\TaskRegistration.json (the file Task 28's
           Register-OrchestratorTask writes).
        3. Removes the orchestrator runtime artifacts directory
           <PartitionRoot>\OrchestratorRuntime\ entirely (the simulated
           C:\ProgramData\OSDeploy\Orchestrator; Q90's integrity-protected
           staged copy, spent once the run completes).

        NEVER touched: Sources, ImageCache, State\FactoryProfile*,
        State\effective-config*, State\IntegrityRecord.json, Logs, and
        every other partition path. The function never enumerates the
        partition - it addresses only the named targets - so the retained
        recovery set is structurally safe rather than protected by a
        filter list.

        Failure contract: a marker path occupied by a DIRECTORY is reported
        as a removal failure instead of recursed into or prompted about.
        The marker is a file artifact; unknown directory content squatting
        on its path is never blindly deleted (probed: Remove-Item without
        -Recurse on a non-empty directory raises an interactive Confirm
        prompt, which is not acceptable in an unattended orchestrator).
        This classification is deterministic on every platform and is how
        the tests simulate an undeletable marker.

        Returns @{ Ok; Failures }: Ok = $true when every step succeeded or
        was already absent (idempotent - an already-clean partition is a
        success; Unregister-OrchestratorTask is itself safe to call twice);
        otherwise $false with one Failures message per failed target.
        TaskName also labels the fallback unregistration and the failure
        detail; it defaults to the same task name
        Register-OrchestratorTask defaults to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [string]$TaskName = 'OSDeploy Orchestrator'
    )
    $failures = @()
    $markerPath = Join-Path $PartitionRoot 'State\TaskRegistration.json'
    $runtimePath = Join-Path $PartitionRoot 'OrchestratorRuntime'

    # --- 1. Retire the Scheduled Task itself (Q89) --------------------------
    # The marker records WHICH task this partition registered; read it
    # before it is removed. A missing, unreadable, or malformed marker
    # (including a directory squatting on the path) falls back to the
    # -TaskName parameter.
    $retireName = $TaskName
    try {
        $markerItem = Get-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        if (-not $markerItem.PSIsContainer) {
            $marker = Read-JsonFile -Path $markerPath
            $markerName = [string](Get-OrchestratorField -Record $marker -Name 'TaskName')
            if (-not [string]::IsNullOrWhiteSpace($markerName)) { $retireName = $markerName }
        }
    }
    catch { }
    try {
        # $null result = the non-Windows no-op branch (one warning, nothing
        # removed); a Windows result carries Ok, and a Windows failure
        # throws and is collected below.
        $unregistered = Unregister-OrchestratorTask -TaskName $retireName
        if ($null -ne $unregistered) {
            $unregOk = Get-OrchestratorField -Record $unregistered -Name 'Ok'
            if ($null -ne $unregOk -and -not [bool]$unregOk) {
                $failures += ("Scheduled Task '{0}' could not be retired by Unregister-OrchestratorTask." -f $retireName)
            }
        }
    }
    catch {
        $failures += ("Scheduled Task '{0}' could not be retired: {1}" -f $retireName, $_.Exception.Message)
    }

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

    # Q73 fix: verify THIS run's own log (the folder embedding the
    # checkpoint's RunId), never a newer foreign folder a second instance
    # may have created in the meantime.
    $log = Get-CurrentRunLog -LogsRoot (Join-Path $PartitionRoot 'Logs') -RunId ([string](Get-OrchestratorField -Record $state -Name 'RunId'))
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

# ---------------------------------------------------------------------------
# Application phase: manifest-driven execution with per-entry retries and
# the Q26 Acknowledge-and-Continue payload (Q25/Q26)
# ---------------------------------------------------------------------------

# Q25/Q26 contract: applications are a workflow-FIXED set driven by the
# per-workflow manifest the partition stages at
# Sources\Apps\<Workflow>\manifest.json (the mock partition stages one entry
# per workflow). Every entry carries the same nine fields; entries are
# retried per the manifest's own RetryCount; exhausted entries accumulate
# into the Q26 payload. There is NO per-application interactive prompt
# anywhere in this phase (Q25): the success path is silent, and the
# Acknowledge-and-Continue modal is the CONSUMER's job, driven by
# NeedsAcknowledgement and the Failures payload (Q26) - the modal comes only
# for failures.

# Internal: the nine manifest fields every application entry must carry.
$script:AppManifestFields = @('Id', 'Name', 'Installer', 'Type', 'SilentArgs',
    'SuccessCodes', 'RetryCount', 'TimeoutMinutes', 'Required')

# Internal: validate a parsed manifest document. Returns a string array of
# errors (empty when valid); Invoke-ApplicationPhase throws on ANY error -
# a malformed manifest is a staging bug, not a runtime warning (fail
# closed). Beyond field presence this also rejects shapes the engine could
# not execute honestly: non-string identity fields, an empty or non-numeric
# SuccessCodes list, RetryCount below one, or a negative TimeoutMinutes.
function Test-ApplicationManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Document
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Document) {
        $errors.Add('Manifest document is null.')
        return $errors.ToArray()
    }
    if (-not ($Document -is [System.Array])) {
        $errors.Add('Manifest document is not a JSON array of application entries.')
        return $errors.ToArray()
    }
    $index = 0
    foreach ($entry in @($Document)) {
        $label = ('entry {0}' -f $index)
        $idValue = Get-OrchestratorField -Record $entry -Name 'Id'
        if (-not [string]::IsNullOrWhiteSpace([string]$idValue)) {
            $label = ('entry {0} (Id ''{1}'')' -f $index, $idValue)
        }
        if ($null -eq $entry) {
            $errors.Add(('{0}: entry is null.' -f $label))
            $index++
            continue
        }
        foreach ($field in $script:AppManifestFields) {
            $value = Get-OrchestratorField -Record $entry -Name $field
            if ($null -eq $value) {
                $errors.Add(('{0}: missing required field ''{1}''.' -f $label, $field))
                continue
            }
            if ($field -in @('Id', 'Name', 'Installer', 'Type')) {
                if ([string]::IsNullOrWhiteSpace([string]$value)) {
                    $errors.Add(('{0}: field ''{1}'' must not be empty.' -f $label, $field))
                }
                continue
            }
            # SilentArgs may legitimately be an empty string (an installer
            # taking no arguments); it must merely be present. Required is
            # a presence-only boolean carried for consumers.
            if ($field -eq 'SilentArgs' -or $field -eq 'Required') { continue }
            if ($field -eq 'SuccessCodes') {
                $codes = @($value)
                if ($codes.Count -lt 1) {
                    $errors.Add(('{0}: SuccessCodes must list at least one code.' -f $label))
                    continue
                }
                foreach ($code in $codes) {
                    try { $null = [long]$code }
                    catch {
                        $errors.Add(('{0}: SuccessCodes entries must be integers (''{1}'').' -f $label, $code))
                    }
                }
                continue
            }
            # RetryCount and TimeoutMinutes must be whole numbers; a
            # non-numeric value throws in the [int] cast and is reported
            # here instead of surfacing mid-run.
            $number = 0
            $isNumber = $true
            try { $number = [int]$value }
            catch { $isNumber = $false }
            if (-not $isNumber) {
                $errors.Add(('{0}: field ''{1}'' must be a whole number.' -f $label, $field))
                continue
            }
            if ($field -eq 'RetryCount' -and $number -lt 1) {
                $errors.Add(('{0}: RetryCount must be at least 1, got {1}.' -f $label, $number))
            }
            if ($field -eq 'TimeoutMinutes' -and $number -lt 0) {
                $errors.Add(('{0}: TimeoutMinutes must be 0 or more, got {1}.' -f $label, $number))
            }
        }
        $index++
    }
    return $errors.ToArray()
}

# Internal: classify one Runner attempt against the entry contract.
# $TimedOut is the combined verdict (the phase clock met the deadline OR
# the runner self-reported TimedOut). Returns @{ Success; Status; ExitCode }
# with the Status vocabulary used verbatim in the Q26 payload:
# - 'Complete': ExitCode is in SuccessCodes, or the runner returned
#   boolean $true (a runner that already evaluated the outcome).
# - 'Failed': the attempt finished but its ExitCode is not in SuccessCodes
#   (or the runner returned exactly $false).
# - 'TimedOut': the attempt ran past TimeoutMinutes. ExitCode still reports
#   whatever the runner produced (often $null for a killed process).
# - 'Error': the runner threw or produced nothing - fail closed, no
#   success is ever inferred from an absent report.
function Get-AttemptOutcome {
    [CmdletBinding()]
    param(
        $Output,
        [string]$RunError,
        [bool]$TimedOut,
        $SuccessCodes
    )
    $exitValue = $null
    if ($null -ne $Output -and -not ($Output -is [bool])) {
        $exitProp = $Output.PSObject.Properties['ExitCode']
        if ($null -ne $exitProp -and $null -ne $exitProp.Value) { $exitValue = $exitProp.Value }
    }
    if ($TimedOut) {
        return @{ Success = $false; Status = 'TimedOut'; ExitCode = $exitValue }
    }
    if (-not [string]::IsNullOrEmpty($RunError)) {
        return @{ Success = $false; Status = 'Error'; ExitCode = $null }
    }
    if ($null -eq $Output) {
        return @{ Success = $false; Status = 'Error'; ExitCode = $null }
    }
    if ($Output -is [bool]) {
        if ($Output) { return @{ Success = $true; Status = 'Complete'; ExitCode = $null } }
        return @{ Success = $false; Status = 'Failed'; ExitCode = $null }
    }
    if ($null -eq $exitValue) {
        return @{ Success = $false; Status = 'Error'; ExitCode = $null }
    }
    # A report whose ExitCode is not numeric at all (a malformed runner
    # return) is a failed attempt, never an escaping cast exception.
    $numericExit = $true
    try { $null = [long]$exitValue }
    catch { $numericExit = $false }
    if (-not $numericExit) {
        return @{ Success = $false; Status = 'Error'; ExitCode = $null }
    }
    foreach ($code in @($SuccessCodes)) {
        if ([long]$code -eq [long]$exitValue) {
            return @{ Success = $true; Status = 'Complete'; ExitCode = $exitValue }
        }
    }
    return @{ Success = $false; Status = 'Failed'; ExitCode = $exitValue }
}

function Invoke-ApplicationPhase {
    <#
        .SYNOPSIS
        Executes the per-workflow application manifest with per-entry
        retries and the Q26 Acknowledge-and-Continue payload.

        .DESCRIPTION
        Q25/Q26: applications are a workflow-FIXED set driven by the
        manifest at -ManifestPath (a JSON ARRAY of entries, each carrying
        Id, Name, Installer, Type, SilentArgs, SuccessCodes, RetryCount,
        TimeoutMinutes, Required). A missing file, unparseable JSON, a
        non-array document, or any entry failing field validation THROWS:
        a malformed manifest is a staging bug, never a runtime warning
        (fail closed). An empty array is valid and completes Ok.

        Per entry, the Runner is invoked up to RetryCount TOTAL attempts
        (retry = re-invoke the Runner; exit 1 twice then 0 satisfies
        RetryCount 3 on the third attempt). The Runner receives ONE
        context object:
        @{ Entry = <the manifest entry>; InstallerPath; SilentArgs;
           LogLocation; TimeoutMinutes; NowUtc; DeadlineUtc }
        - InstallerPath resolves a relative Installer BESIDE the manifest
          (the staged Sources\Apps\<Workflow> layout); a rooted Installer
          is used exactly as written.
        - LogLocation is the per-entry log path <manifest dir>\Logs\<Id>.log
          (a computed reporting path; the deployed host's installer
          logging consumes it - nothing is created here).
        - DeadlineUtc is the attempt's timeout deadline; a cooperating
          runner can self-enforce it.
        The Runner reports an outcome by returning an object with an
        ExitCode property (the Start-Process -PassThru shape), or boolean
        $true. Failure signals: throwing, returning exactly $false,
        returning nothing, a non-numeric report, an object with TimedOut
        = $true, or an ExitCode not in SuccessCodes.

        Default Runner (used when -Runner is omitted): real silent
        execution - Start-Process -FilePath <InstallerPath>
        -ArgumentList <SilentArgs> -PassThru, then a BOUNDED wait. Full
        timeout enforcement for a real installer is Windows behavior;
        where practical it is implemented as the .NET bounded
        Process.WaitForExit(milliseconds) call (Start-Process -Wait has no
        timeout parameter): a timed-out process is force-killed and
        reported as TimedOut with no ExitCode, and TimeoutMinutes 0 kills
        without waiting at all.

        Timeout clock model (deterministic by design): each attempt's
        deadline is (phase clock + TimeoutMinutes), where the phase clock
        is -Now when bound (normalized to UTC, FROZEN at that value) and
        the live [DateTime]::UtcNow otherwise; the attempt is judged
        timed-out when the clock at judgment meets the deadline. With
        -Now bound and TimeoutMinutes 0, deadline == frozen clock, so
        every attempt deterministically times out regardless of the -Now
        value; with -Now bound and TimeoutMinutes above 0, phase-level
        timeout is suspended (the runner's own bounded wait remains the
        enforcer); without -Now the live clock gives real elapsed-time
        enforcement.

        Returns @{ Ok; Failures; NeedsAcknowledgement }: Ok = $true only
        with zero failures; NeedsAcknowledgement = $true exactly when
        failures exist (the Acknowledge-and-Continue modal payload - the
        modal itself is the consumer's job and comes only for failures).
        Each Failure carries EXACTLY the four Q26 fields: Program (= Name),
        Status ('Failed' / 'TimedOut' / 'Error', the final attempt's
        classification), ExitCode (the reported code, $null when none),
        and LogLocation. Required is validated for presence but does not
        differentiate behavior here: every exhausted entry fails the
        phase; consumers may read it from the manifest when presenting the
        modal. NO interactive prompt exists anywhere in this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [scriptblock]$Runner,
        [datetime]$Now
    )
    # --- Load and validate the manifest (fail closed) ----------------------
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw ("Application manifest not found at '{0}'. The phase never invents entries; verify partition staging." -f $ManifestPath)
    }
    try {
        $entries = Read-JsonFile -Path $ManifestPath
    }
    catch {
        throw ("Application manifest at '{0}' could not be parsed: {1}" -f $ManifestPath, $_.Exception.Message)
    }
    if ($null -eq $entries -or -not ($entries -is [System.Array])) {
        # Pipeline enumeration unwraps a top-level JSON array (the same
        # reason Get-FlatInventory uses the comma trick): a 1-entry
        # manifest arrives as the bare entry object and a 0-entry one as
        # $null. Array-ness is therefore decided on the RAW document text:
        # a leading '[' means the document IS an array and the parsed value
        # is re-wrapped to match; anything else is a genuinely non-array
        # document and fails closed in the validator below.
        $raw = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::ASCII).TrimStart()
        if ($raw.Length -gt 0 -and $raw[0] -eq '[') {
            $entries = @($entries)
        }
    }
    $errors = Test-ApplicationManifest -Document $entries
    if (@($errors).Count -gt 0) {
        throw ("Application manifest at '{0}' failed its contract: {1}" -f $ManifestPath, ($errors -join '; '))
    }

    $runner = $Runner
    if ($null -eq $runner) {
        # Default (real) runner: see the .DESCRIPTION timeout note. The
        # mocked-process shapes tests use (HasExited already true) skip the
        # wait entirely; WaitForExit/Stop-Process are Windows behaviors on
        # the deployed host.
        $runner = {
            param($Context)
            $proc = Start-Process -FilePath $Context.InstallerPath -ArgumentList $Context.SilentArgs -PassThru
            $timedOut = $false
            if ([int]$Context.TimeoutMinutes -le 0) {
                $timedOut = $true
            }
            elseif (-not $proc.HasExited) {
                $seconds = [int][Math]::Round([double]$Context.TimeoutMinutes * 60)
                if (-not $proc.WaitForExit($seconds * 1000)) { $timedOut = $true }
            }
            if ($timedOut) {
                if (-not $proc.HasExited) {
                    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
                }
                return [pscustomobject]@{ ExitCode = $null; TimedOut = $true }
            }
            return $proc
        }
    }

    # --- Execute entries, retrying per the manifest ------------------------
    $nowBound = $PSBoundParameters.ContainsKey('Now')
    $nowClock = $null
    if ($nowBound) { $nowClock = $Now.ToUniversalTime() }
    $manifestDir = Split-Path -Parent $ManifestPath
    $failures = @()
    foreach ($entry in @($entries)) {
        $id = [string](Get-OrchestratorField -Record $entry -Name 'Id')
        $name = [string](Get-OrchestratorField -Record $entry -Name 'Name')
        $installer = [string](Get-OrchestratorField -Record $entry -Name 'Installer')
        $silentArgs = [string](Get-OrchestratorField -Record $entry -Name 'SilentArgs')
        $codes = @(Get-OrchestratorField -Record $entry -Name 'SuccessCodes')
        $retryCount = [int](Get-OrchestratorField -Record $entry -Name 'RetryCount')
        $timeoutMinutes = [int](Get-OrchestratorField -Record $entry -Name 'TimeoutMinutes')
        if ([System.IO.Path]::IsPathRooted($installer)) {
            $installerPath = $installer
        }
        else {
            $installerPath = Join-Path $manifestDir $installer
        }
        $logLocation = Join-Path $manifestDir ('Logs\' + $id + '.log')
        $succeeded = $false
        $lastStatus = 'Error'
        $lastExit = $null
        for ($attempt = 1; $attempt -le $retryCount; $attempt++) {
            $attemptStart = [DateTime]::UtcNow
            if ($nowBound) { $attemptStart = $nowClock }
            $deadline = $attemptStart.AddMinutes([double]$timeoutMinutes)
            $context = @{
                Entry          = $entry
                InstallerPath  = $installerPath
                SilentArgs     = $silentArgs
                LogLocation    = $logLocation
                TimeoutMinutes = $timeoutMinutes
                NowUtc         = $attemptStart
                DeadlineUtc    = $deadline
            }
            $runError = $null
            $output = $null
            try { $output = & $runner $context }
            catch { $runError = $_.Exception.Message }
            $judged = [DateTime]::UtcNow
            if ($nowBound) { $judged = $nowClock }
            $runnerTimedOut = $false
            if ($null -ne $output -and -not ($output -is [bool])) {
                $timedProp = $output.PSObject.Properties['TimedOut']
                if ($null -ne $timedProp -and $timedProp.Value -eq $true) { $runnerTimedOut = $true }
            }
            $timedOut = ($judged -ge $deadline) -or $runnerTimedOut
            $outcome = Get-AttemptOutcome -Output $output -RunError $runError -TimedOut $timedOut -SuccessCodes $codes
            if ($outcome.Success) {
                $succeeded = $true
                break
            }
            $lastStatus = $outcome.Status
            $lastExit = $outcome.ExitCode
        }
        if (-not $succeeded) {
            $failures += @{
                Program     = $name
                Status      = $lastStatus
                ExitCode    = $lastExit
                LogLocation = $logLocation
            }
        }
    }
    return @{
        Ok                  = (@($failures).Count -eq 0)
        Failures            = @($failures)
        NeedsAcknowledgement = (@($failures).Count -gt 0)
    }
}

# ---------------------------------------------------------------------------
# EZT workflow specifics: unattend autologon fragment, account plan,
# password transition, activation flow (Q14/Q15/Q16/Q18/Q19/Q24/Q86)
# ---------------------------------------------------------------------------

# REGISTRY STORE INTERFACE (injectable, platform-independent)
#
# Windows registry operations in this section are abstracted behind a
# plain-hashtable "registry store" so the logic runs (and is tested) on
# any platform; the CI suite executes on Linux. The store shape is:
#
#   @{ <registry path string> = @{ <value name> = <value>; ... }; ... }
#
# Example (the deployed EZT Winlogon state, Q16/Q24):
#
#   @{ 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' =
#       @{ DefaultUserName = 'User'; DefaultPassword = ''; AutoAdminLogon = '1' } }
#
# Contract, implemented by the helpers directly below:
# - Set-RegistryStoreValue creates the path's value table when missing and
#   sets the value name. Hashtable keys are case-insensitive, matching
#   Windows registry value-name semantics.
# - Remove-RegistryStoreValue deletes the value name; an absent name is a
#   no-op (idempotent removal - exactly what the Q86 credential clear
#   needs).
# - Path keys are literal path strings; every caller in this module uses
#   the $script:EztWinlogonPath constant so code and tests cannot drift.
# A Get/read helper joins this interface together with its first reader
# (the host wiring or the recovery path that restores the passwordless
# automatic-sign-on state); it is not added speculatively now.
# The real Windows registry adapter arrives with the host wiring change
# and is injected through the same -Registry parameter.

$script:EztWinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# Default store used when -Registry is not injected. Tests always inject a
# fresh fixture; a later host-wiring change binds the real adapter here.
$script:RegistryStore = @{}

# Internal: set one registry value in the store, creating the path's value
# table when missing.
function Set-RegistryStoreValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    if (-not $Registry.Contains($Path) -or $null -eq $Registry[$Path]) {
        $Registry[$Path] = @{}
    }
    $Registry[$Path][$Name] = $Value
}

# Internal: remove one registry value name from the store; absent names are
# a no-op.
function Remove-RegistryStoreValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Registry,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Registry.Contains($Path)) { return }
    $values = $Registry[$Path]
    if ($null -eq $values) { return }
    if ($values.Contains($Name)) {
        $null = $values.Remove($Name)
    }
}

function New-EztUnattend {
    <#
        .SYNOPSIS
        Builds the EZT unattend XML fragment: registry-sync automatic
        sign-on for the passwordless User account (Q14/Q15/Q16/Q24).

        .DESCRIPTION
        Q16 requires UNLIMITED persistent automatic sign-in, so this
        function implements the REGISTRY-SYNC form: the specialize pass
        carries RunSynchronous reg add commands that write the three
        Winlogon values - DefaultUserName = 'User', DefaultPassword = ''
        (the passwordless account's empty credential), and AutoAdminLogon
        = '1'. There is deliberately NO AutoLogonCount element or value
        anywhere: a count would cap automatic sign-in at N sign-ins,
        which Q16 supersedes. Invoke-EztAccountPhase re-asserts the same
        values at runtime through the registry store interface.

        Q18: no product-key field exists anywhere in the document. The
        UserData element carries only the EULA acceptance, and the
        windowsPE ImageInstall MetaData pins the applied image by NAME
        ('Windows 11 <Edition>'); its <Key> child is the image-metadata
        selector (/IMAGE/NAME), never license-key material. Product-key
        entry happens transiently in the activation flow
        (Invoke-ActivationFlow) and is never written to unattend content.

        -Edition selects the image name; -TimeZone lands in the oobeSystem
        Microsoft-Windows-Shell-Setup element. Both are XML-escaped.
        Computer naming is not automated (Q13): no ComputerName element is
        written. Returns the document as a string (parseable with [xml]).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][string]$TimeZone
    )
    $imageValue = [System.Security.SecurityElement]::Escape(('Windows 11 ' + $Edition))
    $timeZoneValue = [System.Security.SecurityElement]::Escape($TimeZone)
    $template = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>{0}</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>EZT automatic sign-on: default user name (Q16)</Description>
          <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d "User" /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>EZT automatic sign-on: empty credential for the passwordless account (Q14)</Description>
          <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "" /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>EZT automatic sign-on: automatic logon value on, with no count so sign-in stays unlimited (Q16)</Description>
          <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d "1" /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <TimeZone>{1}</TimeZone>
    </component>
  </settings>
</unattend>
'@
    return ($template -f $imageValue, $timeZoneValue)
}

function Invoke-EztAccountPhase {
    <#
        .SYNOPSIS
        Builds and executes the EZT account plan: passwordless User,
        disabled built-in Administrator, managed password shortcut
        (Q14/Q15/Q24).

        .DESCRIPTION
        The plan carries EXACTLY four steps:
        1. CreateUser - the local account 'User', passwordless
           (Password = $null, Passwordless = $true) per Q14/Q15.
        2. AddGroupMember - 'User' into 'Administrators': a local
           administrator account that is NOT the built-in one.
        3. EnsureUserDisabled - the built-in 'Administrator' STAYS
           disabled (Q24); the step is an idempotent ensure. The plan
           contains NO enable action anywhere: EZT never activates the
           built-in account.
        4. CreateShortcut - 'Set or Change Your Password' on the common
           (public) desktop C:\Users\Public\Desktop, targeting the staged
           managed workflow entry point
           C:\ProgramData\OSDeploy\Set-OwnerPassword.ps1 (TargetKind =
           'ManagedWorkflow'). Per Q15 the shortcut NEVER targets
           ms-settings:signinoptions: it launches the managed graphical
           transition backed by Invoke-PasswordTransition (Q86). The
           launcher's final on-host form arrives with the host wiring;
           the contract locked here is the managed-workflow target.

        Execution model: each step object is handed to -Runner in plan
        order. The DEFAULT Runner is a recorder that acknowledges each
        step without side effects, so planning stays inspectable on any
        platform; the real Windows account operations arrive with the host
        wiring as an injected Runner. A Runner signals failure by throwing
        or by returning boolean $false (the module-wide failure
        convention); the failure propagates and nothing later runs.

        When -Registry is bound, a fully successful execution seeds the
        three persistent Winlogon automatic sign-on values through the
        registry store - the runtime re-assertion of the unattend's
        registry sync (Q16/Q24: unlimited sign-in, no count). Seeding
        happens only after every step succeeded; a failed step leaves the
        store untouched. Omitting -Registry skips the re-assertion.

        Returns @{ Steps; Executed }: the plan and the steps the Runner
        processed successfully.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Registry,
        [scriptblock]$Runner
    )
    $steps = @(
        @{ Action = 'CreateUser'; Name = 'User'; Password = $null; Passwordless = $true }
        @{ Action = 'AddGroupMember'; Name = 'User'; Group = 'Administrators' }
        @{ Action = 'EnsureUserDisabled'; Name = 'Administrator' }
        @{
            Action     = 'CreateShortcut'
            Name       = 'Set or Change Your Password'
            Directory  = 'C:\Users\Public\Desktop'
            Target     = 'C:\ProgramData\OSDeploy\Set-OwnerPassword.ps1'
            TargetKind = 'ManagedWorkflow'
        }
    )
    $runner = $Runner
    if ($null -eq $runner) {
        # Default Runner: the recorder. Real Windows account work arrives
        # with the host wiring as an injected Runner.
        $runner = { param($Step) return $true }
    }
    $executed = @()
    foreach ($step in $steps) {
        $output = & $runner $step
        if ($output -is [bool] -and $output -eq $false) {
            throw ('Account phase step {0} failed: the Runner signalled failure (boolean $false). No later step runs and no registry seeding happens.' -f $step.Action)
        }
        $executed += $step
    }
    if ($null -ne $Registry) {
        Set-RegistryStoreValue -Registry $Registry -Path $script:EztWinlogonPath -Name 'DefaultUserName' -Value 'User'
        Set-RegistryStoreValue -Registry $Registry -Path $script:EztWinlogonPath -Name 'DefaultPassword' -Value ''
        Set-RegistryStoreValue -Registry $Registry -Path $script:EztWinlogonPath -Name 'AutoAdminLogon' -Value '1'
    }
    return @{ Steps = @($steps); Executed = @($executed) }
}

function Invoke-PasswordTransition {
    <#
        .SYNOPSIS
        Q86's ONE controlled transition: warn, set the password, disable
        automatic sign-on, clear the stored credential.

        .DESCRIPTION
        Exact order (assertable through AppliedSteps and the warning):
        1. Warn - Write-Warning tells the owner that a successful change
           ends automatic sign-in (Q86's warning requirement).
        2. SetPassword - the injected scriptblock is invoked as
           & $SetPassword -NewPassword <password>. A THROW propagates
           unchanged BEFORE any state is touched; a boolean $false return
           is the module-wide failure signal and throws here too. In both
           failure shapes ALL THREE states stay untouched: the password
           is not set, AutoAdminLogon keeps its value, and the
           DefaultPassword value is NOT removed.
        3. DisableAutoLogon - AutoAdminLogon is set to '0' in the registry
           store; reached only when the password change succeeded.
        4. ClearCredential - the DefaultPassword value is REMOVED from
           the store (deleted, not blanked: the stale credential must not
           exist at all).

        The DEFAULT SetPassword (when -SetPassword is omitted) is the
        deployed-host path: ConvertTo-SecureString plus Set-LocalUser on
        the 'User' account. It needs the Windows commands and the host
        wiring; tests always inject.

        -Registry is the injectable registry store; when omitted the
        module's default store is used (the host wiring later binds the
        real adapter there). The transition never writes an AutoLogonCount
        value (Q16: unlimited sign-in has no counter to adjust).

        Returns @{ AppliedSteps } - the ordered record of what ran.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$NewPassword,
        [scriptblock]$SetPassword,
        [hashtable]$Registry
    )
    $store = $Registry
    if ($null -eq $store) { $store = $script:RegistryStore }
    $setPasswordRunner = $SetPassword
    if ($null -eq $setPasswordRunner) {
        $setPasswordRunner = {
            param([Parameter(Mandatory)][string]$NewPassword)
            $secure = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force
            Set-LocalUser -Name 'User' -Password $secure
        }
    }
    $applied = @()

    # Step 1: the Q86 warning comes first, before anything is asked of the
    # password callback.
    Write-Warning -Message ('Setting a password will turn off automatic sign-in for the User account. ' +
        'After this change Windows asks for the new password at sign-in; password-protected automatic sign-in is not supported.')
    $applied += 'Warn'

    # Step 2: the password change. Failure (throw or $false) surfaces
    # before any of the three state writes below.
    $output = & $setPasswordRunner -NewPassword $NewPassword
    if ($output -is [bool] -and $output -eq $false) {
        throw 'The password change was reported as failed by the SetPassword callback (boolean $false). No state was changed.'
    }
    $applied += 'SetPassword'

    # Step 3: disable automatic sign-on in the registry store.
    Set-RegistryStoreValue -Registry $store -Path $script:EztWinlogonPath -Name 'AutoAdminLogon' -Value '0'
    $applied += 'DisableAutoLogon'

    # Step 4: clear the stored automatic-logon credential (remove, not
    # blank).
    Remove-RegistryStoreValue -Registry $store -Path $script:EztWinlogonPath -Name 'DefaultPassword'
    $applied += 'ClearCredential'

    return @{ AppliedSteps = @($applied) }
}

function Invoke-ActivationFlow {
    <#
        .SYNOPSIS
        Shapes the Q19 activation decision surface when activation could
        not be completed.

        .DESCRIPTION
        -ActivationResult is a STATUS TOKEN, never key material:
        - 'Succeeded' (case-insensitive): activation completed; the flow
          returns Incomplete = $false with NO choices.
        - ANY other value ('Failed', 'TimedOut', 'Offline', ...): the
          activation is incomplete, and the return carries the three Q19
          choices - 'Retry' (Q19's Retry Activation), 'Finish Without
          Activation', and 'Cancel' - with Incomplete = $true recording
          the incomplete state.

        Q18: this function has NO key parameter and its return NEVER
        includes key material. Product keys are handled transiently by
        the activation UI and are never stored or logged; the return
        object is exactly @{ ActivationResult; Choices; Incomplete } - a
        status echo and decision data, nothing else. The warning Q19
        requires before finishing without activation belongs to the
        consumer that acts on the 'Finish Without Activation' choice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActivationResult
    )
    if ($ActivationResult -ieq 'Succeeded') {
        return @{ ActivationResult = $ActivationResult; Choices = @(); Incomplete = $false }
    }
    return @{
        ActivationResult = $ActivationResult
        Choices          = @('Retry', 'Finish Without Activation', 'Cancel')
        Incomplete       = $true
    }
}

# ---------------------------------------------------------------------------
# MMC workflow specifics and the Energy Star phase (Q14/Q15/Q30/Q32,
# Q20-Q23)
# ---------------------------------------------------------------------------

function Get-MmcPlan {
    <#
        .SYNOPSIS
        Returns the MMC workflow plan: the Audit-Mode finalize/sysprep
        sequence with NO EZT account work (Q14/Q15/Q30/Q32).

        .DESCRIPTION
        MMC's final endpoint is Windows OOBE (Q14) reached from Audit Mode
        (Q30). Steps is the finalize sequence Invoke-MmcFinalize executes:
        cleanup of the temporary deployment artifacts FIRST, then Sysprep
        /generalize /oobe whose failure routing stays in Audit Mode (Q32).

        AccountSteps is EMPTY BY CONSTRUCTION: unlike the EZT account plan
        (CreateUser / AddGroupMember / EnsureUserDisabled /
        CreateShortcut), MMC creates no User account, seeds no autologon,
        and adds no password shortcut (Q14/Q15) - MMC delivers mostly
        default customer-facing setup at OOBE. The plan is pure data; the
        consumer executes the finalize sequence through Invoke-MmcFinalize.

        Returns @{ Workflow; FinalEndpoint; Steps; AccountSteps } where
        each Step carries Order, Action, and (for the sysprep step)
        Arguments and OnFailure.
    #>
    [CmdletBinding()]
    param()
    return @{
        Workflow      = 'MMC'
        FinalEndpoint = 'OOBE'
        Steps         = @(
            @{ Order = 1; Action = 'CleanupTemporaryArtifacts' }
            @{
                Order     = 2
                Action    = 'Sysprep'
                Arguments = '/generalize /oobe'
                OnFailure = 'StayInAuditMode'
            }
        )
        AccountSteps  = @()
    }
}

function Invoke-MmcFinalize {
    <#
        .SYNOPSIS
        MMC finalize IN Audit Mode: cleanup of temporary artifacts first,
        then Sysprep /generalize /oobe (Q30/Q32).

        .DESCRIPTION
        Exact order (assertable through an injected call log): the Cleanup
        scriptblock runs FIRST - removing the temporary deployment
        artifacts Audit-Mode staging leaves behind - and only then is the
        Sysprep scriptblock invoked. Completion is recorded ONLY when the
        Sysprep call succeeds (Q32): @{ Outcome = 'Complete' }.

        Sysprep failure contract: the Sysprep scriptblock FAILS by
        throwing, by returning exactly boolean $false (the module-wide
        convention), or by returning an object with a non-zero ExitCode
        (the Start-Process -PassThru shape; every non-zero code counts -
        an absent or non-numeric ExitCode is a failure too, never an
        escaping cast exception). Every failure shape returns
        @{ Outcome = 'SysprepFailure'; StayInAuditMode = $true } - the
        BLOCKING technician error that keeps the machine in Audit Mode -
        and NEVER re-runs cleanup: cleanup already ran BEFORE the OOBE
        entry attempt, and no cleanup runs after it (Q32: run no cleanup
        after entering OOBE). The caller routes SysprepFailure to the
        blocking Technician Review; there is no Ignore/Continue path.

        Cleanup failure contract: the Cleanup scriptblock fails by
        throwing or by returning boolean $false, and the failure THROWS out
        of this function BEFORE the Sysprep call is made - with temporary
        artifacts still present the machine must not enter OOBE, so it
        stays in Audit Mode by construction.

        Defaults (both injectable):
        - Cleanup: a recorder that returns the temporary-artifact removal
          steps as data without side effects (the deploy-host-only
          pattern; the real artifact set is host-specific and arrives
          with the host wiring, which injects the performing scriptblock).
        - Sysprep: the REAL call - sysprep.exe /generalize /oobe - a
          deploy-host-only path that maps a non-zero exit code to boolean
          $false so the failure contract above stays uniform; the
          successful call is what initiates the reboot into OOBE (Q32).
          Tests always inject.

        Returns @{ Outcome = 'Complete' } exactly when the Sysprep call
        succeeded.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$Sysprep,
        [scriptblock]$Cleanup
    )
    $cleanupRunner = $Cleanup
    if ($null -eq $cleanupRunner) {
        $cleanupRunner = {
            return @(
                @{ Step = 'RemoveTemporaryArtifacts'; Target = 'Audit-Mode staging artifacts (temporary deployment files)' }
            )
        }
    }
    $sysprepRunner = $Sysprep
    if ($null -eq $sysprepRunner) {
        $sysprepRunner = {
            # String interpolation, not Join-Path: the deploy-host path is
            # drive-qualified and Join-Path rejects an absent drive when the
            # suite stages $env:SystemRoot on a non-Windows platform.
            $sysprepExe = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
            $proc = Start-Process -FilePath $sysprepExe -ArgumentList '/generalize', '/oobe' -Wait -PassThru
            if ($null -ne $proc) {
                $exitProp = $proc.PSObject.Properties['ExitCode']
                if ($null -ne $exitProp -and $null -ne $exitProp.Value -and [int]$exitProp.Value -ne 0) {
                    return $false
                }
            }
            return $true
        }
    }
    # Cleanup FIRST (Q30). Its output is only inspected for the failure
    # signal; the recorded steps never leak into this function's output.
    $cleanupOutput = & $cleanupRunner
    if ($cleanupOutput -is [bool] -and $cleanupOutput -eq $false) {
        throw 'MMC finalize cleanup failed (boolean $false). Nothing entered OOBE; the machine stays in Audit Mode.'
    }
    # THEN Sysprep (Q30/Q32). Every failure shape below keeps the machine
    # in Audit Mode and never re-runs cleanup.
    $output = $null
    $failed = $false
    try { $output = & $sysprepRunner }
    catch { $failed = $true }
    if (-not $failed -and $output -is [bool] -and $output -eq $false) {
        $failed = $true
    }
    if (-not $failed -and $null -ne $output -and -not ($output -is [bool])) {
        $exitProp = $output.PSObject.Properties['ExitCode']
        if ($null -ne $exitProp) {
            $exitValue = $exitProp.Value
            $numericExit = $true
            try { $null = [long]$exitValue }
            catch { $numericExit = $false }
            # Fail closed: an absent, non-numeric, or non-zero exit code in a
            # PassThru-shaped report is a sysprep failure, never a success.
            if (-not $numericExit -or $null -eq $exitValue -or [long]$exitValue -ne 0) {
                $failed = $true
            }
        }
    }
    if ($failed) {
        return @{ Outcome = 'SysprepFailure'; StayInAuditMode = $true }
    }
    return @{ Outcome = 'Complete' }
}

# Q23: the regulated-state list is configurable and evaluated only at
# deployment time. 'CA' is the confirmed member today (Q22); later
# server-side list changes affect new deployments only, and deployed
# systems never phone home for state policy.
$script:RegulatedStates = @('CA')

# Q20's decision vocabulary: the technician's overridable choice for a
# matched state. 'Apply' is the default for matched states; 'Decline' is
# the saved form of Q20's Do-Not-Apply choice (the warning Q20 requires
# before honoring a Decline belongs to the consumer acting on it).
$script:PowerDecisionValues = @('Apply', 'Decline')

function Resolve-PowerPolicy {
    <#
        .SYNOPSIS
        Q20-Q23 power-policy decision table: regulated-state evaluation,
        the per-workflow popup flag, and the saved-decision short-circuit.

        .DESCRIPTION
        Detection (returned when -SavedDecision is NOT bound - the
        deployment-time first evaluation, Q23):
        - Regulated state + MMC -> @{ Action = 'Apply'; Popup = $false;
          Policy = <regulated descriptor> }: Energy Star settings with NO
          popup (Q22).
        - Regulated state + EZT -> @{ Action = 'Apply'; Popup = $true;
          Policy = <regulated descriptor> }: Energy Star settings PLUS the
          persistent choice popup (Q22).
        - Unregulated state -> @{ Action = 'Apply'; Popup = $false;
          Policy = <unregulated descriptor> }: High Performance with a
          60-minute display timeout and system sleep disabled (Q22).
        'Apply' is the default for matched states (Q20); unregulated rows
        apply their policy outright - there is no choice surface. Policy
        descriptors are FRESH objects per call: regulated = the Energy
        Star configuration; unregulated = PowerPlan 'High Performance',
        DisplayTimeoutMinutes 60, SystemSleep 'Disabled'.

        RegulatedState is compared case-insensitively against the
        configurable regulated-state list (Q23). -Workflow matches 'MMC'
        or 'EZT' case-insensitively and defaults to 'MMC' (the no-popup
        profile - the conservative default for a customer-facing popup);
        an unknown workflow token THROWS, because popup semantics are
        never guessed.

        Saved decision (Q20/Q21):
        - VALID ('Apply' or 'Decline', case-insensitive, surrounding
          whitespace tolerated; the canonical token is returned)
          short-circuits detection: @{ Action = <canonical saved token>;
          Popup = <per table>; FromSaved = $true }. FromSaved = $true is
          the Q21 no-re-ask marker: the consumer replays the decision
          without presenting the popup. The Policy descriptor is
          deliberately absent from this shape; it depends only on
          RegulatedState/-Workflow, so the consumer re-derives it from the
          detection table (a call without -SavedDecision).
        - MISSING (bound but empty/whitespace - a caller that looked for a
          saved decision and found none) or INVALID (any other value)
          re-asks: the detection row for context PLUS the Q21 signal:
          @{ Action = 'Apply'; Popup = <per table>; Policy = <descriptor>;
          NeedsPrompt = $true }. Bound-but-empty and not-bound are
          deliberately different: the first is Factory Recovery finding no
          saved decision, the second is the deployment-time evaluation.

        The Q20 warning required before honoring a Decline, and the Q20/
        Q23 persistence of the effective choice into FactoryProfile.json,
        belong to the consumer; this function is the pure decision table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegulatedState,
        [string]$Workflow = 'MMC',
        [string]$SavedDecision
    )
    $workflowToken = ''
    if ($null -ne $Workflow) { $workflowToken = $Workflow.Trim() }
    if ($workflowToken -ine 'MMC' -and $workflowToken -ine 'EZT') {
        throw ("Unknown workflow '{0}': popup semantics are customer-facing and are never guessed; expected 'MMC' or 'EZT'." -f $workflowToken)
    }
    $isRegulated = @($script:RegulatedStates) -contains $RegulatedState.Trim()
    # The persistent choice popup exists only on the regulated EZT row (Q22).
    $popup = ($isRegulated -and ($workflowToken -ieq 'EZT'))
    # Fresh descriptor objects per call: no caller can mutate another
    # caller's descriptor.
    $policy = $null
    if ($isRegulated) {
        $policy = @{
            Regulated = $true
            Name      = 'EnergyStar'
            PowerPlan = 'Energy Star'
        }
    }
    else {
        $policy = @{
            Regulated             = $false
            Name                  = 'HighPerformance'
            PowerPlan             = 'High Performance'
            DisplayTimeoutMinutes = 60
            SystemSleep           = 'Disabled'
        }
    }
    if ($PSBoundParameters.ContainsKey('SavedDecision')) {
        $saved = ''
        if ($null -ne $SavedDecision) { $saved = $SavedDecision.Trim() }
        $matched = $null
        foreach ($value in @($script:PowerDecisionValues)) {
            if ($saved -ieq $value) { $matched = $value }
        }
        if ($null -ne $matched) {
            return @{ Action = $matched; Popup = $popup; FromSaved = $true }
        }
        # Missing (empty) or invalid: the Q21 ask-again signal, with the
        # detection row carried for context.
        return @{ Action = 'Apply'; Popup = $popup; Policy = $policy; NeedsPrompt = $true }
    }
    return @{ Action = 'Apply'; Popup = $popup; Policy = $policy }
}

# ---------------------------------------------------------------------------
# Windows Update phase: the fixed scope, configurable scan/install/reboot
# cycles, the warn-and-acknowledge leftover, the offline skip, and the
# unhealthy-after-reboot routing (Q88)
# ---------------------------------------------------------------------------

function Get-UpdateScope {
    <#
        .SYNOPSIS
        Returns the workflow-FIXED Windows Update scope (Q88 verbatim).

        .DESCRIPTION
        Q88: updates are SCOPED by fixed include/exclude lists, not by an
        open 'install everything'. Include = Security, Quality,
        ServicingStack, DotNet, Defender; Exclude = Preview, Optional,
        Store, FeatureUpgrade, Driver, Firmware, Bios - exact entries,
        exact order, verbatim. The scope is workflow-fixed: it takes no
        parameters and is never filtered per run. Only the CYCLE COUNT is
        configurable (WindowsUpdate.MaxCycles in the effective
        configuration; the consumer reads the config and passes
        -MaxCycles to Invoke-UpdatePhase).

        Returns a FRESH table per call (the module convention): no caller
        can mutate another caller's lists.
    #>
    [CmdletBinding()]
    param()
    return @{
        Include = @('Security', 'Quality', 'ServicingStack', 'DotNet', 'Defender')
        Exclude = @('Preview', 'Optional', 'Store', 'FeatureUpgrade', 'Driver', 'Firmware', 'Bios')
    }
}

# Internal: normalize one category or scope-token name to lowercase
# alphanumerics so containment comparisons ignore spacing and punctuation
# ('Servicing Stack Updates' and 'ServicingStack' normalize identically).
function Get-NormalizedUpdateToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return (($Value.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

# Internal: extra category-name needles for the Q88 tokens whose Windows
# Update classification names do not CONTAIN the token itself: monthly
# quality updates are classified 'Updates'/'Critical Updates'/'Update
# Rollups', Defender signatures are 'Definition Updates', and the .NET
# product family normalizes to 'net'. Real-host validation of this
# mapping belongs to the host wiring (no Windows host is reachable from
# this suite); the engine treats it as data.
$script:UpdateCategoryNeedles = @{
    quality  = @('updates', 'criticalupdates', 'updaterollups')
    dotnet   = @('net')
    defender = @('definitionupdates')
}

# Internal: classify one found update's category names against the Q88
# scope. EXCLUDE WINS: an update carrying any excluded category (a
# preview, a driver, ...) stays out even when another category would
# include it; then any included category includes the update; anything
# else is 'OutOfScope' (neither installed nor counted as pending).
function Test-ScopedUpdateCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Categories,
        [Parameter(Mandatory)]$Scope
    )
    $excludeNeedles = @()
    foreach ($token in @((Get-OrchestratorField -Record $Scope -Name 'Exclude'))) {
        $needle = Get-NormalizedUpdateToken -Value ([string]$token)
        if ($needle -ne '') { $excludeNeedles += $needle }
    }
    $includeNeedles = @()
    foreach ($token in @((Get-OrchestratorField -Record $Scope -Name 'Include'))) {
        $needle = Get-NormalizedUpdateToken -Value ([string]$token)
        if ($needle -ne '') { $includeNeedles += $needle }
        $extra = $script:UpdateCategoryNeedles[$needle]
        foreach ($alias in @($extra)) {
            if ($null -ne $alias -and [string]$alias -ne '') { $includeNeedles += [string]$alias }
        }
    }
    foreach ($category in @($Categories)) {
        $haystack = Get-NormalizedUpdateToken -Value ([string]$category)
        if ($haystack -eq '') { continue }
        foreach ($needle in $excludeNeedles) {
            if ($haystack.Contains($needle)) { return 'Exclude' }
        }
    }
    foreach ($category in @($Categories)) {
        $haystack = Get-NormalizedUpdateToken -Value ([string]$category)
        if ($haystack -eq '') { continue }
        foreach ($needle in $includeNeedles) {
            if ($haystack.Contains($needle)) { return 'Include' }
        }
    }
    return 'OutOfScope'
}

function Invoke-ScopedUpdatePass {
    <#
        .SYNOPSIS
        The REAL scoped Windows Update pass behind the default Scanner.

        .DESCRIPTION
        Deploy-host-only (the raw Windows Update Agent COM API; tests
        always Mock this function and inject their own Scanner). One
        pass = the work of one cycle: search for not-installed,
        not-hidden updates; classify every find against the Q88 scope
        (Exclude wins - Test-ScopedUpdateCategory); install the in-scope
        set; report what the pass found (and installed), whether the
        engine now needs a reboot, and whether the engine state is
        healthy. The NEXT cycle's scan confirms nothing remains.

        Fail-visible contract: ANY engine failure - including the COM
        classes being absent on a non-Windows host - reports
        Healthy = $false so Invoke-UpdatePhase routes to Technician
        Review. The pass never throws and never invents a clean scan.

        Report: @{ PendingCount; PendingUpdates (@{ Title } per in-scope
        update found this pass); RebootRequired; Healthy }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    try {
        $scope = Get-OrchestratorField -Record $Context -Name 'Scope'
        if ($null -eq $scope) { $scope = Get-UpdateScope }
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        $pending = @()
        foreach ($update in @($searchResult.Updates)) {
            $categories = @($update.Categories | ForEach-Object { $_.Name })
            $decision = Test-ScopedUpdateCategory -Categories $categories -Scope $scope
            if ($decision -eq 'Include') {
                $null = $toInstall.Add($update)
                $pending += @{ Title = [string]$update.Title }
            }
        }
        $rebootRequired = $false
        if (@($pending).Count -gt 0) {
            $installer = New-Object -ComObject Microsoft.Update.Installer
            $installResult = $installer.Install($toInstall)
            $rebootRequired = [bool]$installResult.RebootRequired
        }
        return @{
            PendingCount   = @($pending).Count
            PendingUpdates = @($pending)
            RebootRequired = $rebootRequired
            Healthy        = $true
        }
    }
    catch {
        return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $false }
    }
}

function Invoke-UpdatePhase {
    <#
        .SYNOPSIS
        Runs scoped Windows Update cycles to completion, a
        warn-and-acknowledge leftover, or the offline skip (Q88).

        .DESCRIPTION
        SCANNER CONTRACT (the injectable seam): -Scanner is invoked once
        per cycle with ONE context object
        @{ Cycle = <1-based cycle number>; Scope = <the Get-UpdateScope
        table>; RebootCompleted = <bool> } - RebootCompleted is $true
        only on the FIRST scan after a resumed reboot. The Scanner
        performs that cycle's Windows Update work (scan the scoped set,
        install what it found) and returns a report object with at
        least: PendingCount (in-scope updates this pass found and
        installed; the next cycle's scan confirms completion),
        PendingUpdates, RebootRequired [bool] (the engine needs a
        reboot to finish), and Healthy [bool] (the engine state is
        healthy; $false on any pass - including the first scan after a
        reboot - is the unhealthy-after-reboot condition). Hashtable and
        PSCustomObject reports are both accepted.

        OFFLINE (-Online:$false, the FactoryRecovery shape): returns
        @{ Ok = $true; Skipped = $true; Warning } WITHOUT ever invoking
        the Scanner - offline runs never scan for updates and the
        machine stays eligible (Ok = $true).

        ONLINE: up to -MaxCycles cycles (default 3; the consumer reads
        WindowsUpdate.MaxCycles from the effective configuration and
        passes it here). Per cycle, in this order:
        1. Healthy = $false -> @{ Ok = $false; Outcome =
           'TechnicianReview' } - fail closed, no Ignore/Continue path;
           an unhealthy engine's reboot claim is not trusted, so health
           is judged before anything else.
        2. RebootRequired = $true -> @{ Ok = $true; RebootPending =
           $true; CyclesCompleted = <cycle> }. The restart COMPLETES the
           cycle: the caller initiates the reboot, then resumes with
           -ResumeContext <that CyclesCompleted value>; the resumed call
           continues from where it left (the next cycle number) and the
           first resumed scan runs with RebootCompleted = $true.
        3. PendingCount = 0 -> complete: @{ Ok = $true; CyclesCompleted
           = <cycle> } - no acknowledgement, no warning.
        4. Updates remain -> the next cycle runs.
        After the last allowed cycle still shows pending:
        @{ Ok = $true; NeedsAcknowledgement = $true; Warning;
        CyclesCompleted = <MaxCycles> } - the warn-and-acknowledge
        completion (Q88): leftover updates are left to normal Windows
        Update behavior once acknowledged. Resuming with -ResumeContext
        already at the limit returns the same shape without another
        scan (the budget is exhausted).

        FAILURE CONTRACT: the phase NEVER throws for scanner-REPORTED
        conditions - unhealthy, missing, or malformed report fields fail
        closed to the shapes above (a missing/non-numeric PendingCount
        is treated as updates remaining, driving toward the visible
        acknowledgement rather than a silent success). A THROWING
        Scanner is a caller bug and propagates unchanged. The only
        throws from this function are parameter-contract violations:
        MaxCycles below 1, or a negative ResumeContext.

        Default Scanner (when -Scanner is omitted): delegates to the
        real engine pass Invoke-ScopedUpdatePass (deploy-host-only WUA
        COM; fail-visible Healthy = $false - see its doc comment).
    #>
    [CmdletBinding()]
    param(
        [int]$MaxCycles = 3,
        [bool]$Online = $true,
        [scriptblock]$Scanner,
        [int]$ResumeContext = 0
    )
    if ($MaxCycles -lt 1) {
        throw ("MaxCycles must be at least 1, got {0}." -f $MaxCycles)
    }
    if ($ResumeContext -lt 0) {
        throw ("ResumeContext must be 0 or more, got {0}." -f $ResumeContext)
    }
    if (-not $Online) {
        return @{
            Ok      = $true
            Skipped = $true
            Warning = 'Windows Update phase skipped: this run is offline (Factory Recovery never scans for updates). The machine stays eligible; updates are left to normal Windows Update behavior.'
        }
    }
    if ($ResumeContext -ge $MaxCycles) {
        # Resume with the budget exhausted: the last pass left updates
        # pending a completed restart, and no cycles remain to verify -
        # the warn-and-acknowledge completion, without another scan.
        return @{
            Ok                   = $true
            NeedsAcknowledgement = $true
            Warning              = ('Windows Update cycle budget already exhausted ({0} cycle(s)); the last pass left updates pending a completed restart. Acknowledge to finish; the remaining updates are left to normal Windows Update behavior.' -f $MaxCycles)
            CyclesCompleted      = $MaxCycles
        }
    }
    $scanner = $Scanner
    if ($null -eq $scanner) {
        $scanner = { param($Context) return (Invoke-ScopedUpdatePass -Context $Context) }
    }
    $scope = Get-UpdateScope
    # The first scan of a resumed call follows the completed reboot.
    $rebootCompleted = ($ResumeContext -gt 0)
    $lastPending = 0
    for ($cycle = $ResumeContext + 1; $cycle -le $MaxCycles; $cycle++) {
        $context = @{
            Cycle           = $cycle
            Scope           = $scope
            RebootCompleted = $rebootCompleted
        }
        $report = & $scanner $context
        $rebootCompleted = $false
        # Health first: an unhealthy engine (including the first scan
        # after a reboot, the Q88 unhealthy-after-reboot condition) stops
        # before any further cycle work.
        if (-not [bool](Get-OrchestratorField -Record $report -Name 'Healthy')) {
            return @{ Ok = $false; Outcome = 'TechnicianReview' }
        }
        if ([bool](Get-OrchestratorField -Record $report -Name 'RebootRequired')) {
            # The restart completes this cycle; the resumed call
            # continues at the next cycle number.
            return @{ Ok = $true; RebootPending = $true; CyclesCompleted = $cycle }
        }
        $pendingField = Get-OrchestratorField -Record $report -Name 'PendingCount'
        $pendingCount = 1
        if ($null -ne $pendingField) {
            # A non-numeric report field is a malformed report, never an
            # escaping cast exception: treat it as updates remaining.
            try { $pendingCount = [int]$pendingField } catch { $pendingCount = 1 }
        }
        $lastPending = $pendingCount
        if ($pendingCount -eq 0) {
            return @{ Ok = $true; CyclesCompleted = $cycle }
        }
    }
    return @{
        Ok                   = $true
        NeedsAcknowledgement = $true
        Warning              = ('Windows Update cycles exhausted: {0} cycle(s) ran and {1} scoped update(s) are still pending. Acknowledge to finish; the remaining updates are left to normal Windows Update behavior.' -f $MaxCycles, $lastPending)
        CyclesCompleted      = $MaxCycles
    }
}

# ---------------------------------------------------------------------------
# Final validation, result states, boot-entry registration, log finalization,
# and the phase sequence constant (Q28/Q29, Q67-Q73, Q94 orchestrator portion)
# ---------------------------------------------------------------------------

# The full orchestrator phase sequence, exact order. This is the wiring
# constant the resume engine walks (the phase-sequence integration task and
# the host wiring consume it through Get-PhaseOrder; Invoke-Phase checkpoints
# each entry into CompletedPhases as it completes). Exposed as a getter so a
# foreign scriptblock cannot reach into module scope to read it, and so the
# sequence can never be mutated through a leaked reference.
$script:PhaseOrder = @(
    'Drivers',
    'Applications',
    'WorkflowSpecifics',
    'WindowsUpdate',
    'Activation',
    'FinalValidation',
    'BootEntryRegistration',
    'LogFinalization',
    'Cleanup'
)

function Get-PhaseOrder {
    <#
        .SYNOPSIS
        Returns the exact nine-phase orchestrator sequence (PHASE_ORDER).

        .DESCRIPTION
        Drivers, Applications, WorkflowSpecifics, WindowsUpdate, Activation,
        FinalValidation, BootEntryRegistration, LogFinalization, Cleanup - in
        exactly that order. The constant lives at module scope; this getter
        hands back a FRESH cloned array per call (the module convention), so
        no caller can mutate the sequence another caller reads. The resume
        engine and the host wiring treat this list as the authority for phase
        ordering and for the required-phase set handed to
        Complete-Deployment's -RequiredPhases gate.
    #>
    [CmdletBinding()]
    param()
    # Clone: a new array instance every call, identical content.
    return ([object[]]$script:PhaseOrder).Clone()
}

# The Q28 problem-device vocabulary. A device is healthy ONLY when its Status
# is 'Ok' (case-insensitive); every other value - including an absent, null,
# or unrecognized Status - fails closed as a problem device, canonicalized to
# the matching vocabulary token or to 'Unknown' when nothing matches.
$script:PnpProblemStatuses = @('Unknown', 'Missing', 'Incompatible', 'ProblemCode', 'Unhealthy')

function Invoke-PnpValidation {
    <#
        .SYNOPSIS
        Q28 final validation: classify the PnP rescan and produce exactly ONE
        acknowledged warning listing every problem device.

        .DESCRIPTION
        -Devices is the PnP rescan result handed to the validator: an array
        of device records shaped like Get-PnpDevice output, each carrying at
        least Id, FriendlyName, and a Status problem indicator. DESIGN CHOICE
        (documented): the problem indicator is a 'Status' field whose
        vocabulary is 'Unknown', 'Missing', 'Incompatible', 'ProblemCode',
        and 'Unhealthy'; the ONLY healthy value is 'Ok' (case-insensitive).
        An absent, null, empty, or unrecognized Status fails CLOSED as a
        problem device canonicalized to 'Unknown' - a device whose state
        cannot be established positively is never silently passed (the same
        rule identity validation applies). Hashtable and PSCustomObject
        records are both accepted. The engine does no hardware I/O itself:
        the rescan is the consumer's PnP query, classification is pure.

        ONE WARNING, NEVER N: however many problem devices exist, the result
        carries a SINGLE warning object listing them all - Q28's warning is
        one acknowledged warning, never a warning per device. The warning
        shape is @{ Code = 'PnpDeviceIssues'; Message; Devices } where
        Message names every problem device ('<FriendlyName> (<Status>)'
        joined with '; ') and Devices is the per-device finding list.

        Returns @{ Ok; Warning; Findings }:
        - Ok = $true only when no problem device exists;
        - Warning = the single warning object, or $null when Ok;
        - Findings = the per-device @{ Id; FriendlyName; Status } list
          RETAINED for the summary (the consumer presents these as the
          noted issues even after the warning is acknowledged). Findings are
          in input order and are fresh objects per call.
        Empty or absent device input is not a warning: Ok = $true with a
        null Warning and an empty Findings array.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Devices = @()
    )
    $findings = @()
    foreach ($device in @($Devices)) {
        $token = ''
        if ($null -ne $device) {
            $status = Get-OrchestratorField -Record $device -Name 'Status'
            if ($null -ne $status) { $token = ([string]$status).Trim() }
        }
        if ($token -ieq 'Ok') { continue }
        # Fail closed: anything not explicitly 'Ok' is a problem device. A
        # token matching the vocabulary case-insensitively canonicalizes to
        # it; every other shape (absent, empty, unrecognized) becomes
        # 'Unknown'.
        $canonical = 'Unknown'
        foreach ($problem in $script:PnpProblemStatuses) {
            if ($token -ieq $problem) { $canonical = $problem }
        }
        $id = ''
        $name = ''
        if ($null -ne $device) {
            $id = [string](Get-OrchestratorField -Record $device -Name 'Id')
            $name = [string](Get-OrchestratorField -Record $device -Name 'FriendlyName')
        }
        $findings += @{ Id = $id; FriendlyName = $name; Status = $canonical }
    }
    if (@($findings).Count -eq 0) {
        return @{ Ok = $true; Warning = $null; Findings = @() }
    }
    $parts = @()
    foreach ($finding in @($findings)) {
        $parts += ('{0} ({1})' -f $finding.FriendlyName, $finding.Status)
    }
    $warning = @{
        Code    = 'PnpDeviceIssues'
        Message = ('Final device validation found {0} device(s) with problems: {1}.' -f @($findings).Count, ($parts -join '; '))
        Devices = @($findings)
    }
    return @{ Ok = $false; Warning = $warning; Findings = @($findings) }
}

function Get-TechnicianReviewOptions {
    <#
        .SYNOPSIS
        Returns the Q29 Technician Review options for a failed validation.

        .DESCRIPTION
        Exactly three options, exact order, Q29 verbatim: 'Manual
        Remediation', 'Rescan Devices', 'Rerun Validation'. The consumer
        presents these when a validation failure or retryable condition
        routes to the blocking Technician Review; this function is the pure
        option list (no state, no I/O). A FRESH array is returned per call
        (the module convention).
    #>
    [CmdletBinding()]
    param()
    return @('Manual Remediation', 'Rescan Devices', 'Rerun Validation')
}

function Resolve-ResultState {
    <#
        .SYNOPSIS
        Q67-Q72 result-state resolution: the run's finish label from its
        warnings, their acknowledgement, and the finish submission.

        .DESCRIPTION
        The complete vocabulary is exactly three states - 'Completed',
        'Completed with Warnings', 'Completed with Tech-Addressed Warnings' -
        and NOTHING ELSE: there is deliberately no state that asserts the
        machine is fit to hand off; hand-off fitness is never recorded as a
        run state (Q67-Q72).

        Truth table:
        - No warnings -> 'Completed' (regardless of the other inputs).
        - Warnings AND Acknowledged = $true AND FinishSubmitted = $true ->
          'Completed with Tech-Addressed Warnings' (the technician
          acknowledged the warning list AND the finish was submitted; both
          are required).
        - ANY other warning row (Acknowledged $null = not yet asked,
          Acknowledged $false, or finish submitted without acknowledgement)
          -> 'Completed with Warnings'. Acknowledged-but-not-finished is
          deliberately provisional: the acknowledgement only takes effect
          when the finish lands, so the state reads 'Completed with
          Warnings' until the consumer calls this at finish time with
          FinishSubmitted = $true.

        -Warnings is any warning list (Invoke-PnpValidation's single warning
        object, the update phase's leftover warning, ...); a null, absent,
        or all-null list is 'no warnings' (binding $null to the array
        parameter yields a one-element null array - PowerShell binding, not
        a warning - so null entries are filtered before counting).
        -Acknowledged is three-state: $null = the acknowledgement was never
        asked for.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Warnings = @(),
        [Nullable[bool]]$Acknowledged,
        [bool]$FinishSubmitted = $false
    )
    $present = @()
    foreach ($entry in @($Warnings)) {
        if ($null -ne $entry) { $present += $entry }
    }
    if (@($present).Count -eq 0) { return 'Completed' }
    if ($Acknowledged -eq $true -and $FinishSubmitted) {
        return 'Completed with Tech-Addressed Warnings'
    }
    return 'Completed with Warnings'
}

# Internal: parse raw bcdedit /enum output into per-entry field tables.
# PURE (no I/O) so the deploy-host parsing model is testable on any platform
# against fixture text (fix round 1: the capture used to live inline in
# Invoke-RealBootEntryCheck, gated on the recovery DESCRIPTION match, but
# bcdedit emits device and path BEFORE description - so both stayed empty on
# every real host and the phase could never validate).
#
# Capture model: a line matching 'identifier <value>' OPENS an entry; every
# following '<word key> <value>' line belongs to THAT entry REGARDLESS OF
# ORDER, until the next identifier line opens the next entry. bcdedit noise
# that carries no word key is inert: an entry TITLE line and the dash rule
# do not open entries (a title that FOLLOWS an entry attaches to it under
# its first word - consumers read only the known field keys below, so the
# noise never matters), and an indented continuation line (e.g. a second
# displayorder GUID) matches no field shape and is skipped; the FIRST
# occurrence of a key wins.
#
# Returns @{ Entries = @( @{ Identifier = '<id text>'; Fields = @{
# <lowercase key> = <trimmed value> } } ... ) } in output order. The field
# keys the projection reads: description, device, path (per entry) and
# timeout, default (the {bootmgr} entry).
function Parse-BcdeditOutput {
    [CmdletBinding()]
    param(
        # Deliberately NOT [Parameter(Mandatory)]: real bcdedit output has
        # blank separator lines, and Mandatory on a string-array parameter
        # rejects empty-string ELEMENTS - which would fail the whole check
        # through the shell's catch and return the all-false report on every
        # real host (probed on pwsh 7.4.2; found by the canonical fixture).
        # A null Lines simply parses to zero entries.
        [string[]]$Lines
    )
    $entries = @()
    $current = $null
    if ($null -eq $Lines) { return @{ Entries = @() } }
    foreach ($line in $Lines) {
        if ($line -match '^\s*identifier\s+(.+)$') {
            $current = @{ Identifier = $Matches[1].Trim(); Fields = @{} }
            $entries += $current
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*([A-Za-z]+)\s+(.+)$') {
            $key = $Matches[1].ToLowerInvariant()
            if (-not $current.Fields.Contains($key)) {
                $current.Fields[$key] = $Matches[2].Trim()
            }
        }
    }
    return @{ Entries = @($entries) }
}

# Internal: read one field from a Parse-BcdeditOutput entry, '' when absent.
function Get-BcdEntryField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Name
    )
    $fields = Get-OrchestratorField -Record $Entry -Name 'Fields'
    if ($null -eq $fields) { return '' }
    if (-not $fields.Contains($Name)) { return '' }
    return [string]$fields[$Name]
}

# Internal: the REAL deploy-host boot check behind the default BootTool.
# Deploy-host-only SHELL: obtains the raw text (bcdedit.exe, READ-ONLY
# /enum all; the engine never mutates the store here) and delegates ALL
# parsing to the pure Parse-BcdeditOutput. The projection below - like the
# WUA COM body in Invoke-ScopedUpdatePass - belongs to the host wiring's
# live validation pass; the PARSING MODEL and the REPORT CONTRACT are what
# the suite locks (Parse-BcdeditOutput through fixture tests, the report
# contract and registration logic through the injected -BootTool seam).
#
# Fail-visible contract: ANY failure - including bcdedit.exe being absent on
# a non-Windows host - returns the all-false report so the caller fails
# closed (Blocked). This function never throws and never invents a pass.
function Invoke-RealBootEntryCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context
    )
    $report = @{
        EntryPresent        = $false
        TimeoutSeconds      = 0
        WindowsDefault      = $false
        PartitionIdentityOk = $false
        BootFilesOk         = $false
    }
    try {
        # String interpolation, not Join-Path: the deploy-host path is
        # drive-qualified and Join-Path rejects an absent drive when the
        # suite stages $env:SystemRoot on a non-Windows platform.
        $bcdedit = "$env:SystemRoot\System32\bcdedit.exe"
        if (-not (Test-Path -LiteralPath $bcdedit)) { return $report }
        $lines = [string[]](@(& $bcdedit /enum all) | ForEach-Object { [string]$_ })
        if ($null -eq $lines) { $lines = [string[]]@() }
        $parsed = Parse-BcdeditOutput -Lines $lines

        # Entry presence: the persistent Factory Recovery entry's
        # description (the description string the host wiring registers;
        # matched case-insensitively).
        $recovery = $null
        foreach ($entry in @($parsed.Entries)) {
            $description = Get-BcdEntryField -Entry $entry -Name 'description'
            if ($description -imatch 'OSDeploy Factory Recovery') { $recovery = $entry }
        }
        if ($null -eq $recovery) { return $report }
        $report.EntryPresent = $true

        # Boot manager defaults: the {bootmgr} entry's timeout and default.
        $bootMgr = $null
        foreach ($entry in @($parsed.Entries)) {
            if ([string]$entry.Identifier -ieq '{bootmgr}') { $bootMgr = $entry }
        }
        $timeoutText = ''
        $defaultTarget = ''
        if ($null -ne $bootMgr) {
            $timeoutText = Get-BcdEntryField -Entry $bootMgr -Name 'timeout'
            $defaultTarget = Get-BcdEntryField -Entry $bootMgr -Name 'default'
        }
        if ($timeoutText -match '^(\d+)$') { $report.TimeoutSeconds = [int]$Matches[1] }
        # Windows is the default when the boot manager's default entry is
        # the Windows loader (winload), not the recovery entry.
        if ($defaultTarget -ne '' -and $defaultTarget -ine [string]$recovery.Identifier) {
            $defaultEntry = $null
            foreach ($entry in @($parsed.Entries)) {
                if ([string]$entry.Identifier -ieq $defaultTarget) { $defaultEntry = $entry }
            }
            if ($null -ne $defaultEntry) {
                $defaultPath = Get-BcdEntryField -Entry $defaultEntry -Name 'path'
                if ($defaultPath -match '(?i)winload\.(efi|exe)') { $report.WindowsDefault = $true }
            }
        }

        # Partition identity: the recovery entry boots from the partition
        # the orchestrator is running from (the PartitionRoot's drive).
        $root = [string](Get-OrchestratorField -Record $Context -Name 'PartitionRoot')
        $deviceText = Get-BcdEntryField -Entry $recovery -Name 'device'
        $recoveryDevice = ''
        if ($deviceText -match '^partition=(.+)$') { $recoveryDevice = $Matches[1].Trim() }
        if ($recoveryDevice -ne '' -and $root -ne '') {
            $rootDrive = ([System.IO.Path]::GetPathRoot($root.TrimEnd('\')) + '\')
            if ($rootDrive -ne '\' -and $recoveryDevice.TrimEnd('\') -ieq $rootDrive.TrimEnd('\')) {
                $report.PartitionIdentityOk = $true
            }
        }
        # No partition root in the context and no device to compare is not a
        # validated identity - fail closed (the fields stay $false).

        # Boot files: the recovery entry's declared path exists on its
        # declared device partition.
        if ($report.PartitionIdentityOk) {
            $recoveryPath = Get-BcdEntryField -Entry $recovery -Name 'path'
            if ($recoveryPath -ne '') {
                $bootFile = Join-Path ($recoveryDevice.TrimEnd('\') + '\') $recoveryPath.TrimStart('\')
                if (Test-Path -LiteralPath $bootFile) { $report.BootFilesOk = $true }
            }
        }
        return $report
    }
    catch {
        return $report
    }
}

function Invoke-BootEntryRegistration {
    <#
        .SYNOPSIS
        Q94 orchestrator portion: register and validate the persistent
        Factory Recovery boot entry, clear the deployment-only override, and
        block completion on any failure.

        .DESCRIPTION
        BOOT TOOL CONTRACT (the injectable seam): -BootTool is invoked ONCE
        with a context object @{ PartitionRoot = <string or ''> } and returns
        a report carrying at least five fields (hashtable or PSCustomObject):
        EntryPresent [bool] (the persistent Factory Recovery entry exists),
        TimeoutSeconds (the boot-manager timeout; the Q94 contract is FIVE
        seconds), WindowsDefault [bool] (Windows is the default entry, not
        the recovery entry), PartitionIdentityOk [bool] (the entry's
        partition identity matches the orchestrator's partition), and
        BootFilesOk [bool] (the entry's boot files validate). The tool
        READS/CHECKS the boot configuration; registration itself is the
        deploy host's boot step this phase wraps.

        Outcomes (exactly three keys):
        - Registered = $true only when EntryPresent AND TimeoutSeconds = 5
          AND WindowsDefault - the Q94 persistent-entry contract.
        - Validated = $true only when PartitionIdentityOk AND BootFilesOk.
        - Blocked = $true on ANY failure: an unregistered outcome, a failed
          validation, a throwing tool, a malformed or missing report field
          (fail closed - nothing is ever inferred from an absent field), or
          a failure to clear the override marker. Complete-Deployment treats
          Blocked as a completion blocker through its -RequiredPhases gate:
          the sequence engine records the BootEntryRegistration phase
          complete only when this returns Blocked = $false, so a blocked
          registration surfaces as RequiredWorkIncomplete.

        SUCCESS ALSO CLEARS the deployment-only boot override (Q94): when
        registered, validated, and not blocked, the one-time override marker
        <PartitionRoot>\State\BootOverride.json is DELETED (the persistent
        Factory Recovery entry now governs; the deployment-only override is
        spent). An absent marker is a no-op success. A DIRECTORY squatting
        on the marker path is reported as Blocked rather than blindly
        deleted (the Invoke-Cleanup convention). With -PartitionRoot
        unbound there is no marker location to clear.

        Default BootTool (when -BootTool is omitted): delegates to the
        internal Invoke-RealBootEntryCheck - the REAL bcdedit-based check
        (deploy-host-only, read-only, fail-visible; see its doc comment).
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$BootTool,
        [string]$PartitionRoot = ''
    )
    $tool = $BootTool
    if ($null -eq $tool) {
        $tool = { param($Context) return (Invoke-RealBootEntryCheck -Context $Context) }
    }
    $registered = $false
    $validated = $false
    $report = $null
    $toolFailed = $false
    try { $report = & $tool @{ PartitionRoot = $PartitionRoot } }
    catch { $toolFailed = $true }
    if (-not $toolFailed -and $null -ne $report) {
        $entryPresent = [bool](Get-OrchestratorField -Record $report -Name 'EntryPresent')
        $windowsDefault = [bool](Get-OrchestratorField -Record $report -Name 'WindowsDefault')
        # A missing or non-numeric TimeoutSeconds can never satisfy the
        # five-second contract: fail closed instead of throwing.
        $timeoutOk = $false
        $timeoutField = Get-OrchestratorField -Record $report -Name 'TimeoutSeconds'
        if ($null -ne $timeoutField) {
            try { if ([int]$timeoutField -eq 5) { $timeoutOk = $true } }
            catch { $timeoutOk = $false }
        }
        $registered = $entryPresent -and $timeoutOk -and $windowsDefault
        $identityOk = [bool](Get-OrchestratorField -Record $report -Name 'PartitionIdentityOk')
        $bootFilesOk = [bool](Get-OrchestratorField -Record $report -Name 'BootFilesOk')
        $validated = $identityOk -and $bootFilesOk
    }
    $blocked = -not ($registered -and $validated)
    if (-not $blocked -and $PartitionRoot -ne '') {
        # Success clears the deployment-only override (Q94): delete the
        # one-time marker. Unknown directory content squatting on the marker
        # path is never blindly deleted.
        $markerPath = Join-Path $PartitionRoot 'State\BootOverride.json'
        if (Test-Path -LiteralPath $markerPath) {
            $markerItem = Get-Item -LiteralPath $markerPath -Force
            if ($markerItem.PSIsContainer) {
                $blocked = $true
            }
            else {
                try { Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop }
                catch { $blocked = $true }
            }
        }
    }
    return @{ Registered = $registered; Validated = $validated; Blocked = $blocked }
}

function Invoke-LogFinalization {
    <#
        .SYNOPSIS
        Q73 summary gate: the run summary may close only after the log
        verifies.

        .DESCRIPTION
        Gates on Complete-RunLog -Log $Log (the JSONL re-read gate from the
        Logging module): every events line must re-parse as JSON before the
        summary is trustworthy. Returns @{ SummaryMayClose; Verified } -
        the design choice per the contract: the state field is RETURNED
        rather than held in module scope, so every caller (and every retry)
        reads the CURRENT verification. SummaryMayClose stays $false until
        the log verifies; a retry after the log is repaired re-verifies and
        returns $true. Verified mirrors the raw gate result so consumers can
        distinguish 'checked and failed' from unchecked states if they ever
        need to.

        Failure contract: a missing events file, a corrupt line, or a
        malformed log object (no EventsPath - Complete-RunLog's strict-mode
        property access throws) is a verification FAILURE, never an
        exception past this gate. The consumer runs this BEFORE cleanup
        destroys anything else and blocks completion on SummaryMayClose =
        $false (the Q73 order: the summary gate closes before cleanup runs).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Log
    )
    $verified = $false
    try {
        $verified = [bool](Complete-RunLog -Log $Log)
    }
    catch {
        # A malformed log object is a verification failure, never a thrown
        # exception past the summary gate.
        $verified = $false
    }
    return @{ SummaryMayClose = $verified; Verified = $verified }
}

# ---------------------------------------------------------------------------
# The phase-sequence conductor (Q35/Q36/Q89): Invoke-DeploymentSequence walks
# PHASE_ORDER through the Task 18 resume engine and completes through
# Complete-Deployment. The sequence is a CONDUCTOR, not a second engine:
# attempts, checkpointing, reboot marking, and idempotent resume all come
# from Invoke-Phase / Invoke-WithAttempts.
# ---------------------------------------------------------------------------

# The partition root the conductor is currently walking. The default phase
# actions below address the partition through THIS module-scope variable
# instead of a closure: GetNewClosure re-binds a scriptblock to a throwaway
# dynamic module whose $script: scope is empty and whose chain cannot see
# module-internal functions (probed on pwsh 7.4.2), while a plain
# module-authored scriptblock resolves both. Sharing one root is safe
# BECAUSE the single-instance contract (Q35/Q36) admits exactly one
# conductor per process at a time; the conductor sets this right after a
# successful entry.
$script:SequencePartitionRoot = ''

# Internal: parse the staged effective-config snapshot. Returns $null when
# the file is absent; parse errors propagate to the caller's fail-closed
# contract. The document shape is Save-ConfigSnapshot's:
# { Values; Version; Source; Fallbacks; Warnings; SavedUtc } - the resolved
# VALUES live under .Values, NOT at the top level (final-review F1: a
# top-level read silently ignored every configured value and always fell
# back to the engine defaults).
function Read-StagedConfigSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot
    )
    $snapshotPath = Join-Path $PartitionRoot 'Sources\Config\effective-config.json'
    if (-not (Test-Path -LiteralPath $snapshotPath)) { return $null }
    return (Read-JsonFile -Path $snapshotPath)
}

# Internal: best-effort structured event into the CURRENT run's OWN log
# (RunId-preferred folder selection). Q84 config-provenance and Q90
# integrity events must never BLOCK the spine: any failure (no run folder
# yet, unwritable events file) is swallowed - the host wrapper creates the
# run folder at launch, so on the deployed host the events always land.
function Write-ConductorEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Data = @{}
    )
    try {
        $log = Get-CurrentRunLog -LogsRoot (Join-Path $PartitionRoot 'Logs') -RunId $RunId
        if ($null -eq $log) { return }
        Add-LogEvent -Log $log -Event $Event -Data $Data
    }
    catch { }
}

# Internal: the deploy-host-only REAL system identity behind the conductor's
# DEFAULT identity provider (final-review F4). MachineId is the SMBIOS
# machine UUID (Win32_ComputerSystemProduct.UUID); DiskId is the boot disk's
# unique id (Get-Disk). Both commands are Windows-only: on any other host
# the class/disk query fails and the function THROWS - fail visible, exactly
# like the Get-PnpDevice rescan in FinalValidation - because identity is
# established positively or not at all. The exact DiskId derivation may be
# refined by the host wiring as long as it stays deterministic per machine;
# the injectable -IdentityProvider parameter is the seam for that.
function Get-RealSystemIdentity {
    [CmdletBinding()]
    param()
    $machine = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    $machineId = [string]$machine.UUID
    $bootDisk = Get-Disk -ErrorAction Stop |
        Where-Object { $_.IsBoot } |
        Select-Object -First 1
    $diskId = ''
    if ($null -ne $bootDisk) { $diskId = [string]$bootDisk.UniqueId }
    if ([string]::IsNullOrWhiteSpace($machineId) -or [string]::IsNullOrWhiteSpace($diskId)) {
        throw 'Get-RealSystemIdentity could not establish the machine or disk identity (empty value); identity is established positively or not at all.'
    }
    return @{ MachineId = $machineId; DiskId = $diskId }
}

# Internal: the Q35 identity-on-return gate for conductor re-entry. Runs
# ONLY when the loaded checkpoint carries RebootPending = $true (a restart
# is outstanding: 'validate identity on return'). Expected identity comes
# from State\ReadinessRecord.json (the staging-time record); ACTUAL identity
# comes from the injectable provider. Both MachineId AND DiskId must match
# case-insensitively, and neither side may be empty - the same positive-
# establishment rule Resume-AfterReboot applies. A match clears the durable
# marker through the tested engine path (Resume-AfterReboot re-validates the
# STATE identity against the same record and checkpoints RebootPending =
# $false). ANY failure - unreadable readiness record, throwing or malformed
# provider, or a genuine mismatch - returns Outcome 'IdentityMismatch' with
# a distinguishing Reason: identity that cannot be established positively is
# never a pass, the caller stops fail-closed, and NOTHING is mutated.
function Invoke-IdentityEntryGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [Parameter(Mandatory)][scriptblock]$Provider
    )
    $readinessPath = Join-Path $PartitionRoot 'State\ReadinessRecord.json'
    $expectedMachine = ''
    $expectedDisk = ''
    try {
        $readiness = Read-JsonFile -Path $readinessPath
        $expectedMachine = [string](Get-OrchestratorField -Record $readiness -Name 'MachineId')
        $expectedDisk = [string](Get-OrchestratorField -Record $readiness -Name 'DiskId')
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($expectedMachine) -or [string]::IsNullOrWhiteSpace($expectedDisk)) {
        return @{ Ok = $false; Outcome = 'IdentityMismatch'; Reason = 'ReadinessRecordUnavailable' }
    }
    $actual = $null
    try { $actual = & $Provider }
    catch {
        return @{ Ok = $false; Outcome = 'IdentityMismatch'; Reason = 'IdentityProviderFailed' }
    }
    $actualMachine = [string](Get-OrchestratorField -Record $actual -Name 'MachineId')
    $actualDisk = [string](Get-OrchestratorField -Record $actual -Name 'DiskId')
    if ([string]::IsNullOrWhiteSpace($actualMachine) -or [string]::IsNullOrWhiteSpace($actualDisk)) {
        return @{ Ok = $false; Outcome = 'IdentityMismatch'; Reason = 'IdentityProviderFailed' }
    }
    $machineOk = ($actualMachine -eq $expectedMachine)
    $diskOk = ($actualDisk -eq $expectedDisk)
    if (-not ($machineOk -and $diskOk)) {
        return @{ Ok = $false; Outcome = 'IdentityMismatch'; Reason = 'IdentityMismatch' }
    }
    $resume = Resume-AfterReboot -Expected @{ MachineId = $expectedMachine; DiskId = $expectedDisk }
    if ([string]$resume.Outcome -ne 'Ready') {
        return @{ Ok = $false; Outcome = 'IdentityMismatch'; Reason = 'IdentityMismatch' }
    }
    return @{ Ok = $true }
}

# Internal: the Q90/Q92 orchestrator-integrity entry gate. Before first
# execution and after every restart (i.e., on every conductor entry that
# will run phase work), the staged orchestrator copy is rechecked against
# the staging-time integrity record:
# - Directory: <PartitionRoot>\OrchestratorRuntime - the suite stand-in for
#   the deployed C:\ProgramData\OSDeploy\Orchestrator the bootstrap stages.
# - Record: <PartitionRoot>\State\IntegrityRecord.json - stored 'with the
#   authoritative deployment state on the recovery partition' (Q90).
# - Repair source: <PartitionRoot>\Sources\Orchestrator - the LOCAL
#   partition recovery content ONLY (Q91: the parameter list of
#   Repair-FromLocalSource cannot even express a server path).
# A healthy recheck passes silently (one IntegrityValidated event). A failed
# recheck routes through local-only repair and revalidation; a repair that
# still fails validation is a blocking Technician Review - no Ignore/
# Continue-Anyway path, zero phase work, zero state mutation. A missing or
# unparseable record is a STAGING error and stops the same way: the record
# is staging-time truth and is never re-recorded or defaulted at runtime.
# Validation and refresh results land in the run's own log (Q90).
# KNOWN BEHAVIOR: a LogVerification-blocked re-entry (cleanup already removed
# OrchestratorRuntime, Result still null) shows an all-Missing signature, so
# this gate re-stages the home from the repair source on every retry boot -
# the retried completion then removes it again. The cycle is deliberate:
# the record cannot distinguish 'cleanup removed the home' from 'corruption
# did', and repairing toward the staging-time truth is the fail-closed
# direction Q90 specifies. No data is at risk (Sources\Orchestrator is
# immutable recovery content) and the outcome stays Blocked.
function Invoke-EntryIntegrityGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    $orchestratorHome = Join-Path $PartitionRoot 'OrchestratorRuntime'
    $repairSource = Join-Path $PartitionRoot 'Sources\Orchestrator'
    $recordPath = Join-Path $PartitionRoot 'State\IntegrityRecord.json'
    if (-not (Test-Path -LiteralPath $recordPath)) {
        Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityRecordMissing'
        return @{ Ok = $false; Outcome = 'TechnicianReview'; Reason = 'IntegrityRecordMissing' }
    }
    $record = $null
    try {
        $record = Read-JsonFile -Path $recordPath
    }
    catch {
        Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityRecordInvalid'
        return @{ Ok = $false; Outcome = 'TechnicianReview'; Reason = 'IntegrityRecordInvalid' }
    }
    $check = Test-Integrity -Directory $orchestratorHome -Record $record
    if ([bool]$check.Ok) {
        Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityValidated'
        return @{ Ok = $true }
    }
    Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityRepairStarted'
    $repair = Repair-FromLocalSource -Directory $orchestratorHome -RepairSource $repairSource -Record $record
    if ([bool]$repair.Repaired) {
        Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityRepaired'
        return @{ Ok = $true }
    }
    Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $RunId -Event 'IntegrityRepairFailed'
    return @{ Ok = $false; Outcome = 'TechnicianReview'; Reason = 'IntegrityRepairFailed' }
}

function New-PhaseAction {
    <#
        .SYNOPSIS
        Returns the DEFAULT action scriptblock for one PHASE_ORDER entry.

        .DESCRIPTION
        The default phase-to-function mapping (the deploy-host wiring).
        Every action follows the module-wide failure convention: throwing
        or returning exactly boolean $false is a FAILURE into the attempt
        engine (three automatic attempts, then the blocking Technician
        Review); anything else is success. Each action addresses the
        partition through $script:SequencePartitionRoot, which the
        conductor binds after entering.

        - Drivers: Invoke-DriverPhase over Sources\Drivers (real silent
          installer execution through the pattern engine, Q96/Q27). An
          Ok = $false result - including unresolved driver failures already
          routed to review by the phase itself - is a phase failure.
        - Applications: Invoke-ApplicationPhase over the per-workflow
          manifest Sources\Apps\<Workflow>\manifest.json (Q25/Q26). A
          missing or malformed manifest throws inside the phase (fail
          closed); exhausted entries (Ok = $false) fail the phase here -
          the Q26 Acknowledge-and-Continue modal is the review-path
          consumer's job, not the unattended sequence's.
        - WorkflowSpecifics: EZT -> Invoke-EztAccountPhase against the
          module's default registry store (its default Runner is the
          recorder; the real Windows account operations arrive with the
          host wiring, which also binds the real registry adapter into the
          store). MMC -> Invoke-MmcFinalize (the real sysprep default);
          a SysprepFailure outcome is a phase failure (Q32: the machine
          stays in Audit Mode behind a blocking review). Any other
          workflow token THROWS - workflow semantics are never guessed.
        - WindowsUpdate: Invoke-UpdatePhase online with MaxCycles read
          from the staged effective configuration's Values
          (Sources\Config\effective-config.json -> .Values.WindowsUpdate.
          MaxCycles, Q88/Q84), defaulting to the engine default 3 when the
          file or field is absent. A
          RebootRequired report is translated into the sequence-level
          restart signal (Set-OrchestrationRestartRequested); the
          post-reboot cycle continuation (-ResumeContext) is re-driven by
          the host wiring's runner because the phase engine records the
          phase complete when the restart is requested.
        - Activation: Invoke-ActivationFlow with 'Succeeded' - the
          recorder-form default (the deploy-host-only pattern: the real
          activation call, with its transient product-key handling, arrives
          with the host wiring as an injected PhaseRunners override). An
          Incomplete surface would be a phase failure (the Q19 choices are
          the review path's to present).
        - FinalValidation: the deploy-host PnP rescan (Get-PnpDevice)
          mapped onto the Q28 vocabulary and judged by
          Invoke-PnpValidation. The rescan is Windows-only: on any other
          host the absent cmdlet throws and the attempt engine routes to
          review (fail closed, never an invented clean scan). The one
          acknowledged warning (Q28) and the Q29 review options belong to
          the consumer acting on the failure.
        - BootEntryRegistration: Invoke-BootEntryRegistration against the
          partition root. Blocked = $true is a phase FAILURE routed to
          review, never a skip - the sequence must not complete behind an
          unregistered or unvalidated Factory Recovery entry.
        - LogFinalization: Invoke-LogFinalization (the Q73 pre-cleanup
          summary gate) on the CURRENT run log - the run's OWN folder under
          <PartitionRoot>\Logs (RunId-preferred Get-CurrentRunLog
          selection; a second instance's newer folder is never verified).
          The scheduled-task host wrapper creates the run folder at launch;
          the sequence deliberately does not. No run folder at all, or
          SummaryMayClose = $false, is a phase failure.
        - Cleanup: a deliberate no-op success. The destructive removal is
          Complete-Deployment's own step 2 (Invoke-Cleanup, idempotent),
          which the conductor invokes immediately after this action - the
          Q89 order stays in exactly one place.

        A PHASE_ORDER entry with no case below THROWS: a phase is never
        silently skipped or defaulted beyond its wiring.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase
    )
    switch ($Phase) {
        'Drivers' {
            return {
                $r = Invoke-DriverPhase -Root (Join-Path $script:SequencePartitionRoot 'Sources\Drivers')
                if (-not $r.Ok) { return $false }
                return $true
            }
        }
        'Applications' {
            return {
                $state = (Get-RequiredContext).State
                $manifest = Join-Path $script:SequencePartitionRoot ('Sources\Apps\' + $state.Workflow + '\manifest.json')
                $r = Invoke-ApplicationPhase -ManifestPath $manifest
                if (-not $r.Ok) { return $false }
                return $true
            }
        }
        'WorkflowSpecifics' {
            return {
                $state = (Get-RequiredContext).State
                $workflow = [string]$state.Workflow
                if ($workflow -ieq 'MMC') {
                    $r = Invoke-MmcFinalize
                    if ($r.Outcome -ne 'Complete') { return $false }
                    return $true
                }
                if ($workflow -ieq 'EZT') {
                    # Throws on step failure; the Winlogon re-assertion
                    # seeds the module's default registry store.
                    $null = Invoke-EztAccountPhase -Registry $script:RegistryStore
                    return $true
                }
                throw ("WorkflowSpecifics has no wiring for workflow '{0}'; workflow semantics are never guessed." -f $workflow)
            }
        }
        'WindowsUpdate' {
            return {
                $maxCycles = 3
                $snapshot = Read-StagedConfigSnapshot -PartitionRoot $script:SequencePartitionRoot
                if ($null -ne $snapshot) {
                    # F1: the resolved values live under .Values (the
                    # Save-ConfigSnapshot shape), never at the top level. A
                    # parse failure throws (fail closed into the attempt
                    # engine); only an absent file or field falls back to 3.
                    $values = Get-OrchestratorField -Record $snapshot -Name 'Values'
                    $section = $null
                    if ($null -ne $values) { $section = Get-OrchestratorField -Record $values -Name 'WindowsUpdate' }
                    $field = $null
                    if ($null -ne $section) { $field = Get-OrchestratorField -Record $section -Name 'MaxCycles' }
                    if ($null -ne $field) { $maxCycles = [int]$field }
                }
                $r = Invoke-UpdatePhase -MaxCycles $maxCycles
                if (-not $r.Ok) { return $false }
                # Strict-mode-safe read: the non-reboot success shapes carry
                # no RebootPending key at all.
                $rebootField = Get-OrchestratorField -Record $r -Name 'RebootPending'
                if ($null -ne $rebootField -and [bool]$rebootField) {
                    Set-OrchestrationRestartRequested
                }
                return $true
            }
        }
        'Activation' {
            return {
                $r = Invoke-ActivationFlow -ActivationResult 'Succeeded'
                if ($r.Incomplete) { return $false }
                return $true
            }
        }
        'FinalValidation' {
            return {
                $devices = @(Get-PnpDevice | ForEach-Object {
                    [pscustomobject]@{
                        Id           = $_.InstanceId
                        FriendlyName = $_.FriendlyName
                        Status       = [string]$_.Status
                    }
                })
                $r = Invoke-PnpValidation -Devices $devices
                if (-not $r.Ok) { return $false }
                return $true
            }
        }
        'BootEntryRegistration' {
            return {
                $r = Invoke-BootEntryRegistration -PartitionRoot $script:SequencePartitionRoot
                if ($r.Blocked) { return $false }
                return $true
            }
        }
        'LogFinalization' {
            return {
                $state = (Get-RequiredContext).State
                # RunId-preferred selection (Q73 fix): verify THIS run's own
                # log, never a newer foreign folder a second instance created.
                $log = Get-CurrentRunLog -LogsRoot (Join-Path $script:SequencePartitionRoot 'Logs') -RunId ([string](Get-OrchestratorField -Record $state -Name 'RunId'))
                if ($null -eq $log) { return $false }
                $r = Invoke-LogFinalization -Log $log
                if (-not $r.SummaryMayClose) { return $false }
                return $true
            }
        }
        'Cleanup' {
            return {
                # No-op success: the destructive work is Complete-Deployment's
                # own step 2 (Invoke-Cleanup, idempotent), invoked by the
                # conductor right after this action.
                return $true
            }
        }
        default {
            throw ("No default action is wired for phase '{0}'; wire it in New-PhaseAction or inject a PhaseRunners override." -f $Phase)
        }
    }
}

function Invoke-DeploymentSequence {
    <#
        .SYNOPSIS
        Walks PHASE_ORDER through the resume engine and completes the run.

        .DESCRIPTION
        The conductor over the whole installed-Windows deployment sequence.
        Enter-Orchestrator provides the single-instance gate and loads the
        authoritative checkpoint from <PartitionRoot>\State\
        DeploymentState.json (the file is the only state source). A loaded
        checkpoint that already carries a Result is a POST-COMPLETION
        restart (Q89): the conductor delegates IMMEDIATELY to
        Invoke-PostCompletionRestart (cleanup only - no entry gates, no
        phase machinery) and returns the PostCompletionRestart shape.
        Otherwise, in order: ONE config-provenance event is written to the
        run's own log (Q84: source, version, and fallbacks from the staged
        effective-config snapshot), then the ENTRY GATES run before any
        phase work:
        1. Identity gate (Q35 'validate identity on return') - ONLY when
           the checkpoint carries RebootPending = $true. Expected identity
           comes from State\ReadinessRecord.json, actual identity from the
           -IdentityProvider scriptblock (invoked with no arguments; must
           return @{ MachineId; DiskId }). The DEFAULT provider is the
           deploy-host-only Get-RealSystemIdentity (fail visible on any
           non-Windows host, like the Get-PnpDevice rescan). Any failure -
           unreadable readiness record, throwing or malformed provider, or
           a genuine mismatch - returns @{ Outcome = 'IdentityMismatch' }
           with a distinguishing Reason: a fail-closed stop with ZERO phase
           work, ZERO destructive steps, and ZERO state mutation. A match
           clears the durable marker through Resume-AfterReboot.
        2. Integrity gate (Q90/Q92) - the staged orchestrator copy
           (OrchestratorRuntime) is rechecked against
           State\IntegrityRecord.json; a failed recheck routes through
           local-only repair (Sources\Orchestrator, Q91) and revalidation,
           and a repair that still fails stops at the blocking Technician
           Review with zero phase work. See Invoke-EntryIntegrityGate.
        Every
        phase in Get-PhaseOrder is then handed to Invoke-Phase with the
        mapped action scriptblock; attempts, per-attempt checkpointing,
        reboot marking, and idempotent resume (a completed phase's action is
        NEVER re-invoked, Q35) are the Task 18 engine's. The sequence is
        re-entrant: a RebootPending outcome is returned to the caller -
        the SYSTEM STARTUP SCHEDULED TASK re-enters this function at the
        next boot, and Enter-Orchestrator reloads the checkpoint then. A
        crash mid-sequence (power loss) leaves the checkpoint recording
        exactly the completed prefix plus the in-flight attempt; the next
        entry resumes by invoking ONLY the incomplete phase's action.

        ACTION MAPPING: each PHASE_ORDER entry resolves to an action through
        -PhaseRunners first (a hashtable of phase name -> scriptblock; the
        integration seam) and New-PhaseAction otherwise (the deploy-host
        default wiring - see its doc comment for the per-phase mapping).
        BootEntryRegistration records complete ONLY when the boot entry is
        NOT Blocked; LogFinalization only when the current run log verifies
        (SummaryMayClose); both are phase failures into the attempt engine
        otherwise - routed to the blocking Technician Review, never
        skipped. KNOWN LIMITATION: the default WindowsUpdate action
        discards CyclesCompleted - when a mid-cycles reboot is signaled, the
        remaining update cycles (and the warn-and-acknowledge surface)
        require host wiring via -PhaseRunners to drive.

        COMPLETION: after the Cleanup phase's action, the conductor calls
        Complete-Deployment -Handoff 'Completed' -RequiredPhases <every
        phase before Cleanup> - the RequiredWorkIncomplete gate is real
        here. The result-state label resolution (Q67-Q72: the
        warnings-based 'Completed with Warnings' family) is the consumer's
        step over the recorded warnings; the conductor records the fixed
        'Completed' handoff. Complete-Deployment keeps its own internal
        post-cleanup log re-verification as the redundant second gate
        behind the LogFinalization phase (the Q73 pre-cleanup gate).

        RETURN SHAPES (exactly these keys):
        - @{ Outcome = 'SecondInstance'; Phase = $null; Completed = $false;
           Result = $null } - Enter-Orchestrator returned Ran = $false
           (Q35/Q36: a concurrent launch exits without work or state
           mutation).
        - @{ Outcome = 'RebootPending'; Phase = <phase>; Completed = $false;
           Result = $null } - a phase completed but requested a restart;
           the caller (the Scheduled Task at next boot) re-enters.
        - @{ Outcome = 'TechnicianReview'; Phase = <phase>; Completed =
           $false; Result = $null } - the phase exhausted its automatic
           attempts (or returned a blocking failure shape); the sequence
           stopped. The caller blocks - there is no Ignore/Continue-Anyway
           path. An ENTRY-GATE stop carries the same Outcome with Phase =
           $null plus a Reason ('IntegrityRecordMissing',
           'IntegrityRecordInvalid', or 'IntegrityRepairFailed'): zero
           phases ran and the checkpoint was not written.
        - @{ Outcome = 'IdentityMismatch'; Phase = $null; Completed =
           $false; Result = $null; Reason = <'IdentityMismatch' |
           'IdentityProviderFailed' | 'ReadinessRecordUnavailable'> } - the
           re-entry identity gate failed: a restart was outstanding and the
           machine/disk identity could not be positively re-established.
           Fail-closed stop with zero mutation; the technician decides
           whether the disk moved or the record is wrong - there is no
           Ignore/Continue-Anyway path.
        - @{ Outcome = 'Blocked'; Phase = 'Cleanup'; Completed = $false;
           BlockedBy = <Complete-Deployment token>; Result = $null } -
           Complete-Deployment refused to record completion
           (CleanupFailure or LogVerification; RequiredWorkIncomplete
           cannot occur through this conductor). The state carries the
           durable block record, and a re-entry retries the completion
           order with every phase already recorded complete.
        - @{ Outcome = 'Completed'; Phase = 'Cleanup'; Completed = $true;
           Result = 'Completed' } - the run is recorded: Result,
           Completed = $true, CompletedUtc written atomically by
           Complete-Deployment, recovery content retained.
        - @{ Outcome = 'PostCompletionRestart'; Phase = 'Cleanup';
           Completed = $true; Ok = <bool>; Result = $null } - the state
           already carries a Result, so Complete-Deployment delegated to
           the Q89 cleanup-only restart; Ok is that cleanup's result.

        PhaseRunners is validated BEFORE any entry is attempted: an unknown
        phase name or a non-scriptblock value throws (a typo'd phase would
        otherwise silently never run), and the single-instance lock is
        never touched on that path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [hashtable]$PhaseRunners,
        [scriptblock]$IdentityProvider
    )
    if ($null -ne $PhaseRunners) {
        $known = Get-PhaseOrder
        foreach ($key in @($PhaseRunners.Keys)) {
            if ($known -notcontains $key) {
                throw ("PhaseRunners key '{0}' is not a PHASE_ORDER phase; a typo'd override would silently never run." -f $key)
            }
            $value = $PhaseRunners[$key]
            if ($null -eq $value -or -not ($value -is [scriptblock])) {
                throw ("PhaseRunners['{0}'] must be a scriptblock (the phase action), got '{1}'." -f $key, $value)
            }
        }
    }
    $entry = Enter-Orchestrator -PartitionRoot $PartitionRoot
    if (-not $entry.Ran) {
        return @{ Outcome = 'SecondInstance'; Phase = $null; Completed = $false; Result = $null }
    }
    # Bind the partition root the default actions address. Safe to hold in
    # module scope because the single-instance contract admits exactly one
    # conductor per process at a time.
    $script:SequencePartitionRoot = $PartitionRoot
    $state = $entry.State
    $runId = [string](Get-OrchestratorField -Record $state -Name 'RunId')

    # Post-completion restart (Q89): a Result already recorded means this
    # entry runs CLEANUP ONLY. Delegating here (before any gate or phase
    # machinery) also keeps the entry integrity gate off the completed
    # partition, whose orchestrator home was already removed by cleanup.
    $recordedResult = Get-OrchestratorField -Record $state -Name 'Result'
    $resultIsSet = ($null -ne $recordedResult)
    if ($resultIsSet -and $recordedResult -is [string] -and $recordedResult -eq '') {
        $resultIsSet = $false
    }
    if ($resultIsSet) {
        $post = Invoke-PostCompletionRestart -PartitionRoot $PartitionRoot
        return @{
            Outcome   = 'PostCompletionRestart'
            Phase     = 'Cleanup'
            Completed = $true
            Ok        = [bool]$post['Ok']
            Result    = $null
        }
    }

    # Q84: ONE config-provenance event at run start - the staging source,
    # resolved version, and applied fallbacks from the staged snapshot.
    # Purely informational (ASCII, no key material, no server paths) and
    # best-effort: an absent or unreadable snapshot is recorded as such,
    # never invented.
    $provenance = @{
        Source    = ''
        Version   = ''
        Fallbacks = @()
    }
    try {
        $snapshot = Read-StagedConfigSnapshot -PartitionRoot $PartitionRoot
        if ($null -ne $snapshot) {
            $provenance['Source'] = [string](Get-OrchestratorField -Record $snapshot -Name 'Source')
            $provenance['Version'] = [string](Get-OrchestratorField -Record $snapshot -Name 'Version')
            $fallbacks = Get-OrchestratorField -Record $snapshot -Name 'Fallbacks'
            if ($null -ne $fallbacks) { $provenance['Fallbacks'] = @($fallbacks) }
        }
        else {
            $provenance['Source'] = '(snapshot missing)'
        }
    }
    catch {
        $provenance['Source'] = '(snapshot unreadable)'
    }
    Write-ConductorEvent -PartitionRoot $PartitionRoot -RunId $runId -Event 'ConfigProvenance' -Data $provenance

    # Entry gate 1 (Q35): validate identity on return, only when a restart
    # is outstanding.
    $rebootPending = Get-OrchestratorField -Record $state -Name 'RebootPending'
    if ($null -ne $rebootPending -and [bool]$rebootPending) {
        $provider = $IdentityProvider
        if ($null -eq $provider) {
            # Deploy-host-only default (fail visible on any non-Windows
            # host); tests and host wiring inject through -IdentityProvider.
            $provider = { Get-RealSystemIdentity }
        }
        $identityGate = Invoke-IdentityEntryGate -PartitionRoot $PartitionRoot -Provider $provider
        if (-not [bool]$identityGate.Ok) {
            return @{
                Outcome   = 'IdentityMismatch'
                Phase     = $null
                Completed = $false
                Result    = $null
                Reason    = $identityGate.Reason
            }
        }
    }

    # Entry gate 2 (Q90/Q92): recheck the staged orchestrator before first
    # execution and after restarts; repair locally, stop at review on the
    # second failure.
    $integrityGate = Invoke-EntryIntegrityGate -PartitionRoot $PartitionRoot -RunId $runId
    if (-not [bool]$integrityGate.Ok) {
        return @{
            Outcome   = 'TechnicianReview'
            Phase     = $null
            Completed = $false
            Result    = $null
            Reason    = $integrityGate.Reason
        }
    }

    $order = Get-PhaseOrder
    foreach ($phase in $order) {
        $action = $null
        if ($null -ne $PhaseRunners -and $PhaseRunners.Contains($phase)) {
            $action = $PhaseRunners[$phase]
        }
        else {
            $action = New-PhaseAction -Phase $phase
        }
        $result = Invoke-Phase -Phase $phase -Action $action
        if ($result.Outcome -eq 'RebootPending') {
            # The phase is complete and the marker is durable; the caller
            # restarts the machine and the Scheduled Task re-enters here.
            return @{ Outcome = 'RebootPending'; Phase = $phase; Completed = $false; Result = $null }
        }
        if ($result.Outcome -eq 'TechnicianReview') {
            # Blocking: the sequence stops at the failed phase. No later
            # phase runs and completion is never recorded.
            return @{ Outcome = 'TechnicianReview'; Phase = $phase; Completed = $false; Result = $null }
        }
        # 'Complete' or 'Skipped' (idempotent resume) - walk on.
        if ($phase -eq 'Cleanup') {
            $required = @($order | Where-Object { $_ -ne 'Cleanup' })
            $completion = Complete-Deployment -PartitionRoot $PartitionRoot -Handoff 'Completed' -RequiredPhases $required
            if ($completion -is [System.Collections.IDictionary] -and $completion.Contains('Completed')) {
                if (-not [bool]$completion['Completed']) {
                    return @{
                        Outcome   = 'Blocked'
                        Phase     = 'Cleanup'
                        Completed = $false
                        BlockedBy = $completion['BlockedBy']
                        Result    = $null
                    }
                }
                return @{
                    Outcome   = 'Completed'
                    Phase     = 'Cleanup'
                    Completed = $true
                    Result    = $completion['Result']
                }
            }
            # Complete-Deployment returned the Invoke-PostCompletionRestart
            # cleanup shape (@{ Ok; Failures }): the state file already
            # carries a Result, so this entry was a post-completion restart
            # and only cleanup ran (Q89).
            return @{
                Outcome   = 'PostCompletionRestart'
                Phase     = 'Cleanup'
                Completed = $true
                Ok        = [bool]$completion['Ok']
                Result    = $null
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Windows-only staging mechanics (Task 28): the NTFS ACL restriction for the
# orchestrator runtime directory and the SYSTEM startup Scheduled Task
# registration the installed-Windows host needs. Both are staging-time
# mechanics: they run where the OSDCloud Deployment Partition is prepared or
# in installed Windows, never on the PXE bootstrap.
#
# Platform contract (identical for all three functions): when the host is not
# Windows ([System.Environment]::OSVersion.Platform -ne 'Win32NT'; $IsWindows
# does not exist in Windows PowerShell 5.1), the function writes ONE warning
# naming the function and 'Windows only' and returns without throwing, so the
# unit suites stay green on the Linux development host. The internal
# -SkipNoop switch bypasses that branch so the Windows code path is directly
# testable; on a non-Windows host it fails VISIBLE (fail closed, never a
# silent pass). Windows-only cmdlets (Get-Acl/Set-Acl,
# New-ScheduledTask*/Register-ScheduledTask/Unregister-ScheduledTask/
# Get-ScheduledTask) are resolved ONLY inside the function bodies at call
# time - never at import time - so module import stays clean on hosts where
# those cmdlets do not exist.
#
# Q91 boundary: every path parameter is a LOCAL path. A UNC path throws
# before any work, in BOTH spellings - '\\server\share\...' and the
# forward-slash form '//server/share/...' that Windows file APIs normalize
# to UNC. No function here names, accepts, or probes DeploymentShare or any
# deployment server.
# ---------------------------------------------------------------------------

function Set-OrchestratorAcl {
    <#
        .SYNOPSIS
        Restricts one local directory's NTFS ACL to exactly SYSTEM and local
        Administrators, inheritance disabled.

        .DESCRIPTION
        Staging-time Windows mechanic for the orchestrator runtime directory
        (the deployed C:\ProgramData\OSDeploy\Orchestrator). The directory
        DACL is replaced with exactly two Allow FullControl rules - NT
        AUTHORITY\SYSTEM (S-1-5-18) and BUILTIN\Administrators
        (S-1-5-32-544), addressed by well-known SID so a locale-specific
        account name can never break the restriction - and inheritance is
        disabled (SetAccessRuleProtection), so the directory keeps only what
        this function grants. Fail closed: after Set-Acl the STORED ACL is
        re-read and verified (inheritance disabled, exactly two rules, both
        identities present, both Allow FullControl); any mismatch throws - an
        ACL failure never surfaces as a silent success.

        Windows only; see the section banner above for the no-op warning /
        -SkipNoop contract. Q91: -Directory must be a LOCAL path; a UNC path
        throws before any ACL work.

        Returns @{ Ok; Directory; Identities } on success and throws on every
        failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [switch]$SkipNoop
    )
    if (-not $SkipNoop -and [System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Warning ("Set-OrchestratorAcl: Windows only; no ACL work was performed on host platform '{0}'." -f [System.Environment]::OSVersion.Platform)
        return
    }
    if ($Directory.StartsWith('\\') -or $Directory.StartsWith('//')) {
        throw ("Set-OrchestratorAcl: -Directory must be a local path; the UNC path '{0}' is never accepted (Q91: no DeploymentShare or server path)." -f $Directory)
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw ("Set-OrchestratorAcl: -Directory '{0}' is not an existing directory." -f $Directory)
    }
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    # Get-Acl/Set-Acl exist only on Windows: they are resolved here, inside
    # the guarded body, never at import time.
    $acl = Get-Acl -LiteralPath $Directory
    # Disable inheritance and DROP the inherited rules: nothing the
    # directory inherited survives the restriction.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in @($acl.Access)) {
        $null = $acl.RemoveAccessRule($existing)
    }
    foreach ($sid in @($systemSid, $adminsSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl
    # Fail-closed verification: prove the restriction is what the DIRECTORY
    # now stores, never trust Set-Acl's quiet return.
    $stored = Get-Acl -LiteralPath $Directory
    if (-not $stored.AreAccessRulesProtected) {
        throw ("Set-OrchestratorAcl: inheritance is still enabled on '{0}' after the ACL write." -f $Directory)
    }
    $entries = @($stored.Access)
    if ($entries.Count -ne 2) {
        throw ("Set-OrchestratorAcl: the stored ACL on '{0}' has {1} access rules; exactly 2 (SYSTEM, Administrators) are required." -f $Directory, $entries.Count)
    }
    $storedSids = @()
    foreach ($entry in $entries) {
        $identity = $entry.IdentityReference
        if ($identity -is [System.Security.Principal.SecurityIdentifier]) {
            $storedSids += $identity.Value
        }
        else {
            $storedSids += [string]$identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        if ($entry.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            throw ("Set-OrchestratorAcl: the stored rule for '{0}' on '{1}' is not an Allow rule." -f $identity.Value, $Directory)
        }
        if (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) {
            throw ("Set-OrchestratorAcl: the stored rule for '{0}' on '{1}' does not grant FullControl." -f $identity.Value, $Directory)
        }
    }
    if ($storedSids -notcontains 'S-1-5-18' -or $storedSids -notcontains 'S-1-5-32-544') {
        throw ("Set-OrchestratorAcl: the stored ACL on '{0}' does not carry exactly SYSTEM and Administrators (found: {1})." -f $Directory, ($storedSids -join ', '))
    }
    return @{ Ok = $true; Directory = $Directory; Identities = @('S-1-5-18', 'S-1-5-32-544') }
}

function Register-OrchestratorTask {
    <#
        .SYNOPSIS
        Registers the SYSTEM startup Scheduled Task and writes its partition
        registration marker.

        .DESCRIPTION
        Staging-time Windows mechanic: registers the orchestrator's SYSTEM
        startup Scheduled Task, the Q35/Q36 reboot re-entry host. Principal:
        UserId SYSTEM, LogonType ServiceAccount, RunLevel Highest - a service
        account boot task needs NO user sign-in and stores no password.
        Trigger: AtStartup. Multiple-instance policy: IgnoreNew, so an
        overlapping start never launches a second concurrent orchestrator
        (the scheduled-task side of the single-instance contract; the mutex
        inside Enter-Orchestrator is the second side). The -Execute /
        -Argument defaults describe the installed-Windows host wiring (the
        entry wrapper the host places in the runtime directory); callers
        override both - the component suite does, to point the task at a
        probe.

        Fail closed: after Register-ScheduledTask the task is re-fetched
        with Get-ScheduledTask and its principal, logon type, run level,
        instance policy, and boot trigger are VERIFIED; any mismatch throws.
        Only after that verification is the registration marker
        <PartitionRoot>\State\TaskRegistration.json written (atomic,
        TaskName + RegisteredUtc) - the exact file Invoke-Cleanup removes at
        completion, so a marked partition always has the verified task and
        the two paths can never drift apart. A missing partition root or
        State directory throws (staging error; state is never invented).

        Windows only; see the section banner above for the no-op warning /
        -SkipNoop contract. Q91: -PartitionRoot must be a LOCAL partition
        path; a UNC path throws before any registration work.

        Returns @{ Ok; TaskName; MarkerPath } on success and throws on every
        failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PartitionRoot,
        [string]$TaskName = 'OSDeploy Orchestrator',
        [string]$Execute = 'powershell.exe',
        [string]$Argument = '-NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\OSDeploy\Orchestrator\Start-Orchestrator.ps1"',
        [switch]$SkipNoop
    )
    if (-not $SkipNoop -and [System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Warning ("Register-OrchestratorTask: Windows only; no Scheduled Task was registered on host platform '{0}'." -f [System.Environment]::OSVersion.Platform)
        return
    }
    if ($PartitionRoot.StartsWith('\\') -or $PartitionRoot.StartsWith('//')) {
        throw ("Register-OrchestratorTask: -PartitionRoot must be a local partition path; the UNC path '{0}' is never accepted (Q91: no DeploymentShare or server path)." -f $PartitionRoot)
    }
    if (-not (Test-Path -LiteralPath $PartitionRoot -PathType Container)) {
        throw ("Register-OrchestratorTask: -PartitionRoot '{0}' does not exist; the OSDCloud Deployment Partition must be staged first." -f $PartitionRoot)
    }
    $stateDir = Join-Path $PartitionRoot 'State'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw ("Register-OrchestratorTask: the State directory does not exist under '{0}'; the OSDCloud Deployment Partition must be staged first." -f $PartitionRoot)
    }
    # New-ScheduledTask*/Register-ScheduledTask/Get-ScheduledTask exist only
    # on Windows: they are resolved here, inside the guarded body, never at
    # import time.
    $action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
    # -Force: re-registration at re-staging overwrites a prior task of the
    # same name instead of failing on the second staging pass.
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop
    # Fail-closed verification: the registered task must exist with EXACTLY
    # the contract above before success (and the marker) can be reported.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ($null -eq $task) {
        throw ("Register-OrchestratorTask: task '{0}' was not found after registration." -f $TaskName)
    }
    $principalId = [string]$task.Principal.UserId
    if ($principalId -ine 'SYSTEM' -and $principalId -ine 'NT AUTHORITY\SYSTEM') {
        throw ("Register-OrchestratorTask: task '{0}' principal is '{1}', expected SYSTEM." -f $TaskName, $principalId)
    }
    if ([string]$task.Principal.LogonType -ine 'ServiceAccount') {
        throw ("Register-OrchestratorTask: task '{0}' logon type is '{1}', expected ServiceAccount." -f $TaskName, [string]$task.Principal.LogonType)
    }
    if ([string]$task.Principal.RunLevel -ine 'Highest') {
        throw ("Register-OrchestratorTask: task '{0}' run level is '{1}', expected Highest." -f $TaskName, [string]$task.Principal.RunLevel)
    }
    if ([string]$task.Settings.MultipleInstances -ine 'IgnoreNew') {
        throw ("Register-OrchestratorTask: task '{0}' multiple-instance policy is '{1}', expected IgnoreNew." -f $TaskName, [string]$task.Settings.MultipleInstances)
    }
    $bootTriggers = @($task.Triggers | Where-Object { [string]$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    if ($bootTriggers.Count -lt 1) {
        throw ("Register-OrchestratorTask: task '{0}' has no boot (startup) trigger." -f $TaskName)
    }
    $markerPath = Join-Path $stateDir 'TaskRegistration.json'
    Write-AtomicJson -Path $markerPath -Value @{
        TaskName      = $TaskName
        RegisteredUtc = [datetime]::UtcNow.ToString('o')
    }
    return @{ Ok = $true; TaskName = $TaskName; MarkerPath = $markerPath }
}

function Unregister-OrchestratorTask {
    <#
        .SYNOPSIS
        Removes the orchestrator Scheduled Task; idempotent and safe to call
        twice.

        .DESCRIPTION
        The retire-side counterpart of Register-OrchestratorTask: unregisters
        the named Scheduled Task and then VERIFIES with Get-ScheduledTask
        that it is gone; a task still present after Unregister-ScheduledTask
        throws (fail closed). When the task does not exist the call is a
        SUCCESS no-op (Existed = $false) - safe to call twice, or on a
        machine whose task was never registered or already retired. The
        partition registration MARKER is deliberately NOT touched here:
        marker removal is Invoke-Cleanup's single responsibility, so
        registration and cleanup can never drift apart.

        Windows only; see the section banner above for the no-op warning /
        -SkipNoop contract.

        Returns @{ Ok; TaskName; Existed } on success and throws on every
        failure.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskName = 'OSDeploy Orchestrator',
        [switch]$SkipNoop
    )
    if (-not $SkipNoop -and [System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Warning ("Unregister-OrchestratorTask: Windows only; no Scheduled Task was removed on host platform '{0}'." -f [System.Environment]::OSVersion.Platform)
        return
    }
    # Get-ScheduledTask/Unregister-ScheduledTask exist only on Windows: they
    # are resolved here, inside the guarded body, never at import time.
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        return @{ Ok = $true; TaskName = $TaskName; Existed = $false }
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    $after = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $after) {
        throw ("Unregister-OrchestratorTask: task '{0}' is still present after unregistration." -f $TaskName)
    }
    return @{ Ok = $true; TaskName = $TaskName; Existed = $true }
}
