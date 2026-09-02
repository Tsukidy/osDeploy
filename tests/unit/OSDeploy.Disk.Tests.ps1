BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Disk\OSDeploy.Disk.psd1') -Force
}

Describe 'OSDeploy.Disk' {
    Context 'Get-DiskPresentation' {
        It 'returns exactly the five display fields in fixed order' {
            $disk = @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Bus = 'NVMe'; SizeBytes = 500107862016; Internal = $true }
            $p = Get-DiskPresentation -Disk $disk
            ($p.PSObject.Properties.Name -join ',') | Should -Be 'Number,Model,SerialNumber,Bus,SizeBytes'
            $p.Number | Should -Be 0
            $p.Model | Should -Be 'Samsung 980'
            $p.SerialNumber | Should -Be 'S1'
            $p.Bus | Should -Be 'NVMe'
            $p.SizeBytes | Should -Be 500107862016
        }
        It 'projects PSCustomObject inventory records the same way' {
            $disk = [pscustomobject]@{ Number = 2; Model = 'WD Blue'; SerialNumber = 'S9'; Bus = 'SATA'; SizeBytes = 1000204886016; Internal = $true }
            $p = Get-DiskPresentation -Disk $disk
            ($p.PSObject.Properties.Name -join ',') | Should -Be 'Number,Model,SerialNumber,Bus,SizeBytes'
            $p.SerialNumber | Should -Be 'S9'
        }
    }

    Context 'Select-PrimaryDisk (Q4 rules)' {
        It 'auto-selects a sole eligible NVMe even when eligible SATA drives exist' {
            $candidates = @(
                @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Bus = 'NVMe'; SizeBytes = 500107862016; Internal = $true }
                @{ Number = 1; Model = 'WD Blue'; SerialNumber = 'S2'; Bus = 'SATA'; SizeBytes = 1000204886016; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk.SerialNumber | Should -Be 'S1'
            $r.AutoSelected | Should -BeTrue
            $r.RequiresSelection | Should -BeFalse
            $r.NoCandidates | Should -BeFalse
        }
        It 'requires selection when two eligible NVMe drives exist' {
            $candidates = @(
                @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Bus = 'NVMe'; SizeBytes = 500107862016; Internal = $true }
                @{ Number = 1; Model = 'Samsung 990'; SerialNumber = 'S2'; Bus = 'NVMe'; SizeBytes = 1000204886016; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk | Should -BeNullOrEmpty
            $r.AutoSelected | Should -BeFalse
            $r.RequiresSelection | Should -BeTrue
            $r.NoCandidates | Should -BeFalse
        }
        It 'auto-selects the single eligible SATA drive when no NVMe exists' {
            $candidates = @(
                @{ Number = 0; Model = 'WD Blue'; SerialNumber = 'S5'; Bus = 'SATA'; SizeBytes = 1000204886016; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk.SerialNumber | Should -Be 'S5'
            $r.AutoSelected | Should -BeTrue
            $r.RequiresSelection | Should -BeFalse
            $r.NoCandidates | Should -BeFalse
        }
        It 'requires selection when no NVMe exists and multiple eligible SATA drives exist' {
            $candidates = @(
                @{ Number = 0; Model = 'WD Blue'; SerialNumber = 'S5'; Bus = 'SATA'; SizeBytes = 1000204886016; Internal = $true }
                @{ Number = 1; Model = 'Seagate Barracuda'; SerialNumber = 'S6'; Bus = 'SATA'; SizeBytes = 2000398934016; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk | Should -BeNullOrEmpty
            $r.AutoSelected | Should -BeFalse
            $r.RequiresSelection | Should -BeTrue
            $r.NoCandidates | Should -BeFalse
        }
        It 'returns NoCandidates for an empty candidate set' {
            $r = Select-PrimaryDisk -Candidates @()
            $r.Disk | Should -BeNullOrEmpty
            $r.AutoSelected | Should -BeFalse
            $r.RequiresSelection | Should -BeFalse
            $r.NoCandidates | Should -BeTrue
        }
        It 'treats a zero-size internal disk as ineligible (SATA fallback engages)' {
            $candidates = @(
                @{ Number = 0; Model = 'Phantom NVMe'; SerialNumber = 'S7'; Bus = 'NVMe'; SizeBytes = 0; Internal = $true }
                @{ Number = 1; Model = 'WD Blue'; SerialNumber = 'S8'; Bus = 'SATA'; SizeBytes = 1000204886016; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk.SerialNumber | Should -Be 'S8'
            $r.AutoSelected | Should -BeTrue
        }
        It 'returns NoCandidates when the only candidate is a zero-size internal disk' {
            $candidates = @(
                @{ Number = 0; Model = 'Phantom SATA'; SerialNumber = 'S9'; Bus = 'SATA'; SizeBytes = 0; Internal = $true }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.NoCandidates | Should -BeTrue
            $r.Disk | Should -BeNullOrEmpty
        }
        It 'treats an external (Internal=$false) NVMe as ineligible (internal one auto-selects)' {
            $candidates = @(
                @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Bus = 'NVMe'; SizeBytes = 500107862016; Internal = $true }
                @{ Number = 1; Model = 'USB NVMe'; SerialNumber = 'E1'; Bus = 'NVMe'; SizeBytes = 500107862016; Internal = $false }
            )
            $r = Select-PrimaryDisk -Candidates $candidates
            $r.Disk.SerialNumber | Should -Be 'S1'
            $r.AutoSelected | Should -BeTrue
        }
        It 'always returns the four documented result keys' {
            $r = Select-PrimaryDisk -Candidates @()
            (($r.Keys | Sort-Object) -join ',') | Should -Be 'AutoSelected,Disk,NoCandidates,RequiresSelection'
        }
    }
}
