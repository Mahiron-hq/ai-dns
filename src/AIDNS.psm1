#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:ModuleVersion = [version](Import-PowerShellDataFile (Join-Path $PSScriptRoot 'AIDNS.psd1')).ModuleVersion

$privateFiles = @(
    'Config', 'Text', 'Log', 'Util', 'State', 'Providers', 'Engine', 'Evaluate', 'Network', 'Enable', 'Disable', 'Main'
)
foreach ($name in $privateFiles) {
    . (Join-Path $PSScriptRoot "Private\$name.ps1")
}

Export-ModuleMember -Function 'Invoke-AiDns', 'Test-AiDnsElevation', 'Request-AiDnsElevation', 'Wait-AiDnsExit'
