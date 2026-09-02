@{
    RootModule        = 'OSDeploy.Config.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'bf83a86a-2644-4920-9782-08f6370b0d64'
    Author            = 'OSDeploy Suite'
    Description       = 'Config loading, hard defaults with recorded fallbacks, effective-config snapshots, and recovery-side snapshot loading.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-ConfigDefault', 'Resolve-Config', 'Save-ConfigSnapshot', 'Load-RecoveryConfig')
}
