@{
    RootModule        = 'OSDeploy.Image.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'c5fe2928-a22d-4b20-a103-8cdd392616ab'
    Author            = 'OSDeploy Suite'
    Description       = 'Pure multi-index Windows image metadata validation: Home/Pro presence, architecture and language consistency, release/build compatibility, and the exact index name/number record.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Test-ImageMetadata')
}
