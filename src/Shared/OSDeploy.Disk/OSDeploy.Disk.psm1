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
