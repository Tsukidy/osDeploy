Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Internal helpers (not exported)
# ---------------------------------------------------------------------------

# Total size in bytes of every file under a directory (recursive). Used by
# retention to compute the local log history footprint.
function Get-DirectoryBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sum = [long]0
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $files) { $sum += $f.Length }
    return $sum
}

# ---------------------------------------------------------------------------
# Run folder creation (Q8, Q73-Q78: the local run folder is the
# AUTHORITATIVE log for every run)
# ---------------------------------------------------------------------------

function New-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RunId = '',
        [string]$RunType = 'InitialDeployment'
    )
    # A caller that passes no RunId still gets a stable, collision-friendly id.
    if ($RunId -eq '') { $RunId = [guid]::NewGuid().ToString('N').Substring(0, 8) }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = '{0}-{1}-{2}' -f $RunType, $stamp, $RunId
    # Collision suffixes -2, -3, ... -99. Fail closed beyond 99: a single
    # second producing one hundred same-id runs is a caller bug worth
    # stopping for, not silently working around.
    $candidate = $base
    $suffix = 1
    while (Test-Path -LiteralPath (Join-Path $Root $candidate)) {
        $suffix++
        if ($suffix -gt 99) {
            throw "Run log folder exhaustion: more than 99 collisions for '$base' under '$Root'."
        }
        $candidate = '{0}-{1}' -f $base, $suffix
    }
    $folder = Join-Path $Root $candidate
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $eventsPath = Join-Path $folder 'events.jsonl'
    $transcriptPath = Join-Path $folder 'transcript.txt'
    # Transcript choice: New-RunLog only creates an empty placeholder file.
    # Starting a real Start-Transcript here would capture and garble host
    # console output (Pester's included), so the caller that owns the console
    # starts its transcript against this path; the placeholder guarantees the
    # path exists and is writable before the run begins. events.jsonl is NOT
    # created here: it appears with the first appended event, so a folder
    # without it is recognizable as an active run.
    [System.IO.File]::WriteAllText($transcriptPath, '', [System.Text.Encoding]::ASCII)
    return @{
        Root           = $Root
        RunId          = $RunId
        Folder         = $folder
        EventsPath     = $eventsPath
        TranscriptPath = $transcriptPath
        RunType        = $RunType
    }
}

# ---------------------------------------------------------------------------
# Structured event lines (Q8: append-only, one ASCII JSON object per line)
# ---------------------------------------------------------------------------

function Add-LogEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Log,
        [string]$Level = 'Info',
        [string]$Event = '',
        [hashtable]$Data = @{}
    )
    # Fixed property order: TimestampUtc, Level, Event, Data. The ordered
    # dictionary keeps ConvertTo-Json emitting them in exactly this order.
    $record = [ordered]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Level        = $Level
        Event        = $Event
        Data         = $Data
    }
    $line = ConvertTo-Json -InputObject $record -Depth 8 -Compress
    # Plain append (the event log is append-only, so no atomic rewrite), ASCII
    # per the repo-wide source rule.
    [System.IO.File]::AppendAllText($Log.EventsPath, $line + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
}

# ---------------------------------------------------------------------------
# Retention (Q73-Q78: oldest-first at LocalLogHistoryMaxMB, never the active
# run folder, which the caller names via -KeepFolder)
# ---------------------------------------------------------------------------

function Invoke-LogRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        # 1024 matches the central configuration default
        # (Logging.LocalLogHistoryMaxMB; only OSDeploy.Config may own
        # defaults). Consumers read that key from the effective
        # configuration and pass it explicitly; the default only exists so a
        # bare call cannot exceed the configured ceiling.
        [int]$MaxMB = 1024,
        [string]$KeepFolder = ''
    )
    if (-not (Test-Path -LiteralPath $Root)) { return }
    # Complete = contains events.jsonl. Folders without it are active runs and
    # are never deletion candidates (they also do not count toward the total).
    $complete = @(Get-ChildItem -LiteralPath $Root -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'events.jsonl')
    })
    if ($complete.Count -eq 0) { return }
    # Oldest first. The folder name embeds the run timestamp
    # (<RunType>-<yyyyMMdd-HHmmss>-<RunId>); a foreign folder that does not
    # match the naming scheme falls back to its LastWriteTime as the key.
    $entries = @()
    foreach ($d in $complete) {
        $key = $d.LastWriteTime.ToString('yyyyMMdd-HHmmss')
        $m = [regex]::Match($d.Name, '(\d{8}-\d{6})')
        if ($m.Success) { $key = $m.Groups[1].Value }
        $entries += [pscustomobject] @{ Key = $key; Name = $d.Name; Full = $d.FullName }
    }
    $ordered = $entries | Sort-Object -Property Key, Name
    $total = [long]0
    foreach ($e in $ordered) { $total += Get-DirectoryBytes -Path $e.Full }
    $budget = [long]$MaxMB * 1MB
    foreach ($e in $ordered) {
        if ($total -le $budget) { break }
        if ($e.Name -eq $KeepFolder) { continue }
        $size = Get-DirectoryBytes -Path $e.Full
        Remove-Item -LiteralPath $e.Full -Recurse -Force
        $total -= $size
    }
}

# ---------------------------------------------------------------------------
# Secondary server copy (Q73: best effort, non-blocking; the local run folder
# stays authoritative). Q74 hard boundary: FactoryRecovery never contacts the
# server for anything, including logs.
# ---------------------------------------------------------------------------

function Invoke-ServerLogCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Log,
        [string]$Destination = ''
    )
    # Guard FIRST, before any path is touched: violating the Q74 boundary is a
    # programming error, so it throws instead of warning.
    if ($Log.RunType -eq 'FactoryRecovery') {
        throw 'Invoke-ServerLogCopy must never be called for a FactoryRecovery run (Q74: Factory Recovery never contacts the server, not even for logs).'
    }
    try {
        # The destination is an already-reachable share directory; a missing
        # destination is the server-unreachable case, which is a warning.
        if (-not (Test-Path -LiteralPath $Destination)) {
            throw "Log copy destination does not exist: '$Destination'."
        }
        # Copy the whole run folder into the destination directory. On pwsh 7
        # Copy-Item -Recurse can create missing destination trees, so the
        # existence pre-check above is what decides reachable vs unreachable.
        Copy-Item -LiteralPath $Log.Folder -Destination $Destination -Recurse -Force -ErrorAction Stop
        return @{ Ok = $true; Warning = $null }
    }
    catch {
        # Any copy failure is a non-blocking warning; never a throw.
        return @{ Ok = $false; Warning = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Final summary gate (Q73: the run summary is only trustworthy when the
# events file re-reads as valid JSONL)
# ---------------------------------------------------------------------------

function Complete-RunLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Log)
    if (-not (Test-Path -LiteralPath $Log.EventsPath)) { return $false }
    $failures = 0
    $lines = [System.IO.File]::ReadAllLines($Log.EventsPath, [System.Text.Encoding]::ASCII)
    foreach ($line in $lines) {
        try { $null = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { $failures++ }
    }
    return ($failures -eq 0)
}
