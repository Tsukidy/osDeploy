@{
    RootModule        = 'OSDeploy.Util.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7f0b3e2-2c4d-4b9a-9f0e-1a2b3c4d5e6f'
    Author            = 'OSDeploy Suite'
    Description       = 'Hashing, file inventory, and canonical bundle hash helpers.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-FileSha256', 'New-FileInventory', 'Get-BundleHash')
}
