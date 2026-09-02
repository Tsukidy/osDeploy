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
