@{
    RootModule        = 'OSDeploy.Disk.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '30ed9232-1116-43e3-be7a-cf9bc0682ff3'
    Author            = 'OSDeploy Suite'
    Description       = 'Disk inventory presentation and Q4 primary-disk selection; pure logic over injected inventory records.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-DiskPresentation', 'Select-PrimaryDisk')
}
