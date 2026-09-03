# OSDeploy component suite: Windows-only mechanics (Task 28).
#
# A PLAIN SCRIPT, not a Pester file: simple assertion helpers, one PASS/FAIL
# line per numbered check, a summary, and a nonzero exit code on failure.
# Run it on the Windows VM (Task 29), ELEVATED (Administrator) - SYSTEM
# Scheduled Task registration requires it:
#
#     pwsh -NoProfile -File tests\component\ComponentSuite.ps1
#     powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\component\ComponentSuite.ps1
#
# Covers the Task 28 brief Step 1 checks:
#   1. Set-OrchestratorAcl: the ACL resolves to exactly SYSTEM and local
#      Administrators, inheritance disabled.
#   2. Register-OrchestratorTask: the task registers with the SYSTEM
#      ServiceAccount Highest principal, IgnoreNew multiple instances, a
#      startup (boot) trigger, and no sign-in requirement (a service-account
#      boot task needs no signed-in user and stores no password); the
#      partition registration marker is written.
#   3. Unregister-OrchestratorTask: removes the task and is safe to call
#      twice.
#   4. The orchestrator launch under the task acquires the single-instance
#      mutex (Enter-Orchestrator reports Ran = True from inside the task).
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
# would reject the undefined $IsWindows reference.
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { Write-Output 'SKIP: Windows only'; return }

Set-StrictMode -Version Latest

# --- Assertion helpers (Pester-free PASS/FAIL accounting) -------------------
$script:checksPassed = 0
$script:checksFailed = 0
$script:failedChecks = @()

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:checksPassed++
        Write-Output ("PASS {0}: {1}" -f $script:checksPassed, $Name)
    }
    else {
        $script:checksFailed++
        $script:failedChecks += $Name
        Write-Output ("FAIL {0}: {1}" -f $script:checksFailed, $Name)
    }
}

# --- Module and fixture wiring (paths relative to this script) --------------
$script:modulePath = Join-Path $PSScriptRoot '..\..\src\Orchestrator\OSDeploy.Orchestrator.psd1'
# The mock builder also imports OSDeploy.State/Util/Config, so Read-JsonFile
# is available below for marker verification.
. (Join-Path $PSScriptRoot '..\mocks\New-MockPartition.ps1')
Import-Module $script:modulePath -Force

# --- Elevation gate: SYSTEM task registration needs an elevated session -----
$windowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output 'FAIL: this component suite must run ELEVATED (Administrator); SYSTEM Scheduled Task registration requires it.'
    exit 1
}

# Suite-unique task names: the registration code path is identical to the
# default-named one, but clobbering a machine real orchestrator task
# ('OSDeploy Orchestrator') from a test would be unacceptable.
$script:taskName = 'OSDeploy Orchestrator ComponentSuite'
$script:probeTaskName = 'OSDeploy Orchestrator ComponentSuite Probe'

# Workspace under the system drive root (created elevated) so the SYSTEM
# context running the probe task can certainly read it; user-profile temp
# paths can be hardened against SYSTEM. Fall back to the temp path when the
# drive root is not writable.
$script:workspace = $null
try {
    $script:workspace = (New-Item -ItemType Directory -Path (Join-Path $env:SystemDrive ('OSDeploy-ComponentSuite-' + [guid]::NewGuid().ToString('N'))) -ErrorAction Stop).FullName
}
catch {
    $script:workspace = (New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('OSDeploy-ComponentSuite-' + [guid]::NewGuid().ToString('N')))).FullName
}

try {
    # --- Check 1: Set-OrchestratorAcl restricts to exactly SYSTEM and
    #     local Administrators with inheritance disabled --------------------
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

    # --- Check 2: Register-OrchestratorTask registers the SYSTEM startup
    #     task exactly per the contract and writes the marker --------------
    Write-Output ''
    Write-Output 'Check 2: Register-OrchestratorTask SYSTEM startup registration'
    $partition = New-MockPartition -Path (Join-Path $script:workspace 'Partition')
    $regResult = Register-OrchestratorTask -PartitionRoot $partition -TaskName $script:taskName
    Assert-True ([bool]$regResult.Ok) '2.1 Register-OrchestratorTask returns Ok = True'
    $task = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    Assert-True ($null -ne $task) '2.2 Get-ScheduledTask finds the registered task'
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
        Assert-True ([string]$marker.TaskName -ieq $script:taskName) '2.8b the marker TaskName matches'
        Assert-True (-not [string]::IsNullOrEmpty([string]$marker.RegisteredUtc)) '2.8c the marker RegisteredUtc is present'
    }
    else {
        Assert-True ($false) '2.8b the marker TaskName matches (marker missing; check 2.8a failed)'
        Assert-True ($false) '2.8c the marker RegisteredUtc is present (marker missing; check 2.8a failed)'
    }

    # --- Check 3: Unregister-OrchestratorTask removes the task and is safe
    #     to call twice ------------------------------------------------------
    Write-Output ''
    Write-Output 'Check 3: Unregister-OrchestratorTask idempotent removal'
    $unregisterOne = Unregister-OrchestratorTask -TaskName $script:taskName
    Assert-True ([bool]$unregisterOne.Ok -and [bool]$unregisterOne.Existed) '3.1 the first Unregister call reports Ok = True with Existed = True'
    $goneTask = Get-ScheduledTask -TaskName $script:taskName -ErrorAction SilentlyContinue
    Assert-True ($null -eq $goneTask) '3.2 Get-ScheduledTask no longer finds the task'
    $unregisterTwo = Unregister-OrchestratorTask -TaskName $script:taskName
    Assert-True ([bool]$unregisterTwo.Ok -and -not [bool]$unregisterTwo.Existed) '3.3 the second Unregister call is a successful no-op (safe to call twice)'
    Assert-True (Test-Path -LiteralPath $markerPath -PathType Leaf) '3.4 the registration marker is untouched by Unregister (Invoke-Cleanup owns marker removal)'

    # --- Check 4: the orchestrator launch under the task acquires the
    #     single-instance mutex ---------------------------------------------
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
    Assert-True (Test-Path -LiteralPath $outcomePath) '4.2 the task launched and the probe completed within the timeout'
    if (Test-Path -LiteralPath $outcomePath) {
        $outcomeText = ([System.IO.File]::ReadAllText($outcomePath)).Trim()
        Assert-True ($outcomeText -eq 'Ran=True') ('4.3 Enter-Orchestrator under the task acquired the single-instance mutex (outcome: {0})' -f $outcomeText)
    }
    else {
        Assert-True ($false) '4.3 Enter-Orchestrator under the task acquired the single-instance mutex (probe never completed; check 4.2 failed)'
    }
    $probeUnregister = Unregister-OrchestratorTask -TaskName $script:probeTaskName
    Assert-True ([bool]$probeUnregister.Ok) '4.4 the probe task is retired'
}
finally {
    # Best-effort teardown: retire both suite task names (idempotent; never
    # let cleanup itself throw) and remove the workspace.
    foreach ($name in @($script:taskName, $script:probeTaskName)) {
        try { $null = Unregister-OrchestratorTask -TaskName $name } catch { }
    }
    if ($null -ne $script:workspace) {
        Remove-Item -Recurse -Force $script:workspace -ErrorAction SilentlyContinue
    }
}

Write-Output ''
$total = $script:checksPassed + $script:checksFailed
if ($script:checksFailed -gt 0) {
    foreach ($failed in $script:failedChecks) { Write-Output ("FAILED: {0}" -f $failed) }
    Write-Output ("COMPONENT SUITE FAIL: {0} of {1} checks failed" -f $script:checksFailed, $total)
    exit 1
}
Write-Output ("COMPONENT SUITE PASS: {0} checks" -f $total)
exit 0
