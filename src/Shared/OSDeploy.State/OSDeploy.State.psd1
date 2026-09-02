@{
    RootModule        = 'OSDeploy.State.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4b531d76-25e2-4145-be03-f0f35768ea61'
    Author            = 'OSDeploy Suite'
    Description       = 'Atomic JSON state writes and state-file contract validation.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Write-AtomicJson', 'Read-JsonFile', 'Test-ReadinessRecord', 'Test-DeploymentState', 'Test-FactoryProfile', 'Update-FactoryProfile', 'Restore-FactoryProfile')
}
