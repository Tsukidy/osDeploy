Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# OSDeploy.Image: pure validation over a Windows image METADATA OBJECT
# (Q46/Q47). The calling environments (PXE bootstrap, OSDCloud Deployment
# Partition) construct the object from their imaging tooling output before
# calling here; this module NEVER shells out to any external tool or command -
# it only inspects the object it is handed (ruling 3).
#
# Q47 in one line: use one validated multi-index Windows 11 image carrying
# BOTH Home and Pro; reject it if either index is missing or architecture,
# language, release, or build compatibility is inconsistent; record the exact
# index names and numbers (IndexRecord) for later use (Task 14 adds the
# promotion lifecycle and edition resolution on top of this record).
# ---------------------------------------------------------------------------

# Read one field from an index record that may be a hashtable (in-memory) or
# a PSCustomObject (ConvertFrom-Json). Returns $null when the field is
# missing or holds null; the caller decides what that means.
function Get-IndexField {
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

# Display label for error text: the index Name when one is present, else the
# index number. The contract requires error text to name the failing field
# and the index name where possible.
function Get-IndexDisplayName {
    [CmdletBinding()]
    param($Name, $Number)
    if ($null -ne $Name -and [string]$Name -ne '') { return [string]$Name }
    return ("index {0}" -f $Number)
}

# True when $Value holds an integral number usable as an index number.
# Metadata built from tooling output or ConvertFrom-Json yields [int]/[long];
# anything else (including a numeric STRING such as '7') is not numeric and
# triggers the position fallback below (ruling 2).
function Test-IndexNumber {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $false }
    return ($Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or
        $Value -is [long] -or $Value -is [uint64])
}

# Parse a version field, or return $null when it is not version-parseable.
# Used uniformly for the required release and every index Release/Build so
# one definition of "[version]-parseable" governs the whole comparison.
#
# NOTE on the bare-major case: the contract maps RequiredRelease '11' to
# major 11, but System.Version requires at least 'major.minor' - probed on
# .NET, both [version]'11' and [version]::TryParse('11') FAIL - so a lone
# integer is widened to '<n>.0'. Everything else is not parseable.
function ConvertTo-ImageVersion {
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    try { return [version]$s } catch { }
    if ($s -match '^\d+$') {
        try { return [version]($s + '.0') } catch { return $null }
    }
    return $null
}

function Test-ImageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Image,
        [string]$RequiredRelease = '11',
        [string]$RequiredArchitecture = 'x64',
        [string]$RequiredLanguage = 'en-US'
    )

    $errors = New-Object System.Collections.Generic.List[string]

    # Fail closed on a nonsensical requirement before judging any data: a
    # requirement we cannot parse is a caller bug, not an image defect.
    $requiredVersion = ConvertTo-ImageVersion -Value $RequiredRelease
    if ($null -eq $requiredVersion) {
        throw ("RequiredRelease '{0}' is not a parseable version." -f $RequiredRelease)
    }

    $indexes = Get-IndexField -Record $Image -Name 'Indexes'
    if ($null -eq $indexes) { $indexList = @() } else { $indexList = @($indexes) }

    # Empty/missing Indexes never passes silently: one error, no indexes to
    # describe, and the Home/Pro absence is implied by having no indexes.
    if ($indexList.Count -eq 0) {
        $errors.Add('Image metadata contains no indexes.')
        return @{
            Valid      = $false
            Errors     = $errors.ToArray()
            HomeIndex  = $null
            ProIndex   = $null
            IndexRecord = @()
        }
    }

    $homeFound = $false
    $proFound = $false
    $homeIndexName = $null
    $proIndexName = $null
    $indexRecord = New-Object System.Collections.Generic.List[object]

    $position = 0
    foreach ($idx in $indexList) {
        $position++

        # Ruling 2: the recorded index NUMBER prefers the metadata 'Index'
        # field when present and numeric; otherwise it is the 1-based
        # position of the record in the source array.
        $rawIndexNumber = Get-IndexField -Record $idx -Name 'Index'
        $number = $position
        if (Test-IndexNumber -Value $rawIndexNumber) { $number = $rawIndexNumber }

        $name = Get-IndexField -Record $idx -Name 'Name'
        $edition = [string](Get-IndexField -Record $idx -Name 'Edition')

        # Q47: record the exact names and numbers for EVERY index, valid or
        # not, in source order - later stages select from this record.
        $indexRecord.Add([ordered]@{ Index = $number; Name = $name; Edition = $edition })

        $display = Get-IndexDisplayName -Name $name -Number $number

        # Home/Pro presence (Q47: one image carrying BOTH). Edition values
        # 'Home'/'Pro' match case-insensitively (PowerShell -eq semantics);
        # first match supplies the reported index name.
        if (-not $homeFound -and $edition -eq 'Home') {
            $homeFound = $true
            if ($null -ne $name -and [string]$name -ne '') { $homeIndexName = [string]$name }
        }
        if (-not $proFound -and $edition -eq 'Pro') {
            $proFound = $true
            if ($null -ne $name -and [string]$name -ne '') { $proIndexName = [string]$name }
        }

        # Architecture and language consistency. The contract requires every
        # index to equal BOTH the other indexes AND the single required
        # value; per-index equality against one required value implies the
        # pairwise equality, so one per-index check implements both clauses
        # and names the offending index in the error.
        $architecture = [string](Get-IndexField -Record $idx -Name 'Architecture')
        if ($architecture -ne $RequiredArchitecture) {
            $errors.Add(("Index '{0}': Architecture '{1}' does not match required architecture '{2}'." -f
                $display, $architecture, $RequiredArchitecture))
        }
        $language = [string](Get-IndexField -Record $idx -Name 'Language')
        if ($language -ne $RequiredLanguage) {
            $errors.Add(("Index '{0}': Language '{1}' does not match required language '{2}'." -f
                $display, $language, $RequiredLanguage))
        }

        # Release compatibility: every index's Release must be
        # [version]-parseable and its MAJOR must equal the required
        # release's major ('11' -> major 11, i.e. a Windows 11 image).
        $release = Get-IndexField -Record $idx -Name 'Release'
        $releaseVersion = ConvertTo-ImageVersion -Value $release
        if ($null -eq $releaseVersion) {
            $errors.Add(("Index '{0}': Release '{1}' is not a parseable version." -f $display, $release))
        }
        elseif ($releaseVersion.Major -ne $requiredVersion.Major) {
            $errors.Add(("Index '{0}': Release '{1}' (major {2}) does not match required release '{3}' (major {4})." -f
                $display, $release, $releaseVersion.Major, $RequiredRelease, $requiredVersion.Major))
        }

        # Build compatibility, checked only when a Build value is present:
        # parseable, and its major must match THIS index's Release major -
        # cross-release mixing inside one image is invalid (Q47).
        $build = Get-IndexField -Record $idx -Name 'Build'
        if ($null -ne $build) {
            $buildVersion = ConvertTo-ImageVersion -Value $build
            if ($null -eq $buildVersion) {
                $errors.Add(("Index '{0}': Build '{1}' is not a parseable version." -f $display, $build))
            }
            elseif ($null -ne $releaseVersion -and $buildVersion.Major -ne $releaseVersion.Major) {
                $errors.Add(("Index '{0}': Build '{1}' (major {2}) does not match Release '{3}' major {4}; cross-release mixing is invalid." -f
                    $display, $build, $buildVersion.Major, $release, $releaseVersion.Major))
            }
        }
    }

    if (-not $homeFound) {
        $errors.Add('No Home edition index found; the multi-index image must carry both Home and Pro.')
    }
    if (-not $proFound) {
        $errors.Add('No Pro edition index found; the multi-index image must carry both Home and Pro.')
    }

    # Valid is exactly the absence of violations: every failed condition
    # above recorded at least one error.
    return @{
        Valid      = ($errors.Count -eq 0)
        Errors     = $errors.ToArray()
        HomeIndex  = $homeIndexName
        ProIndex   = $proIndexName
        IndexRecord = @($indexRecord.ToArray())
    }
}
