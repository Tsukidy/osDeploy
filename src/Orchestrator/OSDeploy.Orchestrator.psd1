@{
    RootModule        = 'OSDeploy.Orchestrator.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '574ce367-30bb-4cc2-9442-a5012d23b6a6'
    Author            = 'OSDeploy Suite'
    Description       = 'Orchestrator entry, single-instance lock, checkpoint engine, attempt policy, idempotent resume, and reboot handling.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Enter-Orchestrator', 'New-Checkpoint', 'Get-ResumePoint', 'Get-OrchestratorMutex',
        'Set-OrchestrationContext', 'Set-OrchestrationRestartRequested', 'Invoke-WithAttempts', 'Invoke-Phase',
        'Resume-AfterReboot')
}
