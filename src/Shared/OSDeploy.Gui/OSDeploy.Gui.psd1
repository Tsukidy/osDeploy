@{
    RootModule        = 'OSDeploy.Gui.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'af7f50b7-ec4b-435d-8cdb-84f7f8a87b97'
    Author            = 'OSDeploy Suite'
    Description       = 'One shared WPF/XAML GUI module for every environment (Q99): screen XAML definitions shipped under Screens, a declarative wizard host with clamped navigation, and the STA threading contract that fails fast with relaunch guidance before any WPF type is touched.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Assert-STA', 'Get-Screen', 'New-WizardHost', 'Invoke-WizardStep')
}
