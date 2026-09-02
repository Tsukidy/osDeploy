# Static gates for OSDeploy sources. Run after every edit: pwsh tests/gates/Invoke-StaticGates.ps1
[CmdletBinding()]
param(
    [string[]]$Root = @((Join-Path $PSScriptRoot '..\..\src'), (Join-Path $PSScriptRoot '..\..\tests'))
)
Set-StrictMode -Version Latest
$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure { param([string]$Message) $script:failures.Add($Message) }

# --- Check 1: every .ps1/.psm1/.psd1 parses (added in Task 2) ---
# fixtures/ holds intentionally broken files: exclude it from default scans, but scan it
# when -Root is explicitly bound so the gate can self-test against those fixtures.
$excludeFixtures = -not $PSBoundParameters.ContainsKey('Root')
$parseRoots = foreach ($r in $Root) { Get-ChildItem -Path $r -Recurse -Include *.ps1, *.psm1, *.psd1 -File |
    Where-Object { -not $excludeFixtures -or $_.FullName -notmatch 'fixtures' } }
foreach ($file in $parseRoots) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($e in $errors) { Add-Failure ("PARSE {0}: {1}" -f $file.FullName, $e.Message) }
}
# --- Check 2: banned constructs (added in Task 3) ---
# PS 5.1 compatibility: reject PS7-only operators in non-comment source text.
# A line ending in "# gate:allow" is exempt (regex pattern strings in this gate,
# or legitimate installer argument strings).
$bannedPatterns = @(
    @{ Pattern = '&&';         Name = 'pipeline chain operator' },    # gate:allow
    @{ Pattern = '\|\|';       Name = 'pipeline chain operator' },    # gate:allow
    @{ Pattern = '\?\?=';      Name = 'null-coalescing assignment' }, # gate:allow
    @{ Pattern = '\?\?';       Name = 'null-coalescing operator' }    # gate:allow
)
foreach ($file in $parseRoots) {
    $lines = @(Get-Content -LiteralPath $file.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '#\s*gate:allow\s*$') { continue }
        $code = ($lines[$i] -split '#')[0]
        foreach ($b in $bannedPatterns) {
            if ($code -match $b.Pattern) { Add-Failure ("BANNED {0}: line {1} uses {2}" -f $file.FullName, ($i + 1), $b.Name) }
        }
        # ternary heuristic: "?" and ":" each surrounded by spaces on the same line
        if ($code -match '[^?]?\s\?\s' -and $code -match '\s:\s') {
            Add-Failure ("BANNED {0}: line {1} looks like a ternary" -f $file.FullName, ($i + 1))
        }
    }
}
# --- Check 3: ASCII-only bytes (added in Task 4) ---
foreach ($file in $parseRoots) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) { Add-Failure ("ASCII {0}: byte 0x{1:x2} at offset {2}" -f $file.FullName, $bytes[$i], $i); break }
    }
}

foreach ($f in $failures) { Write-Output "GATE FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 }
Write-Output 'GATES PASS'
exit 0
