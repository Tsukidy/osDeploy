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

# Case-insensitive membership test for the secondary label pool.
# List[string].Contains is ordinal/case-sensitive, but NTFS volume-label
# lookups are not, so the Q59 collision rule compares with PowerShell's
# case-insensitive string -eq instead.
function Test-LabelTaken {
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[string]]$Labels,
        [Parameter(Mandatory)][string]$Value
    )
    foreach ($label in $Labels) {
        if ([string]$label -eq $Value) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Public surface (erase scopes and secondary drives, Task 12)
# ---------------------------------------------------------------------------

# Q85 erase-scope variants per run type. InitialDeployment and PXE Full
# Factory Rebuild erase the complete confirmed primary target, so their scope
# is the single area 'EntireDisk'. FactoryRecovery erases only the
# Windows-related target area and preserves the recovery environment: the
# scope is exactly the ordered areas 'Efi', 'Msr', 'WindowsSpan' - the WinRE
# tools partition and the OSDCloud Deployment Partition are NEVER listed for
# any run type. "Deployment Erase" removes/recreates/formats only the area
# the run type permits and is NOT certified secure data sanitization; callers
# must word warnings accordingly.
#
# Fail closed: any RunType other than the three known values throws - no
# default scope is ever guessed. Comparison uses PowerShell's
# case-insensitive string -eq. The returned areas are area NAMES only; this
# pure function performs no erasure.
function Get-EraseScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunType
    )

    if ($RunType -eq 'InitialDeployment') { return @('EntireDisk') }
    if ($RunType -eq 'PXEFullFactoryRebuild') { return @('EntireDisk') }
    if ($RunType -eq 'FactoryRecovery') { return @('Efi', 'Msr', 'WindowsSpan') }

    throw ('Unknown run type ''{0}''. Erase scope is defined only for InitialDeployment, PXEFullFactoryRebuild, and FactoryRecovery.' -f $RunType)
}

# Q58-Q60 secondary-drive preparation planning. Q58: only drives the
# technician explicitly selected are ever planned - this function plans
# exactly the records passed to it (Factory Recovery never modifies
# secondary drives precisely because its caller never invokes this with
# any). Q59: GPT, one full-size NTFS partition, automatic letters, and
# collision-safe Data/Data-2/Data-3 labels. Q60: letters start at D.
#
# Per-drive plan objects carry exactly Disk (the original record, by
# reference), Gpt = $true, FileSystem = 'NTFS', OnePartition = $true,
# Letter, and Label. Letter is the bare drive-letter char (e.g. 'D'); the
# caller renders it as 'D:'. Letters iterate D through Z, skipping
# $ExistingLetters (uppercased, so 'd' and 'D' collide as they should) and
# every letter already assigned within this call. Labels iterate the
# unbounded Q59 sequence Data, Data-2, Data-3, ..., skipping
# $ExistingLabels collisions (compared case-insensitively, since volume
# labels are) and labels consumed earlier in this call.
#
# Fail closed: exhausting the D..Z letter range throws rather than reusing
# a taken letter. A null record is skipped; an empty selection returns an
# empty plan list. This function computes plans only - the caller executes
# them.
function New-SecondaryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Selected,
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$ExistingLabels = @(),
        [AllowEmptyCollection()]
        [AllowNull()]
        [char[]]$ExistingLetters = @()
    )

    $takenLetters = New-Object System.Collections.Generic.List[char]
    foreach ($letter in @($ExistingLetters)) {
        if ($null -eq $letter) { continue }
        $upper = [char]::ToUpperInvariant($letter)
        if (-not $takenLetters.Contains($upper)) { $takenLetters.Add($upper) }
    }

    $takenLabels = New-Object System.Collections.Generic.List[string]
    foreach ($label in @($ExistingLabels)) {
        if ($null -eq $label) { continue }
        if (-not (Test-LabelTaken -Labels $takenLabels -Value ([string]$label))) {
            $takenLabels.Add([string]$label)
        }
    }

    $plans = @()
    $labelIndex = 0
    foreach ($disk in @($Selected)) {
        if ($null -eq $disk) { continue }

        $letter = $null
        for ($code = [int][char]'D'; $code -le [int][char]'Z'; $code++) {
            $candidate = [char]$code
            if (-not $takenLetters.Contains($candidate)) {
                $letter = $candidate
                break
            }
        }
        if ($null -eq $letter) {
            throw 'No free drive letter remains between D and Z for secondary-drive preparation. Reassign or remove existing volumes, or select fewer drives.'
        }
        $takenLetters.Add($letter)

        $label = $null
        while ($null -eq $label) {
            $candidateLabel = 'Data'
            if ($labelIndex -gt 0) {
                $candidateLabel = 'Data-' + ($labelIndex + 1)
            }
            $labelIndex++
            if (-not (Test-LabelTaken -Labels $takenLabels -Value $candidateLabel)) {
                $label = $candidateLabel
            }
        }
        $takenLabels.Add($label)

        $plans += [pscustomobject]([ordered]@{
            Disk         = $disk
            Gpt          = $true
            FileSystem   = 'NTFS'
            OnePartition = $true
            Letter       = $letter
            Label        = $label
        })
    }

    return $plans
}

# Q63 secondary-preparation failure options: exactly Retry Secondary Drive
# or Skip Failed Drive and Continue, in that order. Primary deployment is
# nonblocking either way (the caller's concern, not this function's). The
# strings are fixed text - a fresh array is returned on every call so no
# caller can mutate the canonical pair.
function Get-SecondaryFailureOptions {
    [CmdletBinding()]
    param()

    return @('Retry Secondary Drive', 'Skip Failed Drive and Continue')
}

# Q62 mount-verify-only check for recognized secondary volumes after
# Windows assigns letters: warn when a volume did not mount; never fail,
# never repair, never relabel, never compare inventory, never restore
# letters. The return value is a verification WARNING LIST ONLY - there is
# no failure, block, or repair output anywhere in the shape.
#
# Each entry carries exactly Volume (the original record, by reference, so
# the caller can render it) and Warning. The warning names the volume by
# drive letter (rendered 'E:'; the record may carry Letter or DriveLetter,
# and a trailing ':' on the stored value is tolerated) and by label when
# present. Mounted must be positively established: a volume warns unless
# its Mounted field is $true, so missing/null metadata warns - the safe
# direction for a warning-only check. Empty input or an all-mounted set
# returns an empty list.
function Test-SecondaryMountOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Volumes
    )

    $warnings = @()
    foreach ($volume in @($Volumes)) {
        if ($null -eq $volume) { continue }
        $mounted = Get-DiskField -Record $volume -Name 'Mounted'
        if ($mounted -eq $true) { continue }

        $letter = Get-DiskField -Record $volume -Name 'Letter'
        if ($null -eq $letter) { $letter = Get-DiskField -Record $volume -Name 'DriveLetter' }
        $letterText = ''
        if ($null -ne $letter) {
            $trimmed = ([string]$letter).TrimEnd(':')
            if ($trimmed.Length -gt 0) { $letterText = $trimmed + ':' }
        }

        $label = Get-DiskField -Record $volume -Name 'Label'
        $labelText = ''
        if ($null -ne $label) { $labelText = [string]$label }

        $display = 'unnamed secondary volume'
        if (($letterText.Length -gt 0) -and ($labelText.Length -gt 0)) {
            $display = '{0} ({1})' -f $letterText, $labelText
        } elseif ($letterText.Length -gt 0) {
            $display = $letterText
        } elseif ($labelText.Length -gt 0) {
            $display = $labelText
        }

        $warnings += @{
            Volume  = $volume
            Warning = ('Secondary volume {0} did not mount after drive letters were assigned. This is a warning only: the volume is not repaired, relabeled, or reassigned.' -f $display)
        }
    }

    return $warnings
}
