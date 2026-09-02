<#
.SYNOPSIS
    Recreates the directory structure for the MDT driver share.
.DESCRIPTION
    This script rebuilds the layout of the driver share folder structure
    needed by the autoAll.ps1 installation script. It determines the target
    location based on its current directory by default, but also accepts
    a custom target path.
.PARAMETER Path
    The target directory where the driver share layout should be created.
    Defaults to the directory containing this script ($PSScriptRoot).
.EXAMPLE
    .\RecreateDriverShare.ps1
.EXAMPLE
    .\RecreateDriverShare.ps1 -Path "D:\MDTShare"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Path = $PSScriptRoot
)

# Resolve path to ensure absolute path syntax and clean up any relative references
if ([System.IO.Path]::IsPathRooted($Path)) {
    $TargetRoot = $Path
} else {
    $TargetRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $Path))
}

Write-Host "Determined target directory: $TargetRoot" -ForegroundColor Cyan

# Define the folder structure required by autoAll.ps1
$FoldersToCreate = @(
    "Drivers",
    "Drivers\Video\AMD",
    "Drivers\Video\Intel",
    "Drivers\Video\NVIDIA\Geforce",
    "Drivers\Video\NVIDIA\GeforceOLD",
    "Drivers\Video\NVIDIA\Quadro",
    "Drivers\Chipset",
    "Drivers\Chipset\SampleMotherboardModel",
    "Drivers\Chipset\SampleMotherboardModel\Chipset",
    "Drivers\Chipset\SampleMotherboardModel\LAN",
    "Drivers\Chipset\SampleMotherboardModel\Audio",
    "Drivers\Chipset\SampleMotherboardModel\WiFi"
)

# Recreate folders
foreach ($Folder in $FoldersToCreate) {
    $FullPath = Join-Path -Path $TargetRoot -ChildPath $Folder
    if (!(Test-Path -Path $FullPath)) {
        Write-Host "Creating folder: $Folder" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $FullPath -Force | Out-Null
    } else {
        Write-Host "Folder already exists: $Folder" -ForegroundColor DarkGray
    }
}

# Create README_SHARE.txt in the root of the share to guide users
$ReadmePath = Join-Path -Path $TargetRoot -ChildPath "README_SHARE.txt"
$ReadmeContent = @"
MDT Driver Share Layout
=======================

This folder structure was recreated to match the requirements of the deployment installation script 'autoAll.ps1'.

How to populate this share:
--------------------------

1. GPU Drivers (Drivers\Video):
   - AMD: Copy the AMD GPU installation files here. Note that 'autoAll.ps1' checks for a subfolder named 'bin64' containing 'cccmanifest_64.json' to check the driver version, and copies the contents to run 'Setup.exe' or 'Installer.exe'.
   - Intel: Copy the Intel GPU installation files here. Note that 'autoAll.ps1' reads a file named 'readme.txt' to extract the driver version using the line format "driver version: <version_number>". It expects an executable 'Installer.exe' under this directory to perform the installation.
   - NVIDIA:
     - Geforce: Create folders named with the version prefix (e.g., '555.99-desktop-win10-win11-64bit...') containing the Geforce setup.exe.
     - GeforceOLD: Create folders named with the version prefix containing the older Geforce setup.exe.
     - Quadro: Create folders named with the version prefix containing the Quadro setup.exe.

2. Motherboard Chipset Drivers (Drivers\Chipset):
   - Under 'Drivers\Chipset', create a folder matching the Motherboard Model.
     The motherboard model is determined dynamically in 'autoAll.ps1' by querying the Win32_Baseboard Product and removing non-alphanumeric characters:
     `$MB_MODEL = (Get-CimInstance -ClassName Win32_Baseboard).Product -Replace "[^a-zA-Z0-9]", ""`
   - Within each motherboard model folder, place subfolders containing individual driver installers (e.g., Chipset, LAN, Audio, WiFi). The name of these subfolders does not matter, but 'autoAll.ps1' recursively searches them for executables or MSI packages.
   - See the 'SampleMotherboardModel' folder for an example structure.

"@

Write-Host "Creating README_SHARE.txt..." -ForegroundColor Yellow
Set-Content -Path $ReadmePath -Value $ReadmeContent -Encoding UTF8

Write-Host "`nDriver share layout recreated successfully!" -ForegroundColor Green
