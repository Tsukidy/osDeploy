Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Internal helpers (not exported)
# ---------------------------------------------------------------------------

# Read one field from a record that may be a hashtable (in-memory) or a
# PSCustomObject (from ConvertFrom-Json). Returns $null when the field is
# missing; callers decide whether that is fatal. Never substitutes a value.
function Get-RecordField {
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

# Presence check for fields that are required to EXIST but may legitimately
# hold $null, $false, or an empty value at some lifecycle point.
function Test-RecordFieldPresent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $false }
    if ($Record -is [System.Collections.IDictionary]) { return $Record.Contains($Name) }
    return $null -ne $Record.PSObject.Properties[$Name]
}

# Shared required-field validator (Q87, Q89: identity and structural fields
# never fall back to defaults - validation fails instead).
#   $RequiredNonNull : field must exist AND hold a non-null, non-empty value.
#   $RequiredPresent : field must exist; its value may be null/false/empty.
# Every violation adds one message to Errors; nothing is ever defaulted.
function Test-RequiredFields {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [string[]]$RequiredNonNull, [string[]]$RequiredPresent)
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($name in $RequiredNonNull) {
        $value = Get-RecordField -Record $Record -Name $name
        if ($null -eq $value -or ($value -is [string] -and $value -eq '')) {
            $errors.Add("Missing required field '$name'")
        }
    }
    foreach ($name in $RequiredPresent) {
        if (-not (Test-RecordFieldPresent -Record $Record -Name $name)) {
            $errors.Add("Missing required field '$name' (nullable field must be present)")
        }
    }
    return @{ Valid = $errors.Count -eq 0; Errors = $errors.ToArray() }
}

# Read and validate a FactoryProfile file. Returns the parsed profile when the
# file exists, parses, and passes Test-FactoryProfile; otherwise $null. Never
# returns a guessed or default profile (Q87).
function Get-ValidFactoryProfileFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $profile = Read-JsonFile -Path $Path
        $result = Test-FactoryProfile -Record $profile
        if ($result.Valid) { return $profile }
        return $null
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Atomic JSON writes (Q35, Q89: a reader never observes a partial document)
# ---------------------------------------------------------------------------

function Write-AtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    $tmp = "$Path.tmp$(Get-Random)"
    try {
        # Temp file in the same directory so the move stays on one volume.
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::ASCII)
        # Plain Move-Item, not module-qualified: tests simulate an interrupted
        # move by shadowing this command in the session scope.
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        # SilentlyContinue so cleanup can never mask the original failure.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII) | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# State-file contracts
# ---------------------------------------------------------------------------

function Test-ReadinessRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    # Identity fields (RunId, MachineId, DiskId, Workflow - never defaulted,
    # Q87/Q89) plus the readiness-gate evidence fields (Q92, Q102).
    $nonNull = @('RunId', 'MachineId', 'DiskId', 'Workflow', 'Edition',
        'ConfigVersion', 'BundleHash', 'TimestampUtc')
    Test-RequiredFields -Record $Record -RequiredNonNull $nonNull
}

function Test-DeploymentState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    # Required-field split (Q89):
    # - Required NON-NULL: identity plus structural fields that must carry a
    #   value on every checkpoint - RunId, MachineId, DiskId, Workflow,
    #   Edition, Phase, ConfigVersion, TimestampUtc.
    # - Required PRESENT only (value may be null/false/empty at lifecycle
    #   points): Attempt (null before the first attempt begins),
    #   RebootPending, CompletedPhases, Result (null until the run finishes),
    #   NotedIssues, Acknowledgements. The property must exist, but no value
    #   is ever invented for it.
    $nonNull = @('RunId', 'MachineId', 'DiskId', 'Workflow', 'Edition', 'Phase',
        'ConfigVersion', 'TimestampUtc')
    $present = @('Attempt', 'RebootPending', 'CompletedPhases', 'Result',
        'NotedIssues', 'Acknowledgements')
    Test-RequiredFields -Record $Record -RequiredNonNull $nonNull -RequiredPresent $present
}

function Test-FactoryProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)
    # Q87: profile identity is never defaulted and has no fallback. Noncritical
    # fields (EnergyStar, Locale, EditionHistory, LastRecoveryUtc) may be null
    # and are not required to be present.
    $nonNull = @('MachineId', 'Workflow', 'FactoryEdition', 'DefaultRecoveryEdition',
        'SchemaVersion', 'CreatedUtc')
    Test-RequiredFields -Record $Record -RequiredNonNull $nonNull
}

# ---------------------------------------------------------------------------
# FactoryProfile active + last-known-good maintenance (Q87)
# ---------------------------------------------------------------------------

function Update-FactoryProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]$Profile
    )
    $activePath = Join-Path $Directory 'FactoryProfile.json'
    $lkgPath = Join-Path $Directory 'FactoryProfile.lastknowngood.json'
    # LKG first: the backup receives the currently active content before the
    # active file is replaced, so an interrupted update can never lose the last
    # known-good profile. When there is no valid current active file (first
    # write, or the active copy is corrupt), the profile being committed is
    # the newest known-good content and seeds the backup.
    $current = Get-ValidFactoryProfileFile -Path $activePath
    if ($null -ne $current) {
        Write-AtomicJson -Path $lkgPath -Value $current
    }
    else {
        Write-AtomicJson -Path $lkgPath -Value $Profile
    }
    Write-AtomicJson -Path $activePath -Value $Profile
}

function Restore-FactoryProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)
    $activePath = Join-Path $Directory 'FactoryProfile.json'
    $lkgPath = Join-Path $Directory 'FactoryProfile.lastknowngood.json'
    # Active copy valid: use it unchanged.
    $active = Get-ValidFactoryProfileFile -Path $activePath
    if ($null -ne $active) {
        return @{ Status = 'Active'; Profile = $active; Warning = $null }
    }
    # Backup valid: copy it over the active file (atomic write) and continue
    # with a recorded warning event name for the log.
    $backup = Get-ValidFactoryProfileFile -Path $lkgPath
    if ($null -ne $backup) {
        Write-AtomicJson -Path $activePath -Value $backup
        return @{ Status = 'Restored'; Profile = $backup; Warning = 'FactoryProfileRestoredFromBackup' }
    }
    # Both copies bad: stop without guessing a workflow (Q87).
    return @{ Status = 'Invalid'; Profile = $null; Warning = $null }
}
