BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Shared\OSDeploy.Util\OSDeploy.Util.psd1') -Force
    $script:work = Join-Path ([System.IO.Path]::GetTempPath()) ('util-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    Set-Content -Path (Join-Path $work 'a.txt') -Value 'hello' -Encoding Ascii
}
AfterAll { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
Describe 'OSDeploy.Util' {
    It 'Get-FileSha256 returns the uppercase SHA-256 of the file bytes' {
        $h = Get-FileSha256 -Path (Join-Path $work 'a.txt')
        $h | Should -Be '5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03'
    }
    It 'New-FileInventory emits Path/Size/Sha256 in fixed order for every file' {
        $inv = New-FileInventory -Path $work
        $inv.Count | Should -Be 1
        ($inv[0].PSObject.Properties.Name -join ',') | Should -Be 'Path,Size,Sha256'
        $inv[0].Size | Should -Be 6
    }
    It 'Get-BundleHash is stable across inventory order and changes when content changes' {
        $i1 = New-FileInventory -Path $work
        Set-Content -Path (Join-Path $work 'a.txt') -Value 'hello2' -Encoding Ascii
        $i2 = New-FileInventory -Path $work
        Get-BundleHash -Inventory ($i2 + $i1) | Should -Not -Be (Get-BundleHash -Inventory $i2)
    }
}
