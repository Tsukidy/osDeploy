@{
    RootModule        = 'OSDeploy.Orchestrator.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '574ce367-30bb-4cc2-9442-a5012d23b6a6'
    Author            = 'OSDeploy Suite'
    Description       = 'Orchestrator entry, single-instance lock, checkpoint engine, attempt policy, idempotent resume, reboot handling, integrity recheck, local-only repair, completion gating with scoped cleanup, the pattern-matched driver phase with dry-run, the manifest-driven application phase with retries and the acknowledgement payload, the EZT workflow specifics: registry-sync unattend autologon fragment, account plan, one-shot password transition, and the activation-flow decision payload, the MMC workflow specifics: Audit-Mode finalize with sysprep failure routing, the no-account plan, and the Energy Star power-policy decision table, and the scoped Windows Update phase with configurable cycles, warn-and-acknowledge leftovers, and the offline skip, and the final validation with one-warning device findings, the result-state truth table, boot-entry registration with override clearing, the summary log gate, the phase sequence constant, and the phase-sequence conductor that walks PHASE_ORDER to completion.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Enter-Orchestrator', 'New-Checkpoint', 'Get-ResumePoint', 'Get-OrchestratorMutex',
        'Set-OrchestrationContext', 'Set-OrchestrationRestartRequested', 'Invoke-WithAttempts', 'Invoke-Phase',
        'Resume-AfterReboot', 'New-IntegrityRecord', 'Test-Integrity', 'Repair-FromLocalSource',
        'Invoke-Cleanup', 'Complete-Deployment', 'Invoke-PostCompletionRestart',
        'Find-DriverInstallers', 'Invoke-DriverPhase', 'Invoke-ApplicationPhase',
        'New-EztUnattend', 'Invoke-EztAccountPhase', 'Invoke-PasswordTransition', 'Invoke-ActivationFlow',
        'Get-MmcPlan', 'Invoke-MmcFinalize', 'Resolve-PowerPolicy',
        'Get-UpdateScope', 'Invoke-UpdatePhase',
        'Get-PhaseOrder', 'Invoke-PnpValidation', 'Get-TechnicianReviewOptions', 'Resolve-ResultState',
        'Invoke-BootEntryRegistration', 'Invoke-LogFinalization', 'Invoke-DeploymentSequence')
}
