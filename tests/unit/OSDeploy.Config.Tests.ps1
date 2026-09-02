BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Config\OSDeploy.Config.psd1') -Force
    $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) ('cfg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:template = Join-Path $PSScriptRoot '..\..\config\osdeploy-config.json'
}
AfterAll { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
Describe 'resolution and fallbacks' {
    It 'full template resolves every value with no fallbacks' {
        $e = Resolve-Config -ConfigPath $template
        $e.Values.Deployment.RecoveryPartitionSizeMB | Should -Be 32768
        $e.Fallbacks.Count | Should -Be 0
    }
    It 'missing and invalid values fall back with reasons' {
        $cfg = Get-Content $template -Raw | ConvertFrom-Json
        $cfg.Deployment.RecoveryPartitionSizeMB = $null
        $cfg.Logging.LocalLogHistoryMaxMB = -5
        $p = Join-Path $dir 'c.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 6), [System.Text.Encoding]::ASCII)
        $e = Resolve-Config -ConfigPath $p
        $e.Values.Deployment.RecoveryPartitionSizeMB | Should -Be 32768
        $e.Values.Logging.LocalLogHistoryMaxMB | Should -Be 1024
        (($e.Fallbacks | Where-Object { $_.Key -eq 'Logging.LocalLogHistoryMaxMB' }).Reason) | Should -Be 'invalid'
    }
}
Describe 'snapshot and recovery isolation' {
    It 'snapshot round-trips and recovery loader reads only the snapshot' {
        $e = Resolve-Config -ConfigPath $template
        $snap = Join-Path $dir 'snapshot.json'
        Save-ConfigSnapshot -Effective $e -Path $snap
        $r = Load-RecoveryConfig -SnapshotPath $snap
        $r.Values.Deployment.TimeZone | Should -Be $e.Values.Deployment.TimeZone
        (Get-Command Load-RecoveryConfig).Parameters.ContainsKey('ConfigPath') | Should -BeFalse
    }
}
Describe 'unknown keys and ConfigVersion' {
    It 'unknown keys are ignored with a recorded warning' {
        $cfg = Get-Content $template -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName 'Surprise' -NotePropertyValue 'x'
        $cfg.Deployment | Add-Member -NotePropertyName 'Bogus' -NotePropertyValue 1
        $p = Join-Path $dir 'unknown.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 6), [System.Text.Encoding]::ASCII)
        $e = Resolve-Config -ConfigPath $p
        ($e.Warnings -join ';') | Should -Match ([regex]::Escape("Unknown key 'Surprise' ignored"))
        ($e.Warnings -join ';') | Should -Match ([regex]::Escape("Unknown key 'Deployment.Bogus' ignored"))
        $e.Values.Deployment.RecoveryPartitionSizeMB | Should -Be 32768
        $e.Fallbacks.Count | Should -Be 0
    }
    It 'ConfigVersion is carried through, else the result is unversioned' {
        $cfg = Get-Content $template -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName 'ConfigVersion' -NotePropertyValue '2026-09-02.1'
        $p = Join-Path $dir 'ver.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 6), [System.Text.Encoding]::ASCII)
        (Resolve-Config -ConfigPath $p).Version | Should -Be '2026-09-02.1'
        (Resolve-Config -ConfigPath $template).Version | Should -Be '<unversioned>'
    }
}
Describe 'hard defaults (Q83/Q84)' {
    It 'every key has a default and an emptied config resolves entirely to defaults' {
        $scalarDefaults = @{
            'Deployment.RecoveryPartitionSizeMB'       = 32768
            'Deployment.WindowsReToolsPartitionSizeMB' = 1024
            'Deployment.RecommendedPrimaryDriveSizeMB' = 122070
            'Deployment.TimeZone'                      = 'Pacific Standard Time'
            'Logging.LocalLogHistoryMaxMB'             = 1024
            'WindowsUpdate.MaxCycles'                  = 3
        }
        foreach ($k in $scalarDefaults.Keys) { (Get-ConfigDefault -Key $k) | Should -Be $scalarDefaults[$k] }
        @(Get-ConfigDefault -Key 'RegulatedStates') | Should -Be @('CA')
        (Get-ConfigDefault -Key 'CompanyWorkflowMap')['*'] | Should -Be 'MMC'
        $cfg = Get-Content $template -Raw | ConvertFrom-Json
        $cfg.Deployment.RecoveryPartitionSizeMB = $null
        $cfg.Deployment.WindowsReToolsPartitionSizeMB = $null
        $cfg.Deployment.RecommendedPrimaryDriveSizeMB = $null
        $cfg.Deployment.TimeZone = $null
        $cfg.Logging.LocalLogHistoryMaxMB = $null
        $cfg.WindowsUpdate.MaxCycles = $null
        $cfg.RegulatedStates = $null
        $cfg.CompanyWorkflowMap = $null
        $p = Join-Path $dir 'empty.json'
        [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 6), [System.Text.Encoding]::ASCII)
        $e = Resolve-Config -ConfigPath $p
        $e.Values.Deployment.TimeZone | Should -Be 'Pacific Standard Time'
        $e.Values.WindowsUpdate.MaxCycles | Should -Be 3
        @($e.Values.RegulatedStates) | Should -Be @('CA')
        ($e.Values.CompanyWorkflowMap)['*'] | Should -Be 'MMC'
        $e.Fallbacks.Count | Should -Be 8
        @($e.Fallbacks | Where-Object { $_.Reason -ne 'missing' }).Count | Should -Be 0
    }
}
