Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# OSDeploy.Gui - the ONE shared GUI module for every environment (Q99).
#
# D10 invariant: this module must import cleanly on any host, including Linux
# pwsh and MTA WinPE defaults. It therefore loads NO WPF assemblies at import
# and references NO WPF types outside Show- functions (which do not exist yet;
# rendering is verified on the Windows VM). Screens are declarative data -
# XAML files in the Screens directory beside this module - and everything
# testable without WPF (the STA contract, screen loading, wizard navigation)
# lives here as plain logic.
# ---------------------------------------------------------------------------

# Screen XAML definitions ship beside this module.
$script:ScreenDirectory = Join-Path $PSScriptRoot 'Screens'

# ---------------------------------------------------------------------------
# STA threading contract (Q99): WPF controls can only be created on an STA
# thread. Anything other than STA fails fast BEFORE any WPF type is touched,
# with the relaunch guidance the environment launcher must satisfy (the WinPE
# default can be MTA, so the WinPE launcher invokes powershell.exe -STA;
# installed Windows PowerShell is STA by default).
# ---------------------------------------------------------------------------

function Assert-STA {
    # Emits no output and throws nothing when the thread is already STA.
    [CmdletBinding()]
    param()
    # On Linux pwsh this reports Unknown rather than MTA, so anything that is
    # not exactly STA is treated as the fail-closed case.
    $state = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($state -ne [System.Threading.ApartmentState]::STA) {
        $message = 'The OSDeploy GUI host requires an STA thread, but the current apartment state is ' +
            "'$state' (Q99). Relaunch through an STA host before any WPF control is created, for example: " +
            'powershell.exe -STA'
        throw [System.InvalidOperationException]::new($message)
    }
}

# ---------------------------------------------------------------------------
# Screen loading (Q99: one shared module, screens are data). The content is
# validated as well-formed XML before it is returned so a corrupted screen
# definition can never reach a host.
# ---------------------------------------------------------------------------

function Get-Screen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    # Screen names are plain file stems: reject path-shaped or decorated names
    # outright so -Name can never traverse out of the Screens directory.
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid screen name '$Name': a screen name is a plain file name without path separators."
    }
    $path = Join-Path $script:ScreenDirectory ($Name + '.xaml')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Unknown screen '$Name': no '$Name.xaml' exists in the Screens directory."
    }
    $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::ASCII)
    try {
        $null = [xml]$content
    }
    catch {
        throw "Screen '$Name' is not well-formed XML: $($_.Exception.Message)"
    }
    return $content
}

# ---------------------------------------------------------------------------
# Wizard host (Q99: screen order and navigation are data driven by the host).
# ---------------------------------------------------------------------------

function New-WizardHost {
    # Creates the wizard host state for a screen sequence. Index and Current
    # are maintained by Invoke-WizardStep. Mandatory already rejects an empty
    # screen list (a wizard with no screens has no first screen to sit on),
    # which is the fail-closed path for that caller bug.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Screens
    )
    return @{
        Screens = $Screens
        Index   = 0
        Current = $Screens[0]
    }
}

function Invoke-WizardStep {
    # Advances (or retreats) a wizard host created by New-WizardHost and
    # returns the SAME host object, mutated in place.
    #
    # The contract names the parameter -Host. A parameter literally named
    # $Host cannot bind ($Host is a read-only automatic variable), so the
    # parameter is named WizardHost and carries [Alias('Host')]: callers use
    # exactly Invoke-WizardStep -Host <object> as specified, and the
    # automatic $Host variable is never shadowed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Alias('Host')]
        $WizardHost,
        [string]$Direction = 'Next'
    )
    foreach ($key in @('Screens', 'Index', 'Current')) {
        if (-not $WizardHost.ContainsKey($key)) {
            throw "Invalid wizard host: required key '$key' is missing."
        }
    }
    # Clamped navigation (switch matches the direction names
    # case-insensitively): Next never passes the last screen, Back never
    # passes the first, so Current always resolves in bounds.
    switch ($Direction) {
        'Next' {
            if ($WizardHost.Index -lt $WizardHost.Screens.Count - 1) {
                $WizardHost.Index = $WizardHost.Index + 1
            }
        }
        'Back' {
            if ($WizardHost.Index -gt 0) {
                $WizardHost.Index = $WizardHost.Index - 1
            }
        }
        default {
            throw "Unknown wizard direction '$Direction': expected 'Next' or 'Back'."
        }
    }
    $WizardHost.Current = $WizardHost.Screens[$WizardHost.Index]
    return $WizardHost
}
