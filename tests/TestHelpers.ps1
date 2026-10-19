# Shared setup for the Pester suites. Nothing here touches network settings or the registry.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SourceRoot = Join-Path $script:RepoRoot 'src'

function Import-AiDnsForTest {
    Import-Module (Join-Path $script:SourceRoot 'AIDNS.psd1') -Force
    if ($null -eq ('AiDns.DnsBatch' -as [type])) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $script:SourceRoot 'Probe.cs'))) -Language CSharp
    }
    InModuleScope AIDNS { Import-AiDnsStringTable 'en' }
}
