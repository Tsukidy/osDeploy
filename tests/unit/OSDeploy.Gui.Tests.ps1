BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Gui\OSDeploy.Gui.psd1') -Force
    $script:screensDir = Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Gui\Screens'
    $script:presentationNs = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
}

Describe 'STA threading contract (Q99)' {
    It 'fails fast with InvalidOperationException and STA relaunch guidance on a non-STA thread' {
        # Linux pwsh reports MTA or Unknown for the apartment state - never
        # STA - so this box exercises the fail-closed branch deterministically.
        [System.Threading.Thread]::CurrentThread.GetApartmentState() | Should -Not -Be ([System.Threading.ApartmentState]::STA)
        $err = { Assert-STA } | Should -Throw -PassThru
        $err.Exception | Should -BeOfType ([System.InvalidOperationException])
        $err.Exception.Message | Should -Match 'STA'
        $err.Exception.Message | Should -Match 'powershell\.exe -STA'
    }
    It 'emits no output when the thread is already STA' {
        # STA threads cannot be created on Unix, so the success branch (the
        # absence of any throw or output) is not exercisable on this box.
        Set-ItResult -Skipped -Because 'STA threads cannot be created on Linux pwsh; success branch hand-verified'
    }
}

Describe 'module import hygiene (D10: no WPF at import)' {
    It 'imports without loading WPF assemblies' {
        # The module contract: PresentationFramework and friends may only be
        # touched inside Show- functions called on Windows - and none exist
        # yet. The BeforeAll import already proved import succeeds on Linux.
        $wpf = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
            $_.FullName -match '^(PresentationFramework|PresentationCore|WindowsBase)'
        }
        $wpf | Should -BeNullOrEmpty
    }
}

Describe 'screen definitions (Q99 one shared module; Q100 ASCII)' {
    It 'Get-Screen returns well-formed Window-rooted XAML for TechnicianReview with its exact buttons' {
        $xaml = Get-Screen -Name 'TechnicianReview'
        $xaml | Should -BeOfType ([string])
        $doc = [xml]$xaml
        $doc.DocumentElement.Name | Should -Be 'Window'
        $doc.DocumentElement.NamespaceURI | Should -Be $presentationNs
        foreach ($button in @('Rescan Devices', 'Rerun Validation', 'Continue')) {
            $xaml | Should -Match ([regex]::Escape($button))
        }
        @($doc.GetElementsByTagName('Button')).Count | Should -Be 3
        @($doc.GetElementsByTagName('ListBox')).Count | Should -Be 1
    }
    It 'AcknowledgeContinue carries the Q26 fields, one Acknowledge checkbox, Continue and Cancel' {
        $xaml = Get-Screen -Name 'AcknowledgeContinue'
        $doc = [xml]$xaml
        $doc.DocumentElement.Name | Should -Be 'Window'
        $doc.DocumentElement.NamespaceURI | Should -Be $presentationNs
        foreach ($expected in @('Acknowledge', 'Continue', 'Cancel')) {
            $xaml | Should -Match ([regex]::Escape($expected))
        }
        # Q26 shape: program, status, error or exit code, log location fields
        # (named TextBlocks the host fills at run time).
        $fieldNames = @($doc.GetElementsByTagName('TextBlock') | ForEach-Object { $_.GetAttribute('Name') })
        foreach ($field in @('ProgramText', 'StatusText', 'ErrorText', 'LogText')) {
            $fieldNames | Should -Contain $field
        }
        @($doc.GetElementsByTagName('CheckBox')).Count | Should -Be 1
        @($doc.GetElementsByTagName('Button')).Count | Should -Be 2
    }
    It 'NotedIssuesSummary has an issues ListBox, exactly one acknowledgement checkbox, Finish Deployment only' {
        $xaml = Get-Screen -Name 'NotedIssuesSummary'
        $doc = [xml]$xaml
        $doc.DocumentElement.Name | Should -Be 'Window'
        $doc.DocumentElement.NamespaceURI | Should -Be $presentationNs
        @($doc.GetElementsByTagName('ListBox')).Count | Should -Be 1
        @($doc.GetElementsByTagName('CheckBox')).Count | Should -Be 1
        @($doc.GetElementsByTagName('Button')).Count | Should -Be 1
        $xaml | Should -Match ([regex]::Escape('Finish Deployment'))
    }
    It 'every shipped screen file is pure ASCII' {
        $files = @(Get-ChildItem -LiteralPath $screensDir -Filter '*.xaml' -File)
        $files.Count | Should -Be 3
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }
    It 'throws for an unknown screen name and rejects path-shaped names' {
        { Get-Screen -Name 'NoSuchScreen' } | Should -Throw
        { Get-Screen -Name '..\..\boot\BCD' } | Should -Throw
        { Get-Screen -Name '../etc/passwd' } | Should -Throw
    }
    It 'throws when a screen file is not well-formed XML' {
        # A planted corrupt screen must fail closed rather than reach a host.
        # The probe name must be alnum-leading so the whitelist admits it and
        # the corrupt file is actually read and parsed: an underscore-leading
        # name would throw at name validation and never exercise the [xml]
        # branch this test exists to cover. The message assertion pins the
        # invalid-XML branch specifically, not just any throw.
        $probe = Join-Path $screensDir 'ProbeInvalid.xaml'
        try {
            Set-Content -LiteralPath $probe -Value '<Window><Unclosed>' -Encoding Ascii
            $err = { Get-Screen -Name 'ProbeInvalid' } | Should -Throw -PassThru
            $err.Exception.Message | Should -Match 'not well-formed XML'
        }
        finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'wizard host navigation' {
    It 'New-WizardHost starts at index 0 on the first screen of the given sequence' {
        $wizard = New-WizardHost -Screens @('TechnicianReview', 'AcknowledgeContinue')
        ($wizard.Screens -join '|') | Should -Be 'TechnicianReview|AcknowledgeContinue'
        $wizard.Index | Should -Be 0
        $wizard.Current | Should -Be 'TechnicianReview'
    }
    It 'walks a two-screen sequence forward and back with clamped bounds' {
        $wizard = New-WizardHost -Screens @('TechnicianReview', 'AcknowledgeContinue')
        $null = Invoke-WizardStep -Host $wizard -Direction Next
        $wizard.Index | Should -Be 1
        $wizard.Current | Should -Be 'AcknowledgeContinue'
        # Forward clamp: a second Next stays on the last screen.
        $null = Invoke-WizardStep -Host $wizard -Direction Next
        $wizard.Index | Should -Be 1
        $wizard.Current | Should -Be 'AcknowledgeContinue'
        $null = Invoke-WizardStep -Host $wizard -Direction Back
        $wizard.Index | Should -Be 0
        $wizard.Current | Should -Be 'TechnicianReview'
        # Backward clamp: a second Back stays on the first screen.
        $null = Invoke-WizardStep -Host $wizard -Direction Back
        $wizard.Index | Should -Be 0
        $wizard.Current | Should -Be 'TechnicianReview'
    }
    It 'returns the same host object it advanced' {
        $wizard = New-WizardHost -Screens @('TechnicianReview', 'AcknowledgeContinue')
        $result = Invoke-WizardStep -Host $wizard -Direction Next
        [object]::ReferenceEquals($result, $wizard) | Should -BeTrue
        $result.Current | Should -Be 'AcknowledgeContinue'
    }
    It 'a single-screen host clamps in both directions' {
        $wizard = New-WizardHost -Screens @('NotedIssuesSummary')
        $null = Invoke-WizardStep -Host $wizard -Direction Next
        $null = Invoke-WizardStep -Host $wizard -Direction Back
        $wizard.Index | Should -Be 0
        $wizard.Current | Should -Be 'NotedIssuesSummary'
    }
    It 'throws for an unknown direction' {
        $wizard = New-WizardHost -Screens @('TechnicianReview', 'AcknowledgeContinue')
        { Invoke-WizardStep -Host $wizard -Direction 'Sideways' } | Should -Throw
    }
}
