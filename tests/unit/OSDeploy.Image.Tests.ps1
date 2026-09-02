BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Image\OSDeploy.Image.psd1') -Force

    # Fixture builders (brief Step 1: METADATA objects, never files). Defaults
    # are a canonical valid dual-index Windows 11 image; scenarios mutate
    # fields. Defined inside BeforeAll because Pester 5 does not carry
    # discovery-time definitions into the run phase.
    function New-TestIndex {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Edition,
            $Index,
            [string]$Architecture = 'x64',
            [string]$Language = 'en-US',
            [string]$Release = '11.0.26100.2314',
            [string]$Build = '11.0.26100.2314'
        )
        $record = [ordered]@{
            Name         = $Name
            Edition      = $Edition
            Architecture = $Architecture
            Language     = $Language
            Release      = $Release
            Build        = $Build
        }
        if ($PSBoundParameters.ContainsKey('Index')) { $record['Index'] = $Index }
        return $record
    }
    function New-TestImage {
        param([Parameter(Mandatory)][object[]]$Indexes)
        return @{ Indexes = $Indexes }
    }
}

Describe 'valid dual-index image (Q46/Q47)' {
    It 'passes with no errors and records both indexes' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Index 1)
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Index 2)
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeTrue
        @($r.Errors).Count | Should -Be 0
        $r.HomeIndex | Should -Be 'Windows 11 Home'
        $r.ProIndex | Should -Be 'Windows 11 Pro'
        @($r.IndexRecord).Count | Should -Be 2
        $r.IndexRecord[0].Index | Should -Be 1
        $r.IndexRecord[0].Name | Should -Be 'Windows 11 Home'
        $r.IndexRecord[0].Edition | Should -Be 'Home'
        $r.IndexRecord[1].Index | Should -Be 2
        $r.IndexRecord[1].Name | Should -Be 'Windows 11 Pro'
        $r.IndexRecord[1].Edition | Should -Be 'Pro'
    }
    It 'result carries exactly the five contract keys' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        ((@($r.Keys) | Sort-Object) -join ',') | Should -Be 'Errors,HomeIndex,IndexRecord,ProIndex,Valid'
    }
    It 'each IndexRecord entry carries exactly Edition, Index, Name' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        foreach ($entry in @($r.IndexRecord)) {
            ((@($entry.Keys) | Sort-Object) -join ',') | Should -Be 'Edition,Index,Name'
        }
    }
    It 'edition matching is case-insensitive and names are reported as given' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Home Image' -Edition 'home')
            (New-TestIndex -Name 'PRO Image' -Edition 'PRO')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeTrue
        $r.HomeIndex | Should -Be 'Home Image'
        $r.ProIndex | Should -Be 'PRO Image'
    }
    It 'null Build is acceptable (Build is checked only when present)' {
        # Named ...Record: bare $home collides with the read-only HOME variable.
        $homeRecord = New-TestIndex -Name 'Windows 11 Home' -Edition 'Home'
        $proRecord = New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro'
        $homeRecord.Remove('Build')
        $proRecord.Remove('Build')
        $r = Test-ImageMetadata -Image (New-TestImage -Indexes @($homeRecord, $proRecord))
        $r.Valid | Should -BeTrue
        @($r.Errors).Count | Should -Be 0
    }
    It 'indexes may differ below the major (only major compatibility is enforced)' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release '11.0.26100.2314' -Build '11.0.26100.2314')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Release '11.1.26200.5' -Build '11.1.26200.5')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeTrue
    }
}

Describe 'missing edition fails (Q46/Q47)' {
    It 'missing Pro index fails with Pro named; Home is still reported' {
        $image = New-TestImage -Indexes @((New-TestIndex -Name 'Windows 11 Home' -Edition 'Home'))
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        $r.ProIndex | Should -BeNullOrEmpty
        $r.HomeIndex | Should -Be 'Windows 11 Home'
        ($r.Errors -join ';') | Should -Match 'Pro'
    }
    It 'missing Home index fails with Home named; Pro is still reported' {
        $image = New-TestImage -Indexes @((New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro'))
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        $r.HomeIndex | Should -BeNullOrEmpty
        $r.ProIndex | Should -Be 'Windows 11 Pro'
        ($r.Errors -join ';') | Should -Match 'Home'
    }
    It 'an image with only a third edition fails both lookups' {
        $image = New-TestImage -Indexes @((New-TestIndex -Name 'Windows 11 Enterprise' -Edition 'Enterprise' -Index 3))
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        $r.HomeIndex | Should -BeNullOrEmpty
        $r.ProIndex | Should -BeNullOrEmpty
        ($r.Errors -join ';') | Should -Match 'Home'
        ($r.Errors -join ';') | Should -Match 'Pro'
        @($r.IndexRecord).Count | Should -Be 1
    }
    It 'empty Indexes fails with an error (never a silent pass)' {
        $r = Test-ImageMetadata -Image @{ Indexes = @() }
        $r.Valid | Should -BeFalse
        @($r.Errors).Count | Should -BeGreaterThan 0
        @($r.IndexRecord).Count | Should -Be 0
        $r.HomeIndex | Should -BeNullOrEmpty
        $r.ProIndex | Should -BeNullOrEmpty
    }
    It 'missing Indexes key fails with exactly the no-indexes error' {
        $r = Test-ImageMetadata -Image @{}
        $r.Valid | Should -BeFalse
        @($r.Errors).Count | Should -Be 1
        ($r.Errors -join ';') | Should -Match 'no indexes'
    }
}

Describe 'architecture consistency (Q47)' {
    It 'mixed architecture across indexes fails naming the offending index' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Architecture 'x64')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Architecture 'arm64')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Architecture'
        ($r.Errors -join ';') | Should -Match 'Windows 11 Pro'
    }
    It 'all indexes off the required architecture fail even when mutually consistent' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Architecture 'x86')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Architecture 'x86')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        @($r.Errors).Count | Should -Be 2
        ($r.Errors -join ';') | Should -Match "required architecture 'x64'"
    }
    It 'explicit -RequiredArchitecture accepts a matching pair' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Architecture 'arm64')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Architecture 'arm64')
        )
        $r = Test-ImageMetadata -Image $image -RequiredArchitecture 'arm64'
        $r.Valid | Should -BeTrue
    }
    It 'architecture comparison is case-insensitive' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Architecture 'X64')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Architecture 'x64')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeTrue
    }
}

Describe 'language consistency (Q47)' {
    It 'mixed language across indexes fails naming the offending index' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Language 'en-US')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Language 'en-GB')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Language'
        ($r.Errors -join ';') | Should -Match 'Windows 11 Pro'
    }
    It 'all indexes off the required language fail against the en-US default' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Language 'en-GB')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Language 'en-GB')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        @($r.Errors).Count | Should -Be 2
        ($r.Errors -join ';') | Should -Match "required language 'en-US'"
    }
    It 'explicit -RequiredLanguage accepts a matching pair' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Language 'de-DE')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Language 'de-DE')
        )
        $r = Test-ImageMetadata -Image $image -RequiredLanguage 'de-DE'
        $r.Valid | Should -BeTrue
    }
}

Describe 'release and build compatibility (Q47)' {
    It 'a Windows 10 major image fails against the required-release 11 default' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release '10.0.22621.315' -Build '10.0.22621.315')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Release '10.0.22621.315' -Build '10.0.22621.315')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Release'
    }
    It 'explicit -RequiredRelease 10 accepts a major-10 pair' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release '10.0.22621.315' -Build '10.0.22621.315')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Release '10.0.22621.315' -Build '10.0.22621.315')
        )
        $r = Test-ImageMetadata -Image $image -RequiredRelease '10'
        $r.Valid | Should -BeTrue
    }
    It 'mixed release majors across indexes fail (cross-release mixing)' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release '11.0.26100.1' -Build '11.0.26100.1')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Release '10.0.22621.5' -Build '10.0.22621.5')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Release'
        ($r.Errors -join ';') | Should -Match 'Windows 11 Pro'
    }
    It 'unparseable Release fails naming the field and the index' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release 'not-a-version')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Release'
        ($r.Errors -join ';') | Should -Match 'Windows 11 Home'
    }
    It 'missing Release fails' {
        $homeRecord = New-TestIndex -Name 'Windows 11 Home' -Edition 'Home'
        $homeRecord.Remove('Release')
        $r = Test-ImageMetadata -Image (New-TestImage -Indexes @($homeRecord, (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')))
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Release'
    }
    It 'unparseable Build fails when present' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Build 'not-a-version')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Build'
    }
    It 'Build major mismatching the Release major fails (cross-release mixing)' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Release '11.0.26100.1' -Build '10.0.26100.1')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'Build'
        ($r.Errors -join ';') | Should -Match 'Windows 11 Home'
    }
}

Describe 'IndexRecord exact names and numbers (Q47, ruling 2)' {
    It 'records every index in source order, preferring explicit Index numbers' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Image Five' -Edition 'Home' -Index 5)
            (New-TestIndex -Name 'Image Two' -Edition 'Pro' -Index 2)
            (New-TestIndex -Name 'Image Nine' -Edition 'Enterprise' -Index 9)
        )
        $r = Test-ImageMetadata -Image $image
        @($r.IndexRecord).Count | Should -Be 3
        (@($r.IndexRecord | ForEach-Object { $_.Index }) -join ',') | Should -Be '5,2,9'
        (@($r.IndexRecord | ForEach-Object { $_.Name }) -join '|') | Should -Be 'Image Five|Image Two|Image Nine'
        (@($r.IndexRecord | ForEach-Object { $_.Edition }) -join ',') | Should -Be 'Home,Pro,Enterprise'
    }
    It 'falls back to 1-based array position when Index is absent' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $r = Test-ImageMetadata -Image $image
        (@($r.IndexRecord | ForEach-Object { $_.Index }) -join ',') | Should -Be '1,2'
    }
    It 'falls back to position per index when Index is not numeric' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Index '7')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro' -Index 4)
        )
        $r = Test-ImageMetadata -Image $image
        (@($r.IndexRecord | ForEach-Object { $_.Index }) -join ',') | Should -Be '1,4'
    }
    It 'is built even when validation fails' {
        $image = New-TestImage -Indexes @((New-TestIndex -Name 'Windows 11 Home' -Edition 'Home' -Index 6))
        $r = Test-ImageMetadata -Image $image
        $r.Valid | Should -BeFalse
        @($r.IndexRecord).Count | Should -Be 1
        $r.IndexRecord[0].Index | Should -Be 6
    }
}

Describe 'requirement parameters' {
    It 'unparseable -RequiredRelease throws (fail closed on caller error)' {
        $image = New-TestImage -Indexes @(
            (New-TestIndex -Name 'Windows 11 Home' -Edition 'Home')
            (New-TestIndex -Name 'Windows 11 Pro' -Edition 'Pro')
        )
        $err = { Test-ImageMetadata -Image $image -RequiredRelease 'not-a-version' } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'RequiredRelease'
    }
}

# ---------------------------------------------------------------------------
# Task 14: promotion lifecycle and edition resolution (Q48-Q52).
# Real filesystem in temp directories - no mocking framework. Each It gets its
# own case directory so per-case residue counting cannot see other cases.
# ---------------------------------------------------------------------------

Describe 'Invoke-ImagePromotion validate-then-move lifecycle (Q48-Q52)' {
    BeforeAll {
        $script:promoteDir = Join-Path ([System.IO.Path]::GetTempPath()) ('image-promote-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:promoteDir | Out-Null
        $script:oldBytes = [System.Text.Encoding]::ASCII.GetBytes('EXISTING-CACHE-IMAGE-CONTENT')
        $script:newBytes = [System.Text.Encoding]::ASCII.GetBytes('FRESHLY-DOWNLOADED-IMAGE-CONTENT')

        # Validator harness: the module invokes the scriptblock as
        # & $Validator <path> from inside its own session state, so the
        # scriptblock must carry its counters in a closure (GetNewClosure)
        # rather than relying on It-scope variables being reachable. State is
        # a shared hashtable object: the test reads what the validator saw.
        # Results = one boolean per permitted call; a call beyond the scripted
        # results returns $null (falsy), so an unexpected extra call fails the
        # surrounding assertions instead of passing silently.
        function New-ValidatorHarness {
            param([Parameter(Mandatory)][bool[]]$Results)
            $state = @{
                Results = @($Results)
                Index   = 0
                Seen    = New-Object System.Collections.Generic.List[object]
            }
            $validator = {
                param($Path)
                $entry = @{
                    Path   = $Path
                    Exists = (Test-Path -LiteralPath $Path)
                    Sha256 = $null
                }
                if ($entry.Exists) {
                    $entry.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
                }
                $state.Seen.Add($entry) | Out-Null
                $result = $null
                if ($state.Index -lt $state.Results.Count) { $result = $state.Results[$state.Index] }
                $state.Index = $state.Index + 1
                return $result
            }.GetNewClosure()
            return @{ State = $state; Validator = $validator }
        }

        function New-PromotionCase {
            param([switch]$WithExistingCache)
            $caseDir = Join-Path $script:promoteDir ('case-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $caseDir | Out-Null
            $cache = Join-Path $caseDir 'image-cache.wim'
            $temp = Join-Path $caseDir 'image-download.tmp'
            if ($WithExistingCache) {
                [System.IO.File]::WriteAllBytes($cache, $script:oldBytes)
            }
            [System.IO.File]::WriteAllBytes($temp, $script:newBytes)
            return @{ CaseDir = $caseDir; Cache = $cache; Temp = $temp }
        }
    }
    AfterAll { Remove-Item -Recurse -Force $script:promoteDir -ErrorAction SilentlyContinue }

    It 'failed validation deletes the temp download, leaves the cache byte-identical, and never stages' {
        $case = New-PromotionCase -WithExistingCache
        $beforeHash = (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash
        $harness = New-ValidatorHarness -Results @($false)
        $r = Invoke-ImagePromotion -TempPath $case.Temp -CachePath $case.Cache -Validator $harness.Validator
        $r.Promoted | Should -BeFalse
        $r.CacheIntact | Should -BeTrue
        (Test-Path -LiteralPath $case.Temp) | Should -BeFalse
        (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash | Should -Be $beforeHash
        @(Get-ChildItem -LiteralPath $case.CaseDir -File).Count | Should -Be 1
        $harness.State.Seen.Count | Should -Be 1
        $harness.State.Seen[0].Path | Should -Be $case.Temp
    }

    It 'successful promotion replaces the cache with the downloaded bytes and leaves no residue' {
        $case = New-PromotionCase -WithExistingCache
        $newHash = (Get-FileHash -LiteralPath $case.Temp -Algorithm SHA256).Hash
        $harness = New-ValidatorHarness -Results @($true, $true)
        $r = Invoke-ImagePromotion -TempPath $case.Temp -CachePath $case.Cache -Validator $harness.Validator
        $r.Promoted | Should -BeTrue
        $r.CacheIntact | Should -BeTrue
        (Test-Path -LiteralPath $case.Temp) | Should -BeFalse
        (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash | Should -Be $newHash
        @(Get-ChildItem -LiteralPath $case.CaseDir -File).Count | Should -Be 1
        $harness.State.Seen.Count | Should -Be 2
    }

    It 'validates the temp copy first, then the staged copy beside the cache' {
        $case = New-PromotionCase -WithExistingCache
        $newHash = (Get-FileHash -LiteralPath $case.Temp -Algorithm SHA256).Hash
        $harness = New-ValidatorHarness -Results @($true, $true)
        $r = Invoke-ImagePromotion -TempPath $case.Temp -CachePath $case.Cache -Validator $harness.Validator
        $r.Promoted | Should -BeTrue
        $harness.State.Seen.Count | Should -Be 2
        # First call: the temp download itself.
        $harness.State.Seen[0].Path | Should -Be $case.Temp
        $harness.State.Seen[0].Exists | Should -BeTrue
        $harness.State.Seen[0].Sha256 | Should -Be $newHash
        # Second call: a NEW staging path, not the temp and not the cache,
        # placed in the cache's directory under a staging- name, holding the
        # downloaded bytes, and a real file at call time.
        $stagedPath = [string]$harness.State.Seen[1].Path
        $stagedPath | Should -Not -Be $case.Temp
        $stagedPath | Should -Not -Be $case.Cache
        (Split-Path -Parent $stagedPath) | Should -Be (Split-Path -Parent $case.Cache)
        ([System.IO.Path]::GetFileName($stagedPath)) | Should -BeLike 'staging-*'
        $harness.State.Seen[1].Exists | Should -BeTrue
        $harness.State.Seen[1].Sha256 | Should -Be $newHash
    }

    It 'second-validation failure deletes the staged copy and leaves the cache byte-identical' {
        $case = New-PromotionCase -WithExistingCache
        $beforeHash = (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash
        $harness = New-ValidatorHarness -Results @($true, $false)
        $r = Invoke-ImagePromotion -TempPath $case.Temp -CachePath $case.Cache -Validator $harness.Validator
        $r.Promoted | Should -BeFalse
        $r.CacheIntact | Should -BeTrue
        (Test-Path -LiteralPath $case.Temp) | Should -BeFalse
        (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash | Should -Be $beforeHash
        @(Get-ChildItem -LiteralPath $case.CaseDir -File).Count | Should -Be 1
        $harness.State.Seen.Count | Should -Be 2
    }

    It 'creates the cache on first acquisition when no cache file exists yet' {
        $case = New-PromotionCase
        (Test-Path -LiteralPath $case.Cache) | Should -BeFalse
        $newHash = (Get-FileHash -LiteralPath $case.Temp -Algorithm SHA256).Hash
        $harness = New-ValidatorHarness -Results @($true, $true)
        $r = Invoke-ImagePromotion -TempPath $case.Temp -CachePath $case.Cache -Validator $harness.Validator
        $r.Promoted | Should -BeTrue
        $r.CacheIntact | Should -BeTrue
        (Test-Path -LiteralPath $case.Cache) | Should -BeTrue
        (Get-FileHash -LiteralPath $case.Cache -Algorithm SHA256).Hash | Should -Be $newHash
        @(Get-ChildItem -LiteralPath $case.CaseDir -File).Count | Should -Be 1
    }

    It 'result carries exactly the Promoted and CacheIntact keys in every outcome' {
        $failCase = New-PromotionCase -WithExistingCache
        $failHarness = New-ValidatorHarness -Results @($false)
        $fail = Invoke-ImagePromotion -TempPath $failCase.Temp -CachePath $failCase.Cache -Validator $failHarness.Validator
        ((@($fail.Keys) | Sort-Object) -join ',') | Should -Be 'CacheIntact,Promoted'
        $okCase = New-PromotionCase -WithExistingCache
        $okHarness = New-ValidatorHarness -Results @($true, $true)
        $ok = Invoke-ImagePromotion -TempPath $okCase.Temp -CachePath $okCase.Cache -Validator $okHarness.Validator
        ((@($ok.Keys) | Sort-Object) -join ',') | Should -Be 'CacheIntact,Promoted'
    }
}

Describe 'Resolve-EditionChoice established choices (Q48-Q52)' {
    It 'available edition returns directly with null Choices' {
        $r = Resolve-EditionChoice -Requested 'Pro' -Available @('Home', 'Pro')
        $r.Edition | Should -Be 'Pro'
        $r.Choices | Should -BeNullOrEmpty
        ((@($r.Keys) | Sort-Object) -join ',') | Should -Be 'Choices,Edition'
    }
    It 'matching is case-insensitive and the requested spelling is returned as given' {
        $r = Resolve-EditionChoice -Requested 'home' -Available @('Home', 'Pro')
        $r.Edition | Should -Be 'home'
        $r.Choices | Should -BeNullOrEmpty
    }
    It 'unavailable edition yields exactly the three established choices with null Edition' {
        $r = Resolve-EditionChoice -Requested 'Pro' -Available @('Home', 'Education')
        $r.Edition | Should -BeNullOrEmpty
        @($r.Choices).Count | Should -Be 3
        (@($r.Choices) -join '|') | Should -Be 'Choose Another Edition|Use Saved Default Edition|Cancel Recovery'
    }
    It 'never substitutes an available edition silently' {
        $r = Resolve-EditionChoice -Requested 'Enterprise' -Available @('Home', 'Pro')
        $r.Edition | Should -BeNullOrEmpty
        @($r.Choices) -contains 'Home' | Should -BeFalse
        @($r.Choices) -contains 'Pro' | Should -BeFalse
        @($r.Choices) -contains 'Enterprise' | Should -BeFalse
    }
    It 'empty Available yields the three choices (nothing is defaulted)' {
        $r = Resolve-EditionChoice -Requested 'Home' -Available @()
        $r.Edition | Should -BeNullOrEmpty
        (@($r.Choices) -join '|') | Should -Be 'Choose Another Edition|Use Saved Default Edition|Cancel Recovery'
    }
    It 'empty Requested is unavailable (no edition is invented)' {
        $r = Resolve-EditionChoice -Requested '' -Available @('Home', 'Pro')
        $r.Edition | Should -BeNullOrEmpty
        @($r.Choices).Count | Should -Be 3
    }
}
