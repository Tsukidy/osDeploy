# OSDeploy component suite: FINAL FORM (Task 28 + Task 29).
#
# A PLAIN SCRIPT, not a Pester file: simple assertion helpers, one PASS/FAIL
# line per numbered check, a summary, and a nonzero exit code on failure.
#
# VM RUN PROCEDURE (outstanding: performed on the Windows VM, never from the
# Linux development host):
#   1. Copy this repository worktree onto the Windows VM.
#   2. Open an ELEVATED Windows PowerShell console (Run as Administrator) -
#      SYSTEM Scheduled Task registration requires elevation.
#   3. From the repository root run EXACTLY:
#          powershell -NoProfile -ExecutionPolicy Bypass -File tests/component/ComponentSuite.ps1
#      (backslash form: powershell -NoProfile -ExecutionPolicy Bypass -File tests\component\ComponentSuite.ps1)
#   4. Expected: every numbered check prints PASS, the last line is
#      'COMPONENT SUITE PASS: <n> checks', and the exit code is 0. The full
#      console output is captured to tests\component\last-run.log by the
#      transcript this suite starts AFTER the platform guard below, so a
#      Linux run never creates that file. last-run.log is the evidence
#      artifact for the change's verify record. Do not create it by hand.
#
# Windows PowerShell 5.1 runs STA by default, which the WPF checks require;
# check 7 asserts it explicitly (Assert-STA) and fails closed otherwise.
#
# Check groups:
#   1. Set-OrchestratorAcl: the ACL resolves to exactly SYSTEM and local
#      Administrators, inheritance disabled.
#   2. Register-OrchestratorTask: the task registers with the SYSTEM
#      ServiceAccount Highest principal, IgnoreNew multiple instances, a
#      startup (boot) trigger, and no sign-in requirement; the partition
#      registration marker is written.
#   3. Unregister-OrchestratorTask: removes the task and is safe to call
#      twice.
#   4. The orchestrator launch under the task acquires the single-instance
#      mutex (Enter-Orchestrator reports Ran = True from inside the task),
#      the task settles (its process exit releases the mutex) before the
#      in-process checks continue, and the Q35 abandoned-mutex recovery is
#      proven: a grandchild dies owning Global\OSDeploy.Orchestrator while
#      a probe holds the kernel object open, and the probe's
#      Enter-Orchestrator still acquires.
#   5. Invoke-DeploymentSequence FULL RUN against a fresh mock
#      OSDCloud Deployment Partition staged on the real filesystem:
#      contract-valid end state, scoped cleanup (marker, boot override,
#      runtime directory removed; recovery content retained), log
#      verification, and the scheduled task itself retired by cleanup.
#   6. Integrity record -> tamper detection -> local-only repair (Q90/Q92):
#      stage a record over a copy of the orchestrator source, flip a byte
#      and delete a file, Test-Integrity fails closed, Repair-FromLocalSource
#      from the partition repair source restores and revalidates, and a
#      missing repair source stops at Technician Review.
#   7. GUI: STA assertion, WPF assembly load, and every shipped XAML screen
#      rendered through the OSDeploy.Gui module's own loader path (Get-Screen)
#      into a real Window with its named elements resolvable, plus a wizard
#      walk over the real screen list.
#   8. Phase handoffs write contract-valid state: second instance (no
#      mutation), RebootPending checkpoint and its post-reboot resume,
#      Technician Review exhaustion through the REAL bcdedit-based boot
#      check (fail closed), and the post-completion cleanup-only restart.
#
# Boundaries honored by every check: no DeploymentShare or any server path
# is contacted, mapped, or named anywhere (Q91 - local paths only); no
# product key material is written or logged (Q18); scheduled-task mutations
# use SUITE-UNIQUE names only ('OSDeploy Orchestrator' stays reserved for
# real machines); teardown runs in finally blocks.
#
# Windows PowerShell 5.1 compatible: no ternary, no ?? / ??= / && / ||,
# pure ASCII. All paths resolve relative to THIS script, so the suite runs
# from any working directory.

# Skip guard. Rationale: on Windows PowerShell 5.1, $IsWindows is undefined
# (so -not $IsWindows is $true) but PSVersion.Major is 5, so the condition
# is FALSE and the suite RUNS; on pwsh 6+ Windows, $IsWindows is $true, so
# the suite RUNS; on pwsh 6+ Linux/macOS, both halves are true, so the
# suite prints 'SKIP: Windows only' and exits 0. This must stay the FIRST
# executable statement, before Set-StrictMode: on 5.1 a StrictMode session
# would reject the undefined $IsWindows reference. The last-run.log
# transcript starts AFTER this guard, so a Linux run never creates it.
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { Write-Output 'SKIP: Windows only'; return }

Set-StrictMode -Version Latest

# --- Assertion helpers (Pester-free PASS/FAIL accounting) -------------------
$script:checksPassed = 0
$script:checksFailed = 0
$script:failedChecks = @()

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$HintOnFail = '')
    if ($Condition) {
        $script:checksPassed++
        Write-Output ("PASS {0}: {1}" -f $script:checksPassed, $Name)
    }
    else {
        $script:checksFailed++
        $script:failedChecks += $Name
        Write-Output ("FAIL {0}: {1}" -f $script:checksFailed, $Name)
        if ($HintOnFail -ne '') {
            Write-Output ("      HINT: {0}" -f $HintOnFail)
        }
    }
}

# Internal: read one field from a hashtable (in-memory) or PSCustomObject
# (ConvertFrom-Json) record; $null when absent. StrictMode-safe.
function Get-SuiteJsonField {
    param($Record, [string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# --- Module and fixture wiring (paths relative to this script) --------------
$script:modulePath = Join-Path $PSScriptRoot '..\..\src\Orchestrator\OSDeploy.Orchestrator.psd1'
$script:guiModulePath = Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Gui\OSDeploy.Gui.psd1'
$script:loggingModulePath = Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Logging\OSDeploy.Logging.psd1'
# The mock builder also imports OSDeploy.State/Util/Config, so Read-JsonFile
# and Test-DeploymentState are available below for state verification.
. (Join-Path $PSScriptRoot '..\mocks\New-MockPartition.ps1')
Import-Module $script:modulePath -Force
# The Gui module imports cleanly on any host (it loads no WPF assemblies at
# import time); the WPF assemblies themselves load inside check 7.
Import-Module $script:guiModulePath -Force
# Logging is imported for THIS session: the orchestrator module's internal
# import does not leak to its caller, and the suite itself stages and
# verifies run logs (New-RunLog / Add-LogEvent / Complete-RunLog).
Import-Module $script:loggingModulePath -Force

# --- Run transcript: the VM-run evidence file -------------------------------
# Started here (after the platform guard) so Linux runs NEVER create it.
$script:transcriptStarted = $false
$script:exitCode = 1
try {
    Start-Transcript -Path (Join-Path $PSScriptRoot 'last-run.log') -Force | Out-Null
    $script:transcriptStarted = $true
}
catch {
    Write-Output ("FAIL: could not start the last-run.log transcript in '{0}': {1}" -f $PSScriptRoot, $_.Exception.Message)
    exit 1
}

try {
    # --- Elevation gate: SYSTEM task registration needs an elevated session -
    $windowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output 'FAIL 0.1: this component suite must run ELEVATED (Administrator); SYSTEM Scheduled Task registration requires it.'
        exit 1
    }

    # Suite-unique task names: the registration code path is identical to the
    # default-named one, but clobbering a machine's real orchestrator task
    # ('OSDeploy Orchestrator') from a test would be unacceptable.
    $script:taskName = 'OSDeploy Orchestrator ComponentSuite'
    $script:probeTaskName = 'OSDeploy Orchestrator ComponentSuite Probe'
    $script:seqTaskName = 'OSDeploy Orchestrator ComponentSuite Seq'

    # Workspace under the system drive root (created elevated) so the SYSTEM
    # context running the probe task can certainly read it; user-profile temp
    # paths can be hardened against SYSTEM. Fall back to the temp path when
    # the drive root is not writable.
    $script:workspace = $null
    try {
        $script:workspace = (New-Item -ItemType Directory -Path (Join-Path $env:SystemDrive ('OSDeploy-ComponentSuite-' + [guid]::NewGuid().ToString('N'))) -ErrorAction Stop).FullName
    }
    catch {
        $script:workspace = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('OSDeploy-ComponentSuite-' + [guid]::NewGuid().ToString('N')))).FullName
    }

    try {
        # --- Check 1: Set-OrchestratorAcl restricts to exactly SYSTEM and
        #     local Administrators with inheritance disabled ----------------
        try {
            Write-Output ''
            Write-Output 'Check 1: Set-OrchestratorAcl NTFS restriction'
            $aclDir = (New-Item -ItemType Directory -Path (Join-Path $script:workspace 'AclTarget')).FullName
            $aclResult = Set-OrchestratorAcl -Directory $aclDir
            Assert-True ([bool]$aclResult.Ok) '1.1 Set-OrchestratorAcl returns Ok = True'
            $storedAcl = Get-Acl -LiteralPath $aclDir
            Assert-True ($storedAcl.AreAccessRulesProtected) '1.2 inheritance is disabled on the directory (AreAccessRulesProtected)'
            $storedEntries = @($storedAcl.Access)
            Assert-True ($storedEntries.Count -eq 2) ('1.3 exactly two access rules exist (found {0})' -f $storedEntries.Count)
            $storedSids = @()
            foreach ($entry in $storedEntries) {
                $identity = $entry.IdentityReference
                if ($identity -is [System.Security.Principal.SecurityIdentifier]) {
                    $storedSids += $identity.Value
                }
                else {
                    $storedSids += [string]$identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
                }
            }
            Assert-True ($storedSids -contains 'S-1-5-18') '1.4a the ACL carries NT AUTHORITY\SYSTEM (S-1-5-18)'
            Assert-True ($storedSids -contains 'S-1-5-32-544') '1.4b the ACL carries BUILTIN\Administrators (S-1-5-32-544)'
            $allAllowFull = $true
            foreach ($entry in $storedEntries) {
                if ($entry.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { $allAllowFull = $false }
                if (($entry.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl) { $allAllowFull = $false }
            }
            Assert-True ($allAllowFull) '1.5 every rule is an Allow FullControl rule'
        }
        catch {
            Assert-True $false ('1.ABORT the ACL check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 2: Register-OrchestratorTask registers the SYSTEM startup
        #     task exactly per the contract and writes the marker -----------
        try {
            Write-Output ''
            Write-Output 'Check 2: Register-OrchestratorTask SYSTEM startup registration'
            $partition = New-MockPartition -Path (Join-Path $script:workspace 'Partition')
            $regResult = Register-OrchestratorTask -PartitionRoot $partition -TaskName $script:taskName
            Assert-True ([bool]$regResult.Ok) '2.1 Register-OrchestratorTask returns Ok = True'
            $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
            Assert-True ($null -ne $task) '2.2 Get-ScheduledTask finds the registered task' -HintOnFail 'Get-ScheduledTask -TaskName without -TaskPath matches the name in ANY task folder; a same-named task in another folder can satisfy or confuse this lookup.'
            $principalId = [string]$task.Principal.UserId
            Assert-True ($principalId -ieq 'SYSTEM' -or $principalId -ieq 'NT AUTHORITY\SYSTEM') ('2.3 the principal is SYSTEM (found {0})' -f $principalId)
            Assert-True ([string]$task.Principal.LogonType -ieq 'ServiceAccount') ('2.4 the logon type is ServiceAccount: no sign-in required, no stored password (found {0})' -f [string]$task.Principal.LogonType)
            Assert-True ([string]$task.Principal.RunLevel -ieq 'Highest') ('2.5 the run level is Highest (found {0})' -f [string]$task.Principal.RunLevel)
            Assert-True ([string]$task.Settings.MultipleInstances -ieq 'IgnoreNew') ('2.6 the multiple-instance policy is IgnoreNew (found {0})' -f [string]$task.Settings.MultipleInstances)
            $bootTriggers = @($task.Triggers | Where-Object { [string]$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
            Assert-True ($bootTriggers.Count -ge 1) '2.7 a startup (boot) trigger is present'
            $markerPath = Join-Path $partition 'State\TaskRegistration.json'
            $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
            Assert-True ($markerExists) '2.8a the registration marker TaskRegistration.json is written'
            if ($markerExists) {
                $marker = Read-JsonFile -Path $markerPath
                Assert-True ([string](Get-SuiteJsonField -Record $marker -Name 'TaskName') -ieq $script:taskName) '2.8b the marker TaskName matches'
                Assert-True (-not [string]::IsNullOrEmpty([string](Get-SuiteJsonField -Record $marker -Name 'RegisteredUtc'))) '2.8c the marker RegisteredUtc is present'
            }
            else {
                Assert-True $false '2.8b the marker TaskName matches (marker missing; check 2.8a failed)'
                Assert-True $false '2.8c the marker RegisteredUtc is present (marker missing; check 2.8a failed)'
            }
        }
        catch {
            Assert-True $false ('2.ABORT the task registration check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 3: Unregister-OrchestratorTask removes the task and is
        #     safe to call twice ---------------------------------------------
        try {
            Write-Output ''
            Write-Output 'Check 3: Unregister-OrchestratorTask idempotent removal'
            $unregisterOne = Unregister-OrchestratorTask -TaskName $script:taskName
            Assert-True ([bool]$unregisterOne.Ok -and [bool]$unregisterOne.Existed) '3.1 the first Unregister call reports Ok = True with Existed = True'
            $goneTask = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
            Assert-True ($null -eq $goneTask) '3.2 Get-ScheduledTask no longer finds the task' -HintOnFail 'Get-ScheduledTask -TaskName without -TaskPath matches the name in ANY task folder; a same-named task in another folder can satisfy or confuse this lookup.'
            $unregisterTwo = Unregister-OrchestratorTask -TaskName $script:taskName
            Assert-True ([bool]$unregisterTwo.Ok -and -not [bool]$unregisterTwo.Existed) '3.3 the second Unregister call is a successful no-op (safe to call twice)'
            Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) '3.4 the registration marker is untouched by Unregister (Invoke-Cleanup owns marker removal)'
        }
        catch {
            Assert-True $false ('3.ABORT the task unregistration check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 4: the orchestrator launch under the task acquires the
        #     single-instance mutex, then the task settles -------------------
        try {
            Write-Output ''
            Write-Output 'Check 4: orchestrator launch under the task acquires the mutex'
            $probePath = Join-Path $script:workspace 'Enter-Orchestrator-Probe.ps1'
            $outcomePath = Join-Path $script:workspace 'mutex-outcome.txt'
            $probeScript = @'
param(
    [string]$ModulePath,
    [string]$PartitionRoot,
    [string]$OutcomePath
)
Import-Module $ModulePath -Force
$entry = Enter-Orchestrator -PartitionRoot $PartitionRoot
[System.IO.File]::WriteAllText($OutcomePath, 'Ran=' + ([string]$entry.Ran))
# Release through the module copy BEFORE exiting: deterministic teardown.
# This probe must die holding nothing, and an unreleased exit must never be
# relied on - whether the kernel marks the mutex abandoned or destroys the
# object at owner death depends on whether any other handle survives (the
# 4.6/4.7 keeper-handle mechanics), so proper release is what makes the
# outcome deterministic.
$m = Get-OrchestratorMutex
if ($null -ne $m) {
    try { $null = $m.ReleaseMutex() } catch { }
    try { $m.Dispose() } catch { }
}
'@
            [System.IO.File]::WriteAllText($probePath, $probeScript, [System.Text.Encoding]::ASCII)
            $probeArgument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}"' -f $probePath, $script:modulePath, $partition, $outcomePath
            $probeReg = Register-OrchestratorTask -PartitionRoot $partition -TaskName $script:probeTaskName -Execute 'powershell.exe' -Argument $probeArgument
            Assert-True ([bool]$probeReg.Ok) '4.1 the probe task registers Ok = True'
            Start-ScheduledTask -TaskName $script:probeTaskName
            $deadline = (Get-Date).AddSeconds(120)
            while (-not (Test-Path -LiteralPath $outcomePath) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
            }
            Assert-True (Test-Path -LiteralPath $outcomePath) '4.2 the task launched and the probe completed within the timeout' -HintOnFail 'Get-ScheduledTask -TaskName without -TaskPath matches the name in ANY task folder; a same-named task in another folder can satisfy or confuse this lookup.'
            if (Test-Path -LiteralPath $outcomePath) {
                $outcomeText = ([System.IO.File]::ReadAllText($outcomePath)).Trim()
                Assert-True ($outcomeText -eq 'Ran=True') ('4.3 Enter-Orchestrator under the task acquired the single-instance mutex (outcome: {0})' -f $outcomeText)
            }
            else {
                Assert-True $false '4.3 Enter-Orchestrator under the task acquired the single-instance mutex (probe never completed; check 4.2 failed)'
            }
            # The probe's process exit releases the Global mutex; the task
            # leaving the Running state proves that happened BEFORE the
            # in-process checks (5+) try to acquire it themselves.
            $settleDeadline = (Get-Date).AddSeconds(60)
            $probeSettled = $false
            while ((Get-Date) -lt $settleDeadline) {
                $probeTask = Get-ScheduledTask -TaskName $script:probeTaskName -ErrorAction SilentlyContinue
                if ($null -eq $probeTask -or ([string]$probeTask.State -ine 'Running' -and [string]$probeTask.State -ine 'Queued')) {
                    $probeSettled = $true
                    break
                }
                Start-Sleep -Seconds 1
            }
            Start-Sleep -Seconds 2
            Assert-True $probeSettled '4.4 the probe task left the Running state (its process exit released the single-instance mutex before the in-process checks)'
            $probeUnregister = Unregister-OrchestratorTask -TaskName $script:probeTaskName
            Assert-True ([bool]$probeUnregister.Ok) '4.5 the probe task is retired'

            # 4.6/4.7: the Q35 abandoned-mutex recovery. True abandonment
            # needs a THIRD-PARTY handle alive while the owner dies (with no
            # other handle the kernel destroys the object and nothing is
            # abandoned), so the mechanics are: the probe process opens the
            # named mutex WITHOUT owning it (the keeper handle), spawns a
            # grandchild that acquires through Enter-Orchestrator and exits
            # immediately without releasing (the owner dies), and then calls
            # Enter-Orchestrator itself - which must acquire despite the
            # abandonment. Everything runs in suite-unique workspace paths.
            Write-Output 'NOTE 4.6 this check proves the Q35 abandoned-mutex recovery: a grandchild acquires Global\OSDeploy.Orchestrator and dies without releasing while a probe holds the kernel object open (true abandonment); the probe Enter-Orchestrator must still acquire.'
            $abandonGrandchildPath = Join-Path $script:workspace 'Enter-Orchestrator-Abandon.ps1'
            $abandonProbePath = Join-Path $script:workspace 'Abandonment-Probe.ps1'
            $abandonGrandchildOutcome = Join-Path $script:workspace 'abandon-grandchild-outcome.txt'
            $abandonProbeOutcome = Join-Path $script:workspace 'abandon-probe-outcome.txt'
            $abandonGrandchildScript = @'
param(
    [string]$ModulePath,
    [string]$PartitionRoot,
    [string]$OutcomePath
)
Import-Module $ModulePath -Force
$entry = Enter-Orchestrator -PartitionRoot $PartitionRoot
[System.IO.File]::WriteAllText($OutcomePath, 'Ran=' + ([string]$entry.Ran), [System.Text.Encoding]::ASCII)
# Deliberately exit WITHOUT releasing: this process dies owning
# Global\OSDeploy.Orchestrator, abandoning it (the Q35 power-loss shape).
exit 0
'@
            $abandonProbeScript = @'
param(
    [string]$ModulePath,
    [string]$PartitionRoot,
    [string]$GrandchildPath,
    [string]$GrandchildOutcomePath,
    [string]$OutcomePath
)
Import-Module $ModulePath -Force
try {
    # Keeper handle: opens the named mutex WITHOUT owning it, so the kernel
    # object survives the grandchild's death and is marked abandoned.
    $keeper = New-Object System.Threading.Mutex($false, 'Global\OSDeploy.Orchestrator')
    $null = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}"' -f $GrandchildPath, $ModulePath, $PartitionRoot, $GrandchildOutcomePath) -Wait -PassThru
    if (-not (Test-Path -LiteralPath $GrandchildOutcomePath)) {
        [System.IO.File]::WriteAllText($OutcomePath, 'ProbeRan=False:GrandchildNoOutcome', [System.Text.Encoding]::ASCII)
        exit 1
    }
    $grandchildText = ([System.IO.File]::ReadAllText($GrandchildOutcomePath)).Trim()
    if ($grandchildText -ne 'Ran=True') {
        [System.IO.File]::WriteAllText($OutcomePath, ('ProbeRan=False:Grandchild=' + $grandchildText), [System.Text.Encoding]::ASCII)
        exit 1
    }
    # Abandonment is now in force: the owner died holding the mutex while
    # this probe keeps the object open. Enter-Orchestrator must acquire.
    $result = 'ProbeRan=False'
    try {
        $entry = Enter-Orchestrator -PartitionRoot $PartitionRoot
        $result = 'ProbeRan=' + ([string]$entry.Ran)
    }
    catch {
        $result = 'ProbeRan=Threw:' + $_.Exception.GetType().Name
    }
    # Release cleanly whatever happened, then drop the keeper handle.
    $m = Get-OrchestratorMutex
    if ($null -ne $m) {
        try { $null = $m.ReleaseMutex() } catch { }
        try { $m.Dispose() } catch { }
    }
    try { $keeper.Dispose() } catch { }
    [System.IO.File]::WriteAllText($OutcomePath, $result, [System.Text.Encoding]::ASCII)
    if ($result -eq 'ProbeRan=True') { exit 0 }
    exit 1
}
catch {
    [System.IO.File]::WriteAllText($OutcomePath, ('ProbeRan=Error:' + $_.Exception.Message), [System.Text.Encoding]::ASCII)
    exit 1
}
'@
            [System.IO.File]::WriteAllText($abandonGrandchildPath, $abandonGrandchildScript, [System.Text.Encoding]::ASCII)
            [System.IO.File]::WriteAllText($abandonProbePath, $abandonProbeScript, [System.Text.Encoding]::ASCII)
            $abandonArgument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}" "{4}" "{5}"' -f $abandonProbePath, $script:modulePath, $partition, $abandonGrandchildPath, $abandonGrandchildOutcome, $abandonProbeOutcome
            $abandonProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $abandonArgument -Wait -PassThru
            $abandonGrandchildText = ''
            if (Test-Path -LiteralPath $abandonGrandchildOutcome) {
                $abandonGrandchildText = ([System.IO.File]::ReadAllText($abandonGrandchildOutcome)).Trim()
            }
            Assert-True ($abandonGrandchildText -eq 'Ran=True') ('4.6 the grandchild acquired Global\OSDeploy.Orchestrator through Enter-Orchestrator and died holding it (outcome: {0})' -f $abandonGrandchildText)
            $abandonProbeText = ''
            if (Test-Path -LiteralPath $abandonProbeOutcome) {
                $abandonProbeText = ([System.IO.File]::ReadAllText($abandonProbeOutcome)).Trim()
            }
            Assert-True ($abandonProc.ExitCode -eq 0 -and $abandonProbeText -eq 'ProbeRan=True') ('4.7 Enter-Orchestrator recovered from the abandoned mutex and acquired it (probe exit {0}, outcome: {1})' -f $abandonProc.ExitCode, $abandonProbeText)
        }
        catch {
            Assert-True $false ('4.ABORT the mutex-under-task check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Shared determinism table for the sequence-driving checks --------
        # $script:suitePartition is read by the runner scriptblocks AT
        # INVOCATION TIME; set it before each Invoke-DeploymentSequence call.
        $script:suitePartition = ''
        # The exact nine-phase completion sequence every completion assert
        # compares against (PHASE_ORDER).
        $expectedPhases = 'Drivers,Applications,WorkflowSpecifics,WindowsUpdate,Activation,FinalValidation,BootEntryRegistration,LogFinalization,Cleanup'
        # The partition of the RebootPending/resume scenario, kept for the
        # post-completion-restart scenario at the end of Check 8.
        $handoffPartitionPath = ''
        function New-SuiteRunnerTable {
            # Deterministic runners for the host-coupled phases. Each runs the
            # REAL phase engine and stubs only the genuinely host-coupled
            # innermost execution, so the component run still exercises real
            # discovery, manifest loading/validation, the update cycle engine,
            # the PnP validator, and the real BootEntryRegistration wrapper
            # (including BootOverride marker clearing) on the real filesystem.
            # Every use of this table is announced in a NOTE output line.
            param([string[]]$SkipPhases = @())
            $table = @{}
            $table['Drivers'] = {
                # Real pattern discovery over the staged Sources\Drivers tree;
                # the stubbed executor stands in for the real silent installer
                # run (the staged payloads are dummy files, not installers).
                $stubExecutor = { param($Plan) return $true }
                $r = Invoke-DriverPhase -Root (Join-Path $script:suitePartition 'Sources\Drivers') -Runner $stubExecutor
                if (-not $r.Ok) { return $false }
                if (@($r.Plans).Count -lt 1) { return $false }
                return $true
            }
            $table['Applications'] = {
                # Real manifest load + contract validation + retry engine; the
                # stubbed executor stands in for the real installer process
                # (the staged manifest points at a payload that does not exist).
                $state = Read-JsonFile -Path (Join-Path $script:suitePartition 'State\DeploymentState.json')
                $workflow = [string](Get-SuiteJsonField -Record $state -Name 'Workflow')
                $manifest = Join-Path (Join-Path $script:suitePartition ('Sources\Apps\' + $workflow)) 'manifest.json'
                $stubExecutor = { param($Context) return $true }
                $r = Invoke-ApplicationPhase -ManifestPath $manifest -Runner $stubExecutor
                if (-not $r.Ok) { return $false }
                return $true
            }
            $table['WindowsUpdate'] = {
                # Real cycle engine; the scanner reports one clean pass instead
                # of running the real WUA COM scan/install (host- and
                # network-dependent, and a RebootRequired report would divert
                # the success-path scenario).
                $scanner = { param($Context) return @{ PendingCount = 0; PendingUpdates = @(); RebootRequired = $false; Healthy = $true } }
                $r = Invoke-UpdatePhase -MaxCycles 1 -Scanner $scanner
                if (-not $r.Ok) { return $false }
                return $true
            }
            $table['FinalValidation'] = {
                # Real validator over an empty rescan: a real Get-PnpDevice
                # pass includes phantom devices with Status Unknown, which
                # would make the success-path check host-dependent.
                $r = Invoke-PnpValidation -Devices @()
                if (-not $r.Ok) { return $false }
                return $true
            }
            $table['BootEntryRegistration'] = {
                # Real wrapper (Blocked computation + BootOverride marker
                # clearing); the BootTool report is a contract-valid stub
                # because the VM has no registered OSDeploy Factory Recovery
                # boot entry and the suite never mutates the BCD store.
                $report = @{ EntryPresent = $true; TimeoutSeconds = 5; WindowsDefault = $true; PartitionIdentityOk = $true; BootFilesOk = $true }
                $tool = { param($Context) return $report }
                $r = Invoke-BootEntryRegistration -PartitionRoot $script:suitePartition -BootTool $tool
                if ($r.Blocked) { return $false }
                return $true
            }
            foreach ($skip in @($SkipPhases)) {
                if ($table.Contains($skip)) {
                    $null = $table.Remove($skip)
                }
            }
            return $table
        }

        function Reset-OrchestratorForNextEntry {
            # The same file-only-state reset the unit suite uses: release any
            # mutex this process still holds THROUGH THE CURRENT MODULE COPY
            # first (a bare re-import would orphan the named mutex), then
            # re-import so the module's process-level entry state is fresh.
            $m = Get-OrchestratorMutex
            if ($null -ne $m) {
                try { $null = $m.ReleaseMutex() } catch { }
                try { $m.Dispose() } catch { }
            }
            Import-Module $script:modulePath -Force
        }

        # --- Check 5: the full orchestrator sequence against a fresh mock
        #     partition on the real filesystem -------------------------------
        try {
            Write-Output ''
            Write-Output 'Check 5: Invoke-DeploymentSequence full run against a fresh mock partition'
            Write-Output 'NOTE 5.0 PhaseRunners injections for determinism on this VM: Drivers and Applications (real engines, stubbed host executors), WindowsUpdate (real cycle engine, clean-report scanner), FinalValidation (real validator, empty rescan), BootEntryRegistration (real wrapper incl. BootOverride clearing, contract-valid BootTool report). Real default bodies ran for WorkflowSpecifics (EZT recorder), Activation, LogFinalization, Cleanup, and Complete-Deployment, and the REAL entry gates ran: config-provenance event and the Q90 integrity recheck over the staged orchestrator home (RebootPending is clear at first entry, so the identity gate is not in play here).'
            $script:suitePartition = New-MockPartition -Path (Join-Path $script:workspace 'SequencePartition')
            # Host-wrapper role: the scheduled-task host creates the run
            # folder at launch; the sequence deliberately does not.
            $runLog = New-RunLog -Root (Join-Path $script:suitePartition 'Logs') -RunType 'InitialDeployment'
            Add-LogEvent -Log $runLog -Event 'ComponentSuiteSequenceStart'
            # Completion footprint, staged for real: the task registration
            # writes the real marker (suite-unique task name), the runtime
            # artifacts directory and the one-time boot override are staged.
            $seqReg = Register-OrchestratorTask -PartitionRoot $script:suitePartition -TaskName $script:seqTaskName
            # OrchestratorRuntime is no longer staged with foreign cache
            # files: it is the Q90 integrity-protected orchestrator home
            # (New-MockPartition stages the exact copy and its record), and
            # an extra file would be repaired away at the entry gate. The
            # runtime directory itself plus the one-time boot override are
            # the rest of the completion footprint.
            $runtimeDir = Join-Path $script:suitePartition 'OrchestratorRuntime'
            Write-AtomicJson -Path (Join-Path $script:suitePartition 'State\BootOverride.json') -Value @{
                Source  = 'PXE bootstrap'
                OneTime = $true
            }
            Assert-True ([bool]$seqReg.Ok) '5.0a the real task registration (suite-unique name) returns Ok before the sequence runs'
            Assert-True ((Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\TaskRegistration.json')) -and (Test-Path -LiteralPath $runtimeDir) -and (Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\BootOverride.json'))) '5.0b the completion footprint (marker, runtime directory, boot override) is staged before the sequence runs'
            $seqStatePath = Join-Path $script:suitePartition 'State\DeploymentState.json'
            # Pre-flight diagnostic (first Windows run stopped at the entry
            # integrity gate): probe the fixture's record DIRECTLY so the log
            # names the failing comparison (Missing/Changed/Extra/BundleHash/
            # InvalidRecord) and shows the path forms both sides use.
            $diagRecord = Read-JsonFile -Path (Join-Path $script:suitePartition 'State\IntegrityRecord.json')
            $diagCheck = Test-Integrity -Directory $runtimeDir -Record $diagRecord
            $diagFresh = New-FileInventory -Path $runtimeDir
            $diagRecordPath = [string](Get-SuiteJsonField -Record @(Get-SuiteJsonField -Record $diagRecord -Name 'FileHashes')[0] -Name 'Path')
            $diagFreshPath = [string](Get-SuiteJsonField -Record @($diagFresh)[0] -Name 'Path')
            Write-Output ('DIAG 5.0c fixture Test-Integrity: Ok=' + [string]$diagCheck.Ok + ' Mismatches=' + ((@($diagCheck.Mismatches) | ForEach-Object { '{0}:{1}' -f [string](Get-SuiteJsonField -Record $_ -Name 'Path'), [string](Get-SuiteJsonField -Record $_ -Name 'Reason') }) -join ' | '))
            Write-Output ('DIAG 5.0d path forms - record: [' + $diagRecordPath + ']  fresh: [' + $diagFreshPath + ']')
            Write-Output ('DIAG 5.0e raw IntegrityRecord.json: ' + ([System.IO.File]::ReadAllText((Join-Path $script:suitePartition 'State\IntegrityRecord.json'))))
            Write-Output ('DIAG 5.0f in-suite serialization of the same fresh inventory: ' + (ConvertTo-Json -InputObject @{ FileHashes = $diagFresh; BundleHash = 'X' } -Depth 8))
            $seqResult = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition -PhaseRunners (New-SuiteRunnerTable)
            Assert-True ($seqResult.Outcome -eq 'Completed' -and [bool]$seqResult.Completed -and [string]$seqResult.Result -eq 'Completed') ('5.1 the sequence completes: Outcome Completed, Completed True, Result Completed (found Outcome {0}, Completed {1}, Result {2}, Reason {3})' -f [string]$seqResult.Outcome, [string]$seqResult.Completed, [string]$seqResult.Result, [string]$seqResult.Reason)
            $seqStateRaw = [System.IO.File]::ReadAllText($seqStatePath)
            $seqValidation = Test-DeploymentState -Record (Read-JsonFile -Path $seqStatePath)
            Assert-True ([bool]$seqValidation.Valid) ('5.2 the completed DeploymentState.json passes Test-DeploymentState (errors: {0})' -f (($seqValidation.Errors) -join '; '))
            Assert-True ($seqStateRaw -match '"CompletedUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"') '5.3a CompletedUtc is recorded as an ISO 8601 UTC string'
            Assert-True ($seqStateRaw -notmatch 'BlockedBy') '5.3b no stale BlockedBy record remains on the completed document'
            $resumePoint = Get-ResumePoint -Path $seqStatePath
            Assert-True ((@($resumePoint.CompletedPhases) -join ',') -eq $expectedPhases) ('5.4 CompletedPhases records the full nine-phase sequence in order (found {0})' -f (@($resumePoint.CompletedPhases) -join ','))
            Assert-True (-not [bool]$resumePoint.RebootPending) '5.5 RebootPending is clear on the completed checkpoint'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\TaskRegistration.json'))) '5.6a scoped cleanup removed the TaskRegistration.json marker'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\BootOverride.json'))) '5.6b boot-entry registration success cleared the one-time BootOverride.json marker'
            Assert-True (-not (Test-Path -LiteralPath $runtimeDir)) '5.6c scoped cleanup removed the OrchestratorRuntime directory'
            $missingRetained = @()
            foreach ($retained in @(
                'Sources\Orchestrator\Part1.psm1',
                'Sources\Orchestrator\Part2.psm1',
                'Sources\Apps\EZT\manifest.json',
                'Sources\Apps\MMC\manifest.json',
                'Sources\Drivers\Asus\PRIME\Chipset\AsusSetup.exe',
                'Sources\Drivers\Gigabyte\B650\LAN\installer.exe',
                'Sources\Config\effective-config.json',
                'State\FactoryProfile.json',
                'State\FactoryProfile.lastknowngood.json',
                'State\ReadinessRecord.json',
                'ImageCache')) {
                if (-not (Test-Path -LiteralPath (Join-Path $script:suitePartition $retained))) { $missingRetained += $retained }
            }
            Assert-True ($missingRetained.Count -eq 0) ('5.7 recovery content is retained through cleanup (missing: {0})' -f ($missingRetained -join ', '))
            Assert-True ((Test-Path -LiteralPath $runLog.EventsPath) -and [bool](Complete-RunLog -Log $runLog)) '5.8 the verified run log survives cleanup and still re-parses as valid JSONL'
            $seqTaskAfter = Get-ScheduledTask -TaskName $script:seqTaskName -ErrorAction SilentlyContinue
            Assert-True ($null -eq $seqTaskAfter) '5.9 cleanup retired the SCHEDULED TASK ITSELF as well as the marker (Q89: cleanup removes the task; Invoke-Cleanup unregisters by the marker task name)' -HintOnFail 'Get-ScheduledTask -TaskName without -TaskPath matches the name in ANY task folder; a same-named task in another folder can satisfy or confuse this lookup.'
            Assert-True (([System.IO.File]::ReadAllText($runLog.EventsPath)) -match 'ConfigProvenance' -and ([System.IO.File]::ReadAllText($runLog.EventsPath)) -match 'IntegrityValidated') '5.10 the entry gates logged the config provenance and integrity validation events into the run own log (Q84/Q90)'
        }
        catch {
            Assert-True $false ('5.ABORT the full-sequence check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 6: integrity record, tamper detection, local-only repair --
        try {
            Write-Output ''
            Write-Output 'Check 6: integrity record, tamper detection, local-only repair (Q90/Q92)'
            $integrityPartition = New-MockPartition -Path (Join-Path $script:workspace 'IntegrityPartition')
            $integritySource = Join-Path $integrityPartition 'Sources\Orchestrator'
            $integrityTarget = Join-Path $script:workspace 'IntegrityTarget'
            $null = New-Item -ItemType Directory -Path $integrityTarget -Force
            Copy-Item -Path (Join-Path $integritySource '*') -Destination $integrityTarget -Force
            $recordPath = Join-Path $integrityPartition 'State\IntegrityRecord.json'
            $record = New-IntegrityRecord -Directory $integrityTarget -RecordPath $recordPath
            Assert-True ($null -ne $record -and @($record.FileHashes).Count -eq 2 -and (Test-Path -LiteralPath $recordPath -PathType Leaf)) '6.1 New-IntegrityRecord inventories both staged orchestrator files and writes the record'
            Assert-True ([bool](Test-Integrity -Directory $integrityTarget -Record $record).Ok) '6.2 Test-Integrity passes against the in-memory record'
            $recordFromFile = Read-JsonFile -Path $recordPath
            Assert-True ([bool](Test-Integrity -Directory $integrityTarget -Record $recordFromFile).Ok) '6.3 Test-Integrity passes against the record read back from IntegrityRecord.json (the post-restart shape)'
            $part1Path = Join-Path $integrityTarget 'Part1.psm1'
            $part2Path = Join-Path $integrityTarget 'Part2.psm1'
            $tamperBytes = [System.IO.File]::ReadAllBytes($part1Path)
            if ($tamperBytes[0] -eq 35) { $tamperBytes[0] = 36 } else { $tamperBytes[0] = 35 }
            [System.IO.File]::WriteAllBytes($part1Path, $tamperBytes)
            $tampered = Test-Integrity -Directory $integrityTarget -Record $recordFromFile
            $changedEntry = @($tampered.Mismatches | Where-Object { (Get-SuiteJsonField -Record $_ -Name 'Path') -eq 'Part1.psm1' -and (Get-SuiteJsonField -Record $_ -Name 'Reason') -eq 'Changed' })
            Assert-True ((-not [bool]$tampered.Ok) -and $changedEntry.Count -ge 1) '6.4 a flipped byte in Part1.psm1 fails the recheck with a Changed mismatch'
            Remove-Item -LiteralPath $part2Path -Force
            $deleted = Test-Integrity -Directory $integrityTarget -Record $recordFromFile
            $missingEntry = @($deleted.Mismatches | Where-Object { (Get-SuiteJsonField -Record $_ -Name 'Path') -eq 'Part2.psm1' -and (Get-SuiteJsonField -Record $_ -Name 'Reason') -eq 'Missing' })
            Assert-True ((-not [bool]$deleted.Ok) -and $missingEntry.Count -ge 1) '6.5 a deleted Part2.psm1 fails the recheck with a Missing mismatch'
            $repair = Repair-FromLocalSource -Directory $integrityTarget -RepairSource $integritySource -Record $recordFromFile
            Assert-True ([bool]$repair.Repaired) '6.6 Repair-FromLocalSource recopies from the LOCAL partition repair source and reports Repaired = True'
            Assert-True ([bool](Test-Integrity -Directory $integrityTarget -Record $recordFromFile).Ok) '6.7 the repaired directory revalidates against the SAME record'
            $tamperBytes2 = [System.IO.File]::ReadAllBytes($part1Path)
            if ($tamperBytes2[0] -eq 35) { $tamperBytes2[0] = 36 } else { $tamperBytes2[0] = 35 }
            [System.IO.File]::WriteAllBytes($part1Path, $tamperBytes2)
            $tamperedHashBefore = (Get-FileHash -LiteralPath $part1Path -Algorithm SHA256).Hash
            $failedRepair = Repair-FromLocalSource -Directory $integrityTarget -RepairSource (Join-Path $script:workspace 'NoSuchRepairSource') -Record $recordFromFile
            $tamperedHashAfter = (Get-FileHash -LiteralPath $part1Path -Algorithm SHA256).Hash
            Assert-True ((-not [bool]$failedRepair.Repaired) -and [string](Get-SuiteJsonField -Record $failedRepair -Name 'Outcome') -eq 'TechnicianReview' -and $tamperedHashAfter -eq $tamperedHashBefore) '6.8 a missing repair source stops at the blocking Technician Review (no Ignore/Continue path) and leaves the directory untouched (tampered file hash unchanged)'
            Assert-True (-not [bool](Test-Integrity -Directory $integrityTarget -Record $recordFromFile).Ok) '6.9 the still-tampered directory continues to fail the recheck after the refused repair'
        }
        catch {
            Assert-True $false ('6.ABORT the integrity check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 7: GUI screens render in an STA runspace ------------------
        try {
            Write-Output ''
            Write-Output 'Check 7: GUI screens render in an STA runspace (OSDeploy.Gui)'
            $staOk = $false
            $staError = ''
            try { Assert-STA; $staOk = $true }
            catch { $staError = $_.Exception.Message }
            Assert-True $staOk ('7.1 the host thread is STA (Assert-STA passes before any WPF type is touched): ' + $staError)
            $assembliesOk = $false
            $assemblyError = ''
            try {
                Add-Type -AssemblyName PresentationFramework
                $assembliesOk = $true
            }
            catch { $assemblyError = $_.Exception.Message }
            Assert-True $assembliesOk ('7.2 the WPF assemblies load on this Windows host: ' + $assemblyError)
            $guiScreens = @(
                @{ Name = 'AcknowledgeContinue'; Title = 'Acknowledge and Continue'; Elements = @('AcknowledgeCheckBox', 'ContinueButton') }
                @{ Name = 'NotedIssuesSummary'; Title = 'Noted Issues Summary'; Elements = @('IssuesList', 'FinishDeploymentButton') }
                @{ Name = 'TechnicianReview'; Title = 'Technician Review'; Elements = @('FindingsList', 'RescanDevicesButton', 'ContinueButton') }
            )
            $screenIndex = 3
            foreach ($screen in $guiScreens) {
                $screenName = $screen.Name
                $content = ''
                $loadOk = $false
                $loadError = ''
                try {
                    # The Gui module's OWN loader path: reads the XAML and
                    # validates it as well-formed XML. No second parser here.
                    $content = Get-Screen -Name $screenName
                    if (-not [string]::IsNullOrEmpty($content)) { $loadOk = $true }
                }
                catch { $loadError = $_.Exception.Message }
                Assert-True $loadOk ('7.' + $screenIndex + ' Get-Screen loads ' + $screenName + '.xaml through the Gui module loader: ' + $loadError)
                $screenIndex++
                $renderOk = $false
                $titleOk = $false
                $elementsOk = $false
                $missingElements = @()
                $renderDetail = ''
                if ($loadOk -and $assembliesOk) {
                    try {
                        $xamlDoc = New-Object System.Xml.XmlDocument
                        $xamlDoc.LoadXml($content)
                        $xamlReader = New-Object System.Xml.XmlNodeReader($xamlDoc)
                        $window = [System.Windows.Markup.XamlReader]::Load($xamlReader)
                        if ($null -ne $window -and $window -is [System.Windows.Window]) {
                            $renderOk = $true
                            if ([string]$window.Title -ieq $screen.Title) { $titleOk = $true }
                            foreach ($element in @($screen.Elements)) {
                                if ($null -eq $window.FindName($element)) { $missingElements += $element }
                            }
                            if ($missingElements.Count -eq 0) { $elementsOk = $true }
                        }
                    }
                    catch { $renderDetail = $_.Exception.Message }
                }
                else {
                    $renderDetail = 'screen content did not load or WPF assemblies unavailable (see the checks above)'
                }
                Assert-True ($renderOk -and $titleOk) ('7.' + $screenIndex + ' ' + $screenName + ' instantiates a WPF Window titled ' + $screen.Title + ': ' + $renderDetail)
                $screenIndex++
                Assert-True $elementsOk ('7.' + $screenIndex + ' ' + $screenName + ' named elements resolve in the instantiated window (missing: ' + ($missingElements -join ', ') + ')')
                $screenIndex++
            }
            $screenNames = @($guiScreens | ForEach-Object { $_.Name })
            $wizard = New-WizardHost -Screens $screenNames
            $walkForwardOk = $true
            for ($step = 0; $step -lt ($screenNames.Count - 1); $step++) {
                # -WizardHost is the literal parameter name; 'Host' is its
                # documented alias.
                $null = Invoke-WizardStep -WizardHost $wizard -Direction Next
                if ([string]$wizard.Current -ne $screenNames[$step + 1]) { $walkForwardOk = $false }
            }
            Assert-True ($walkForwardOk -and [string]$wizard.Current -eq $screenNames[$screenNames.Count - 1]) '7.12 the wizard host walks the three real screens forward to the last screen'
            for ($step = 0; $step -lt ($screenNames.Count - 1); $step++) {
                $null = Invoke-WizardStep -WizardHost $wizard -Direction Back
            }
            Assert-True ([string]$wizard.Current -eq $screenNames[0]) '7.13 the wizard host walks back to the first screen without passing it'
        }
        catch {
            Assert-True $false ('7.ABORT the GUI check group aborted with an unexpected error: ' + $_.Exception.Message)
        }

        # --- Check 8: phase handoffs write contract-valid state --------------
        try {
            Write-Output ''
            Write-Output 'Check 8: phase handoffs write contract-valid state'
            Write-Output 'NOTE 8.0 PhaseRunners injections in this group: the Check 5 determinism table wherever phases still run; the 8.3 scenario injects Drivers with a restart-request action; the 8.5 re-entry injects the IDENTITY PROVIDER with the mock partition staged identity (the real provider reports this VM actual identity, which never matches the mock GUIDs); the 8.8 scenario deliberately leaves BootEntryRegistration on its DEFAULT wiring so the REAL bcdedit-based boot check runs and fails closed.'

            # 8.1: a second in-process launch exits without work or mutation.
            # The mutex Check 5's entry still holds IS the second-instance
            # condition here (same process, Q35/Q36). The pre-check makes the
            # scenario FAIL CLOSED (rather than silently running a real
            # sequence with default host runners) when Check 5 never entered.
            $mutexHeld = ($null -ne (Get-OrchestratorMutex))
            Assert-True $mutexHeld '8.0 the single-instance lock is held by this process after the Check 5 entry (the second-instance handoff needs it)'
            $secondStatePath = Join-Path $script:suitePartition 'State\DeploymentState.json'
            $stateHashBefore = (Get-FileHash -LiteralPath $secondStatePath -Algorithm SHA256).Hash
            $second = $null
            if ($mutexHeld) {
                $second = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition
            }
            $secondOutcome = 'NOT RUN (8.0 failed)'
            if ($null -ne $second) { $secondOutcome = [string]$second.Outcome }
            Assert-True ($null -ne $second -and $second.Outcome -eq 'SecondInstance' -and -not [bool]$second.Completed -and $null -eq (Get-SuiteJsonField -Record $second -Name 'Result')) ('8.1 a second in-process launch returns SecondInstance without phase work (found Outcome {0})' -f $secondOutcome)
            Assert-True ((Get-FileHash -LiteralPath $secondStatePath -Algorithm SHA256).Hash -eq $stateHashBefore) '8.2 the second instance mutated no state file (DeploymentState.json hash unchanged)'

            # 8.3-8.5: RebootPending checkpoint handoff on the real filesystem.
            Reset-OrchestratorForNextEntry
            $script:suitePartition = New-MockPartition -Path (Join-Path $script:workspace 'HandoffPartition')
            $handoffPartitionPath = $script:suitePartition
            $handoffRunLog = New-RunLog -Root (Join-Path $script:suitePartition 'Logs') -RunType 'InitialDeployment'
            Add-LogEvent -Log $handoffRunLog -Event 'ComponentSuiteHandoffStart'
            $handoffStatePath = Join-Path $script:suitePartition 'State\DeploymentState.json'
            $rebootTable = New-SuiteRunnerTable -SkipPhases @('Drivers')
            $rebootTable['Drivers'] = {
                Set-OrchestrationRestartRequested
                return $true
            }
            $rebootResult = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition -PhaseRunners $rebootTable
            Assert-True ($rebootResult.Outcome -eq 'RebootPending' -and [string]$rebootResult.Phase -eq 'Drivers' -and -not [bool]$rebootResult.Completed) ('8.3 a restart-requesting Drivers phase returns RebootPending (found Outcome {0}, Phase {1}, Reason {2})' -f [string]$rebootResult.Outcome, [string]$rebootResult.Phase, [string]$rebootResult.Reason)
            $rebootResume = Get-ResumePoint -Path $handoffStatePath
            $rebootValidation = Test-DeploymentState -Record (Read-JsonFile -Path $handoffStatePath)
            Assert-True ((@($rebootResume.CompletedPhases) -join ',') -eq 'Drivers' -and [bool]$rebootResume.RebootPending -and [bool]$rebootValidation.Valid) '8.4 the pre-reboot checkpoint is contract-valid: Drivers completed, RebootPending durable'

            # 8.5-8.7: the post-reboot re-entry completes without re-running
            # the completed phase. The checkpoint carries RebootPending, so
            # the entry IDENTITY gate runs; the suite injects the provider
            # reporting the mock partition's staged identity (the REAL
            # Get-RealSystemIdentity provider reports this VM's actual
            # machine/disk identity, which by construction never matches the
            # mock partition's fixed GUIDs). $script:suitePartition is read
            # at INVOCATION time, like the runner table does.
            Reset-OrchestratorForNextEntry
            $stagedIdentityProvider = {
                $readiness = Read-JsonFile -Path (Join-Path $script:suitePartition 'State\ReadinessRecord.json')
                return @{
                    MachineId = [string](Get-SuiteJsonField -Record $readiness -Name 'MachineId')
                    DiskId    = [string](Get-SuiteJsonField -Record $readiness -Name 'DiskId')
                }
            }
            $resumeResult = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition -PhaseRunners (New-SuiteRunnerTable) -IdentityProvider $stagedIdentityProvider
            Assert-True ($resumeResult.Outcome -eq 'Completed' -and [string]$resumeResult.Result -eq 'Completed') ('8.5 the post-reboot re-entry completes the sequence (found Outcome {0}, Reason {1})' -f [string]$resumeResult.Outcome, [string]$resumeResult.Reason)
            $finalResume = Get-ResumePoint -Path $handoffStatePath
            $driversCount = @($finalResume.CompletedPhases | Where-Object { $_ -eq 'Drivers' }).Count
            Assert-True ((@($finalResume.CompletedPhases) -join ',') -eq $expectedPhases -and $driversCount -eq 1) ('8.6 the resumed checkpoint records the full sequence exactly once per phase (Drivers appears {0} time(s))' -f $driversCount)
            Assert-True ([System.IO.File]::ReadAllText($handoffStatePath) -match '"CompletedUtc"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"') '8.7 the resumed completion records CompletedUtc'

            # 8.8-8.12: Technician Review through the REAL bcdedit-based boot
            # check. The VM has no registered 'OSDeploy Factory Recovery'
            # boot entry, so the real read-only check (bcdedit /enum all)
            # reports Blocked and the attempt engine exhausts into review.
            Reset-OrchestratorForNextEntry
            $script:suitePartition = New-MockPartition -Path (Join-Path $script:workspace 'ReviewPartition')
            $reviewRunLog = New-RunLog -Root (Join-Path $script:suitePartition 'Logs') -RunType 'InitialDeployment'
            Add-LogEvent -Log $reviewRunLog -Event 'ComponentSuiteReviewStart'
            $reviewStatePath = Join-Path $script:suitePartition 'State\DeploymentState.json'
            Write-AtomicJson -Path (Join-Path $script:suitePartition 'State\TaskRegistration.json') -Value @{
                TaskName      = $script:taskName
                RegisteredUtc = [datetime]::UtcNow.ToString('o')
            }
            $reviewRuntimeDir = Join-Path $script:suitePartition 'OrchestratorRuntime'
            $null = New-Item -ItemType Directory -Path $reviewRuntimeDir -Force
            # BootEntryRegistration deliberately NOT overridden: its default
            # action runs the real bcdedit-based check.
            $reviewResult = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition -PhaseRunners (New-SuiteRunnerTable -SkipPhases @('BootEntryRegistration'))
            Assert-True ($reviewResult.Outcome -eq 'TechnicianReview' -and [string]$reviewResult.Phase -eq 'BootEntryRegistration') ('8.8 the real bcdedit boot check fails closed into the blocking Technician Review (found Outcome {0}, Phase {1})' -f [string]$reviewResult.Outcome, [string]$reviewResult.Phase)
            $reviewResume = Get-ResumePoint -Path $reviewStatePath
            $reviewValidation = Test-DeploymentState -Record (Read-JsonFile -Path $reviewStatePath)
            Assert-True (((@($reviewResume.CompletedPhases) -join ',') -eq 'Drivers,Applications,WorkflowSpecifics,WindowsUpdate,Activation,FinalValidation') -and [bool]$reviewValidation.Valid) ('8.9 the review checkpoint is contract-valid with exactly the six phases before the block completed (found {0})' -f (@($reviewResume.CompletedPhases) -join ','))
            Assert-True ([int]$reviewResume.Attempt -eq 4) ('8.10 three automatic attempts exhausted, the fourth failure recorded for the person (Attempt {0})' -f [int]$reviewResume.Attempt)
            $reviewRaw = [System.IO.File]::ReadAllText($reviewStatePath)
            Assert-True ($reviewRaw -notmatch 'CompletedUtc' -and $null -eq (Get-SuiteJsonField -Record (Read-JsonFile -Path $reviewStatePath) -Name 'Result')) '8.11 the blocked run records no Result and no CompletedUtc'
            Assert-True ((Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\TaskRegistration.json')) -and (Test-Path -LiteralPath $reviewRuntimeDir)) '8.12 the sequence stopped BEFORE completion work: the marker and runtime directory survive untouched'

            # 8.13-8.15: the post-completion restart performs CLEANUP ONLY.
            $script:suitePartition = $handoffPartitionPath
            $postStatePath = Join-Path $script:suitePartition 'State\DeploymentState.json'
            Write-AtomicJson -Path (Join-Path $script:suitePartition 'State\TaskRegistration.json') -Value @{
                TaskName      = $script:taskName
                RegisteredUtc = [datetime]::UtcNow.ToString('o')
            }
            $postRuntimeDir = Join-Path $script:suitePartition 'OrchestratorRuntime'
            $null = New-Item -ItemType Directory -Path $postRuntimeDir -Force
            $postHashBefore = (Get-FileHash -LiteralPath $postStatePath -Algorithm SHA256).Hash
            Reset-OrchestratorForNextEntry
            $postResult = Invoke-DeploymentSequence -PartitionRoot $script:suitePartition -PhaseRunners (New-SuiteRunnerTable)
            Assert-True ($postResult.Outcome -eq 'PostCompletionRestart' -and [bool]$postResult.Completed -and [bool]$postResult.Ok) ('8.13 the post-completion re-entry returns PostCompletionRestart with Ok True (found Outcome {0}, Ok {1})' -f [string]$postResult.Outcome, [string]$postResult.Ok)
            Assert-True ((-not (Test-Path -LiteralPath (Join-Path $script:suitePartition 'State\TaskRegistration.json'))) -and (-not (Test-Path -LiteralPath $postRuntimeDir))) '8.14 the cleanup-only re-entry removed the re-staged marker and runtime directory'
            Assert-True ((Get-FileHash -LiteralPath $postStatePath -Algorithm SHA256).Hash -eq $postHashBefore) '8.15 the cleanup-only re-entry rewrote no state field (DeploymentState.json hash unchanged)'
        }
        catch {
            Assert-True $false ('8.ABORT the phase-handoff check group aborted with an unexpected error: ' + $_.Exception.Message)
        }
    }
    finally {
        # Best-effort teardown: retire every suite task name (idempotent;
        # never let cleanup itself throw) and remove the workspace.
        foreach ($name in @($script:taskName, $script:probeTaskName, $script:seqTaskName)) {
            try { $null = Unregister-OrchestratorTask -TaskName $name } catch { }
        }
        if ($null -ne $script:workspace) {
            Remove-Item -Recurse -Force $script:workspace -ErrorAction SilentlyContinue
        }
    }

    # --- Summary (inside the transcript) --------------------------------------
    Write-Output ''
    $total = $script:checksPassed + $script:checksFailed
    if ($script:checksFailed -gt 0) {
        foreach ($failed in $script:failedChecks) { Write-Output ("FAILED: {0}" -f $failed) }
        Write-Output ("COMPONENT SUITE FAIL: {0} of {1} checks failed" -f $script:checksFailed, $total)
        $script:exitCode = 1
    }
    else {
        Write-Output ("COMPONENT SUITE PASS: {0} checks" -f $total)
        $script:exitCode = 0
    }
}
finally {
    if ($script:transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
exit $script:exitCode
