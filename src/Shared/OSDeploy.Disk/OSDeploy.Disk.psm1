Set-StrictMode -Version Latest

# Pure logic over injected inventory records (design D12): this module never
# calls Get-Disk or Get-PhysicalDisk itself. The caller (PXE bootstrap, the
# OSDCloud Deployment Partition, or a test) supplies candidate records shaped
# like @{ Number; Model; SerialNumber; Bus; SizeBytes; Internal }, built from
# whatever the environment's real inventory cmdlets return. Hashtable and
# PSCustomObject records are both accepted everywhere.

# ---------------------------------------------------------------------------
# Internal helpers (not exported)
# ---------------------------------------------------------------------------

# Read one field from a record that may be a hashtable (in-memory) or a
# PSCustomObject (from ConvertFrom-Json / projected inventory). Returns $null
# when the field is missing or holds null; the caller decides what that means.
# Strict-mode safe: no direct property reference can throw on a missing field.
function Get-DiskField {
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# Q4 eligibility: internal AND size above 0. Model and bus never affect
# eligibility; a null/missing Internal or SizeBytes fails closed as ineligible.
function Test-DiskEligible {
    [CmdletBinding()]
    param($Disk)
    if ($null -eq $Disk) { return $false }
    $internal = Get-DiskField -Record $Disk -Name 'Internal'
    $sizeBytes = Get-DiskField -Record $Disk -Name 'SizeBytes'
    return (($internal -eq $true) -and ($sizeBytes -gt 0))
}

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

# Plain display projection: exactly the five technician-facing fields, in
# fixed order. Never decides eligibility and never invents values - a missing
# source field projects as $null.
function Get-DiskPresentation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Disk)
    return [pscustomobject]([ordered]@{
        Number       = Get-DiskField -Record $Disk -Name 'Number'
        Model        = Get-DiskField -Record $Disk -Name 'Model'
        SerialNumber = Get-DiskField -Record $Disk -Name 'SerialNumber'
        Bus          = Get-DiskField -Record $Disk -Name 'Bus'
        SizeBytes    = Get-DiskField -Record $Disk -Name 'SizeBytes'
    })
}

# Q4 primary-disk selection: auto-select a sole eligible NVMe (the caller
# still displays it before erasure); require selection when several eligible
# NVMe drives exist; apply the same sole/multiple rule to the remaining
# eligible drives when no NVMe exists. Any bus other than 'NVMe' counts as
# SATA-side for that fallback ('-eq' on strings is case-insensitive).
#
# Result contract (documented choice): the returned hashtable ALWAYS carries
# all four keys - Disk, AutoSelected, RequiresSelection, NoCandidates.
# NoCandidates is $true only when no candidate is eligible at all, so the
# caller can distinguish 'nothing to show' from 'technician must choose'.
function Select-PrimaryDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Candidates
    )

    $eligible = @($Candidates | Where-Object { Test-DiskEligible -Disk $_ })
    $nvme = @($eligible |
        Where-Object { (Get-DiskField -Record $_ -Name 'Bus') -eq 'NVMe' })

    if ($nvme.Count -gt 0) {
        if ($nvme.Count -eq 1) {
            return @{
                Disk              = $nvme[0]
                AutoSelected      = $true
                RequiresSelection = $false
                NoCandidates      = $false
            }
        }
        return @{
            Disk              = $null
            AutoSelected      = $false
            RequiresSelection = $true
            NoCandidates      = $false
        }
    }

    # No eligible NVMe: same sole/multiple rule over the SATA-side remainder.
    $sataSide = @($eligible |
        Where-Object { (Get-DiskField -Record $_ -Name 'Bus') -ne 'NVMe' })
    if ($sataSide.Count -eq 1) {
        return @{
            Disk              = $sataSide[0]
            AutoSelected      = $true
            RequiresSelection = $false
            NoCandidates      = $false
        }
    }
    if ($sataSide.Count -gt 1) {
        return @{
            Disk              = $null
            AutoSelected      = $false
            RequiresSelection = $true
            NoCandidates      = $false
        }
    }
    return @{
        Disk              = $null
        AutoSelected      = $false
        RequiresSelection = $false
        NoCandidates      = $true
    }
}

# Q5 removable-storage blocking: a device blocks destructive work only when
# it is BOTH Removable AND Storage. Ordinary non-storage USB peripherals
# (keyboards, mice) never block, and fixed internal storage never blocks
# here. Devices are injected records shaped like
# @{ Removable; Storage; ... }; classification is strict-mode safe, so a
# missing field simply fails the -eq $true test (does not block).
#
# Result contract: the returned hashtable ALWAYS carries Blocked, Reason,
# and RemovableStorage. Reason is a human-readable string when blocked and
# $null otherwise; RemovableStorage is the array of blocking device records
# (the caller renders them per Q5's removal-confirmation-rescan flow).
function Test-RemovableBlocking {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Devices
    )

    $blockers = @()
    foreach ($device in @($Devices)) {
        if ($null -eq $device) { continue }
        $removable = Get-DiskField -Record $device -Name 'Removable'
        $storage = Get-DiskField -Record $device -Name 'Storage'
        if (($removable -eq $true) -and ($storage -eq $true)) {
            $blockers += $device
        }
    }

    if ($blockers.Count -gt 0) {
        return @{
            Blocked          = $true
            Reason           = ('Removable storage is connected ({0} device(s)). Remove all removable storage, confirm removal, and rescan before any destructive work.' -f $blockers.Count)
            RemovableStorage = $blockers
        }
    }
    return @{
        Blocked          = $false
        Reason           = $null
        RemovableStorage = @()
    }
}

# Q6 Emergency Bypass chain: the bypass is allowed only when BOTH the
# acknowledgement checkbox (Acknowledged) and the Yes-or-Cancel confirmation
# (-Confirmed) are true. There is deliberately no reason-dropdown parameter
# anywhere in this chain (Q6 forbids requiring one). Target-disk revalidation
# is the caller's job via Compare-DiskIdentity immediately before use.
#
# The audit event is emitted on EVERY invocation - including denials - because
# a denied bypass attempt is itself an audit-worthy event. The event carries
# exactly Event ('EmergencyBypass'), TargetSerial (from the target record;
# $null when absent), and TimestampUtc (ISO 8601 round-trip 'o' format, UTC).
function Invoke-EmergencyBypass {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Target,
        [Parameter(Mandatory)][bool]$Acknowledged,
        [switch]$Confirmed
    )

    return @{
        Allowed = (($Acknowledged -eq $true) -and ($Confirmed.IsPresent))
        AuditEvent = @{
            Event        = 'EmergencyBypass'
            TargetSerial = Get-DiskField -Record $Target -Name 'SerialNumber'
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

# Q12/Q87 identity revalidation at time of use: the disk about to receive
# destructive work must still be the disk that was selected. Returns $true
# only when Number, SerialNumber, AND SizeBytes all match. Fails closed: a
# missing or null field on either record is never a match (identity must be
# positively established, not assumed).
#
# Documented comparison choices: Number and SizeBytes compare numerically by
# value; SerialNumber compares as a case-INSENSITIVE string (inventory
# sources are inconsistent about serial casing, and a case-only difference
# is not evidence of a different physical disk).
function Compare-DiskIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Selected,
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Observed
    )

    if ($null -eq $Selected) { return $false }
    if ($null -eq $Observed) { return $false }

    $numberSelected = Get-DiskField -Record $Selected -Name 'Number'
    $numberObserved = Get-DiskField -Record $Observed -Name 'Number'
    if ($null -eq $numberSelected) { return $false }
    if ($null -eq $numberObserved) { return $false }
    if ($numberSelected -ne $numberObserved) { return $false }

    $sizeSelected = Get-DiskField -Record $Selected -Name 'SizeBytes'
    $sizeObserved = Get-DiskField -Record $Observed -Name 'SizeBytes'
    if ($null -eq $sizeSelected) { return $false }
    if ($null -eq $sizeObserved) { return $false }
    if ($sizeSelected -ne $sizeObserved) { return $false }

    $serialSelected = Get-DiskField -Record $Selected -Name 'SerialNumber'
    $serialObserved = Get-DiskField -Record $Observed -Name 'SerialNumber'
    if ([string]::IsNullOrEmpty($serialSelected)) { return $false }
    if ([string]::IsNullOrEmpty($serialObserved)) { return $false }
    if (-not ([string]$serialSelected -eq [string]$serialObserved)) { return $false }

    return $true
}

# Q79-Q82 capacity rules: no granular pre-download capacity modeling. A
# simple warning below the configurable recommended size (RecommendedMB,
# default 122070 MB per Q82); a hard block only for impossible layouts
# (RequiredMB is set and the required layout cannot fit). Q80: the warning
# is acknowledgement-gated - NeedsAcknowledgement tells the caller to
# require the "I understand the capacity risk" checkbox before Continue
# Anyway is enabled. A block has no acknowledgement path at all: an
# impossible layout blocks even when acknowledged, so NeedsAcknowledgement
# is $false and Warning is $null whenever Block is set.
#
# Q81: the capacity warning and override are NOT specially logged, so the
# result carries no logging-related property - exactly Warning, Block, and
# NeedsAcknowledgement. Block messages never claim forensic sanitization
# (Q85): "Deployment Erase" is not a sanitization pass.
function Test-Capacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$DiskSizeBytes,
        [int]$RecommendedMB = 122070,
        [int]$RequiredMB = 0
    )

    $recBytes = [long]$RecommendedMB * 1MB
    $reqBytes = [long]$RequiredMB * 1MB

    if (($RequiredMB -gt 0) -and ($DiskSizeBytes -lt $reqBytes)) {
        return @{
            Warning             = $null
            Block               = 'Required layout cannot fit on this disk.'
            NeedsAcknowledgement = $false
        }
    }
    if ($DiskSizeBytes -lt $recBytes) {
        return @{
            Warning             = ('Primary drive is below the recommended size of {0} MB.' -f $RecommendedMB)
            Block               = $null
            NeedsAcknowledgement = $true
        }
    }
    return @{
        Warning             = $null
        Block               = $null
        NeedsAcknowledgement = $false
    }
}
