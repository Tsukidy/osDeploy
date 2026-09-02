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

Describe 'OSDeploy.Disk safety rules' {
    Context 'Test-RemovableBlocking (Q5)' {
        It 'blocks when usable removable storage is present' {
            $devices = @(
                @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Removable = $false; Storage = $true }
                @{ Number = 1; Model = 'SanDisk Ultra Fit'; SerialNumber = 'U1'; Removable = $true; Storage = $true }
            )
            $r = Test-RemovableBlocking -Devices $devices
            $r.Blocked | Should -BeTrue
            $r.Reason | Should -Not -BeNullOrEmpty
            @($r.RemovableStorage).Count | Should -Be 1
            @($r.RemovableStorage)[0].SerialNumber | Should -Be 'U1'
        }
        It 'does not block for a non-storage removable peripheral (keyboard)' {
            $devices = @(
                @{ Model = 'USB Keyboard'; Removable = $true; Storage = $false }
                @{ Model = 'USB Mouse'; Removable = $true; Storage = $false }
            )
            $r = Test-RemovableBlocking -Devices $devices
            $r.Blocked | Should -BeFalse
            $r.Reason | Should -BeNullOrEmpty
            @($r.RemovableStorage).Count | Should -Be 0
        }
        It 'does not block for fixed (non-removable) storage' {
            $devices = @(
                @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Removable = $false; Storage = $true }
            )
            $r = Test-RemovableBlocking -Devices $devices
            $r.Blocked | Should -BeFalse
            $r.Reason | Should -BeNullOrEmpty
            @($r.RemovableStorage).Count | Should -Be 0
        }
        It 'lists every blocking device when several exist' {
            $devices = @(
                @{ SerialNumber = 'U1'; Removable = $true; Storage = $true }
                @{ SerialNumber = 'U2'; Removable = $true; Storage = $true }
            )
            $r = Test-RemovableBlocking -Devices $devices
            $r.Blocked | Should -BeTrue
            @($r.RemovableStorage).Count | Should -Be 2
        }
        It 'returns exactly the three documented result keys' {
            $r = Test-RemovableBlocking -Devices @()
            (($r.Keys | Sort-Object) -join ',') | Should -Be 'Blocked,Reason,RemovableStorage'
        }
    }

    Context 'Invoke-EmergencyBypass (Q6)' {
        BeforeAll {
            $script:bypassTarget = @{ Number = 0; Model = 'Samsung 980'; SerialNumber = 'S1'; Bus = 'NVMe'; SizeBytes = 500107862016 }
        }
        It 'allows only when acknowledged AND confirmed' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $true -Confirmed
            $r.Allowed | Should -BeTrue
        }
        It 'denies when acknowledged but not confirmed, and still emits the audit event' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $true
            $r.Allowed | Should -BeFalse
            $r.AuditEvent | Should -Not -BeNullOrEmpty
        }
        It 'denies when confirmed but not acknowledged, and still emits the audit event' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $false -Confirmed
            $r.Allowed | Should -BeFalse
            $r.AuditEvent | Should -Not -BeNullOrEmpty
        }
        It 'denies when neither acknowledged nor confirmed, and still emits the audit event' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $false
            $r.Allowed | Should -BeFalse
            $r.AuditEvent | Should -Not -BeNullOrEmpty
        }
        It 'emits an EmergencyBypass audit event with target serial and UTC timestamp' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $true -Confirmed
            $evt = $r.AuditEvent
            $evt | Should -Not -BeNullOrEmpty
            (($evt.Keys | Sort-Object) -join ',') | Should -Be 'Event,TargetSerial,TimestampUtc'
            $evt.Event | Should -Be 'EmergencyBypass'
            $evt.TargetSerial | Should -Be 'S1'
            $evt.TimestampUtc | Should -Match 'Z$'
            $parsed = [datetime]::Parse($evt.TimestampUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $parsed.Kind | Should -Be ([DateTimeKind]::Utc)
        }
        It 'returns exactly the two documented result keys' {
            $r = Invoke-EmergencyBypass -Target $script:bypassTarget -Acknowledged $false
            (($r.Keys | Sort-Object) -join ',') | Should -Be 'Allowed,AuditEvent'
        }
    }

    Context 'Compare-DiskIdentity (Q12/Q87 time-of-use revalidation)' {
        BeforeAll {
            $script:selected = @{ Number = 0; SerialNumber = 'S1'; SizeBytes = 500107862016 }
        }
        It 'matches an unchanged disk' {
            $observed = @{ Number = 0; SerialNumber = 'S1'; SizeBytes = 500107862016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeTrue
        }
        It 'fails when the serial number changed' {
            $observed = @{ Number = 0; SerialNumber = 'S9'; SizeBytes = 500107862016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeFalse
        }
        It 'fails when the disk number changed' {
            $observed = @{ Number = 1; SerialNumber = 'S1'; SizeBytes = 500107862016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeFalse
        }
        It 'fails when the size changed' {
            $observed = @{ Number = 0; SerialNumber = 'S1'; SizeBytes = 1000204886016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeFalse
        }
        It 'compares serials case-insensitively (documented)' {
            $observed = @{ Number = 0; SerialNumber = 's1'; SizeBytes = 500107862016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeTrue
        }
        It 'fails closed when the observed record is missing a serial' {
            $observed = @{ Number = 0; SizeBytes = 500107862016 }
            Compare-DiskIdentity -Selected $script:selected -Observed $observed | Should -BeFalse
        }
        It 'fails closed when the observed record is null' {
            Compare-DiskIdentity -Selected $script:selected -Observed $null | Should -BeFalse
        }
    }

    Context 'Test-Capacity (Q79-Q82)' {
        It 'passes silently above the recommended size' {
            $r = Test-Capacity -DiskSizeBytes 500107862016
            $r.Warning | Should -BeNullOrEmpty
            $r.Block | Should -BeNullOrEmpty
            $r.NeedsAcknowledgement | Should -BeFalse
        }
        It 'treats exactly the recommended size as sufficient' {
            $r = Test-Capacity -DiskSizeBytes (122070 * 1MB)
            $r.Warning | Should -BeNullOrEmpty
            $r.NeedsAcknowledgement | Should -BeFalse
        }
        It 'warns with NeedsAcknowledgement below the recommended size' {
            $r = Test-Capacity -DiskSizeBytes 68719476736
            $r.Warning | Should -Not -BeNullOrEmpty
            $r.Warning | Should -Match 'recommended'
            $r.NeedsAcknowledgement | Should -BeTrue
            $r.Block | Should -BeNullOrEmpty
        }
        It 'honors a custom RecommendedMB override' {
            $r = Test-Capacity -DiskSizeBytes (130000 * 1MB) -RecommendedMB 140000
            $r.Warning | Should -Not -BeNullOrEmpty
            $r.NeedsAcknowledgement | Should -BeTrue
        }
        It 'blocks an impossible layout with no acknowledgement path (blocks even when acknowledged)' {
            $r = Test-Capacity -DiskSizeBytes 68719476736 -RequiredMB 100000
            $r.Block | Should -Not -BeNullOrEmpty
            $r.Block | Should -Match 'cannot fit'
            $r.Block | Should -Not -Match 'sanitiz'
            $r.Warning | Should -BeNullOrEmpty
            $r.NeedsAcknowledgement | Should -BeFalse
        }
        It 'does not block when the required layout fits' {
            $r = Test-Capacity -DiskSizeBytes 500107862016 -RequiredMB 100000
            $r.Block | Should -BeNullOrEmpty
        }
        It 'warns below recommended even when a smaller required layout fits' {
            $r = Test-Capacity -DiskSizeBytes 68719476736 -RequiredMB 50000
            $r.Warning | Should -Not -BeNullOrEmpty
            $r.NeedsAcknowledgement | Should -BeTrue
            $r.Block | Should -BeNullOrEmpty
        }
        It 'returns exactly the three documented result keys with no logging property' {
            $r = Test-Capacity -DiskSizeBytes 500107862016
            (($r.Keys | Sort-Object) -join ',') | Should -Be 'Block,NeedsAcknowledgement,Warning'
        }
    }
}
