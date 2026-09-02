@{
    RootModule        = 'OSDeploy.Image.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c5fe2928-a22d-4b20-a103-8cdd392616ab'
    Author            = 'OSDeploy Suite'
    Description       = 'Multi-index Windows image metadata validation (Home/Pro presence, architecture and language consistency, release/build compatibility, exact index name/number record), validate-then-move cache promotion with reopen-and-revalidate, and established-choices edition resolution.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Test-ImageMetadata', 'Invoke-ImagePromotion', 'Resolve-EditionChoice')
}
