@{
    RootModule        = 'OSDeploy.Logging.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '2d71c332-e4a4-40d4-b71e-d07ccc449c3f'
    Author            = 'OSDeploy Suite'
    Description       = 'Per-run log folders, structured event lines, retention, and server-copy semantics.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('New-RunLog', 'Add-LogEvent', 'Invoke-LogRetention', 'Invoke-ServerLogCopy', 'Complete-RunLog')
}
