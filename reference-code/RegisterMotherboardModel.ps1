<#
.SYNOPSIS
    Queries the current computer's motherboard model and creates the corresponding
    folder structure on the deployment driver share to prep it for new drivers.
.DESCRIPTION
    This script is run on a unit being deployed. It connects to the deployment
    driver share, queries the unit's motherboard details, formats the
    motherboard name exactly as expected by autoAll.ps1, and creates the
    model-specific directories under the Drivers\Chipset folder.
    
    If run from within the share, it auto-detects the share path. Otherwise,
    it maps the share to Y: using TechserverZ (primary) or x79 (secondary).
.PARAMETER DryRun
    If specified, the script only performs queries and prints the actions it
    would take, without mapping drives or creating directories.
.PARAMETER TestPath
    An alternate local directory path to use instead of mapping the network share.
    Useful for offline testing.
.PARAMETER NoMount
    If specified, the script skips the network mapping phase and assumes Y:
    is already mapped or accessible.
.PARAMETER Mock
    If specified, the script will use test/mock hardware details (an MSI motherboard)
    if the local motherboard query fails. Recommended for non-Windows testing.
.EXAMPLE
    .\RegisterMotherboardModel.ps1
.EXAMPLE
    .\RegisterMotherboardModel.ps1 -DryRun
.EXAMPLE
    .\RegisterMotherboardModel.ps1 -TestPath "C:\Temp\DriverShare"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$TestPath,

    [Parameter(Mandatory = $false)]
    [switch]$NoMount,

    [Parameter(Mandatory = $false)]
    [switch]$Mock
)

# Terminate execution on any unexpected errors
$ErrorActionPreference = "Stop"

$DriversDrive = "Y"
$DriversFolderPath = $null

# --- Step 1: Resolve Target Driver Share Path ---
if ($TestPath) {
    # Test path resolution for offline development
    if ([System.IO.Path]::IsPathRooted($TestPath)) {
        $DriversFolderPath = $TestPath
    } else {
        $DriversFolderPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TestPath))
    }
    Write-Host "Running in test mode. Target path set to: $DriversFolderPath" -ForegroundColor Cyan
} elseif ($DryRun) {
    Write-Host "[DryRun] Would evaluate local/network share location." -ForegroundColor Cyan
} else {
    # Check if we are running directly from the share by searching upwards for a "Drivers\Chipset" hierarchy.
    # This prevents redundant drive mapping and handles UNC or existing drive mappings automatically.
    $CurrentPath = $PSScriptRoot
    while ($CurrentPath) {
        $PotentialDriversPath = Join-Path -Path $CurrentPath -ChildPath "Drivers"
        if (Test-Path -Path (Join-Path -Path $PotentialDriversPath -ChildPath "Chipset") -ErrorAction SilentlyContinue) {
            $DriversFolderPath = $CurrentPath
            Write-Host "Auto-detected driver share root from script location: $DriversFolderPath" -ForegroundColor Green
            break
        }
        
        $Parent = Split-Path -Path $CurrentPath -Parent
        if ($Parent -eq $CurrentPath -or [string]::IsNullOrEmpty($Parent)) { break }
        $CurrentPath = $Parent
    }

    # If not found locally, proceed to map/mount the share
    if ($null -eq $DriversFolderPath) {
        if ($NoMount) {
            Write-Host "Skipping share mounting. Assuming drive ${DriversDrive}: is already mounted." -ForegroundColor Cyan
            $DriversFolderPath = "${DriversDrive}:\"
        } else {
            Write-Host "Could not auto-detect local Drivers folder. Resolving network share..." -ForegroundColor Cyan

            # Define the servers in priority order (TechserverZ is primary, x79 is secondary)
            $ShareConfigs = @(
                @{
                    Server = "\\TechserverZ\Drivers"
                    User   = "Planetz\opk"
                    Pass   = "opk"
                    Label  = "TechserverZ (Primary)"
                },
                @{
                    Server = "\\x79\Drivers"
                    User   = "MMTest\opk"
                    Pass   = "opk"
                    Label  = "x79 (Secondary)"
                }
            )

            $ConnectionSuccessful = $false
            
            foreach ($Config in $ShareConfigs) {
                $ServerName = $Config.Server
                Write-Host "Attempting connection to $($Config.Label) at $ServerName..." -ForegroundColor Gray
                
                try {
                    $secpasswd = ConvertTo-SecureString -String $Config.Pass -AsPlainText -Force
                    $Credential = New-Object Management.Automation.PSCredential ($Config.User, $secpasswd)
                    
                    # Cleanup old techserverz connection if present
                    if ($ServerName -like "*TechserverZ*") {
                        if (Test-Path "\\techserverz\drivers" -ErrorAction SilentlyContinue) {
                            Write-Host "Cleaning up old unnamed connection..." -ForegroundColor Gray
                            net use \\techserverz\drivers /delete /y 2>&1 | Out-Null
                        }
                    }
                    
                    # Check if target drive is already mapped
                    if (Test-Path "${DriversDrive}:\" -ErrorAction SilentlyContinue) {
                        Write-Host "Drive ${DriversDrive}: is currently mapped. Unmapping to redirect to $ServerName..." -ForegroundColor Yellow
                        Remove-PSDrive -Name $DriversDrive -Force
                    }
                    
                    # Map the drive
                    Write-Host "Mapping ${DriversDrive}: drive to $ServerName..." -ForegroundColor Yellow
                    New-PSDrive -Name $DriversDrive -PSProvider FileSystem -Root $ServerName -Credential $Credential -Scope Global | Out-Null
                    
                    # Verify key directory structure exists
                    if (Test-Path -Path "${DriversDrive}:\Drivers\Chipset" -ErrorAction SilentlyContinue) {
                        $DriversFolderPath = "${DriversDrive}:\"
                        $ConnectionSuccessful = $true
                        Write-Host "Successfully connected to $ServerName and verified layout." -ForegroundColor Green
                        break
                    } else {
                        Write-Warning "Connected to $ServerName, but '\Drivers\Chipset' was not found."
                        Remove-PSDrive -Name $DriversDrive -Force | Out-Null
                    }
                } catch {
                    Write-Warning "Failed to connect to ${ServerName}: $_"
                    if (Test-Path "${DriversDrive}:\" -ErrorAction SilentlyContinue) {
                        Remove-PSDrive -Name $DriversDrive -Force | Out-Null
                    }
                }
            }
            
            if (!$ConnectionSuccessful) {
                Write-Error "CRITICAL: Unable to locate or connect to any driver share server. Please verify network access." -ErrorAction Stop
            }
        }
    }
}

# --- Step 2: Query Motherboard and Format Model Name ---
Write-Host "`nQuerying motherboard details..." -ForegroundColor Cyan

# Gather motherboard details
$MB_MFG = ""
$RawProduct = ""

try {
    $Motherboard = Get-CimInstance -ClassName Win32_Baseboard -ErrorAction Stop
    $MB_MFG = $Motherboard.Manufacturer
    $RawProduct = $Motherboard.Product
} catch {
    if ($Mock) {
        Write-Warning "Failed to query motherboard via CIM/WMI. Using mock MSI hardware details for testing."
        $MB_MFG = "Micro-Star International Co., Ltd."
        $RawProduct = "MPG Z790 EDGE WIFI (MS-7D91)"
    } else {
        Write-Error "CRITICAL: Failed to query motherboard via CIM/WMI: $_. This script must run on a Windows machine being deployed." -ErrorAction Stop
    }
}

Write-Host "Manufacturer: $MB_MFG" -ForegroundColor Gray
Write-Host "Raw Product:  $RawProduct" -ForegroundColor Gray

# Format the motherboard product name exactly as autoAll.ps1 does
$MB_MODEL = $RawProduct | ForEach-Object { $_ -Replace "[^a-zA-Z0-9]", "" }

# Strip off MSXXXX MSI model suffix if manufacturer matches Micro-Star
if ($MB_MFG -imatch "Micro-star") {
    $MB_MODEL = $MB_MODEL -Replace ".{6}$"
    Write-Host "MSI motherboard detected. Stripped suffix." -ForegroundColor Gray
}

Write-Host "Formatted Model Name (Folder name): $MB_MODEL" -ForegroundColor Green

# --- Step 3: Create Folders on Share ---
if ($DryRun) {
    Write-Host "`n[DryRun] Would write to folder: Drivers\Chipset\$MB_MODEL" -ForegroundColor Yellow
    Write-Host "[DryRun] Complete." -ForegroundColor Green
    exit
}

$ChipsetRootPath = Join-Path -Path $DriversFolderPath -ChildPath "Drivers\Chipset"
$ModelPath = Join-Path -Path $ChipsetRootPath -ChildPath $MB_MODEL

$FoldersToCreate = @(
    "", # Root motherboard directory
    "Chipset",
    "LAN",
    "Audio",
    "WiFi"
)

Write-Host "`nPreparing directory structures on share..." -ForegroundColor Cyan

foreach ($SubFolder in $FoldersToCreate) {
    if ([string]::IsNullOrEmpty($SubFolder)) {
        $FullPath = $ModelPath
        $DisplayPath = "Drivers\Chipset\$MB_MODEL"
    } else {
        $FullPath = Join-Path -Path $ModelPath -ChildPath $SubFolder
        $DisplayPath = "Drivers\Chipset\$MB_MODEL\$SubFolder"
    }

    try {
        if (!(Test-Path -Path $FullPath)) {
            Write-Host "Creating directory: $DisplayPath" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $FullPath -Force | Out-Null
        } else {
            Write-Host "Directory already exists: $DisplayPath" -ForegroundColor DarkGray
        }
    } catch {
        Write-Error "CRITICAL: Failed to create directory ${DisplayPath}: $_" -ErrorAction Stop
    }
}

Write-Host "`nMotherboard registration complete!" -ForegroundColor Green
Write-Host "You can now place the installer files inside: $ModelPath" -ForegroundColor White
