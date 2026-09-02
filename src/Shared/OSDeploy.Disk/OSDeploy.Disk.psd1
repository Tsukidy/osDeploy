@{
    RootModule        = 'OSDeploy.Disk.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '30ed9232-1116-43e3-be7a-cf9bc0682ff3'
    Author            = 'OSDeploy Suite'
    Description       = 'Disk inventory presentation, Q4 primary-disk selection, Q5 removable blocking, Q6 Emergency Bypass audit, Q12/Q87 identity revalidation, and Q79-Q82 capacity rules; pure logic over injected records.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-DiskPresentation', 'Select-PrimaryDisk', 'Test-RemovableBlocking', 'Invoke-EmergencyBypass', 'Compare-DiskIdentity', 'Test-Capacity')
}
