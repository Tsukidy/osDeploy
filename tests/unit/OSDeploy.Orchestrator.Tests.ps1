BeforeAll {
    # Mock partition builder (dot-sourced script; imports State/Util/Config).
    . (Join-Path $PSScriptRoot '..\mocks\New-MockPartition.ps1')
    $script:modulePath = Join-Path $PSScriptRoot '..\..\src\Orchestrator\OSDeploy.Orchestrator.psd1'
    Import-Module $script:modulePath -Force
    $script:root = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-' + [guid]::NewGuid().ToString('N')))
    $script:stateDir = Join-Path $script:root 'State'
    $script:statePath = Join-Path $script:stateDir 'DeploymentState.json'
    $script:ckDir = Join-Path ([System.IO.Path]::GetTempPath()) ('orch-ck-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:ckDir | Out-Null

    # SHA-256 fingerprint of every State json file, joined to one comparable
    # string - proves the second-instance path mutates NO state file at all.
    # (Pester 5: helpers used by It blocks must be defined inside BeforeAll.)
    function Get-StateSnapshot {
        param([string]$Directory)
        $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.json' | Sort-Object Name)
        $parts = foreach ($f in $files) { '{0}={1}' -f $f.Name, (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        return ($parts -join '|')
    }

    # Task 18: fresh contract-valid state template for the attempt/resume
    # engine tests. Identity values are the mock partition's fixed GUID-shaped
    # strings so resume-identity assertions are deterministic.
    function New-TestState {
        return @{
            RunId            = '11111111-1111-1111-1111-111111111111'
            MachineId        = '22222222-2222-2222-2222-222222222222'
            DiskId           = '33333333-3333-3333-3333-333333333333'
            Workflow         = 'EZT'
            Edition          = 'Pro'
            Phase            = 'Drivers'
            Attempt          = 0
            RebootPending    = $false
            ConfigVersion    = 'test-v1'
            TimestampUtc     = [datetime]::UtcNow.ToString('o')
            CompletedPhases  = @()
            Result           = $null
            NotedIssues      = @()
            Acknowledgements = @()
        }
    }
}
AfterAll {
    # Release the single-instance lock exactly as the brief prescribes so no
    # hold leaks into later suites running in the same process.
    $mutex = Get-OrchestratorMutex
    if ($null -ne $mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ckDir -ErrorAction SilentlyContinue
}

# ORDER MATTERS: this Describe must run BEFORE 'Enter-Orchestrator single
# instance lock'. A successful entry holds the single-instance lock for the
# process lifetime by contract, so these throw-path tests need a module that
# has not entered yet (Pester runs Describes in file order).
Describe 'Enter-Orchestrator fail-closed state loading' {
    It 'throws when DeploymentState.json is missing and never invents state (Q87/Q89)' {
        $fresh = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-miss-' + [guid]::NewGuid().ToString('N')))
        try {
            Remove-Item (Join-Path $fresh 'State\DeploymentState.json') -Force
            { Enter-Orchestrator -PartitionRoot $fresh } | Should -Throw
            # A fatal entry failure must give the lock back, not poison the process.
            Get-OrchestratorMutex | Should -BeNullOrEmpty
        }
        finally { Remove-Item -Recurse -Force $fresh -ErrorAction SilentlyContinue }
    }
    It 'throws when DeploymentState.json is unparseable' {
        $fresh = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-bad-' + [guid]::NewGuid().ToString('N')))
        try {
            Set-Content -Path (Join-Path $fresh 'State\DeploymentState.json') -Value 'not json at all' -Encoding Ascii
            { Enter-Orchestrator -PartitionRoot $fresh } | Should -Throw
            Get-OrchestratorMutex | Should -BeNullOrEmpty
        }
        finally { Remove-Item -Recurse -Force $fresh -ErrorAction SilentlyContinue }
    }
    It 'throws when DeploymentState.json fails Test-DeploymentState - identity is never defaulted' {
        $fresh = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-inv-' + [guid]::NewGuid().ToString('N')))
        try {
            $bad = @{
                RunId = $null; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
                Phase = 'Drivers'; Attempt = 0; RebootPending = $false; ConfigVersion = 'v1'
                TimestampUtc = '2026-01-01T00:00:00.0000000Z'; CompletedPhases = @(); Result = $null
                NotedIssues = @(); Acknowledgements = @()
            }
            # Reaching the contract check proves the lock was re-acquired after
            # the previous test's fatal entry (a leaked hold would return
            # Ran = $false instead of throwing).
            Write-AtomicJson -Path (Join-Path $fresh 'State\DeploymentState.json') -Value $bad
            { Enter-Orchestrator -PartitionRoot $fresh } | Should -Throw
            Get-OrchestratorMutex | Should -BeNullOrEmpty
        }
        finally { Remove-Item -Recurse -Force $fresh -ErrorAction SilentlyContinue }
    }
}

Describe 'Enter-Orchestrator single instance lock (Q35/Q36)' {
    It 'first entry acquires the lock and returns the loaded partition state' {
        $r = Enter-Orchestrator -PartitionRoot $root
        $r.Ran | Should -BeTrue
        $r.PartitionRoot | Should -Be $root
        $r.State.Phase | Should -Be 'Drivers'
        $r.State.Workflow | Should -Be 'EZT'
        $r.State.Edition | Should -Be 'Pro'
        $r.State.Attempt | Should -Be 0
        $r.State.RunId | Should -Be '11111111-1111-1111-1111-111111111111'
        Get-OrchestratorMutex | Should -Not -BeNullOrEmpty
    }
    It 'a second launch in the same process exits without work or state mutation' {
        $before = Get-StateSnapshot -Directory $stateDir
        $r2 = Enter-Orchestrator -PartitionRoot $root
        $r2.Ran | Should -BeFalse
        Get-StateSnapshot -Directory $stateDir | Should -Be $before
        # The exit is recorded on the partition log as the SecondInstanceExit event.
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $root 'Logs') -Directory)
        $logs.Count | Should -Be 1
        $events = Join-Path $logs[0].FullName 'events.jsonl'
        Test-Path -LiteralPath $events | Should -BeTrue
        ([System.IO.File]::ReadAllText($events)) | Should -Match 'SecondInstanceExit'
        # The first instance keeps the lock.
        Get-OrchestratorMutex | Should -Not -BeNullOrEmpty
    }
    It 'a launch from another thread exits without work (kernel mutex WaitOne(0) path)' {
        if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Start-ThreadJob is not available in this host'
        }
        else {
            $before = Get-StateSnapshot -Directory $stateDir
            # A second runspace on a separate thread is the same-process stand-in
            # for a second orchestrator PROCESS: its fresh module copy reaches the
            # named kernel mutex, which this thread holds (probed: cross-thread
            # WaitOne(0) returns $false on this platform and on Windows).
            $job = Start-ThreadJob -ScriptBlock {
                param($ModulePathParam, $PartitionRootParam)
                Import-Module $ModulePathParam -Force
                return (Enter-Orchestrator -PartitionRoot $PartitionRootParam)
            } -ArgumentList $modulePath, $root
            $remote = Receive-Job -Job $job -Wait
            Remove-Job $job
            $remote.Ran | Should -BeFalse
            Get-StateSnapshot -Directory $stateDir | Should -Be $before
        }
    }
}

Describe 'New-Checkpoint and Get-ResumePoint checkpoint engine' {
    It 'writes an atomic, contract-valid checkpoint stamped with the current UTC time' {
        $state = Read-JsonFile -Path $statePath
        $state.Phase = 'Apps'
        $state.Attempt = 2
        $state.RebootPending = $true
        $state.CompletedPhases = @('Prepare', 'Drivers')
        $cp = Join-Path $ckDir 'cp1.json'
        $written = New-Checkpoint -State $state -Path $cp
        Test-Path -LiteralPath $cp | Should -BeTrue
        $written.Phase | Should -Be 'Apps'
        # TimestampUtc is stamped as an ISO 8601 UTC string. Asserted on the raw
        # file text because pwsh 7 ConvertFrom-Json auto-types ISO strings to
        # [datetime] (Task 16 note); never hardcode the value.
        ([System.IO.File]::ReadAllText($cp)) | Should -Match '"TimestampUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
        ([string]$written.TimestampUtc) | Should -Match 'Z$'
        (Test-DeploymentState -Record (Read-JsonFile -Path $cp)).Valid | Should -BeTrue
        @(Get-ChildItem -LiteralPath $ckDir -Filter '*.tmp*').Count | Should -Be 0
    }
    It 'round-trips phase, attempt, and completion through Get-ResumePoint with arrays preserved' {
        $cp1 = Join-Path $ckDir 'cp1.json'
        $rp = Get-ResumePoint -Path $cp1
        $rp.Phase | Should -Be 'Apps'
        $rp.Attempt | Should -Be 2
        $rp.RebootPending | Should -BeTrue
        $rp.CompletedPhases -is [System.Array] | Should -BeTrue
        @($rp.CompletedPhases).Count | Should -Be 2
        ($rp.CompletedPhases -join ',') | Should -Be 'Prepare,Drivers'
        # Single- and zero-element completions must still arrive as arrays.
        $state2 = Read-JsonFile -Path $statePath
        $state2.CompletedPhases = @('Prepare')
        $cp2 = Join-Path $ckDir 'cp2.json'
        $null = New-Checkpoint -State $state2 -Path $cp2
        $rp2 = Get-ResumePoint -Path $cp2
        $rp2.CompletedPhases -is [System.Array] | Should -BeTrue
        @($rp2.CompletedPhases).Count | Should -Be 1
        $state3 = Read-JsonFile -Path $statePath
        $state3.CompletedPhases = @()
        $cp3 = Join-Path $ckDir 'cp3.json'
        $null = New-Checkpoint -State $state3 -Path $cp3
        $rp3 = Get-ResumePoint -Path $cp3
        $rp3.CompletedPhases -is [System.Array] | Should -BeTrue
        @($rp3.CompletedPhases).Count | Should -Be 0
    }
    It 'refuses to write an invalid state and leaves no file behind (fail closed)' {
        $bad = @{
            RunId = $null; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
            Phase = 'Drivers'; Attempt = 0; RebootPending = $false; ConfigVersion = 'v1'
            TimestampUtc = '2026-01-01T00:00:00.0000000Z'; CompletedPhases = @(); Result = $null
            NotedIssues = @(); Acknowledgements = @()
        }
        $badPath = Join-Path $ckDir 'bad.json'
        { New-Checkpoint -State $bad -Path $badPath } | Should -Throw
        Test-Path -LiteralPath $badPath | Should -BeFalse
    }
    It 'Get-ResumePoint throws on a missing or unparseable checkpoint file' {
        { Get-ResumePoint -Path (Join-Path $ckDir 'nope.json') } | Should -Throw
        $garbage = Join-Path $ckDir 'garbage.json'
        Set-Content -Path $garbage -Value 'not json at all' -Encoding Ascii
        { Get-ResumePoint -Path $garbage } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
# Task 18 (appended AFTER the existing Describes on purpose - see the ORDER
# MATTERS note above): attempt policy, idempotent resume, and reboot
# handling. None of these call Enter-Orchestrator. The round-trip and
# no-context tests release the process-lifetime mutex and re-import the
# module with -Force to simulate a process restart (fresh module context,
# state rebuilt from the checkpoint FILE only), so they must never run
# before the single-instance Describe above.
# ---------------------------------------------------------------------------

Describe 'Invoke-WithAttempts automatic attempt policy (Q36)' {
    BeforeEach {
        $script:calls = 0
        $script:reviewCalls = 0
        $script:reviewPhase = $null
        $script:reviewAttempts = 0
        $script:seenAttempts = @()
        $script:cp = Join-Path $ckDir ('attempts-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:st = New-TestState
        $null = New-Checkpoint -State $script:st -Path $script:cp
        Set-OrchestrationContext -State $script:st -CheckpointPath $script:cp
    }
    It 'fails twice then succeeds on attempt 3: the phase completes and Attempt resets to 0' {
        $action = { $script:calls++; if ($script:calls -lt 3) { throw 'flaky' }; 'ok' }
        $onFailure = { param($Phase, $Attempts) $script:reviewCalls++ }
        $r = Invoke-WithAttempts -Phase 'Drivers' -Action $action -OnFailure $onFailure
        $r.Outcome | Should -Be 'Complete'
        $r.Attempts | Should -Be 3
        $script:calls | Should -Be 3
        $script:reviewCalls | Should -Be 0
        $rp = Get-ResumePoint -Path $script:cp
        ($rp.CompletedPhases -join ',') | Should -Be 'Drivers'
        $rp.Attempt | Should -Be 0
    }
    It 'an always-failing action reaches Technician Review exactly once with Attempts = 4 recorded in the result and the file' {
        $action = { $script:calls++; throw 'always broken' }
        $onFailure = {
            param($Phase, $Attempts)
            $script:reviewCalls++
            $script:reviewPhase = $Phase
            $script:reviewAttempts = $Attempts
        }
        $r = Invoke-WithAttempts -Phase 'Drivers' -Action $action -OnFailure $onFailure
        $r.Outcome | Should -Be 'TechnicianReview'
        $r.Attempts | Should -Be 4
        $script:calls | Should -Be 3
        $script:reviewCalls | Should -Be 1
        $script:reviewPhase | Should -Be 'Drivers'
        $script:reviewAttempts | Should -Be 4
        $rp = Get-ResumePoint -Path $script:cp
        $rp.Attempt | Should -Be 4
        @($rp.CompletedPhases).Count | Should -Be 0
    }
    It 'checkpoints Attempt BEFORE each try (the file already records the attempt in flight)' {
        $action = { $script:seenAttempts += (Get-ResumePoint -Path $script:cp).Attempt; throw 'nope' }
        $r = Invoke-WithAttempts -Phase 'Drivers' -Action $action -OnFailure { param($Phase, $Attempts) }
        $r.Outcome | Should -Be 'TechnicianReview'
        ($script:seenAttempts -join ',') | Should -Be '1,2,3'
    }
    It 'resumes a crashed in-flight phase at the recorded attempt number (crash at attempt 2 means one more try)' {
        # Simulate a crash mid-try-2: the file records Phase/Attempt but the
        # phase never completed. The crashed attempt is consumed, so exactly
        # one automatic try remains under the Q36 three-attempt cap.
        $script:st.Phase = 'Drivers'
        $script:st.Attempt = 2
        $null = New-Checkpoint -State $script:st -Path $script:cp
        $r = Invoke-WithAttempts -Phase 'Drivers' -Action { $script:calls++ } -OnFailure { param($Phase, $Attempts) }
        $r.Outcome | Should -Be 'Complete'
        $r.Attempts | Should -Be 3
        $script:calls | Should -Be 1
        $rp = Get-ResumePoint -Path $script:cp
        $rp.Attempt | Should -Be 0
        ($rp.CompletedPhases -join ',') | Should -Be 'Drivers'
    }
    It 'a phase already in CompletedPhases is skipped without any invocation (idempotent resume)' {
        $script:st.CompletedPhases = @('Drivers', 'Audit')
        $null = New-Checkpoint -State $script:st -Path $script:cp
        $r = Invoke-WithAttempts -Phase 'Drivers' -Action { $script:calls++ } -OnFailure { param($Phase, $Attempts) }
        $r.Outcome | Should -Be 'Skipped'
        $script:calls | Should -Be 0
    }
    It 'Set-OrchestrationContext refuses a state that fails the contract (identity never defaulted)' {
        $bad = @{
            RunId = $null; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
            Phase = 'Drivers'; Attempt = 0; RebootPending = $false; ConfigVersion = 'v1'
            TimestampUtc = '2026-01-01T00:00:00.0000000Z'; CompletedPhases = @(); Result = $null
            NotedIssues = @(); Acknowledgements = @()
        }
        { Set-OrchestrationContext -State $bad -CheckpointPath $script:cp } | Should -Throw
    }
}

Describe 'Invoke-Phase reboot handling and Resume-AfterReboot identity gate (Q35)' {
    BeforeEach {
        $script:calls = 0
        $script:appsCalls = 0
        $script:reviewCalls = 0
        $script:seenReboot = @()
        $script:cp = Join-Path $ckDir ('reboot-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:st = New-TestState
        $null = New-Checkpoint -State $script:st -Path $script:cp
        Set-OrchestrationContext -State $script:st -CheckpointPath $script:cp
    }
    It 'marks RebootPending=true in the file BEFORE delegating the action and returns RebootPending on a restart request' {
        $action = {
            $script:calls++
            $script:seenReboot += [bool](Get-ResumePoint -Path $script:cp).RebootPending
            Set-OrchestrationRestartRequested
        }
        $r = Invoke-Phase -Phase 'Drivers' -Action $action
        $r.Outcome | Should -Be 'RebootPending'
        $script:calls | Should -Be 1
        # While the action is in flight the checkpoint already carries the
        # marker, so a crash anywhere in the window forces the identity gate.
        $script:seenReboot[0] | Should -BeTrue
        $rp = Get-ResumePoint -Path $script:cp
        $rp.RebootPending | Should -BeTrue
        ($rp.CompletedPhases -join ',') | Should -Be 'Drivers'
        $rp.Attempt | Should -Be 0
    }
    It 'completes normally with RebootPending=false when the action does not request a restart' {
        $r = Invoke-Phase -Phase 'Drivers' -Action { $script:calls++ }
        $r.Outcome | Should -Be 'Complete'
        $rp = Get-ResumePoint -Path $script:cp
        $rp.RebootPending | Should -BeFalse
        ($rp.CompletedPhases -join ',') | Should -Be 'Drivers'
    }
    It 'exhaustion through Invoke-Phase clears the reboot marker and reaches review exactly once' {
        $r = Invoke-Phase -Phase 'Drivers' -Action { $script:calls++; throw 'broken' } -OnFailure {
            param($Phase, $Attempts)
            $script:reviewCalls++
        }
        $r.Outcome | Should -Be 'TechnicianReview'
        $r.Attempts | Should -Be 4
        $script:reviewCalls | Should -Be 1
        $rp = Get-ResumePoint -Path $script:cp
        $rp.RebootPending | Should -BeFalse
        $rp.Attempt | Should -Be 4
    }
    It 'full reboot round trip: the file keeps RebootPending while outstanding, resume validates identity, and completed phases are never re-invoked' {
        # The phase's work finishes and it requests a restart.
        $r1 = Invoke-Phase -Phase 'Drivers' -Action { $script:calls++; Set-OrchestrationRestartRequested }
        $r1.Outcome | Should -Be 'RebootPending'
        (Get-ResumePoint -Path $script:cp).RebootPending | Should -BeTrue
        # Simulated restart: the process is gone. Release the process-lifetime
        # lock so nothing leaks, re-import the module (all module state lost),
        # and rebuild the context from the checkpoint FILE only.
        $m = Get-OrchestratorMutex
        if ($null -ne $m) { $m.ReleaseMutex(); $m.Dispose() }
        Import-Module $script:modulePath -Force
        Set-OrchestrationContext -State (Read-JsonFile -Path $script:cp) -CheckpointPath $script:cp
        (Get-ResumePoint -Path $script:cp).RebootPending | Should -BeTrue
        $rr = Resume-AfterReboot -Expected @{
            MachineId = '22222222-2222-2222-2222-222222222222'
            DiskId    = '33333333-3333-3333-3333-333333333333'
        }
        $rr.Outcome | Should -Be 'Ready'
        $rr.State.DiskId | Should -Be '33333333-3333-3333-3333-333333333333'
        (Get-ResumePoint -Path $script:cp).RebootPending | Should -BeFalse
        # Idempotent resume: the completed phase is skipped with zero further
        # invocations; the next phase in the sequence runs exactly once.
        $r2 = Invoke-Phase -Phase 'Drivers' -Action { $script:calls++ }
        $r2.Outcome | Should -Be 'Skipped'
        $script:calls | Should -Be 1
        $r3 = Invoke-Phase -Phase 'Apps' -Action { $script:appsCalls++ }
        $r3.Outcome | Should -Be 'Complete'
        $script:appsCalls | Should -Be 1
        ((Get-ResumePoint -Path $script:cp).CompletedPhases -join ',') | Should -Be 'Drivers,Apps'
    }
    It 'a mismatched identity stops with zero phase work and no state mutation (CompletedPhases intact)' {
        $r1 = Invoke-Phase -Phase 'Drivers' -Action { Set-OrchestrationRestartRequested }
        $r1.Outcome | Should -Be 'RebootPending'
        $before = (Get-FileHash -LiteralPath $script:cp -Algorithm SHA256).Hash
        $rr = Resume-AfterReboot -Expected @{
            MachineId = '99999999-9999-9999-9999-999999999999'
            DiskId    = '33333333-3333-3333-3333-333333333333'
        }
        $rr.Outcome | Should -Be 'IdentityMismatch'
        # Zero mutation: not even a checkpoint recording the mismatch.
        (Get-FileHash -LiteralPath $script:cp -Algorithm SHA256).Hash | Should -Be $before
        ((Get-ResumePoint -Path $script:cp).CompletedPhases -join ',') | Should -Be 'Drivers'
    }
    It 'a null or missing expected identity field is a mismatch, never a pass (fail closed)' {
        $rr = Resume-AfterReboot -Expected @{ MachineId = $null; DiskId = '33333333-3333-3333-3333-333333333333' }
        $rr.Outcome | Should -Be 'IdentityMismatch'
        $rr2 = Resume-AfterReboot -Expected @{ DiskId = '33333333-3333-3333-3333-333333333333' }
        $rr2.Outcome | Should -Be 'IdentityMismatch'
    }
    It 'throws when no orchestration context is bound (fail closed)' {
        $m = Get-OrchestratorMutex
        if ($null -ne $m) { $m.ReleaseMutex(); $m.Dispose() }
        Import-Module $script:modulePath -Force
        { Invoke-WithAttempts -Phase 'X' -Action { } -OnFailure { param($Phase, $Attempts) } } | Should -Throw
        { Invoke-Phase -Phase 'X' -Action { } } | Should -Throw
        { Resume-AfterReboot -Expected @{ MachineId = 'm'; DiskId = 'd' } } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
# Task 19: integrity record, recheck, and local-only repair (Q90/Q92; Q91).
# None of these tests needs an orchestration context or the single-instance
# lock. The DEPLOYED directory under test is a fresh engine directory staged
# from the mock partition's repair source (Sources\Orchestrator); the shared
# fixture repair source itself is never modified - the dirty-source scenario
# copies it aside first.
# ---------------------------------------------------------------------------

Describe 'Integrity record and recheck (Q90/Q92)' {
    BeforeEach {
        # Stage a fresh "deployed engine" directory from the partition repair
        # source: the two dummy .psm1 files, nothing else.
        $script:engineDir = Join-Path $ckDir ('engine-' + [guid]::NewGuid().ToString('N'))
        $script:repairSrc = Join-Path $root 'Sources\Orchestrator'
        New-Item -ItemType Directory -Path $script:engineDir | Out-Null
        Get-ChildItem -LiteralPath $script:repairSrc -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $script:engineDir
        }
        # Record placement is caller-controlled by design (documented on
        # New-IntegrityRecord), so the test owns it: a per-test path in the
        # checkpoint scratch area.
        $script:recordPath = Join-Path $ckDir ('integrity-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:record = New-IntegrityRecord -Directory $script:engineDir -RecordPath $script:recordPath
    }
    It 'generates the record from the staged tree (no manual manifest) and stores it atomically' {
        # Key set is exactly the two contract fields.
        (@($script:record.Keys | Sort-Object) -join ',') | Should -Be 'BundleHash,FileHashes'
        @($script:record.FileHashes).Count | Should -Be 2
        (@($script:record.FileHashes | ForEach-Object { $_.Path } | Sort-Object) -join ',') |
            Should -Be 'Part1.psm1,Part2.psm1'
        # Hashes are RECOMPUTED here for comparison - never hardcoded (the
        # recorded bundle depends only on content, but comparing against a
        # fresh computation proves the record describes this exact tree).
        $fresh = Get-BundleHash -Inventory (New-FileInventory -Path $script:engineDir)
        $script:record.BundleHash | Should -Be $fresh
        # Atomic write: the file exists, is parseable, matches the returned
        # record, and leaves no temp residue.
        Test-Path -LiteralPath $script:recordPath | Should -BeTrue
        $fromFile = Read-JsonFile -Path $script:recordPath
        $fromFile.BundleHash | Should -Be $script:record.BundleHash
        (@($fromFile.FileHashes | ForEach-Object { $_.Path } | Sort-Object) -join ',') |
            Should -Be 'Part1.psm1,Part2.psm1'
        @(Get-ChildItem -LiteralPath $ckDir -Filter ('*' + [System.IO.Path]::GetFileName($script:recordPath) + '.tmp*')).Count | Should -Be 0
    }
    It 'record-then-verify passes on the untouched directory, in memory and after a JSON round trip' {
        $r = Test-Integrity -Directory $script:engineDir -Record $script:record
        $r.Ok | Should -BeTrue
        @($r.Mismatches).Count | Should -Be 0
        # The after-restart path: the orchestrator reads IntegrityRecord.json
        # back from the partition and verifies against the PSCustomObject.
        $fromFile = Read-JsonFile -Path $script:recordPath
        $r2 = Test-Integrity -Directory $script:engineDir -Record $fromFile
        $r2.Ok | Should -BeTrue
        @($r2.Mismatches).Count | Should -Be 0
    }
    It 'tampering one file fails the recheck with that file listed as Changed' {
        [System.IO.File]::AppendAllText((Join-Path $script:engineDir 'Part1.psm1'), 'tamper')
        $r = Test-Integrity -Directory $script:engineDir -Record $script:record
        $r.Ok | Should -BeFalse
        $changed = @($r.Mismatches | Where-Object { $_.Path -eq 'Part1.psm1' })
        $changed.Count | Should -Be 1
        $changed[0].Reason | Should -Be 'Changed'
        # The derived bundle no longer matches either, so the bundle entry
        # rides along with the per-file entry.
        @($r.Mismatches | Where-Object { $_.Reason -eq 'BundleHash' }).Count | Should -Be 1
    }
    It 'reports Missing and Extra entries for a deleted and an added file' {
        Remove-Item -LiteralPath (Join-Path $script:engineDir 'Part2.psm1') -Force
        [System.IO.File]::WriteAllText((Join-Path $script:engineDir 'Extra.txt'), 'extra')
        $r = Test-Integrity -Directory $script:engineDir -Record $script:record
        $r.Ok | Should -BeFalse
        @($r.Mismatches | Where-Object { $_.Path -eq 'Part2.psm1' -and $_.Reason -eq 'Missing' }).Count | Should -Be 1
        @($r.Mismatches | Where-Object { $_.Path -eq 'Extra.txt' -and $_.Reason -eq 'Extra' }).Count | Should -Be 1
    }
    It 'fails closed on a tampered record bundle or a record missing its inventory' {
        # Files untouched, but the record's BundleHash was altered: the file
        # hashes match and the bundle does not - still not Ok.
        $badBundle = @{ FileHashes = $script:record.FileHashes; BundleHash = ('0' * 64) }
        $r = Test-Integrity -Directory $script:engineDir -Record $badBundle
        $r.Ok | Should -BeFalse
        @($r.Mismatches | Where-Object { $_.Reason -eq 'BundleHash' }).Count | Should -Be 1
        # A record without its inventory can never verify (never defaulted).
        $r2 = Test-Integrity -Directory $script:engineDir -Record @{ BundleHash = 'x' }
        $r2.Ok | Should -BeFalse
        @($r2.Mismatches | Where-Object { $_.Reason -eq 'InvalidRecord' }).Count | Should -Be 1
    }
}

Describe 'Repair-FromLocalSource local-only repair and the Q91 parameter boundary' {
    BeforeEach {
        $script:engineDir = Join-Path $ckDir ('engine-' + [guid]::NewGuid().ToString('N'))
        $script:repairSrc = Join-Path $root 'Sources\Orchestrator'
        New-Item -ItemType Directory -Path $script:engineDir | Out-Null
        Get-ChildItem -LiteralPath $script:repairSrc -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $script:engineDir
        }
        $script:recordPath = Join-Path $ckDir ('integrity-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:record = New-IntegrityRecord -Directory $script:engineDir -RecordPath $script:recordPath
    }
    It 'repairs from the clean partition repair source: recopy, exact content restored, Ok under the SAME record' {
        [System.IO.File]::AppendAllText((Join-Path $script:engineDir 'Part2.psm1'), 'tamper')
        [System.IO.File]::WriteAllText((Join-Path $script:engineDir 'Leftover.txt'), 'junk')
        $r = Repair-FromLocalSource -Directory $script:engineDir -RepairSource $script:repairSrc -Record $script:record
        $r.Repaired | Should -BeTrue
        # Success shape is exactly @{ Repaired = $true } - no Outcome key.
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Repaired'
        # The copy went OVER the directory: the extra file is gone, the
        # tampered file is restored, and the recheck passes with the same
        # record (no re-recording after repair).
        Test-Path -LiteralPath (Join-Path $script:engineDir 'Leftover.txt') | Should -BeFalse
        $check = Test-Integrity -Directory $script:engineDir -Record $script:record
        $check.Ok | Should -BeTrue
        @($check.Mismatches).Count | Should -Be 0
    }
    It 'tampering after a successful repair yields the blocking Technician Review outcome' {
        # First damage is repaired from the clean source.
        [System.IO.File]::AppendAllText((Join-Path $script:engineDir 'Part1.psm1'), 'tamper')
        $first = Repair-FromLocalSource -Directory $script:engineDir -RepairSource $script:repairSrc -Record $script:record
        $first.Repaired | Should -BeTrue
        # Damage returns AND the repair source copy is dirty the same way, so
        # the recopy cannot restore the recorded hashes: second failure stops
        # for a person (Q92). The dirty source is a COPY - the shared mock
        # fixture is never modified.
        [System.IO.File]::AppendAllText((Join-Path $script:engineDir 'Part1.psm1'), 'tamper-again')
        $badSrc = Join-Path $ckDir ('badsrc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $badSrc | Out-Null
        Get-ChildItem -LiteralPath $script:repairSrc -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $badSrc
        }
        [System.IO.File]::AppendAllText((Join-Path $badSrc 'Part1.psm1'), 'tamper-again')
        $second = Repair-FromLocalSource -Directory $script:engineDir -RepairSource $badSrc -Record $script:record
        $second.Repaired | Should -BeFalse
        $second.Outcome | Should -Be 'TechnicianReview'
        # The directory now holds the bad content and still fails the recheck.
        (Test-Integrity -Directory $script:engineDir -Record $script:record).Ok | Should -BeFalse
    }
    It 'the parameter list IS the connectivity boundary: no Share/UNC/Server/SMB parameters (Q91)' {
        foreach ($name in @('Repair-FromLocalSource', 'New-IntegrityRecord', 'Test-Integrity')) {
            $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $offending = @($cmd.Parameters.Keys | Where-Object { $_ -match '(?i)share|unc|server|smb' })
            ('{0} parameters: [{1}]' -f $name, ($offending -join ', ')) | Should -Be ('{0} parameters: []' -f $name)
        }
    }
}
