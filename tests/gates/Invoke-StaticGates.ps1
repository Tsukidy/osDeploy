# Static gates for OSDeploy sources. Run after every edit: pwsh tests/gates/Invoke-StaticGates.ps1
[CmdletBinding()]
param(
    [string[]]$Root = @((Join-Path $PSScriptRoot '..\..\src'), (Join-Path $PSScriptRoot '..\..\tests'))
)
Set-StrictMode -Version Latest
$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure { param([string]$Message) $script:failures.Add($Message) }

# --- Check 1: every .ps1/.psm1/.psd1 parses (added in Task 2) ---
# --- Check 2: banned constructs (added in Task 3) ---
# --- Check 3: ASCII-only bytes (added in Task 4) ---

foreach ($f in $failures) { Write-Output "GATE FAIL: $f" }
if ($failures.Count -gt 0) { exit 1 }
Write-Output 'GATES PASS'
exit 0
