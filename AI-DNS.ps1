#Requires -Version 5.1
<#
.SYNOPSIS
    Finds a working smart DNS for ChatGPT, Claude and Gemini, applies it, and rolls it back exactly.

.DESCRIPTION
    Enable polls every known smart DNS resolver in parallel, verifies each AI service through the
    proxy it returns (Cloudflare region, API answers, DPI stalls, SNI resets), applies the best
    resolver with a fallback, routes services the primary cannot open through NRPT, and finally
    re-checks everything through the system resolver.

    Disable restores the adapter, IPv6, NRPT, DoH, browser policy and hosts settings saved before
    the first change and removes all AI-DNS data. Update runs Disable, clears every cache and then
    runs Enable with freshly downloaded provider lists. Status shows the current configuration and
    checks every service without changing anything. Settings opens the interactive settings menu.

    Enable, Disable and Update relaunch themselves through the UAC prompt when not elevated. Before
    that they mention a new release once, unless that is switched off in the settings.

.PARAMETER Action
    Enable, Disable, Update, Status or Settings.

.PARAMETER TestOnly
    Enable only: rank the resolvers and stop without changing anything.

.PARAMETER DryRun
    Perform every check but only log the changes instead of making them.

.PARAMETER Trace
    Log every probe and every change with the state before and after it.

.PARAMETER Full
    Disable and Update: reset all adapters to DHCP, delete the commented-out hosts entries and
    remove the data directory even after errors.

.PARAMETER ResetNetwork
    Disable only: also reset Winsock and TCP/IP. A restart is required afterwards.

.PARAMETER EnableIPv6
    Disable and Update: enable IPv6 on every adapter, not only where AI-DNS disabled it.

.PARAMETER Offline
    Enable and Update: do not download provider lists; use the bundled list and the cache.

.PARAMETER Language
    Console language: Auto (from the Windows UI language), en or ru.

.PARAMETER LogDirectory
    Where to write the log. Defaults to %ProgramData%\AIDNS\logs.

.PARAMETER NoWait
    Close the window as soon as the action finishes.

.PARAMETER NoUpdateCheck
    Do not look for a new release before starting.

.EXAMPLE
    .\AI-DNS.ps1 -Action Enable -TestOnly

.EXAMPLE
    .\AI-DNS.ps1 -Action Disable -Full

.EXAMPLE
    .\AI-DNS.ps1 -Action Settings

.NOTES
    Exit codes: 0 success, 1 failure, 2 no working resolver found, 3 finished with problems,
    1223 elevation was cancelled.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Enable', 'Disable', 'Update', 'Status', 'Settings')]
    [string] $Action,

    [switch] $TestOnly,
    [switch] $DryRun,
    [switch] $Trace,
    [switch] $Full,
    [switch] $ResetNetwork,
    [switch] $EnableIPv6,
    [switch] $Offline,

    [ValidateSet('Auto', 'en', 'ru')]
    [string] $Language = 'Auto',

    [string] $LogDirectory,

    [switch] $NoWait,

    [switch] $NoUpdateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src\AIDNS.psd1') -Force

if ($Action -eq 'Settings') { exit (Start-AiDnsSettingsMenu -Language $Language) }

# The elevated copy starts in System32, so a relative log directory must be resolved here.
if ($PSBoundParameters.ContainsKey('LogDirectory')) {
    $PSBoundParameters['LogDirectory'] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDirectory)
}

# Shown here, before elevation, so the release page opens in the user's own browser session.
if ($Action -ne 'Status' -and -not $NoUpdateCheck) {
    Invoke-AiDnsVersionCheck -Language $Language
    $PSBoundParameters['NoUpdateCheck'] = [switch]::Present
}

if ($Action -ne 'Status' -and -not (Test-AiDnsElevation)) {
    exit (Request-AiDnsElevation -ScriptPath $PSCommandPath -Parameters $PSBoundParameters -Language $Language)
}

$arguments = @{}
foreach ($name in $PSBoundParameters.Keys) {
    if ($name -notin @('NoWait', 'NoUpdateCheck')) { $arguments[$name] = $PSBoundParameters[$name] }
}
$exitCode = Invoke-AiDns @arguments
if (-not $NoWait) { Wait-AiDnsExit -ExitCode $exitCode }
exit $exitCode
