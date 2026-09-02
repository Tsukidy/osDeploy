Set-StrictMode -Version Latest
function Get-FileSha256 {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function New-FileInventory {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object -Property FullName | ForEach-Object {
        New-Object pscustomobject -Property ([ordered]@{
            Path   = $_.FullName.Substring($root.Length + 1)
            Size   = $_.Length
            Sha256 = Get-FileSha256 -Path $_.FullName
        })
    })
    # Always return object[]: normal output enumerates and a single-file directory
    # would otherwise collapse to one object at the call site.
    Write-Output -NoEnumerate $items
}
function Get-BundleHash {
    [CmdletBinding()] param([Parameter(Mandatory)][object[]]$Inventory)
    $sorted = $Inventory | Sort-Object -Property Path
    $json = ConvertTo-Json -InputObject $sorted -Depth 4 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}
