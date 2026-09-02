Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '..\OSDeploy.State\OSDeploy.State.psd1')

# ---------------------------------------------------------------------------
# Hard defaults (Q83/Q84): every defaulted setting has exactly one hard-coded
# value, and this table is the single source of those values. Nothing else in
# the suite may invent a default. Missing or invalid file values fall back to
# these values WITH a recorded reason (Fallbacks), never silently.
# ---------------------------------------------------------------------------
$script:Defaults = @{
    'Deployment.RecoveryPartitionSizeMB'       = 32768
    'Deployment.WindowsReToolsPartitionSizeMB' = 1024
    'Deployment.RecommendedPrimaryDriveSizeMB' = 122070
    'Deployment.TimeZone'                      = 'Pacific Standard Time'
    'Logging.LocalLogHistoryMaxMB'             = 1024
    'WindowsUpdate.MaxCycles'                  = 3
    'RegulatedStates'                          = @('CA')
    'CompanyWorkflowMap'                       = @{ 'EZT' = 'EZT'; 'EZ Trading Computers' = 'EZT'; '*' = 'MMC' }
}

# Integer range rules per defaulted key (ruling 3): partition and log sizes
# must be positive ints; MaxCycles must be an int in 1..10. A value failing
# its rule (including wrong type) is 'invalid' and falls back.
$script:RangeRules = @{
    'Deployment.RecoveryPartitionSizeMB'       = @{ Min = 1; Max = 2147483647 }
    'Deployment.WindowsReToolsPartitionSizeMB' = @{ Min = 1; Max = 2147483647 }
    'Deployment.RecommendedPrimaryDriveSizeMB' = @{ Min = 1; Max = 2147483647 }
    'Logging.LocalLogHistoryMaxMB'             = @{ Min = 1; Max = 2147483647 }
    'WindowsUpdate.MaxCycles'                  = @{ Min = 1; Max = 10 }
}

# Top-level key set the resolver knows: the defaulted sections plus the
# OrderDatabase section (Q98) and the ConfigVersion metadata field.
$script:KnownTopLevel = @('OrderDatabase', 'Deployment', 'Logging', 'WindowsUpdate',
    'RegulatedStates', 'CompanyWorkflowMap', 'ConfigVersion')
$script:KnownOrderDatabase = @('Host', 'Port', 'Database', 'Username', 'Password',
    'Table', 'ColumnMap')
$script:KnownColumnMap = @('OrderNumber', 'Company', 'EditionDefault', 'RegulatedState')

# ---------------------------------------------------------------------------
# Internal helpers (not exported)
# ---------------------------------------------------------------------------

# Read one field from a record that may be a hashtable (in-memory) or a
# PSCustomObject (from ConvertFrom-Json). Returns $null when the field is
# missing or holds null; the caller decides what that means. Array values
# are wrapped with the unary comma so function output cannot unroll them
# (a one-element RegulatedStates must stay an array, not collapse to its
# single string).
function Get-ConfigField {
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) {
            $value = $Record[$Name]
            if ($value -is [System.Array]) { return ,$value }
            return $value
        }
        return $null
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    if ($prop.Value -is [System.Array]) { return ,$prop.Value }
    return $prop.Value
}

# Enumerate a record's child key/property names for unknown-key detection.
function Get-ConfigChildNames {
    [CmdletBinding()]
    param($Record)
    if ($null -eq $Record) { return @() }
    if ($Record -is [System.Collections.IDictionary]) { return @($Record.Keys) }
    return @($Record.PSObject.Properties | ForEach-Object { $_.Name })
}

# Read the raw file value for a dot-named key ('Section.Leaf' or 'TopLevel').
# Array values are re-wrapped at this boundary too: every function boundary
# between the record and the consumer would otherwise unroll a one-element
# array (e.g. RegulatedStates @('CA')) down to a bare scalar.
function Get-ConfigValueByKey {
    [CmdletBinding()]
    param($Document, [Parameter(Mandatory)][string]$Key)
    $parts = $Key.Split('.')
    if ($parts.Count -eq 1) {
        $raw = Get-ConfigField -Record $Document -Name $Key
    }
    else {
        $sectionRecord = Get-ConfigField -Record $Document -Name $parts[0]
        $raw = Get-ConfigField -Record $sectionRecord -Name $parts[1]
    }
    if ($raw -is [System.Array]) { return ,$raw }
    return $raw
}

# True when $Value is an integral number acceptable for an [int]-typed
# setting within [Min, Max]. ConvertFrom-Json parses JSON integers as
# [long] on pwsh 7 and as [int] on Windows PowerShell 5.1, so both forms
# count as an int when the value fits the [int] range; strings, bools,
# doubles, and arrays are the wrong type and fail closed as 'invalid'.
function Test-ConfigIntValue {
    [CmdletBinding()]
    param($Value, [Parameter(Mandatory)][int]$Min, [Parameter(Mandatory)][int]$Max)
    if ($null -eq $Value) { return $false }
    if ($Value -is [int]) { return ($Value -ge $Min -and $Value -le $Max) }
    if ($Value -is [long]) {
        if ($Value -gt 2147483647 -or $Value -lt -2147483648) { return $false }
        return ($Value -ge $Min -and $Value -le $Max)
    }
    return $false
}

# True when the raw file value for a defaulted key is usable as-is.
function Test-ConfigValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, $Value)
    if ($null -eq $Value) { return $false }
    if ($script:RangeRules.ContainsKey($Key)) {
        $rule = $script:RangeRules[$Key]
        return (Test-ConfigIntValue -Value $Value -Min $rule.Min -Max $rule.Max)
    }
    switch ($Key) {
        'Deployment.TimeZone' {
            return ($Value -is [string] -and $Value -ne '')
        }
        'RegulatedStates' {
            if (-not ($Value -is [System.Array])) { return $false }
            foreach ($item in $Value) {
                if (-not ($item -is [string])) { return $false }
            }
            return $true
        }
        'CompanyWorkflowMap' {
            return ($Value -is [System.Collections.IDictionary] -or
                $Value -is [System.Management.Automation.PSCustomObject])
        }
        default { return $false }
    }
}

# Normalize a raw version field: a non-empty string passes through, anything
# else (missing, null, wrong type) becomes '<unversioned>'.
function ConvertTo-ConfigVersion {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return '<unversioned>' }
    if ($Value -is [string] -and $Value -ne '') { return $Value }
    return '<unversioned>'
}

# Shared resolution core. Used by Resolve-Config (central template) and by
# Load-RecoveryConfig (local snapshot) so recovery re-applies identical
# fallback semantics (Q83/Q84) - but only ever to the snapshot document.
# Walks the template's own key set: every known defaulted key either keeps
# its file value (when valid) or falls back to the hard default with a
# recorded reason; unknown extra keys never fail resolution, they only
# append entries to Warnings.
function Resolve-ConfigDocument {
    [CmdletBinding()]
    param($Document, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$SourcePath)
    $fallbacks = @()
    $warnings = New-Object System.Collections.Generic.List[string]
    $resolved = @{}

    foreach ($key in @($script:Defaults.Keys)) {
        $raw = Get-ConfigValueByKey -Document $Document -Key $key
        if (Test-ConfigValue -Key $key -Value $raw) {
            $resolved[$key] = $raw
        }
        else {
            $reason = 'invalid'
            if ($null -eq $raw) { $reason = 'missing' }
            $resolved[$key] = Get-ConfigDefault -Key $key
            $fallbacks += ,@{ Key = $key; Reason = $reason }
        }
    }

    # Unknown-key detection (never fatal): top-level extras, extras inside
    # the defaulted sections, and extras inside OrderDatabase/ColumnMap.
    foreach ($name in (Get-ConfigChildNames -Record $Document)) {
        if ($script:KnownTopLevel -notcontains $name) {
            $warnings.Add("Unknown key '$name' ignored")
        }
    }
    foreach ($sectionName in @('Deployment', 'Logging', 'WindowsUpdate')) {
        $sectionRecord = Get-ConfigField -Record $Document -Name $sectionName
        $knownLeaves = @($script:Defaults.Keys |
            Where-Object { $_.StartsWith($sectionName + '.') } |
            ForEach-Object { $_.Split('.')[1] })
        foreach ($name in (Get-ConfigChildNames -Record $sectionRecord)) {
            if ($knownLeaves -notcontains $name) {
                $warnings.Add("Unknown key '$sectionName.$name' ignored")
            }
        }
    }
    $orderDatabase = Get-ConfigField -Record $Document -Name 'OrderDatabase'
    if ($null -ne $orderDatabase) {
        foreach ($name in (Get-ConfigChildNames -Record $orderDatabase)) {
            if ($script:KnownOrderDatabase -notcontains $name) {
                $warnings.Add("Unknown key 'OrderDatabase.$name' ignored")
            }
        }
        $columnMap = Get-ConfigField -Record $orderDatabase -Name 'ColumnMap'
        if ($null -ne $columnMap) {
            foreach ($name in (Get-ConfigChildNames -Record $columnMap)) {
                if ($script:KnownColumnMap -notcontains $name) {
                    $warnings.Add("Unknown key 'OrderDatabase.ColumnMap.$name' ignored")
                }
            }
        }
    }

    $values = [ordered]@{
        OrderDatabase      = $orderDatabase
        Deployment         = [ordered]@{
            RecoveryPartitionSizeMB       = $resolved['Deployment.RecoveryPartitionSizeMB']
            WindowsReToolsPartitionSizeMB = $resolved['Deployment.WindowsReToolsPartitionSizeMB']
            RecommendedPrimaryDriveSizeMB = $resolved['Deployment.RecommendedPrimaryDriveSizeMB']
            TimeZone                      = $resolved['Deployment.TimeZone']
        }
        Logging            = [ordered]@{
            LocalLogHistoryMaxMB = $resolved['Logging.LocalLogHistoryMaxMB']
        }
        WindowsUpdate      = [ordered]@{
            MaxCycles = $resolved['WindowsUpdate.MaxCycles']
        }
        RegulatedStates    = $resolved['RegulatedStates']
        CompanyWorkflowMap = $resolved['CompanyWorkflowMap']
    }

    return @{
        Values    = $values
        Version   = $Version
        Source    = $SourcePath
        Fallbacks = $fallbacks
        Warnings  = $warnings.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

function Get-ConfigDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:Defaults.ContainsKey($Key)) {
        throw "Unknown config default key '$Key'."
    }
    $value = $script:Defaults[$Key]
    # Arrays and maps are returned as copies so a caller can never mutate the
    # single source of hard defaults. The clone plus unary comma keeps both
    # the copy and the array shape across the function boundary (a plain
    # return would unroll @('CA') down to a bare string at the call site).
    if ($value -is [System.Array]) { return ,@($value.Clone()) }
    if ($value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($name in @($value.Keys)) { $copy[$name] = $value[$name] }
        return $copy
    }
    return $value
}

function Resolve-Config {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    # Fail closed (Q84): an unreadable or unparseable central config is never
    # silently resolved to full defaults - Read-JsonFile throws instead.
    $document = Read-JsonFile -Path $ConfigPath
    $version = ConvertTo-ConfigVersion -Value (Get-ConfigField -Record $document -Name 'ConfigVersion')
    return (Resolve-ConfigDocument -Document $document -Version $version -SourcePath $ConfigPath)
}

function Save-ConfigSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Effective, [Parameter(Mandatory)][string]$Path)
    # The snapshot is the effective object itself plus SavedUtc, written
    # atomically so a reader never observes a partial document (Q35).
    $snapshot = @{}
    if ($Effective -is [System.Collections.IDictionary]) {
        foreach ($name in @($Effective.Keys)) { $snapshot[$name] = $Effective[$name] }
    }
    else {
        foreach ($prop in $Effective.PSObject.Properties) { $snapshot[$prop.Name] = $prop.Value }
    }
    $snapshot['SavedUtc'] = [datetime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $Path -Value $snapshot
}

function Load-RecoveryConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SnapshotPath)
    # Connectivity boundary (FactoryRecovery): this function reads ONLY the
    # local snapshot and deliberately has no central/share/server path
    # parameter at all. A missing or corrupt snapshot throws - recovery
    # never silently continues from defaults alone.
    $snapshot = Read-JsonFile -Path $SnapshotPath
    $valuesDocument = Get-ConfigField -Record $snapshot -Name 'Values'
    $version = ConvertTo-ConfigVersion -Value (Get-ConfigField -Record $snapshot -Name 'Version')
    return (Resolve-ConfigDocument -Document $valuesDocument -Version $version -SourcePath $SnapshotPath)
}
