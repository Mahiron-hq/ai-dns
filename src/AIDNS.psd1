@{
    RootModule           = 'AIDNS.psm1'
    ModuleVersion        = '3.1.0'
    GUID                 = '4f6c2a51-8f0e-4b8a-9a43-2d7f3c1e9b60'
    Author               = 'Lev Burmistrov'
    CompanyName          = 'Mahiron-hq'
    Copyright            = 'Copyright 2026 Lev Burmistrov (Mahiron-hq). Licensed under the Apache License 2.0.'
    Description          = 'Finds a working smart DNS for ChatGPT, Claude and Gemini, applies it and rolls it back exactly.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    FunctionsToExport    = @('Invoke-AiDns', 'Test-AiDnsElevation', 'Request-AiDnsElevation', 'Wait-AiDnsExit',
                             'Invoke-AiDnsVersionCheck', 'Start-AiDnsSettingsMenu')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('DNS', 'SmartDNS', 'ChatGPT', 'Claude', 'Gemini', 'Windows')
            LicenseUri = 'https://github.com/Mahiron-hq/ai-dns/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Mahiron-hq/ai-dns'
        }
    }
}
