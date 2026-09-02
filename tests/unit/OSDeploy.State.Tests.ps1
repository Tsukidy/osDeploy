BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.State\OSDeploy.State.psd1') -Force
    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ('state-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
}
AfterAll { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
Describe 'atomic writes' {
    It 'replaces content completely and leaves no temp files' {
        $p = Join-Path $dir 's.json'
        Write-AtomicJson -Path $p -Value @{ a = 1 }
        Write-AtomicJson -Path $p -Value @{ a = 2; b = 'x' }
        (Read-JsonFile -Path $p).a | Should -Be 2
        (Get-ChildItem $dir -Filter '*.tmp*').Count | Should -Be 0
    }
    It 'a failed move leaves the previous document intact' {
        $p = Join-Path $dir 't.json'
        Write-AtomicJson -Path $p -Value @{ a = 1 }
        # Forced deviation (one token) from the brief: an It-scope function is not
        # visible to module session-state code on pwsh 7.4.2 / Pester 5.9.1 (probed:
        # the real cmdlet ran instead), so the override must be global for the
        # module's Move-Item call to resolve to it. The brief's own Remove-Item line
        # below removes it correctly and later tests are unaffected (probed).
        function global:Move-Item { param($Path, $Destination, $Force) throw 'simulated interruption' }
        { Write-AtomicJson -Path $p -Value @{ a = 2 } } | Should -Throw
        Remove-Item Function:\Move-Item
        (Read-JsonFile -Path $p).a | Should -Be 1
    }
}
Describe 'contracts' {
    It 'DeploymentState requires all identity and phase fields' {
        $ok = @{ RunId = 'r1'; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
                 Phase = 'Drivers'; Attempt = 1; RebootPending = $false; ConfigVersion = 'v1'
                 TimestampUtc = '2026-01-01T00:00:00Z'; CompletedPhases = @(); Result = $null
                 NotedIssues = @(); Acknowledgements = @() }
        (Test-DeploymentState -Record $ok).Valid | Should -BeTrue
        $bad = $ok.Clone(); $bad.Workflow = $null
        (Test-DeploymentState -Record $bad).Valid | Should -BeFalse
    }
    It 'FactoryProfile restore prefers active, then backup, else Invalid without guessing' {
        $prof = @{ SchemaVersion = 1; MachineId = 'm1'; Workflow = 'EZT'; FactoryEdition = 'Home'
                   DefaultRecoveryEdition = 'Home'; EditionHistory = @(); EnergyStar = @{ }
                   Locale = 'en-US'; CreatedUtc = '2026-01-01T00:00:00Z'; LastRecoveryUtc = $null }
        Update-FactoryProfile -Directory $dir -Profile $prof
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Active'
        Remove-Item (Join-Path $dir 'FactoryProfile.json')
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Restored'
        # Forced deviation (one added line) from the brief: the Restored step copies
        # the backup over the active file (plan Step 3 mandates this), so the active
        # file exists again and must also be removed before asserting Invalid.
        Remove-Item (Join-Path $dir 'FactoryProfile.json')
        Remove-Item (Join-Path $dir 'FactoryProfile.lastknowngood.json')
        (Restore-FactoryProfile -Directory $dir).Status | Should -Be 'Invalid'
    }
}
Describe 'readiness record contract (state-files spec)' {
    It 'valid record passes with no errors and every required field is enforced' {
        $ok = @{ RunId = 'r1'; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
                 ConfigVersion = 'v1'; BundleHash = 'A1B2C3D4'; TimestampUtc = '2026-01-01T00:00:00Z' }
        $r = Test-ReadinessRecord -Record $ok
        $r.Valid | Should -BeTrue
        $r.Errors.Count | Should -Be 0
        foreach ($f in @('RunId', 'MachineId', 'DiskId', 'Workflow', 'Edition', 'ConfigVersion', 'BundleHash', 'TimestampUtc')) {
            $bad = $ok.Clone(); $bad.$f = $null
            $br = Test-ReadinessRecord -Record $bad
            $br.Valid | Should -BeFalse
            ($br.Errors -join ';') | Should -Match ([regex]::Escape($f))
        }
    }
    It 'empty-string required values are invalid, never defaulted' {
        $bad = @{ RunId = ''; MachineId = ''; DiskId = ''; Workflow = ''; Edition = ''
                  ConfigVersion = ''; BundleHash = ''; TimestampUtc = '' }
        $r = Test-ReadinessRecord -Record $bad
        $r.Valid | Should -BeFalse
        $r.Errors.Count | Should -Be 8
    }
}
Describe 'deployment state contract (state-files spec)' {
    It 'identity and structural fields are required non-null; lifecycle fields must exist but may be null' {
        $base = @{ RunId = 'r1'; MachineId = 'm1'; DiskId = 'd1'; Workflow = 'EZT'; Edition = 'Pro'
                   Phase = 'Drivers'; Attempt = 1; RebootPending = $false; ConfigVersion = 'v1'
                   TimestampUtc = '2026-01-01T00:00:00Z'; CompletedPhases = @(); Result = $null
                   NotedIssues = @(); Acknowledgements = @() }
        foreach ($f in @('RunId', 'MachineId', 'DiskId', 'Workflow', 'Edition', 'Phase', 'ConfigVersion', 'TimestampUtc')) {
            $bad = $base.Clone(); $bad.$f = $null
            (Test-DeploymentState -Record $bad).Valid | Should -BeFalse
        }
        foreach ($f in @('Attempt', 'RebootPending', 'CompletedPhases', 'Result', 'NotedIssues', 'Acknowledgements')) {
            $bad = $base.Clone(); $bad.Remove($f)
            $br = Test-DeploymentState -Record $bad
            $br.Valid | Should -BeFalse
            ($br.Errors -join ';') | Should -Match ([regex]::Escape($f))
        }
        $nullOk = $base.Clone()
        $nullOk.Attempt = $null; $nullOk.RebootPending = $null; $nullOk.CompletedPhases = $null
        $nullOk.Result = $null; $nullOk.NotedIssues = $null; $nullOk.Acknowledgements = $null
        (Test-DeploymentState -Record $nullOk).Valid | Should -BeTrue
    }
}
Describe 'factory profile contract (state-files spec)' {
    It 'valid profile passes and every required field is enforced without defaults' {
        $ok = @{ SchemaVersion = 1; MachineId = 'm1'; Workflow = 'EZT'; FactoryEdition = 'Home'
                 DefaultRecoveryEdition = 'Home'; CreatedUtc = '2026-01-01T00:00:00Z'
                 EditionHistory = @(); EnergyStar = @{ }; Locale = 'en-US'; LastRecoveryUtc = $null }
        $r = Test-FactoryProfile -Record $ok
        $r.Valid | Should -BeTrue
        $r.Errors.Count | Should -Be 0
        foreach ($f in @('MachineId', 'Workflow', 'FactoryEdition', 'DefaultRecoveryEdition', 'SchemaVersion', 'CreatedUtc')) {
            $bad = $ok.Clone(); $bad.$f = $null
            $br = Test-FactoryProfile -Record $bad
            $br.Valid | Should -BeFalse
            ($br.Errors -join ';') | Should -Match ([regex]::Escape($f))
        }
    }
}
Describe 'factory profile update and restore (state-files spec)' {
    It 'first update seeds the LKG copy, later updates refresh LKG from the previous active first' {
        $pdir = Join-Path $dir 'profiles'
        New-Item -ItemType Directory -Path $pdir | Out-Null
        $v1 = @{ SchemaVersion = 1; MachineId = 'm1'; Workflow = 'EZT'; FactoryEdition = 'Home'
                 DefaultRecoveryEdition = 'Home'; CreatedUtc = '2026-01-01T00:00:00Z'
                 EditionHistory = @(); EnergyStar = @{ }; Locale = 'en-US'; LastRecoveryUtc = $null }
        $v2 = $v1.Clone(); $v2.FactoryEdition = 'Pro'; $v2.CreatedUtc = '2026-02-02T00:00:00Z'
        Update-FactoryProfile -Directory $pdir -Profile $v1
        Test-Path (Join-Path $pdir 'FactoryProfile.json') | Should -BeTrue
        Test-Path (Join-Path $pdir 'FactoryProfile.lastknowngood.json') | Should -BeTrue
        (Read-JsonFile -Path (Join-Path $pdir 'FactoryProfile.lastknowngood.json')).FactoryEdition | Should -Be 'Home'
        Update-FactoryProfile -Directory $pdir -Profile $v2
        (Read-JsonFile -Path (Join-Path $pdir 'FactoryProfile.lastknowngood.json')).FactoryEdition | Should -Be 'Home'
        (Read-JsonFile -Path (Join-Path $pdir 'FactoryProfile.json')).FactoryEdition | Should -Be 'Pro'
    }
    It 'corrupt active copy is restored from backup with a warning event and no guessing' {
        $pdir = Join-Path $dir 'profiles-corrupt'
        New-Item -ItemType Directory -Path $pdir | Out-Null
        $prof = @{ SchemaVersion = 1; MachineId = 'm1'; Workflow = 'EZT'; FactoryEdition = 'Home'
                   DefaultRecoveryEdition = 'Home'; CreatedUtc = '2026-01-01T00:00:00Z'
                   EditionHistory = @(); EnergyStar = @{ }; Locale = 'en-US'; LastRecoveryUtc = $null }
        Update-FactoryProfile -Directory $pdir -Profile $prof
        Set-Content -Path (Join-Path $pdir 'FactoryProfile.json') -Value 'not json at all' -Encoding Ascii
        $r = Restore-FactoryProfile -Directory $pdir
        $r.Status | Should -Be 'Restored'
        $r.Warning | Should -Be 'FactoryProfileRestoredFromBackup'
        $r.Profile | Should -Not -BeNullOrEmpty
        $repaired = Read-JsonFile -Path (Join-Path $pdir 'FactoryProfile.json')
        (Test-FactoryProfile -Record $repaired).Valid | Should -BeTrue
        $repaired.FactoryEdition | Should -Be 'Home'
    }
    It 'both copies invalid stops as Invalid with no profile and no warning' {
        $pdir = Join-Path $dir 'profiles-dead'
        New-Item -ItemType Directory -Path $pdir | Out-Null
        Set-Content -Path (Join-Path $pdir 'FactoryProfile.json') -Value 'not json at all' -Encoding Ascii
        Set-Content -Path (Join-Path $pdir 'FactoryProfile.lastknowngood.json') -Value 'not json at all' -Encoding Ascii
        $r = Restore-FactoryProfile -Directory $pdir
        $r.Status | Should -Be 'Invalid'
        $r.Profile | Should -BeNullOrEmpty
        $r.Warning | Should -BeNullOrEmpty
    }
    It 'a failed atomic write leaves no temp file behind' {
        $p = Join-Path $dir 'tmpclean.json'
        Write-AtomicJson -Path $p -Value @{ a = 1 }
        function global:Move-Item { param($Path, $Destination, $Force) throw 'simulated interruption' }
        { Write-AtomicJson -Path $p -Value @{ a = 2 } } | Should -Throw
        Remove-Item Function:\Move-Item
        (Get-ChildItem $dir -Filter '*.tmp*').Count | Should -Be 0
    }
}
