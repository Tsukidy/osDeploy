BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Logging\OSDeploy.Logging.psd1') -Force
    $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('log-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'runs') | Out-Null
}
AfterAll { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
Describe 'run folders' {
    It 'same-second collisions get numeric suffixes' {
        # Controller ruling: both calls use the SAME RunId so the second call in
        # the same second collides with the first and takes the -2 suffix (the
        # brief's two different RunIds can never collide because the RunId is
        # part of the folder name).
        $a = New-RunLog -Root (Join-Path $root 'runs') -RunId 'aaa' -RunType 'InitialDeployment'
        $b = New-RunLog -Root (Join-Path $root 'runs') -RunId 'aaa' -RunType 'InitialDeployment'
        $a.Folder | Should -Not -Be $b.Folder
        $b.Folder | Should -Match '-2$|-3$'
    }
    It 'folder name is RunType-yyyyMMdd-HHmmss-RunId and the paths live inside it' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'fff' -RunType 'FactoryRecovery'
        $log.Root | Should -Be (Join-Path $root 'runs')
        $log.RunId | Should -Be 'fff'
        $log.RunType | Should -Be 'FactoryRecovery'
        $log.Folder | Should -Match 'FactoryRecovery-\d{8}-\d{6}-fff$'
        (Split-Path $log.EventsPath -Leaf) | Should -Be 'events.jsonl'
        (Split-Path $log.EventsPath -Parent) | Should -Be $log.Folder
        (Split-Path $log.TranscriptPath -Parent) | Should -Be $log.Folder
        (Test-Path $log.Folder) | Should -BeTrue
        (Test-Path $log.TranscriptPath) | Should -BeTrue
    }
}
Describe 'event lines' {
    It 'appends one ASCII JSON line per event in fixed property order' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'ggg' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Warn -Event 'DiskCheck' -Data @{ Disk = 's' }
        Add-LogEvent -Log $log -Level Info -Event 'Done'
        $lines = [System.IO.File]::ReadAllLines($log.EventsPath)
        $lines.Count | Should -Be 2
        $line = $lines[0]
        $line.IndexOf('"TimestampUtc"') | Should -BeLessThan ($line.IndexOf('"Level"'))
        $line.IndexOf('"Level"') | Should -BeLessThan ($line.IndexOf('"Event"'))
        $line.IndexOf('"Event"') | Should -BeLessThan ($line.IndexOf('"Data"'))
        $obj = $line | ConvertFrom-Json
        $obj.Level | Should -Be 'Warn'
        $obj.Event | Should -Be 'DiskCheck'
        $obj.Data.Disk | Should -Be 's'
        $bytes = [System.IO.File]::ReadAllBytes($log.EventsPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
Describe 'retention' {
    It 'prunes oldest complete folders first and keeps the active one' {
        $runs = Join-Path $root 'ret'
        New-Item -ItemType Directory -Path $runs | Out-Null
        foreach ($n in @('InitialDeployment-20260101-000000-x1', 'InitialDeployment-20260102-000000-x2', 'InitialDeployment-20260103-000000-x3')) {
            New-Item -ItemType Directory -Path (Join-Path $runs $n) | Out-Null
            Set-Content -Path (Join-Path $runs "$n\events.jsonl") -Value '{}' -Encoding Ascii
        }
        # Controller ruling: MaxMB 0 (the fixture folders total a few bytes, so
        # the brief's -MaxMB 1 would prune nothing).
        Invoke-LogRetention -Root $runs -MaxMB 0 -KeepFolder 'InitialDeployment-20260103-000000-x3'
        (Test-Path (Join-Path $runs 'InitialDeployment-20260101-000000-x1')) | Should -BeFalse
        (Test-Path (Join-Path $runs 'InitialDeployment-20260103-000000-x3')) | Should -BeTrue
    }
    It 'never removes incomplete folders (no events file means an active run)' {
        $runs = Join-Path $root 'ret-incomplete'
        New-Item -ItemType Directory -Path $runs | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runs 'InitialDeployment-20260101-000000-old') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runs 'InitialDeployment-20260102-000000-done') | Out-Null
        Set-Content -Path (Join-Path $runs 'InitialDeployment-20260102-000000-done\events.jsonl') -Value '{}' -Encoding Ascii
        Invoke-LogRetention -Root $runs -MaxMB 0
        (Test-Path (Join-Path $runs 'InitialDeployment-20260101-000000-old')) | Should -BeTrue
        (Test-Path (Join-Path $runs 'InitialDeployment-20260102-000000-done')) | Should -BeFalse
    }
}
Describe 'copy semantics and gating' {
    It 'server copy failure is a warning, never a throw; recovery never copies' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'ccc' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Info -Event 'Test'
        $r = Invoke-ServerLogCopy -Log $log -Destination (Join-Path $root 'no\such\share')
        $r.Ok | Should -BeFalse
        $r.Warning | Should -Not -BeNullOrEmpty
        $rec = New-RunLog -Root (Join-Path $root 'runs') -RunId 'ddd' -RunType 'FactoryRecovery'
        { Invoke-ServerLogCopy -Log $rec -Destination 'x' } | Should -Throw
    }
    It 'a successful copy returns Ok with no warning' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'hhh' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Info -Event 'E'
        $dest = Join-Path $root 'srv'
        New-Item -ItemType Directory -Path $dest | Out-Null
        $r = Invoke-ServerLogCopy -Log $log -Destination $dest
        $r.Ok | Should -BeTrue
        $r.Warning | Should -BeNullOrEmpty
        (Test-Path (Join-Path (Join-Path $dest (Split-Path $log.Folder -Leaf)) 'events.jsonl')) | Should -BeTrue
    }
    It 'Complete-RunLog verifies the events file' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'eee' -RunType 'InitialDeployment'
        Add-LogEvent -Log $log -Level Info -Event 'E'
        (Complete-RunLog -Log $log) | Should -BeTrue
        Set-Content -Path $log.EventsPath -Value 'not json' -Encoding Ascii
        (Complete-RunLog -Log $log) | Should -BeFalse
    }
    It 'Complete-RunLog returns false when the events file is missing' {
        $log = New-RunLog -Root (Join-Path $root 'runs') -RunId 'iii' -RunType 'InitialDeployment'
        (Complete-RunLog -Log $log) | Should -BeFalse
    }
}
