BeforeAll {
    # Mock partition builder (dot-sourced script; imports State/Util/Config).
    . (Join-Path $PSScriptRoot '..\mocks\New-MockPartition.ps1')
    # Logging is imported INSIDE the Orchestrator module, so its functions are
    # not in the test session; Task 20 fixtures stage run logs directly.
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Logging\OSDeploy.Logging.psd1') -Force
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

    # Task 22: manifest-driven application phase fixtures. New-AppEntry
    # returns a FRESH valid entry on every call (tests mutate their own
    # copy); New-AppManifest writes the entries as a JSON array into a fresh
    # temp directory and returns the manifest path. Created directories are
    # tracked and removed by the Task 22 Describes' AfterEach.
    $script:appDirs = @()
    function New-AppEntry {
        return @{
            Id             = 'app-1'
            Name           = 'Sample Utility'
            Installer      = 'SampleSetup.exe'
            Type           = 'Exe'
            SilentArgs     = '/S /norestart'
            SuccessCodes   = @(0)
            RetryCount     = 3
            TimeoutMinutes = 10
            Required       = $true
        }
    }
    function New-AppManifest {
        param($Entries)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('apps-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:appDirs += $dir
        $path = Join-Path $dir 'manifest.json'
        Write-AtomicJson -Path $path -Value @($Entries)
        return $path
    }

    # Task 21: staged driver-tree fixture covering every classification shape
    # the Q96 pattern engine must decide: exact-name and case-variant
    # AsusSetup.exe folders, a single-exe Gigabyte-style folder, an uppercase
    # .EXE extension, an empty folder, a two-installer folder, and a folder
    # whose single installer has another installer nested below it (whose own
    # subfolder is a clean SingleExe). Probed on this host: PowerShell builds
    # real nested directories from backslash-joined paths on every platform,
    # so the tree is identical on Windows and Linux.
    function New-DriverTree {
        $treeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('drivers-' + [guid]::NewGuid().ToString('N'))
        foreach ($dir in @(
            (Join-Path $treeRoot 'Asus\PRIME\Chipset'),
            (Join-Path $treeRoot 'Asus\AUDIO'),
            (Join-Path $treeRoot 'Gigabyte\B650\LAN'),
            (Join-Path $treeRoot 'Upper'),
            (Join-Path $treeRoot 'Empty'),
            (Join-Path $treeRoot 'Multi'),
            (Join-Path $treeRoot 'Nested\sub'))) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Asus\PRIME\Chipset\AsusSetup.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Asus\AUDIO\asussetup.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Gigabyte\B650\LAN\installer.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Upper\SETUP.EXE'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Multi\a.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Multi\b.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Nested\outer.exe'), 'dummy')
        [System.IO.File]::WriteAllText((Join-Path $treeRoot 'Nested\sub\inner.exe'), 'dummy')
        return $treeRoot
    }

    # Task 23: EZT registry-store fixture. The documented injectable
    # registry interface is a hashtable of registry path strings ->
    # hashtables of value name -> value. New-EztRegistry returns the
    # deployed EZT Winlogon state: persistent automatic sign-on for the
    # passwordless User account (Q16/Q24).
    $script:EztWinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    function New-EztRegistry {
        $store = @{}
        $store[$script:EztWinlogonPath] = @{
            DefaultUserName = 'User'
            DefaultPassword = ''
            AutoAdminLogon  = '1'
        }
        return $store
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
    It 'an existing-but-EMPTY directory fails closed with every recorded file Missing (no exception)' {
        # The "all files deleted, directory remains" tamper shape: the recheck
        # must report it, never throw a binding error on the empty inventory.
        Get-ChildItem -LiteralPath $script:engineDir -File | Remove-Item -Force
        $r = Test-Integrity -Directory $script:engineDir -Record $script:record
        $r.Ok | Should -BeFalse
        $missing = @($r.Mismatches | Where-Object { $_.Reason -eq 'Missing' })
        $missing.Count | Should -Be 2
        (@($missing | ForEach-Object { $_.Path } | Sort-Object) -join ',') |
            Should -Be 'Part1.psm1,Part2.psm1'
        # Record generation refuses an empty tree outright (staging error)
        # with its own clear throw, not a downstream binding exception.
        { New-IntegrityRecord -Directory $script:engineDir -RecordPath ($script:recordPath + '.empty') } |
            Should -Throw
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
    It 'an empty-but-present repair source fails closed to Technician Review without throwing' {
        # The recopy empties the damaged directory (nothing to copy) and the
        # deciding recheck runs on that empty directory: the outcome must be
        # the blocking review, never a binding exception that would bypass
        # the Q92 second-failure routing.
        [System.IO.File]::AppendAllText((Join-Path $script:engineDir 'Part1.psm1'), 'tamper')
        $emptySrc = Join-Path $ckDir ('emptysrc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptySrc | Out-Null
        $r = Repair-FromLocalSource -Directory $script:engineDir -RepairSource $emptySrc -Record $script:record
        $r.Repaired | Should -BeFalse
        $r.Outcome | Should -Be 'TechnicianReview'
        @(Get-ChildItem -LiteralPath $script:engineDir -Force).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Task 20: completion gating and scoped cleanup (Q89). Every test builds its
# OWN fresh mock partition so removal assertions never disturb the shared
# fixture, and none of these tests needs the single-instance lock or an
# orchestration context (Complete-Deployment reads the checkpoint file, which
# is the only state source).
#
# Mock locations (documented per the brief):
#   - Scheduled Task registration marker: <root>\State\TaskRegistration.json,
#     staged as the JSON file Task 28's Register-OrchestratorTask will write.
#   - Orchestrator runtime artifacts: <root>\OrchestratorRuntime\ (the
#     simulated C:\ProgramData\OSDeploy\Orchestrator), staged with NESTED
#     content so the recursive removal path is exercised.
#   - Cleanup-failure simulation: a NON-EMPTY DIRECTORY planted at the
#     marker path. Invoke-Cleanup classifies 'a directory where the marker
#     FILE is expected' as a removal failure - it never recurses into
#     unknown content and never prompts - which is deterministic on Linux
#     AND Windows (probed: Remove-Item without -Recurse on a non-empty
#     directory raises an interactive Confirm prompt, which is not a
#     reliable test signal; a read-only bit is bypassed under -Force and
#     ignored by root, so permission tricks are not reliable either).
# ---------------------------------------------------------------------------

Describe 'Invoke-Cleanup scoped removal and recovery retention (Q89)' {
    BeforeEach {
        $script:troot = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-cln-' + [guid]::NewGuid().ToString('N')))
        # Completion footprint: the task registration marker file, the
        # runtime artifacts tree, and a State-side effective-config copy
        # (the retained set names State\effective-config* in addition to the
        # Sources\Config copy the mock partition stages).
        Write-AtomicJson -Path (Join-Path $script:troot 'State\TaskRegistration.json') -Value @{
            TaskName       = 'OSDeploy Orchestrator'
            RegisteredUtc  = [datetime]::UtcNow.ToString('o')
        }
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'OrchestratorRuntime\Cache') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:troot 'OrchestratorRuntime\RuntimeMarker.txt'), 'runtime')
        [System.IO.File]::WriteAllText((Join-Path $script:troot 'OrchestratorRuntime\Cache\deep.txt'), 'nested')
        Write-AtomicJson -Path (Join-Path $script:troot 'State\effective-config.json') -Value @{ ConfigVersion = 'test-v1' }
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:troot -ErrorAction SilentlyContinue
    }
    It 'removes the task registration marker and the runtime artifacts directory and nothing else' {
        $r = Invoke-Cleanup -PartitionRoot $script:troot
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
        # Recovery content is ALWAYS retained: every named path survives.
        foreach ($retained in @(
            'Sources\Orchestrator\Part1.psm1',
            'Sources\Orchestrator\Part2.psm1',
            'Sources\Apps\EZT\manifest.json',
            'Sources\Apps\MMC\manifest.json',
            'Sources\Drivers\Asus\PRIME\Chipset\AsusSetup.exe',
            'Sources\Drivers\Gigabyte\B650\LAN\installer.exe',
            'Sources\Config\effective-config.json',
            'ImageCache',
            'State\FactoryProfile.json',
            'State\FactoryProfile.lastknowngood.json',
            'State\effective-config.json',
            'State\DeploymentState.json',
            'State\ReadinessRecord.json',
            'Logs')) {
            Test-Path -LiteralPath (Join-Path $script:troot $retained) | Should -BeTrue
        }
    }
    It 'is idempotent: an already-clean partition returns Ok with an empty failure list' {
        $first = Invoke-Cleanup -PartitionRoot $script:troot
        $first.Ok | Should -BeTrue
        $second = Invoke-Cleanup -PartitionRoot $script:troot
        $second.Ok | Should -BeTrue
        @($second.Failures).Count | Should -Be 0
    }
    It 'reports Ok=$false with a Failures list when the marker path holds a directory instead of the marker file' {
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'State\TaskRegistration.json\Squat') -Force | Out-Null
        $r = Invoke-Cleanup -PartitionRoot $script:troot
        $r.Ok | Should -BeFalse
        @($r.Failures).Count | Should -Be 1
        $r.Failures[0] | Should -Match 'TaskRegistration\.json'
        # Every target is attempted: one failure never hides the other removal.
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
        # Nothing retained was touched by the failed cleanup.
        Test-Path -LiteralPath (Join-Path $script:troot 'State\FactoryProfile.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:troot 'Sources\Config\effective-config.json') | Should -BeTrue
    }
    It 'carries the task name in the failure detail: default and caller-supplied' {
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'State\TaskRegistration.json\Squat') -Force | Out-Null
        $default = Invoke-Cleanup -PartitionRoot $script:troot
        $default.Failures[0] | Should -Match ([regex]::Escape('OSDeploy Orchestrator'))
        $named = Invoke-Cleanup -PartitionRoot $script:troot -TaskName 'Custom Task 99'
        $named.Failures[0] | Should -Match ([regex]::Escape('Custom Task 99'))
    }
}

Describe 'Complete-Deployment Q89 completion gating' {
    BeforeEach {
        $script:troot = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-fin-' + [guid]::NewGuid().ToString('N')))
        Write-AtomicJson -Path (Join-Path $script:troot 'State\TaskRegistration.json') -Value @{
            TaskName       = 'OSDeploy Orchestrator'
            RegisteredUtc  = [datetime]::UtcNow.ToString('o')
        }
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'OrchestratorRuntime\Cache') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:troot 'OrchestratorRuntime\RuntimeMarker.txt'), 'runtime')
        # A finished run's log: the partition's newest run folder holds
        # valid JSONL (one event written through the real logging path).
        $log = New-RunLog -Root (Join-Path $script:troot 'Logs') -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Event 'SuiteFixture'
        $script:eventsPath = $log.EventsPath
        # The checkpoint of a run whose phases are all complete.
        $script:statePath = Join-Path $script:troot 'State\DeploymentState.json'
        $state = Read-JsonFile -Path $script:statePath
        $state.Phase = 'Audit'
        $state.CompletedPhases = @('Prepare', 'Drivers', 'Apps', 'Audit')
        $null = New-Checkpoint -State $state -Path $script:statePath
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:troot -ErrorAction SilentlyContinue
    }
    It 'records Result and CompletedUtc only after cleanup and final-log verification succeed' {
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $r.Completed | Should -BeTrue
        $r.Result | Should -Be 'Completed'
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Completed,Result'
        $after = Read-JsonFile -Path $script:statePath
        $after.Result | Should -Be 'Completed'
        # CompletedUtc is an ISO 8601 UTC string; asserted on the RAW FILE
        # TEXT because pwsh 7 auto-types ISO strings to [datetime] on read
        # (Task 16 note) - and never hardcoded, only shape-matched.
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Match '"CompletedUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
        # Success carries positive completion polarity and NO block record:
        # Completed = $true is set and BlockedBy is absent (a retry after a
        # blocked attempt must land on the same shape as a first-try success).
        $after.Completed | Should -BeTrue
        $after.PSObject.Properties['BlockedBy'] | Should -BeNullOrEmpty
        # Cleanup ran, and the verified run log survived it (Logs retained).
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
        Test-Path -LiteralPath $script:eventsPath | Should -BeTrue
    }
    It 'blocks on cleanup failure: Completed=$false, BlockedBy=CleanupFailure, and NO CompletedUtc in the state' {
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'State\TaskRegistration.json\Squat') -Force | Out-Null
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $r.Completed | Should -BeFalse
        $r.BlockedBy | Should -Be 'CleanupFailure'
        $after = Read-JsonFile -Path $script:statePath
        $after.PSObject.Properties['CompletedUtc'] | Should -BeNullOrEmpty
        $after.PSObject.Properties['Completed'].Value | Should -BeFalse
        $after.BlockedBy | Should -Be 'CleanupFailure'
        $after.Result | Should -BeNullOrEmpty
        # The runtime target was still attempted (failures are collected,
        # never first-abort), so a restart retries the whole order cleanly.
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
    }
    It 'a retry after a cleanup failure completes cleanly: no stale BlockedBy, CompletedUtc present' {
        # Round 1: cleanup fails and the block is durably checkpointed.
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'State\TaskRegistration.json\Squat') -Force | Out-Null
        $blocked = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $blocked.Completed | Should -BeFalse
        $blocked.BlockedBy | Should -Be 'CleanupFailure'
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Match 'CleanupFailure'
        # The technician clears the obstruction and a fresh marker is staged;
        # the restart retries the full Q89 order.
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Recurse -Force
        Write-AtomicJson -Path (Join-Path $script:troot 'State\TaskRegistration.json') -Value @{
            TaskName      = 'OSDeploy Orchestrator'
            RegisteredUtc = [datetime]::UtcNow.ToString('o')
        }
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $r.Completed | Should -BeTrue
        $r.Result | Should -Be 'Completed'
        # The FINAL authoritative document carries no stale block record:
        # no BlockedBy field and no CleanupFailure text anywhere in the file.
        $final = Read-JsonFile -Path $script:statePath
        $final.Completed | Should -BeTrue
        $final.PSObject.Properties['BlockedBy'] | Should -BeNullOrEmpty
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Not -Match 'CleanupFailure'
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Match '"CompletedUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
        # The retried cleanup consumed the restored marker as well.
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
    }
    It 'blocks on final-log verification failure after successful cleanup, leaving the checkpoint untouched' {
        [System.IO.File]::AppendAllText($script:eventsPath, 'this line is not json' + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
        $before = (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $r.Completed | Should -BeFalse
        $r.BlockedBy | Should -Be 'LogVerification'
        # No completion was recorded and the checkpoint is byte-identical.
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Not -Match 'CompletedUtc'
        # Cleanup already ran BEFORE the log gate (the Q89 order).
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
    }
    It 'treats a partition with no run log at all as a log-verification block' {
        Get-ChildItem -LiteralPath (Join-Path $script:troot 'Logs') -Force |
            Remove-Item -Recurse -Force
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed'
        $r.Completed | Should -BeFalse
        $r.BlockedBy | Should -Be 'LogVerification'
        ([System.IO.File]::ReadAllText($script:statePath)) | Should -Not -Match 'CompletedUtc'
    }
    It 'throws when DeploymentState.json is missing (state is never invented)' {
        Remove-Item -LiteralPath $script:statePath -Force
        { Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed' } | Should -Throw
    }
    It 'blocks before any cleanup when a required phase is missing from the checkpoint' {
        $before = (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed' -RequiredPhases @('Prepare', 'Drivers', 'Apps', 'Audit', 'Summary')
        $r.Completed | Should -BeFalse
        $r.BlockedBy | Should -Be 'RequiredWorkIncomplete'
        # No destructive step ran and no state was written.
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeTrue
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
    }
}

Describe 'Invoke-PostCompletionRestart cleanup-only restart (Q89)' {
    BeforeEach {
        $script:troot = New-MockPartition -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('orch-post-' + [guid]::NewGuid().ToString('N')))
        Write-AtomicJson -Path (Join-Path $script:troot 'State\TaskRegistration.json') -Value @{
            TaskName       = 'OSDeploy Orchestrator'
            RegisteredUtc  = [datetime]::UtcNow.ToString('o')
        }
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'OrchestratorRuntime') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:troot 'OrchestratorRuntime\RuntimeMarker.txt'), 'runtime')
        # An ALREADY completed run: Result and CompletedUtc were recorded by
        # an earlier Complete-Deployment call.
        $script:statePath = Join-Path $script:troot 'State\DeploymentState.json'
        $state = Read-JsonFile -Path $script:statePath
        $state.Result = 'Completed'
        Add-Member -InputObject $state -MemberType NoteProperty -Name 'CompletedUtc' -Value ([datetime]::UtcNow.ToString('o'))
        $null = New-Checkpoint -State $state -Path $script:statePath
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:troot -ErrorAction SilentlyContinue
    }
    It 'performs cleanup with zero phase-action invocations and no state change' {
        # Regression-sensitive wiring (fix round 1): the phase engine entry
        # points are MOCKED with counters, so any invocation from inside the
        # post-completion path moves the count and fails the assertion. An
        # unwired scriptblock counter cannot fail (review Minor #1).
        $script:phaseCalls = 0
        Mock Invoke-Phase -ModuleName OSDeploy.Orchestrator { $script:phaseCalls++ }
        Mock Invoke-WithAttempts -ModuleName OSDeploy.Orchestrator { $script:phaseCalls++ }
        $before = (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash
        $r = Invoke-PostCompletionRestart -PartitionRoot $script:troot
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        # No phase engine entry point ran.
        $script:phaseCalls | Should -Be 0
        Should -Invoke Invoke-Phase -ModuleName OSDeploy.Orchestrator -Exactly 0 -Scope It
        Should -Invoke Invoke-WithAttempts -ModuleName OSDeploy.Orchestrator -Exactly 0 -Scope It
        # The state (Result, CompletedUtc, everything) is byte-identical.
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
        # A second restart is equally clean (idempotent).
        $again = Invoke-PostCompletionRestart -PartitionRoot $script:troot
        $again.Ok | Should -BeTrue
        $script:phaseCalls | Should -Be 0
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
    }
    It 'Complete-Deployment with Result already set delegates to the post-completion restart (cleanup shape, no re-completion)' {
        $before = (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash
        # Even an unmet required-phase list must not matter: the delegation
        # happens before any required-work evaluation.
        $r = Complete-Deployment -PartitionRoot $script:troot -Handoff 'Completed' -RequiredPhases @('NeverRan')
        # The return IS the cleanup result - the cleanup shape, not a
        # completion shape (no Completed / BlockedBy keys).
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Failures,Ok'
        $r.Ok | Should -BeTrue
        # No re-completion: the state still carries exactly the ORIGINAL
        # Result and CompletedUtc, byte for byte.
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
        Test-Path -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:troot 'OrchestratorRuntime') | Should -BeFalse
    }
    It 'reports a post-completion cleanup failure as-is (cleanup shape, state untouched)' {
        Remove-Item -LiteralPath (Join-Path $script:troot 'State\TaskRegistration.json') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:troot 'State\TaskRegistration.json\Squat') -Force | Out-Null
        $before = (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash
        $r = Invoke-PostCompletionRestart -PartitionRoot $script:troot
        $r.Ok | Should -BeFalse
        @($r.Failures).Count | Should -Be 1
        (Get-FileHash -LiteralPath $script:statePath -Algorithm SHA256).Hash | Should -Be $before
    }
}

# ---------------------------------------------------------------------------
# Task 21: driver phase - pattern-matched discovery with dry-run (Q96/Q27).
# None of these tests needs the single-instance lock or an orchestration
# context. Each test stages its own driver tree (New-DriverTree in the
# file-level BeforeAll); no real installer is ever launched - execution
# tests inject a recording Runner, and the default-runner test MOCKS
# Start-Process in module scope.
# ---------------------------------------------------------------------------

Describe 'Find-DriverInstallers pattern engine (Q96)' {
    BeforeEach {
        $script:tree = New-DriverTree
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tree -ErrorAction SilentlyContinue
    }
    It 'classifies Asus (exact and case-variant names) and SingleExe folders into folder-ordered plans' {
        $r = Find-DriverInstallers -Root $script:tree
        (@($r.Plans | ForEach-Object { $_.Pattern }) -join ',') | Should -Be 'Asus,Asus,SingleExe,SingleExe,SingleExe'
        # Installer is always the staged file's ACTUAL name, so the execution
        # path still resolves on case-sensitive filesystems.
        (@($r.Plans | ForEach-Object { $_.Installer }) -join ',') |
            Should -Be 'asussetup.exe,AsusSetup.exe,installer.exe,inner.exe,SETUP.EXE'
        # Plans are ordered by folder path.
        $r.Plans[0].Folder | Should -BeLike ('*' + (Join-Path 'Asus' 'AUDIO'))
        $r.Plans[1].Folder | Should -BeLike ('*' + (Join-Path 'Asus' 'PRIME\Chipset'))
        $r.Plans[2].Folder | Should -BeLike ('*' + (Join-Path 'Gigabyte' 'B650\LAN'))
        $r.Plans[3].Folder | Should -BeLike ('*' + (Join-Path 'Nested' 'sub'))
        $r.Plans[4].Folder | Should -BeLike ('*Upper')
    }
    It 'records every folder without a plan in SkippedFolders with its reason' {
        $r = Find-DriverInstallers -Root $script:tree
        $reasonByFolder = @{}
        foreach ($s in @($r.SkippedFolders)) { $reasonByFolder[$s.Folder] = $s.Reason }
        # 13 candidate folders at or below the root, 5 with plans: 8 skipped.
        @($r.SkippedFolders).Count | Should -Be 8
        # The tree root itself and every intermediate parent hold no direct
        # installer, so they are reported with the NoInstaller reason.
        $reasonByFolder[$script:tree] | Should -Be 'NoInstaller'
        $reasonByFolder[(Join-Path $script:tree 'Asus')] | Should -Be 'NoInstaller'
        $reasonByFolder[(Join-Path $script:tree 'Gigabyte\B650')] | Should -Be 'NoInstaller'
        $reasonByFolder[(Join-Path $script:tree 'Empty')] | Should -Be 'NoInstaller'
        $reasonByFolder[(Join-Path $script:tree 'Multi')] | Should -Be 'MultipleInstallers'
        # One direct installer but another one below it: ambiguous, never guessed.
        $reasonByFolder[(Join-Path $script:tree 'Nested')] | Should -Be 'NestedInstaller'
    }
    It 'classifies the staged mock partition Drivers tree: one Asus plan and one SingleExe plan' {
        $r = Find-DriverInstallers -Root (Join-Path $root 'Sources\Drivers')
        (@($r.Plans | ForEach-Object { $_.Pattern }) -join ',') | Should -Be 'Asus,SingleExe'
        (@($r.Plans | ForEach-Object { $_.Installer }) -join ',') | Should -Be 'AsusSetup.exe,installer.exe'
        $r.Plans[0].Folder | Should -BeLike ('*' + (Join-Path 'Drivers' 'Asus\PRIME\Chipset'))
        $r.Plans[1].Folder | Should -BeLike ('*' + (Join-Path 'Drivers' 'Gigabyte\B650\LAN'))
        @($r.SkippedFolders).Count | Should -Be 5
        @($r.SkippedFolders | Where-Object { $_.Reason -ne 'NoInstaller' }).Count | Should -Be 0
    }
    It 'yields exactly one plan when Root points directly at a single driver folder' {
        $chipset = Join-Path $script:tree 'Asus\PRIME\Chipset'
        $r = Find-DriverInstallers -Root $chipset
        @($r.Plans).Count | Should -Be 1
        $r.Plans[0].Folder | Should -Be $chipset
        $r.Plans[0].Installer | Should -Be 'AsusSetup.exe'
        $r.Plans[0].Pattern | Should -Be 'Asus'
        @($r.SkippedFolders).Count | Should -Be 0
    }
    It 'reads no manifest file: identical output with junk manifests present and absent (Q96)' {
        $manifestAtRoot = Join-Path $script:tree 'manifest.json'
        $manifestNested = Join-Path $script:tree 'Asus\PRIME\manifest.json'
        # Invalid JSON on purpose: any attempt to read AND parse a manifest
        # would throw and fail this test outright.
        [System.IO.File]::WriteAllText($manifestAtRoot, '{{ this is not json')
        [System.IO.File]::WriteAllText($manifestNested, '{{ this is not json')
        $withManifests = Find-DriverInstallers -Root $script:tree
        @($withManifests.Plans).Count | Should -Be 5
        $project = {
            param($Found)
            (@($Found.Plans | ForEach-Object { '{0}|{1}|{2}' -f $_.Folder, $_.Installer, $_.Pattern }) -join ';') + '##' +
                (@($Found.SkippedFolders | ForEach-Object { '{0}|{1}' -f $_.Folder, $_.Reason }) -join ';')
        }
        $before = & $project $withManifests
        Remove-Item -LiteralPath $manifestAtRoot, $manifestNested -Force
        $withoutManifests = Find-DriverInstallers -Root $script:tree
        (& $project $withoutManifests) | Should -Be $before
        # A manifest is never mistaken for an installer either way.
        @($withoutManifests.Plans | Where-Object { $_.Installer -match 'manifest' }).Count | Should -Be 0
    }
    It 'throws when the Root does not exist or is not a directory (fail closed)' {
        { Find-DriverInstallers -Root (Join-Path $script:tree 'DoesNotExist') } | Should -Throw
        { Find-DriverInstallers -Root (Join-Path $script:tree 'Multi\a.exe') } | Should -Throw
    }
}

Describe 'Invoke-DriverPhase execution, dry-run, and failure routing (Q27)' {
    BeforeEach {
        $script:tree = New-DriverTree
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tree -ErrorAction SilentlyContinue
    }
    It 'dry-run returns the identical plan list with zero Runner invocations and executes nothing' {
        $script:invocations = 0
        $found = Find-DriverInstallers -Root $script:tree
        $runner = { param($Plan) $script:invocations++; return $true }
        $r = Invoke-DriverPhase -Root $script:tree -DryRun -Runner $runner
        $r.DryRun | Should -BeTrue
        $r.Ok | Should -BeTrue
        $script:invocations | Should -Be 0
        @($r.Executed).Count | Should -Be 0
        @($r.FailedDrivers).Count | Should -Be 0
        # The recorded plan list is IDENTICAL to the discovery result.
        $expected = (@($found.Plans | ForEach-Object { '{0}|{1}|{2}' -f $_.Folder, $_.Installer, $_.Pattern }) -join ';')
        $actual = (@($r.Plans | ForEach-Object { '{0}|{1}|{2}' -f $_.Folder, $_.Installer, $_.Pattern }) -join ';')
        $actual | Should -Be $expected
        @($r.SkippedFolders).Count | Should -Be @($found.SkippedFolders).Count
        # Nothing failed, so no review routing rides along.
        @($r.Keys) -contains 'RoutedToReview' | Should -BeFalse
    }
    It 'a throwing Runner fails exactly that driver while every other plan still runs, routed to review' {
        $script:ran = @()
        $runner = {
            param($Plan)
            $script:ran += $Plan.Installer
            if ($Plan.Installer -eq 'installer.exe') { throw 'LAN installer crashed' }
        }
        $r = Invoke-DriverPhase -Root $script:tree -Runner $runner
        $r.Ok | Should -BeFalse
        $r.DryRun | Should -BeFalse
        $r.RoutedToReview | Should -BeTrue
        # Every plan was attempted; one failure never stops the others (Q27).
        @($script:ran).Count | Should -Be 5
        @($script:ran | Where-Object { $_ -eq 'installer.exe' }).Count | Should -Be 1
        @($r.FailedDrivers).Count | Should -Be 1
        $r.FailedDrivers[0].Installer | Should -Be 'installer.exe'
        $r.FailedDrivers[0].Folder | Should -BeLike ('*' + (Join-Path 'Gigabyte' 'B650\LAN'))
        $r.FailedDrivers[0].Error | Should -Match 'LAN installer crashed'
        @($r.Executed).Count | Should -Be 4
        @($r.Executed | Where-Object { $_.Installer -eq 'installer.exe' }).Count | Should -Be 0
    }
    It 'a non-zero installer exit code fails that driver' {
        $runner = {
            param($Plan)
            if ($Plan.Installer -eq 'SETUP.EXE') { return [pscustomobject]@{ ExitCode = 2 } }
            return $true
        }
        $r = Invoke-DriverPhase -Root $script:tree -Runner $runner
        $r.Ok | Should -BeFalse
        $r.RoutedToReview | Should -BeTrue
        @($r.FailedDrivers).Count | Should -Be 1
        $r.FailedDrivers[0].Installer | Should -Be 'SETUP.EXE'
        $r.FailedDrivers[0].Error | Should -Match 'exited with code 2'
        @($r.Executed).Count | Should -Be 4
    }
    It 'never throws: a missing driver root is reported and routed to review' {
        $missing = Join-Path $script:tree 'DoesNotExist'
        $script:missingResult = $null
        { $script:missingResult = Invoke-DriverPhase -Root $missing -DryRun } | Should -Not -Throw
        $script:missingResult.Ok | Should -BeFalse
        $script:missingResult.DryRun | Should -BeTrue
        $script:missingResult.RoutedToReview | Should -BeTrue
        @($script:missingResult.FailedDrivers).Count | Should -Be 1
        $script:missingResult.FailedDrivers[0].Installer | Should -BeNullOrEmpty
        $script:missingResult.FailedDrivers[0].Error | Should -Match 'DoesNotExist'
        @($script:missingResult.Executed).Count | Should -Be 0
    }
    It 'the default runner silently invokes Start-Process once per plan with the -s ASUS convention' {
        Mock Start-Process -ModuleName OSDeploy.Orchestrator { return [pscustomobject]@{ ExitCode = 0 } }
        $r = Invoke-DriverPhase -Root $script:tree
        $r.Ok | Should -BeTrue
        $r.DryRun | Should -BeFalse
        @($r.Executed).Count | Should -Be 5
        @($r.FailedDrivers).Count | Should -Be 0
        Should -Invoke Start-Process -ModuleName OSDeploy.Orchestrator -Exactly 5 -ParameterFilter { $ArgumentList -eq '-s' } -Scope It
        Should -Invoke Start-Process -ModuleName OSDeploy.Orchestrator -Exactly 1 -ParameterFilter {
            $FilePath -like ('*' + (Join-Path 'Gigabyte' 'B650\LAN\installer.exe')) -and $ArgumentList -eq '-s'
        } -Scope It
    }
    It 'never references autoAll.ps1 or eztConfig.ps1 (Q95)' {
        # Comment-stripped code scan, the same convention the static gates
        # use for banned constructs: documenting the prohibition in a
        # comment must not trip the lock, but any CODE reference fails it.
        $psm1Path = Join-Path (Split-Path -Parent $modulePath) 'OSDeploy.Orchestrator.psm1'
        $codeLines = @((Get-Content -LiteralPath $psm1Path) | ForEach-Object { ($_ -split '#')[0] })
        ($codeLines -join "`n") | Should -Not -Match '(?i)autoall|eztconfig'
    }
}

# ---------------------------------------------------------------------------
# Task 22: application phase - manifest-driven execution with per-entry
# retries and the Q26 Acknowledge-and-Continue payload (Q25/Q26). None of
# these tests needs the single-instance lock or an orchestration context.
# No real installer is ever launched: execution tests inject a recording
# FAKE Runner, and the default-runner test MOCKS Start-Process in module
# scope (the mock returns an already-exited Process shape).
# ---------------------------------------------------------------------------

Describe 'Invoke-ApplicationPhase manifest loading (fail closed)' {
    AfterEach {
        foreach ($d in $script:appDirs) {
            Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
        }
        $script:appDirs = @()
    }
    It 'throws when the manifest file is missing' {
        $missing = Join-Path $ckDir ('apps-missing-' + [guid]::NewGuid().ToString('N') + '.json')
        { Invoke-ApplicationPhase -ManifestPath $missing -Runner { param($Context) } } | Should -Throw
    }
    It 'throws when the manifest is unparseable JSON' {
        $garbage = Join-Path $ckDir ('apps-garbage-' + [guid]::NewGuid().ToString('N') + '.json')
        Set-Content -Path $garbage -Value 'not json at all' -Encoding Ascii
        { Invoke-ApplicationPhase -ManifestPath $garbage -Runner { param($Context) } } | Should -Throw
    }
    It 'throws when the document is valid JSON but not an array of entries' {
        $object = Join-Path $ckDir ('apps-object-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-AtomicJson -Path $object -Value @{ Id = 'only'; Name = 'Not An Array' }
        { Invoke-ApplicationPhase -ManifestPath $object -Runner { param($Context) } } | Should -Throw
    }
    It 'throws naming the missing field when an entry lacks one of the nine, before any Runner invocation' {
        $script:calls = 0
        $entry = New-AppEntry
        $null = $entry.Remove('SuccessCodes')
        $path = New-AppManifest -Entries @($entry)
        $err = $null
        try { Invoke-ApplicationPhase -ManifestPath $path -Runner { param($Context) $script:calls++ } }
        catch { $err = $_.Exception.Message }
        $err | Should -Match 'SuccessCodes'
        $script:calls | Should -Be 0
    }
    It 'throws when SuccessCodes is empty or RetryCount is below one' {
        $badCodes = New-AppEntry
        $badCodes.SuccessCodes = @()
        $path1 = New-AppManifest -Entries @($badCodes)
        $err1 = $null
        try { Invoke-ApplicationPhase -ManifestPath $path1 -Runner { param($Context) } }
        catch { $err1 = $_.Exception.Message }
        $err1 | Should -Match 'SuccessCodes'
        $badRetry = New-AppEntry
        $badRetry.RetryCount = 0
        $path2 = New-AppManifest -Entries @($badRetry)
        $err2 = $null
        try { Invoke-ApplicationPhase -ManifestPath $path2 -Runner { param($Context) } }
        catch { $err2 = $_.Exception.Message }
        $err2 | Should -Match 'RetryCount'
    }
    It 'an empty manifest array is Ok with nothing to do' {
        $script:calls = 0
        $path = New-AppManifest -Entries @()
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner { param($Context) $script:calls++ }
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
        $script:calls | Should -Be 0
    }
}

Describe 'Invoke-ApplicationPhase execution, retries, and the Q26 acknowledgement payload (Q25/Q26)' {
    AfterEach {
        foreach ($d in $script:appDirs) {
            Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
        }
        $script:appDirs = @()
    }
    It 'success path: Ok with zero failures, NeedsAcknowledgement false, exactly three result keys, one Runner call' {
        $script:calls = 0
        $script:seen = $null
        $path = New-AppManifest -Entries @(New-AppEntry)
        $runner = {
            param($Context)
            $script:calls++
            $script:seen = $Context
            return [pscustomobject]@{ ExitCode = 0 }
        }
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner $runner
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
        # The result is pure data for the consumer: exactly the three keys,
        # so no prompt or acknowledgement affordance rides along (Q25).
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Failures,NeedsAcknowledgement,Ok'
        $script:calls | Should -Be 1
        # The runner received the entry object plus the computed paths.
        $script:seen.Entry.Id | Should -Be 'app-1'
        $script:seen.Entry.Name | Should -Be 'Sample Utility'
        $script:seen.InstallerPath | Should -Be (Join-Path (Split-Path -Parent $path) 'SampleSetup.exe')
        $script:seen.LogLocation | Should -Be (Join-Path (Split-Path -Parent $path) 'Logs\app-1.log')
        $script:seen.TimeoutMinutes | Should -Be 10
    }
    It 'has zero prompt surface: no interactive prompt construct anywhere in module code (Q25)' {
        # Comment-stripped code scan (same convention as the Q95 lock):
        # documenting the prohibition in a comment must not trip it, but any
        # CODE reference to an interactive prompt fails it.
        $psm1Path = Join-Path (Split-Path -Parent $modulePath) 'OSDeploy.Orchestrator.psm1'
        $codeLines = @((Get-Content -LiteralPath $psm1Path) | ForEach-Object { ($_ -split '#')[0] })
        ($codeLines -join "`n") | Should -Not -Match '(?i)read-host|ui\.prompt|messagebox'
    }
    It 'runs the staged mock-partition app manifests (EZT and MMC, one entry each) to Ok' {
        $script:ranIds = @()
        $runner = {
            param($Context)
            $script:ranIds += [string]$Context.Entry.Id
            return [pscustomobject]@{ ExitCode = 0 }
        }
        foreach ($wf in @('EZT', 'MMC')) {
            $r = Invoke-ApplicationPhase -ManifestPath (Join-Path $root ('Sources\Apps\' + $wf + '\manifest.json')) -Runner $runner
            $r.Ok | Should -BeTrue
            @($r.Failures).Count | Should -Be 0
            $r.NeedsAcknowledgement | Should -BeFalse
        }
        (@($script:ranIds) -join ',') | Should -Be 'ezt-app-1,mmc-app-1'
    }
    It 'retries per the manifest: exit 1 twice then 0 satisfies RetryCount 3 on the third attempt' {
        $script:calls = 0
        $runner = {
            param($Context)
            $script:calls++
            if ($script:calls -lt 3) { return [pscustomobject]@{ ExitCode = 1 } }
            return [pscustomobject]@{ ExitCode = 0 }
        }
        $path = New-AppManifest -Entries @(New-AppEntry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner $runner
        $r.Ok | Should -BeTrue
        $script:calls | Should -Be 3
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
    }
    It 'honors the per-entry success code list: 3010 succeeds when listed and consumes no retry' {
        $script:calls = 0
        $entry = New-AppEntry
        $entry.SuccessCodes = @(0, 3010)
        $path = New-AppManifest -Entries @($entry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            $script:calls++
            return [pscustomobject]@{ ExitCode = 3010 }
        }
        $r.Ok | Should -BeTrue
        $script:calls | Should -Be 1
    }
    It 'treats a runner returning boolean true as success' {
        $path = New-AppManifest -Entries @(New-AppEntry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner { param($Context) return $true }
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
    }
    It 'treats a non-numeric runner report as a failed attempt, never an escaping exception' {
        $entry = New-AppEntry
        $entry.RetryCount = 2
        $path = New-AppManifest -Entries @($entry)
        $script:calls = 0
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            $script:calls++
            return [pscustomobject]@{ ExitCode = 'garbage' }
        }
        $r.Ok | Should -BeFalse
        $script:calls | Should -Be 2
        @($r.Failures).Count | Should -Be 1
        $r.Failures[0].Status | Should -Be 'Error'
        $r.Failures[0].ExitCode | Should -BeNullOrEmpty
    }
    It 'permanent failure: the exhausted entry lands in Failures with the exact four-field Q26 payload' {
        $script:calls = 0
        $path = New-AppManifest -Entries @(New-AppEntry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            $script:calls++
            return [pscustomobject]@{ ExitCode = 1 }
        }
        $r.Ok | Should -BeFalse
        $script:calls | Should -Be 3
        $r.NeedsAcknowledgement | Should -BeTrue
        @($r.Failures).Count | Should -Be 1
        $f = $r.Failures[0]
        # EXACTLY the Q26 payload fields - program, status, exit code, log
        # location - and nothing else.
        (@($f.Keys | Sort-Object) -join ',') | Should -Be 'ExitCode,LogLocation,Program,Status'
        $f.Program | Should -Be 'Sample Utility'
        $f.Status | Should -Be 'Failed'
        $f.ExitCode | Should -Be 1
        $f.LogLocation | Should -Be (Join-Path (Split-Path -Parent $path) 'Logs\app-1.log')
    }
    It 'multiple exhausted entries accumulate into the payload in manifest order' {
        $first = New-AppEntry
        $first.Name = 'First Utility'
        $second = New-AppEntry
        $second.Id = 'app-2'
        $second.Name = 'Second Utility'
        $second.RetryCount = 2
        $path = New-AppManifest -Entries @($first, $second)
        $script:calls = 0
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            $script:calls++
            if ($Context.Entry.Id -eq 'app-1') { return [pscustomobject]@{ ExitCode = 7 } }
            return [pscustomobject]@{ ExitCode = 9 }
        }
        $r.Ok | Should -BeFalse
        $r.NeedsAcknowledgement | Should -BeTrue
        @($r.Failures).Count | Should -Be 2
        # Both entries exhausted their own attempt budgets: 3 + 2 invocations.
        $script:calls | Should -Be 5
        $r.Failures[0].Program | Should -Be 'First Utility'
        $r.Failures[0].Status | Should -Be 'Failed'
        $r.Failures[0].ExitCode | Should -Be 7
        $r.Failures[0].LogLocation | Should -Be (Join-Path (Split-Path -Parent $path) 'Logs\app-1.log')
        $r.Failures[1].Program | Should -Be 'Second Utility'
        $r.Failures[1].ExitCode | Should -Be 9
        $r.Failures[1].LogLocation | Should -Be (Join-Path (Split-Path -Parent $path) 'Logs\app-2.log')
    }
    It 'a throwing runner exhausts its attempts and reports Status Error with a null exit code' {
        $script:calls = 0
        $entry = New-AppEntry
        $entry.RetryCount = 2
        $path = New-AppManifest -Entries @($entry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            $script:calls++
            throw 'installer wrapper exploded'
        }
        $r.Ok | Should -BeFalse
        $script:calls | Should -Be 2
        @($r.Failures).Count | Should -Be 1
        $r.Failures[0].Status | Should -Be 'Error'
        $r.Failures[0].ExitCode | Should -BeNullOrEmpty
        $r.Failures[0].Program | Should -Be 'Sample Utility'
        $r.NeedsAcknowledgement | Should -BeTrue
    }
    It 'timeout: an attempt judged past a TimeoutMinutes 0 deadline fails even with a success-shaped exit code' {
        $entry = New-AppEntry
        $entry.RetryCount = 2
        $entry.TimeoutMinutes = 0
        $path = New-AppManifest -Entries @($entry)
        $sleepyRunner = {
            param($Context)
            Start-Sleep -Milliseconds 50
            return [pscustomobject]@{ ExitCode = 0 }
        }
        # Deterministic both with the frozen -Now clock and with the live
        # wall clock: a zero-minute deadline IS the attempt start, so the
        # judgment read always meets it.
        $withNow = Invoke-ApplicationPhase -ManifestPath $path -Runner $sleepyRunner -Now ([datetime]::UtcNow)
        $withNow.Ok | Should -BeFalse
        $withNow.NeedsAcknowledgement | Should -BeTrue
        @($withNow.Failures).Count | Should -Be 1
        $withNow.Failures[0].Status | Should -Be 'TimedOut'
        $withNow.Failures[0].LogLocation | Should -Be (Join-Path (Split-Path -Parent $path) 'Logs\app-1.log')
        $live = Invoke-ApplicationPhase -ManifestPath $path -Runner $sleepyRunner
        $live.Ok | Should -BeFalse
        @($live.Failures).Count | Should -Be 1
        $live.Failures[0].Status | Should -Be 'TimedOut'
    }
    It 'a bounded timeout does not fire before the deadline (frozen -Now clock, TimeoutMinutes 5)' {
        $entry = New-AppEntry
        $entry.RetryCount = 1
        $entry.TimeoutMinutes = 5
        $path = New-AppManifest -Entries @($entry)
        $r = Invoke-ApplicationPhase -ManifestPath $path -Runner {
            param($Context)
            Start-Sleep -Milliseconds 50
            return [pscustomobject]@{ ExitCode = 0 }
        } -Now ([datetime]::UtcNow)
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
    }
    It 'the default runner silently invokes Start-Process with the entry arguments, resolving relative and rooted installers' {
        Mock Start-Process -ModuleName OSDeploy.Orchestrator {
            # Already-exited Process shape: the bounded wait is skipped and
            # the ExitCode evaluation path runs.
            return [pscustomobject]@{ Id = 4242; HasExited = $true; ExitCode = 0 }
        }
        $rooted = Join-Path $ckDir 'RootedSetup.exe'
        $second = New-AppEntry
        $second.Id = 'app-2'
        $second.Installer = $rooted
        $path = New-AppManifest -Entries @((New-AppEntry), $second)
        $r = Invoke-ApplicationPhase -ManifestPath $path
        $r.Ok | Should -BeTrue
        @($r.Failures).Count | Should -Be 0
        $r.NeedsAcknowledgement | Should -BeFalse
        # A relative Installer resolves BESIDE the manifest; a rooted one is
        # used exactly as written; the entry's own SilentArgs are passed.
        Should -Invoke Start-Process -ModuleName OSDeploy.Orchestrator -Exactly 1 -ParameterFilter {
            $FilePath -eq (Join-Path (Split-Path -Parent $path) 'SampleSetup.exe') -and $ArgumentList -eq '/S /norestart'
        } -Scope It
        Should -Invoke Start-Process -ModuleName OSDeploy.Orchestrator -Exactly 1 -ParameterFilter {
            $FilePath -eq $rooted
        } -Scope It
    }
}

# ---------------------------------------------------------------------------
# Task 23: EZT workflow specifics (Q14/Q15/Q16/Q18/Q19/Q24/Q86)
# ---------------------------------------------------------------------------

Describe 'New-EztUnattend registry-sync automatic sign-on fragment (Q14/Q16/Q18)' {
    It 'returns a parseable unattend XML document with the three passes' {
        $xml = New-EztUnattend -Edition 'Pro' -TimeZone 'China Standard Time'
        $xml | Should -BeOfType [string]
        $doc = [xml]$xml
        $doc.DocumentElement.LocalName | Should -Be 'unattend'
        (@($doc.GetElementsByTagName('settings') | ForEach-Object { $_.pass }) -join ',') | Should -Be 'windowsPE,specialize,oobeSystem'
    }
    It 'syncs the three Winlogon values for the passwordless User through reg add commands' {
        $doc = [xml](New-EztUnattend -Edition 'Pro' -TimeZone 'China Standard Time')
        $paths = @($doc.GetElementsByTagName('Path') | ForEach-Object { $_.InnerText })
        @($paths).Count | Should -Be 3
        foreach ($p in $paths) {
            $p | Should -BeLike '*HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon*'
        }
        $userCmd = @($paths | Where-Object { $_ -match '/v DefaultUserName' })
        $userCmd.Count | Should -Be 1
        $userCmd[0] | Should -BeLike '* /d "User" /f*'
        $pwCmd = @($paths | Where-Object { $_ -match '/v DefaultPassword' })
        $pwCmd.Count | Should -Be 1
        $pwCmd[0] | Should -BeLike '* /d "" /f*'
        $autoCmd = @($paths | Where-Object { $_ -match '/v AutoAdminLogon' })
        $autoCmd.Count | Should -Be 1
        $autoCmd[0] | Should -BeLike '* /d "1" /f*'
    }
    It 'contains no AutoLogonCount element or text anywhere (Q16: unlimited sign-in)' {
        $xml = New-EztUnattend -Edition 'Pro' -TimeZone 'China Standard Time'
        $doc = [xml]$xml
        @($doc.GetElementsByTagName('AutoLogonCount')).Count | Should -Be 0
        $xml | Should -Not -Match '(?i)autologoncount'
    }
    It 'contains no product-key element, field, or key-shaped material anywhere (Q18)' {
        $xml = New-EztUnattend -Edition 'Pro' -TimeZone 'China Standard Time'
        $doc = [xml]$xml
        @($doc.GetElementsByTagName('ProductKey')).Count | Should -Be 0
        $xml | Should -Not -Match '(?i)productkey'
        $xml | Should -Not -Match '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}'
        # UserData is the element a product key would live under: it
        # carries only the EULA acceptance.
        $userData = @($doc.GetElementsByTagName('UserData'))
        $userData.Count | Should -Be 1
        (@($userData[0].ChildNodes | ForEach-Object { $_.LocalName }) -join ',') | Should -Be 'AcceptEula'
    }
    It 'consumes Edition as the image-name metadata value and TimeZone as the Shell-Setup time zone' {
        $doc = [xml](New-EztUnattend -Edition 'Pro' -TimeZone 'China Standard Time')
        $values = @($doc.GetElementsByTagName('Value') | ForEach-Object { $_.InnerText })
        $values -contains 'Windows 11 Pro' | Should -BeTrue
        $tz = @($doc.GetElementsByTagName('TimeZone'))
        $tz.Count | Should -Be 1
        $tz[0].InnerText | Should -Be 'China Standard Time'
    }
}

Describe 'Invoke-EztAccountPhase account plan (Q14/Q15/Q24)' {
    It 'creates the passwordless User and adds Administrators membership (Q14/Q15)' {
        $plan = Invoke-EztAccountPhase
        $steps = @($plan.Steps)
        $create = @($steps | Where-Object { $_.Action -eq 'CreateUser' })
        $create.Count | Should -Be 1
        $create[0].Name | Should -Be 'User'
        $create[0].Passwordless | Should -BeTrue
        $create[0].Password | Should -BeNullOrEmpty
        $group = @($steps | Where-Object { $_.Action -eq 'AddGroupMember' })
        $group.Count | Should -Be 1
        $group[0].Name | Should -Be 'User'
        $group[0].Group | Should -Be 'Administrators'
    }
    It 'keeps the built-in Administrator disabled: one idempotent disable step, no enable action anywhere (Q24)' {
        $plan = Invoke-EztAccountPhase
        $actions = @($plan.Steps | ForEach-Object { $_.Action })
        ($actions -join ',') | Should -Be 'CreateUser,AddGroupMember,EnsureUserDisabled,CreateShortcut'
        @($plan.Steps | Where-Object { $_.Action -match 'Enable' }).Count | Should -Be 0
        # The serialized plan text carries no enable token at all.
        ($plan | ConvertTo-Json -Depth 6) | Should -Not -Match '(?i)enable'
        $disable = @($plan.Steps | Where-Object { $_.Action -eq 'EnsureUserDisabled' })
        $disable.Count | Should -Be 1
        $disable[0].Name | Should -Be 'Administrator'
    }
    It 'creates the public-desktop shortcut targeting the managed workflow, never ms-settings:signinoptions (Q15)' {
        $plan = Invoke-EztAccountPhase
        $shortcut = @($plan.Steps | Where-Object { $_.Action -eq 'CreateShortcut' })
        $shortcut.Count | Should -Be 1
        $shortcut[0].Name | Should -Be 'Set or Change Your Password'
        $shortcut[0].Directory | Should -Be 'C:\Users\Public\Desktop'
        $shortcut[0].Target | Should -Not -Match '(?i)ms-settings:signinoptions'
        $shortcut[0].TargetKind | Should -Be 'ManagedWorkflow'
        $shortcut[0].Target | Should -Be 'C:\ProgramData\OSDeploy\Set-OwnerPassword.ps1'
    }
    It 'default Runner records every step with no side effects and the result carries exactly the two keys' {
        $plan = Invoke-EztAccountPhase
        @($plan.Executed).Count | Should -Be 4
        (@($plan.Executed | ForEach-Object { $_.Action }) -join ',') | Should -Be (@($plan.Steps | ForEach-Object { $_.Action }) -join ',')
        (@($plan.Keys | Sort-Object) -join ',') | Should -Be 'Executed,Steps'
    }
    It 'executes each step through an injected Runner in plan order' {
        $script:ranActions = @()
        $plan = Invoke-EztAccountPhase -Runner {
            param($Step)
            $script:ranActions += $Step.Action
            return $true
        }
        ($script:ranActions -join ',') | Should -Be 'CreateUser,AddGroupMember,EnsureUserDisabled,CreateShortcut'
        @($plan.Executed).Count | Should -Be 4
    }
    It 'seeds the persistent Winlogon automatic sign-on values through the registry store fixture (Q16/Q24)' {
        $reg = @{}
        $null = Invoke-EztAccountPhase -Registry $reg
        $winlogon = $reg[$script:EztWinlogonPath]
        $winlogon['DefaultUserName'] | Should -Be 'User'
        $winlogon['DefaultPassword'] | Should -Be ''
        $winlogon['AutoAdminLogon'] | Should -Be '1'
        $winlogon.Contains('AutoLogonCount') | Should -BeFalse
    }
    It 'a throwing Runner propagates and the registry fixture stays untouched (fail closed)' {
        $reg = @{}
        { Invoke-EztAccountPhase -Runner { param($Step) throw 'account subsystem offline' } -Registry $reg } | Should -Throw
        $reg.Contains($script:EztWinlogonPath) | Should -BeFalse
        @($reg.Keys).Count | Should -Be 0
    }
    It 'a Runner returning $false fails the phase before any registry seeding (module failure convention)' {
        $reg = @{}
        $runner = {
            param($Step)
            if ($Step.Action -eq 'AddGroupMember') { return $false }
            return $true
        }
        { Invoke-EztAccountPhase -Runner $runner -Registry $reg } | Should -Throw
        $reg.Contains($script:EztWinlogonPath) | Should -BeFalse
    }
}

Describe 'Invoke-PasswordTransition one controlled transition (Q86)' {
    It 'applies the four steps in order and lands the registry end state' {
        $reg = New-EztRegistry
        $script:setCalls = 0
        $script:received = $null
        $setPassword = {
            param([string]$NewPassword)
            $script:setCalls++
            $script:received = $NewPassword
            return $true
        }
        $r = Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword $setPassword -Registry $reg
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'AppliedSteps'
        ($r.AppliedSteps -join ',') | Should -Be 'Warn,SetPassword,DisableAutoLogon,ClearCredential'
        $script:setCalls | Should -Be 1
        $script:received | Should -Be 'Owner-Pass-1'
        $winlogon = $reg[$script:EztWinlogonPath]
        $winlogon['AutoAdminLogon'] | Should -Be '0'
        $winlogon.Contains('DefaultPassword') | Should -BeFalse
        $winlogon['DefaultUserName'] | Should -Be 'User'
    }
    It 'proves the cross-boundary order with one shared call log: warn, set, disable, clear' {
        $script:log = @()
        Mock Write-Warning -ModuleName OSDeploy.Orchestrator { $script:log += 'Warn' }
        Mock Set-RegistryStoreValue -ModuleName OSDeploy.Orchestrator { $script:log += ('registry-set:' + $Name) }
        Mock Remove-RegistryStoreValue -ModuleName OSDeploy.Orchestrator { $script:log += ('registry-remove:' + $Name) }
        $setPassword = {
            param([string]$NewPassword)
            $script:log += 'SetPassword'
            return $true
        }
        $reg = New-EztRegistry
        $null = Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword $setPassword -Registry $reg
        ($script:log -join ',') | Should -Be 'Warn,SetPassword,registry-set:AutoAdminLogon,registry-remove:DefaultPassword'
    }
    It 'warns that a successful password change ends automatic sign-in (Q86 warning requirement)' {
        $script:warnText = $null
        Mock Write-Warning -ModuleName OSDeploy.Orchestrator { $script:warnText = $Message }
        $null = Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword { param([string]$NewPassword) return $true } -Registry (New-EztRegistry)
        $script:warnText | Should -Not -BeNullOrEmpty
        $script:warnText | Should -Match '(?i)automatic sign-in'
        $script:warnText | Should -Match '(?i)password'
    }
    It 'a throwing SetPassword propagates and leaves ALL THREE states untouched' {
        $reg = New-EztRegistry
        $before = $reg | ConvertTo-Json -Depth 5
        $script:setCalls = 0
        $boom = {
            param([string]$NewPassword)
            $script:setCalls++
            throw 'password service exploded'
        }
        { Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword $boom -Registry $reg } | Should -Throw 'password service exploded'
        $script:setCalls | Should -Be 1
        # State compare: the fixture is identical to its pre-call snapshot.
        ($reg | ConvertTo-Json -Depth 5) | Should -Be $before
        # Explicit field asserts: password unset, autologon intact, credential intact.
        $winlogon = $reg[$script:EztWinlogonPath]
        $winlogon['AutoAdminLogon'] | Should -Be '1'
        $winlogon.Contains('DefaultPassword') | Should -BeTrue
        $winlogon['DefaultPassword'] | Should -Be ''
        $winlogon['DefaultUserName'] | Should -Be 'User'
    }
    It 'a $false-returning SetPassword is a failure: throw with all three states untouched' {
        $reg = New-EztRegistry
        $before = $reg | ConvertTo-Json -Depth 5
        { Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword { param([string]$NewPassword) return $false } -Registry $reg } | Should -Throw
        ($reg | ConvertTo-Json -Depth 5) | Should -Be $before
        $reg[$script:EztWinlogonPath]['AutoAdminLogon'] | Should -Be '1'
        $reg[$script:EztWinlogonPath].Contains('DefaultPassword') | Should -BeTrue
    }
    It 'removes the credential value rather than blanking it and never writes an AutoLogonCount (Q16/Q86)' {
        $reg = New-EztRegistry
        $null = Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword { param([string]$NewPassword) return $true } -Registry $reg
        $winlogon = $reg[$script:EztWinlogonPath]
        (@($winlogon.Keys | Sort-Object) -join ',') | Should -Be 'AutoAdminLogon,DefaultUserName'
        @($reg.Keys).Count | Should -Be 1
    }
    It 'tolerates a store that never carried the Winlogon values (idempotent removal)' {
        $reg = @{}
        $r = Invoke-PasswordTransition -NewPassword 'Owner-Pass-1' -SetPassword { param([string]$NewPassword) return $true } -Registry $reg
        ($r.AppliedSteps -join ',') | Should -Be 'Warn,SetPassword,DisableAutoLogon,ClearCredential'
        $reg[$script:EztWinlogonPath]['AutoAdminLogon'] | Should -Be '0'
        $reg[$script:EztWinlogonPath].Contains('DefaultPassword') | Should -BeFalse
    }
}

Describe 'Invoke-ActivationFlow incomplete-activation choices (Q19, Q18)' {
    It 'offers exactly Retry, Finish Without Activation, Cancel with the incomplete state recorded' {
        $r = Invoke-ActivationFlow -ActivationResult 'Failed'
        (@($r.Choices) -join ',') | Should -Be 'Retry,Finish Without Activation,Cancel'
        $r.Incomplete | Should -BeTrue
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'ActivationResult,Choices,Incomplete'
        $r.ActivationResult | Should -Be 'Failed'
    }
    It 'a succeeded activation returns no choices and Incomplete false' {
        $r = Invoke-ActivationFlow -ActivationResult 'Succeeded'
        @($r.Choices).Count | Should -Be 0
        $r.Incomplete | Should -BeFalse
    }
    It 'any non-success status is treated as incomplete (fail visible)' {
        foreach ($status in @('TimedOut', 'Offline', 'NeedsAttention')) {
            $r = Invoke-ActivationFlow -ActivationResult $status
            $r.Incomplete | Should -BeTrue
            @($r.Choices).Count | Should -Be 3
        }
    }
    It 'never includes key material: no key-named property, no planted marker, no key-shaped value (Q18)' {
        $planted = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        $global:PlantedProductKey = $planted
        try {
            $r = Invoke-ActivationFlow -ActivationResult 'Failed'
            (@($r.Keys) -join ',') | Should -Not -Match '(?i)key'
            $text = $r | ConvertTo-Json -Depth 5
            $text | Should -Not -Match [regex]::Escape($planted)
            $text | Should -Not -Match '[A-Z0-9]{5}(-[A-Z0-9]{5}){4}'
            foreach ($k in @($r.Keys)) {
                ([string]$r[$k]) | Should -Not -Be $planted
            }
        }
        finally {
            Remove-Variable -Name PlantedProductKey -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Task 24: MMC workflow specifics and the Energy Star phase (Q14/Q15/Q30/
# Q32, Q20-Q23). None of these tests needs the single-instance lock or an
# orchestration context. No real sysprep ever runs: finalize tests inject
# recording scriptblocks, and the default-sysprep tests MOCK Start-Process
# in module scope (the deploy-host-only default; $env:SystemRoot is staged
# so the path resolves on Linux too).
# ---------------------------------------------------------------------------

Describe 'Invoke-MmcFinalize Audit-Mode finalize order and failure routing (Q30/Q32)' {
    BeforeEach {
        $script:log = @()
    }
    It 'success is Complete after cleanup, proven by one shared call log: every cleanup call precedes the sysprep call' {
        $r = Invoke-MmcFinalize -Cleanup { $script:log += 'cleanup' } -Sysprep { $script:log += 'sysprep'; return $true }
        # Completion is recorded ONLY on sysprep success: exactly one key.
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Outcome'
        $r.Outcome | Should -Be 'Complete'
        ($script:log -join ',') | Should -Be 'cleanup,sysprep'
    }
    It 'a throwing sysprep returns SysprepFailure that stays in Audit Mode and is NOT Complete' {
        $r = Invoke-MmcFinalize -Cleanup { $script:log += 'cleanup' } -Sysprep { $script:log += 'sysprep'; throw 'sysprep fatal error' }
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Outcome,StayInAuditMode'
        $r.Outcome | Should -Be 'SysprepFailure'
        $r.StayInAuditMode | Should -BeTrue
    }
    It 'a $false-returning sysprep is a failure that NEVER re-runs cleanup: exactly one cleanup call, before sysprep' {
        $r = Invoke-MmcFinalize -Cleanup { $script:log += 'cleanup' } -Sysprep { $script:log += 'sysprep'; return $false }
        $r.Outcome | Should -Be 'SysprepFailure'
        $r.StayInAuditMode | Should -BeTrue
        # Q32: run no cleanup after entering (or attempting) OOBE - the one
        # cleanup call happened BEFORE the sysprep attempt and is not retried.
        @($script:log | Where-Object { $_ -eq 'cleanup' }).Count | Should -Be 1
        ($script:log -join ',') | Should -Be 'cleanup,sysprep'
    }
    It 'a non-zero sysprep exit code (Start-Process -PassThru shape) is a failure; every non-zero code counts' {
        foreach ($code in @(1, 5, 3010)) {
            $script:log = @()
            $r = Invoke-MmcFinalize -Cleanup { $script:log += 'cleanup' } -Sysprep {
                $script:log += 'sysprep'
                return [pscustomobject]@{ ExitCode = $code }
            }
            $r.Outcome | Should -Be 'SysprepFailure'
            $r.StayInAuditMode | Should -BeTrue
            ($script:log -join ',') | Should -Be 'cleanup,sysprep'
        }
    }
    It 'a failing cleanup (throw or $false) fails BEFORE the sysprep call: nothing enters OOBE (Q32)' {
        # Temporary artifacts must be gone before OOBE entry, so a failed
        # cleanup can never be followed by sysprep; the machine stays in
        # Audit Mode by construction.
        $script:sysprepCalls = 0
        { Invoke-MmcFinalize -Cleanup { return $false } -Sysprep { $script:sysprepCalls++; return $true } } | Should -Throw
        $script:sysprepCalls | Should -Be 0
        { Invoke-MmcFinalize -Cleanup { throw 'cleanup could not remove the artifacts' } -Sysprep { $script:sysprepCalls++; return $true } } | Should -Throw
        $script:sysprepCalls | Should -Be 0
    }
    It 'the default sysprep invokes sysprep.exe /generalize /oobe exactly once and a zero exit code is Complete' {
        $oldSystemRoot = $env:SystemRoot
        $env:SystemRoot = 'C:\Windows'
        try {
            Mock Start-Process -ModuleName OSDeploy.Orchestrator { return [pscustomobject]@{ ExitCode = 0 } }
            # Both scriptblocks defaulted: the recorder cleanup runs without
            # side effects, then the real (deploy-host-only) sysprep call.
            $r = Invoke-MmcFinalize
            $r.Outcome | Should -Be 'Complete'
            Should -Invoke Start-Process -ModuleName OSDeploy.Orchestrator -Exactly 1 -Scope It -ParameterFilter {
                $FilePath -match '(?i)sysprep\.exe$' -and (@($ArgumentList) -join ' ') -eq '/generalize /oobe'
            }
        }
        finally {
            if ($null -eq $oldSystemRoot) { Remove-Item Env:\SystemRoot -ErrorAction SilentlyContinue }
            else { $env:SystemRoot = $oldSystemRoot }
        }
    }
    It 'the default sysprep maps a non-zero exit code to SysprepFailure with StayInAuditMode (deploy-host failure path)' {
        $oldSystemRoot = $env:SystemRoot
        $env:SystemRoot = 'C:\Windows'
        try {
            Mock Start-Process -ModuleName OSDeploy.Orchestrator { return [pscustomobject]@{ ExitCode = 5 } }
            $r = Invoke-MmcFinalize
            $r.Outcome | Should -Be 'SysprepFailure'
            $r.StayInAuditMode | Should -BeTrue
        }
        finally {
            if ($null -eq $oldSystemRoot) { Remove-Item Env:\SystemRoot -ErrorAction SilentlyContinue }
            else { $env:SystemRoot = $oldSystemRoot }
        }
    }
}

Describe 'Get-MmcPlan MMC finalize plan and the no-EZT-account guard (Q14/Q15/Q30/Q32)' {
    It 'describes the Audit-Mode finalize sequence: cleanup temporary artifacts first, then sysprep /generalize /oobe with StayInAuditMode routing' {
        $plan = Get-MmcPlan
        (@($plan.Keys | Sort-Object) -join ',') | Should -Be 'AccountSteps,FinalEndpoint,Steps,Workflow'
        $plan.Workflow | Should -Be 'MMC'
        $plan.FinalEndpoint | Should -Be 'OOBE'
        (@($plan.Steps | ForEach-Object { $_.Order }) -join ',') | Should -Be '1,2'
        (@($plan.Steps | ForEach-Object { $_.Action }) -join ',') | Should -Be 'CleanupTemporaryArtifacts,Sysprep'
        $sysprepStep = @($plan.Steps | Where-Object { $_.Action -eq 'Sysprep' })[0]
        $sysprepStep.Arguments | Should -Be '/generalize /oobe'
        $sysprepStep.OnFailure | Should -Be 'StayInAuditMode'
    }
    It 'creates NO User account, autologon, or password shortcut: AccountSteps is empty and no such token exists anywhere in the plan (Q14/Q15)' {
        $plan = Get-MmcPlan
        @($plan.AccountSteps).Count | Should -Be 0
        $actions = @(@($plan.Steps) + @($plan.AccountSteps) | ForEach-Object { [string]$_.Action })
        foreach ($banned in @('CreateUser', 'AddGroupMember', 'EnsureUserDisabled', 'CreateShortcut')) {
            $actions -contains $banned | Should -BeFalse
        }
        # The serialized plan text carries no account, autologon, or password
        # token at all (structured scan + raw-text scan, the Q24 convention).
        ($plan | ConvertTo-Json -Depth 6) | Should -Not -Match '(?i)createuser|addgroupmember|ensureuserdisabled|createshortcut|autologon|password'
    }
    It 'contrast: the EZT account plan carries the four account steps MMC omits' {
        $ezt = Invoke-EztAccountPhase
        (@($ezt.Steps | ForEach-Object { $_.Action }) -join ',') | Should -Be 'CreateUser,AddGroupMember,EnsureUserDisabled,CreateShortcut'
        $mmcActions = @((Get-MmcPlan).Steps | ForEach-Object { $_.Action })
        foreach ($eztAction in @('CreateUser', 'AddGroupMember', 'EnsureUserDisabled', 'CreateShortcut')) {
            $mmcActions -contains $eztAction | Should -BeFalse
        }
    }
}

Describe 'Resolve-PowerPolicy decision table and saved-decision handling (Q20-Q23)' {
    It 'CA + MMC applies the regulated Energy Star policy with NO popup' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'MMC'
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Action,Policy,Popup'
        $r.Action | Should -Be 'Apply'
        $r.Popup | Should -BeFalse
        $r.Policy.Regulated | Should -BeTrue
        $r.Policy.Name | Should -Be 'EnergyStar'
        $r.Policy.PowerPlan | Should -Be 'Energy Star'
    }
    It 'CA + EZT applies the regulated Energy Star policy WITH the persistent choice popup' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'EZT'
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Action,Policy,Popup'
        $r.Action | Should -Be 'Apply'
        $r.Popup | Should -BeTrue
        $r.Policy.Regulated | Should -BeTrue
        $r.Policy.Name | Should -Be 'EnergyStar'
    }
    It 'an unregulated state applies High Performance with a 60-minute display timeout and system sleep disabled, regardless of workflow (Q22)' {
        foreach ($state in @('TX', 'NV', 'WA')) {
            $r = Resolve-PowerPolicy -RegulatedState $state -Workflow 'EZT'
            (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Action,Policy,Popup'
            $r.Action | Should -Be 'Apply'
            $r.Popup | Should -BeFalse
            $r.Policy.Regulated | Should -BeFalse
            $r.Policy.Name | Should -Be 'HighPerformance'
            $r.Policy.PowerPlan | Should -Be 'High Performance'
            $r.Policy.DisplayTimeoutMinutes | Should -Be 60
            $r.Policy.SystemSleep | Should -Be 'Disabled'
        }
    }
    It 'state and workflow tokens match case-insensitively' {
        $r = Resolve-PowerPolicy -RegulatedState 'ca' -Workflow 'ezt'
        $r.Popup | Should -BeTrue
        $r.Policy.Regulated | Should -BeTrue
    }
    It 'defaults the workflow to MMC (the no-popup profile) when -Workflow is omitted' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA'
        $r.Popup | Should -BeFalse
        $r.Policy.Name | Should -Be 'EnergyStar'
    }
    It 'an unknown workflow token throws: popup semantics are customer-facing and never guessed' {
        { Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'XYZ' } | Should -Throw
    }
    It 'an empty regulated state fails closed at binding (the state is a required input)' {
        { Resolve-PowerPolicy -RegulatedState '' } | Should -Throw
    }
    It 'a valid saved decision short-circuits detection: FromSaved with the table popup (Q20/Q21)' {
        $ezt = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'EZT' -SavedDecision 'Apply'
        (@($ezt.Keys | Sort-Object) -join ',') | Should -Be 'Action,FromSaved,Popup'
        $ezt.Action | Should -Be 'Apply'
        $ezt.FromSaved | Should -BeTrue
        $ezt.Popup | Should -BeTrue
        $mmc = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'MMC' -SavedDecision 'Decline'
        $mmc.Action | Should -Be 'Decline'
        $mmc.FromSaved | Should -BeTrue
        $mmc.Popup | Should -BeFalse
    }
    It 'the saved decision matches case-insensitively, tolerates surrounding whitespace, and returns the canonical token' {
        foreach ($supplied in @('apply', 'APPLY', ' decline ')) {
            $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'EZT' -SavedDecision $supplied
            $r.FromSaved | Should -BeTrue
        }
        (Resolve-PowerPolicy -RegulatedState 'CA' -SavedDecision 'apply').Action | Should -Be 'Apply'
        (Resolve-PowerPolicy -RegulatedState 'CA' -SavedDecision ' decline ').Action | Should -Be 'Decline'
    }
    It 'an INVALID saved decision re-asks: NeedsPrompt = $true with the detection table row carried for context (Q21)' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'EZT' -SavedDecision 'Maybe'
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Action,NeedsPrompt,Policy,Popup'
        $r.NeedsPrompt | Should -BeTrue
        $r.Action | Should -Be 'Apply'
        $r.Popup | Should -BeTrue
        $r.Policy.Regulated | Should -BeTrue
    }
    It 'a MISSING saved decision (bound but empty) re-asks the same way (Q21)' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'MMC' -SavedDecision ''
        $r.NeedsPrompt | Should -BeTrue
        $r.Action | Should -Be 'Apply'
        $r.Popup | Should -BeFalse
        $r.Policy.Regulated | Should -BeTrue
    }
    It 'an unbound -SavedDecision is the deployment-time detection: the clean three-key row, no prompt flag (Q23)' {
        $r = Resolve-PowerPolicy -RegulatedState 'CA' -Workflow 'EZT'
        @($r.Keys) -contains 'NeedsPrompt' | Should -BeFalse
        @($r.Keys) -contains 'FromSaved' | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# Task 25: Windows Update phase - the fixed scope, configurable cycles, the
# warn-and-acknowledge leftover, the offline skip, and the unhealthy-after-
# reboot routing (Q88). None of these tests needs the single-instance lock
# or an orchestration context. Every scenario drives the phase through an
# injected FAKE Scanner scriptblock (the documented seam); the
# default-scanner tests MOCK the module-internal real pass
# (Invoke-ScopedUpdatePass) the way Tasks 20/23 mock internal helpers.
# ---------------------------------------------------------------------------

Describe 'Get-UpdateScope fixed workflow scope (Q88)' {
    It 'returns the Q88-verbatim include and exclude lists, exact entries, exact order, as arrays' {
        $scope = Get-UpdateScope
        (@($scope.Keys | Sort-Object) -join ',') | Should -Be 'Exclude,Include'
        (@($scope.Include) -join ',') | Should -Be 'Security,Quality,ServicingStack,DotNet,Defender'
        (@($scope.Exclude) -join ',') | Should -Be 'Preview,Optional,Store,FeatureUpgrade,Driver,Firmware,Bios'
        $scope.Include -is [System.Array] | Should -BeTrue
        $scope.Exclude -is [System.Array] | Should -BeTrue
    }
    It 'returns a FRESH table per call: mutating one result never changes the next' {
        $first = Get-UpdateScope
        $first.Include = @('Tampered')
        $first.Exclude = @()
        $second = Get-UpdateScope
        (@($second.Include) -join ',') | Should -Be 'Security,Quality,ServicingStack,DotNet,Defender'
        (@($second.Exclude) -join ',') | Should -Be 'Preview,Optional,Store,FeatureUpgrade,Driver,Firmware,Bios'
    }
}

Describe 'Invoke-UpdatePhase scoped cycles, acknowledgement, and offline skip (Q88)' {
    It 'completes without acknowledgement when the next cycle confirms nothing remains (all installed first cycle)' {
        $script:calls = 0
        $script:contexts = @()
        $scanner = {
            param($Context)
            $script:calls++
            $script:contexts += $Context
            if ($script:calls -eq 1) {
                return @{
                    PendingCount   = 2
                    PendingUpdates = @(@{ Title = 'Security update A' }, @{ Title = 'Quality update B' })
                    RebootRequired = $false
                    Healthy        = $true
                }
            }
            return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $true }
        }
        $r = Invoke-UpdatePhase -Scanner $scanner
        $r.Ok | Should -BeTrue
        # The plain completion is exactly two keys: no acknowledgement, no warning.
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'CyclesCompleted,Ok'
        $r.CyclesCompleted | Should -Be 2
        $script:calls | Should -Be 2
        # The scanner saw 1-based cycle numbers and the fixed Q88 scope every time.
        (@($script:contexts | ForEach-Object { $_.Cycle }) -join ',') | Should -Be '1,2'
        foreach ($c in @($script:contexts)) {
            (@($c.Scope.Include) -join ',') | Should -Be (@((Get-UpdateScope).Include) -join ',')
            (@($c.Scope.Exclude) -join ',') | Should -Be (@((Get-UpdateScope).Exclude) -join ',')
            $c.RebootCompleted | Should -BeFalse
        }
    }
    It 'warns and requires acknowledgement when updates remain after the configured cycle limit' {
        $script:calls = 0
        $scanner = {
            param($Context)
            $script:calls++
            return @{ PendingCount = 1; PendingUpdates = @(@{ Title = 'Stubborn update' }); RebootRequired = $false; Healthy = $true }
        }
        $r = Invoke-UpdatePhase -MaxCycles 2 -Scanner $scanner
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'CyclesCompleted,NeedsAcknowledgement,Ok,Warning'
        $r.Ok | Should -BeTrue
        $r.NeedsAcknowledgement | Should -BeTrue
        $r.Warning | Should -Not -BeNullOrEmpty
        $r.Warning | Should -Match '(?i)pending'
        $r.CyclesCompleted | Should -Be 2
        $script:calls | Should -Be 2
    }
    It 'offline (-Online:$false) skips with a warning, stays eligible (Ok), and NEVER invokes the scanner' {
        $script:calls = 0
        $scanner = {
            param($Context)
            $script:calls++
            return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $true }
        }
        $r = Invoke-UpdatePhase -Online:$false -Scanner $scanner
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Ok,Skipped,Warning'
        $r.Ok | Should -BeTrue
        $r.Skipped | Should -BeTrue
        $r.Warning | Should -Not -BeNullOrEmpty
        $r.Warning | Should -Match '(?i)offline'
        $script:calls | Should -Be 0
    }
    It 'an unhealthy scanner report routes to Technician Review and never throws' {
        $r = Invoke-UpdatePhase -Scanner {
            param($Context)
            return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $false }
        }
        (@($r.Keys | Sort-Object) -join ',') | Should -Be 'Ok,Outcome'
        $r.Ok | Should -BeFalse
        $r.Outcome | Should -Be 'TechnicianReview'
    }
    It 'a malformed scanner report (missing Healthy) fails closed to Technician Review, never a throw' {
        $r = Invoke-UpdatePhase -Scanner { param($Context) return @{ PendingCount = 0 } }
        $r.Ok | Should -BeFalse
        $r.Outcome | Should -Be 'TechnicianReview'
    }
    It 'a required reboot mid-cycle records the reboot-pending shape and the resumed call continues from where it left' {
        $script:calls = 0
        $script:contexts = @()
        $scanner = {
            param($Context)
            $script:calls++
            $script:contexts += $Context
            if ($Context.RebootCompleted) {
                # The pass after the reboot: everything settled, nothing pending.
                return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $true }
            }
            return @{ PendingCount = 1; PendingUpdates = @(@{ Title = 'Cumulative update' }); RebootRequired = $true; Healthy = $true }
        }
        $r1 = Invoke-UpdatePhase -MaxCycles 3 -Scanner $scanner
        (@($r1.Keys | Sort-Object) -join ',') | Should -Be 'CyclesCompleted,Ok,RebootPending'
        $r1.Ok | Should -BeTrue
        $r1.RebootPending | Should -BeTrue
        # The restart completes the cycle: the return already counts it.
        $r1.CyclesCompleted | Should -Be 1
        $script:calls | Should -Be 1
        # Simulated restart: the caller resumes with the CyclesCompleted value
        # as -ResumeContext; the first resumed scan runs with RebootCompleted
        # = $true (the scripted "reboot then continue" key).
        $r2 = Invoke-UpdatePhase -MaxCycles 3 -ResumeContext $r1.CyclesCompleted -Scanner $scanner
        (@($r2.Keys | Sort-Object) -join ',') | Should -Be 'CyclesCompleted,Ok'
        $r2.Ok | Should -BeTrue
        $r2.CyclesCompleted | Should -Be 2
        $script:calls | Should -Be 2
        (@($script:contexts | ForEach-Object { $_.Cycle }) -join ',') | Should -Be '1,2'
        @($script:contexts)[0].RebootCompleted | Should -BeFalse
        @($script:contexts)[1].RebootCompleted | Should -BeTrue
    }
    It 'an unhealthy scanner result AFTER the reboot routes to Technician Review (Q88 unhealthy-after-reboot)' {
        $script:calls = 0
        $scanner = {
            param($Context)
            $script:calls++
            if ($Context.RebootCompleted) {
                return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $false }
            }
            return @{ PendingCount = 1; PendingUpdates = @(); RebootRequired = $true; Healthy = $true }
        }
        $r1 = Invoke-UpdatePhase -MaxCycles 3 -Scanner $scanner
        $r1.RebootPending | Should -BeTrue
        $r2 = Invoke-UpdatePhase -MaxCycles 3 -ResumeContext 1 -Scanner $scanner
        (@($r2.Keys | Sort-Object) -join ',') | Should -Be 'Ok,Outcome'
        $r2.Ok | Should -BeFalse
        $r2.Outcome | Should -Be 'TechnicianReview'
    }
    It 'resuming with the cycle budget already exhausted returns the acknowledgement shape without another scan' {
        $script:calls = 0
        $scanner = {
            param($Context)
            $script:calls++
            return @{ PendingCount = 1; PendingUpdates = @(); RebootRequired = $true; Healthy = $true }
        }
        $r1 = Invoke-UpdatePhase -MaxCycles 1 -Scanner $scanner
        $r1.RebootPending | Should -BeTrue
        $r1.CyclesCompleted | Should -Be 1
        $r2 = Invoke-UpdatePhase -MaxCycles 1 -ResumeContext 1 -Scanner $scanner
        (@($r2.Keys | Sort-Object) -join ',') | Should -Be 'CyclesCompleted,NeedsAcknowledgement,Ok,Warning'
        $r2.Ok | Should -BeTrue
        $r2.NeedsAcknowledgement | Should -BeTrue
        $r2.Warning | Should -Not -BeNullOrEmpty
        $r2.CyclesCompleted | Should -Be 1
        $script:calls | Should -Be 1
    }
    It 'the default Scanner delegates to the real engine pass and maps its report (healthy zero-pending -> complete)' {
        Mock Invoke-ScopedUpdatePass -ModuleName OSDeploy.Orchestrator {
            return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $true }
        }
        $r = Invoke-UpdatePhase
        $r.Ok | Should -BeTrue
        $r.CyclesCompleted | Should -Be 1
        Should -Invoke Invoke-ScopedUpdatePass -ModuleName OSDeploy.Orchestrator -Exactly 1 -Scope It -ParameterFilter {
            $Context.Cycle -eq 1 -and
            $Context.RebootCompleted -eq $false -and
            (@($Context.Scope.Include) -join ',') -eq 'Security,Quality,ServicingStack,DotNet,Defender'
        }
    }
    It 'the default Scanner routes an unhealthy real pass to Technician Review without throwing' {
        Mock Invoke-ScopedUpdatePass -ModuleName OSDeploy.Orchestrator {
            return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $false }
        }
        $r = Invoke-UpdatePhase
        $r.Ok | Should -BeFalse
        $r.Outcome | Should -Be 'TechnicianReview'
    }
    It 'throws on an invalid cycle configuration (MaxCycles below one, negative ResumeContext)' {
        { Invoke-UpdatePhase -MaxCycles 0 -Scanner { param($Context) } } | Should -Throw
        { Invoke-UpdatePhase -MaxCycles 2 -ResumeContext -1 -Scanner { param($Context) } } | Should -Throw
    }
}
