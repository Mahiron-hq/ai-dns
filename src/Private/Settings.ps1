# User settings: settings.json next to AI-DNS.ps1, edited through AI-DNS-Settings.bat.
# Every value is validated on load, so a hand-edited or damaged file degrades to defaults instead of failing a run.

$script:SettingsSchemaVersion = 1
$script:Settings = $null
$script:SettingsProblem = $null

# Launcher switches a user can turn on by default. Each applies only to the actions that accept it.
$script:SettingFlags = [ordered]@{
    TestOnly     = @('Enable')
    DryRun       = @('Enable', 'Disable', 'Update')
    Trace        = @('Enable', 'Disable', 'Update', 'Status')
    Offline      = @('Enable', 'Update')
    Full         = @('Disable', 'Update')
    EnableIPv6   = @('Disable', 'Update')
    ResetNetwork = @('Disable')
}
# What Enable may change. Disable always reverts all of them.
$script:SystemToggles = @('DisableIpv6', 'BrowserPolicies', 'Hosts', 'Nrpt', 'Doh')
$script:WaitChoices = @(0, 5, 10, 20, 30, 60, 120)
$script:ListLimit = 64

function New-AiDnsSetting {
    $modes = [ordered]@{}
    foreach ($s in $script:BuiltInServices) { $modes[$s.Id] = $s.Mode }
    $flags = [ordered]@{}
    foreach ($name in $script:SettingFlags.Keys) { $flags[$name] = $false }
    $system = [ordered]@{}
    foreach ($name in $script:SystemToggles) { $system[$name] = $true }
    [pscustomobject]@{
        Language         = 'Auto'
        LogDirectory     = ''
        WaitSeconds      = 20
        CheckUpdates     = $true
        DismissedVersion = ''
        LastUpdateCheck  = ''
        Flags            = [pscustomobject]$flags
        System           = [pscustomobject]$system
        Modes            = $modes
        CustomServices   = [Collections.Generic.List[object]]::new()
        CustomResolvers  = [Collections.Generic.List[string]]::new()
        BlockedProviders = [Collections.Generic.List[string]]::new()
        BlockedAddresses = [Collections.Generic.List[string]]::new()
        PinnedProvider   = ''
        Blocking         = [Collections.Generic.List[string]]::new()
    }
}

function ConvertTo-ServiceMode {
    param([AllowNull()] $Value)

    $text = [string]$Value
    foreach ($mode in $script:ServiceModes) {
        if ($mode -eq $text) { return $mode }
    }
    return $null
}

# Only a JSON boolean counts: in PowerShell the string "false" would convert to $true.
function ConvertTo-SettingBool {
    param([AllowNull()] $Value, [Parameter(Mandatory)] [bool] $Default)
    if ($Value -is [bool]) { return $Value }
    return $Default
}

function Test-ProviderId {
    param([AllowNull()] [AllowEmptyString()] [string] $Id)
    return (-not [string]::IsNullOrEmpty($Id)) -and $Id -cmatch '^[a-z0-9][a-z0-9-]{0,31}$'
}

<#
.SYNOPSIS
    Turns user input such as "https://www.Example.com/path" into a bare lower-case ASCII domain.
.OUTPUTS
    System.String, or $null when the input is not a valid domain name.
#>
function ConvertTo-AiDnsDomain {
    param([AllowNull()] [AllowEmptyString()] [string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = $Text.Trim() -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $value = ($value -split '[/?#]', 2)[0]
    $value = ($value -replace ':\d+$', '').TrimEnd('.').ToLowerInvariant()
    if ($value.StartsWith('*.')) { $value = $value.Substring(2) }
    if ($value.StartsWith('www.')) { $value = $value.Substring(4) }
    try { $value = [Globalization.IdnMapping]::new().GetAscii($value) }
    catch { return $null }
    if (-not (Test-Hostname $value)) { return $null }
    return $value
}

function Get-CustomServiceId {
    param([Parameter(Mandatory)] [string] $Domain)
    "custom-$Domain"
}

<#
.SYNOPSIS
    Builds the service entry for a user-added domain. It is checked with the Strict rule and routed
    through NRPT together with its subdomains.
#>
function New-CustomService {
    param([Parameter(Mandatory)] [string] $Domain, [ValidateSet('Required', 'Preferred', 'Off')] [string] $Mode = 'Required')

    [pscustomobject]@{
        Id = (Get-CustomServiceId $Domain); Mode = $Mode; Name = $Domain; Domain = $Domain; Weight = 100; Group = 'Custom'; Kind = 'Strict'
        RegionFrom = $null; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'), (New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @($Domain, ".$Domain")
    }
}

<#
.SYNOPSIS
    Finds a service whose namespaces contain Domain or are contained in it, so the same names are
    never routed by two rules.
.OUTPUTS
    The conflicting service, or $null.
#>
function Find-ServiceOverlap {
    param([Parameter(Mandatory)] [string] $Domain, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Services)

    foreach ($service in $Services) {
        foreach ($ns in @(@($service.Namespaces) + $service.Domain)) {
            $name = ([string]$ns).TrimStart('.').ToLowerInvariant()
            if ($name -eq $Domain -or $name.EndsWith(".$Domain") -or $Domain.EndsWith(".$name")) { return $service }
        }
    }
    return $null
}

function Get-StringList {
    param([AllowNull()] $Value, [Parameter(Mandatory)] [scriptblock] $Filter)

    $list = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $text = ([string]$item).Trim()
        if ($text -and -not $list.Contains($text) -and $list.Count -lt $script:ListLimit -and (& $Filter $text)) { $list.Add($text) }
    }
    return , $list
}

<#
.SYNOPSIS
    Validates a deserialized settings.json. Unknown fields are ignored and invalid values fall back
    to their defaults one by one.
#>
function ConvertFrom-AiDnsSettingsDocument {
    param([AllowNull()] $Document)

    $settings = New-AiDnsSetting
    if ($null -eq $Document) { return $settings }

    $language = [string](Get-JsonProperty $Document 'language' 'Auto')
    if ($language -in @('Auto', 'en', 'ru')) { $settings.Language = @('Auto', 'en', 'ru') | Where-Object { $_ -eq $language } }
    $directory = [string](Get-JsonProperty $Document 'logDirectory' '')
    if ($directory.IndexOfAny([IO.Path]::GetInvalidPathChars()) -lt 0) { $settings.LogDirectory = $directory.Trim() }
    $wait = Get-JsonProperty $Document 'waitSeconds' 20
    if ($wait -is [ValueType] -and $script:WaitChoices -contains [int]$wait) { $settings.WaitSeconds = [int]$wait }
    $settings.CheckUpdates = ConvertTo-SettingBool (Get-JsonProperty $Document 'checkUpdates') $true
    $dismissed = [string](Get-JsonProperty $Document 'dismissedVersion' '')
    if ($dismissed -match '^\d+(\.\d+){1,3}$') { $settings.DismissedVersion = $dismissed }
    $checked = [string](Get-JsonProperty $Document 'lastUpdateCheck' '')
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($checked, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        $settings.LastUpdateCheck = $checked
    }

    $flags = Get-JsonProperty $Document 'flags'
    foreach ($name in $script:SettingFlags.Keys) { $settings.Flags.$name = ConvertTo-SettingBool (Get-JsonProperty $flags $name) $false }
    $system = Get-JsonProperty $Document 'system'
    foreach ($name in $script:SystemToggles) { $settings.System.$name = ConvertTo-SettingBool (Get-JsonProperty $system $name) $true }

    $services = Get-JsonProperty $Document 'services'
    foreach ($s in $script:BuiltInServices) {
        $mode = ConvertTo-ServiceMode (Get-JsonProperty $services $s.Id)
        if ($null -ne $mode) { $settings.Modes[$s.Id] = $mode }
    }
    foreach ($entry in @(Get-JsonProperty $Document 'customServices' @())) {
        if ($settings.CustomServices.Count -ge $script:CustomServiceLimit) { break }
        $domain = ConvertTo-AiDnsDomain ([string](Get-JsonProperty $entry 'domain' ''))
        $mode = ConvertTo-ServiceMode (Get-JsonProperty $entry 'mode' 'Required')
        if ($null -eq $domain -or $null -eq $mode) { continue }
        $existing = @($script:BuiltInServices) + @($settings.CustomServices | ForEach-Object { New-CustomService $_.Domain })
        if ($null -ne (Find-ServiceOverlap $domain $existing)) { continue }
        $settings.CustomServices.Add([pscustomobject]@{ Domain = $domain; Mode = $mode })
    }

    $settings.CustomResolvers = Get-StringList (Get-JsonProperty $Document 'customResolvers' @()) { param($v) Test-PublicIPv4 $v }
    $settings.BlockedAddresses = Get-StringList (Get-JsonProperty $Document 'blockedAddresses' @()) { param($v) Test-PublicIPv4 $v }
    $settings.BlockedProviders = Get-StringList (Get-JsonProperty $Document 'blockedProviders' @()) { param($v) Test-ProviderId $v }
    $pinned = [string](Get-JsonProperty $Document 'pinnedProvider' '')
    if (Test-ProviderId $pinned) { $settings.PinnedProvider = $pinned }
    $settings.Blocking = Get-StringList (Get-JsonProperty $Document 'blocking' @()) { param($v) $v -cmatch '^[a-z0-9.-]{1,300}$' }
    return $settings
}

function ConvertTo-AiDnsSettingsDocument {
    param([Parameter(Mandatory)] $Settings)

    $flags = [ordered]@{}
    foreach ($name in $script:SettingFlags.Keys) { $flags[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = [bool]$Settings.Flags.$name }
    $system = [ordered]@{}
    foreach ($name in $script:SystemToggles) { $system[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] = [bool]$Settings.System.$name }
    [ordered]@{
        schemaVersion    = $script:SettingsSchemaVersion
        language         = $Settings.Language
        logDirectory     = $Settings.LogDirectory
        waitSeconds      = $Settings.WaitSeconds
        checkUpdates     = $Settings.CheckUpdates
        dismissedVersion = $Settings.DismissedVersion
        lastUpdateCheck  = $Settings.LastUpdateCheck
        flags            = $flags
        system           = $system
        services         = $Settings.Modes
        customServices   = @($Settings.CustomServices | ForEach-Object { [ordered]@{ domain = $_.Domain; mode = $_.Mode } })
        customResolvers  = @($Settings.CustomResolvers)
        blockedProviders = @($Settings.BlockedProviders)
        blockedAddresses = @($Settings.BlockedAddresses)
        pinnedProvider   = $Settings.PinnedProvider
        blocking         = @($Settings.Blocking)
    }
}

<#
.SYNOPSIS
    Returns the settings of this copy, reading settings.json on first use. A damaged file yields the
    defaults and is described in $script:SettingsProblem.
#>
function Get-AiDnsSetting {
    param([switch] $Reload)

    if ($null -ne $script:Settings -and -not $Reload) { return $script:Settings }
    $script:SettingsProblem = $null
    $document = $null
    try { $document = Read-JsonFile $script:Paths.Settings }
    catch { $script:SettingsProblem = $_.Exception.Message }
    $script:Settings = ConvertFrom-AiDnsSettingsDocument $document
    return $script:Settings
}

<#
.SYNOPSIS
    Writes the settings to settings.json. Settings belong to the user, not to the system, so this is
    not a system change and also happens in a dry run.
.OUTPUTS
    System.Boolean. False when the file could not be written; the reason is traced.
#>
function Save-AiDnsSetting {
    param([Parameter(Mandatory)] $Settings)

    try {
        Write-JsonFile $script:Paths.Settings (ConvertTo-AiDnsSettingsDocument $Settings)
        $script:Settings = $Settings
        $script:SettingsProblem = $null
        return $true
    }
    catch {
        Write-TraceLine "settings: write failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    The service table for the given settings: built-in services with the user's modes, then the
    user's domains.
#>
function Get-AiDnsServiceTable {
    param([Parameter(Mandatory)] $Settings)

    $table = [Collections.Generic.List[object]]::new()
    foreach ($s in $script:BuiltInServices) {
        $copy = $s.PSObject.Copy()
        $copy.Mode = $Settings.Modes[$s.Id]
        $table.Add($copy)
    }
    foreach ($entry in $Settings.CustomServices) { $table.Add((New-CustomService $entry.Domain $entry.Mode)) }
    return $table.ToArray()
}

function Use-AiDnsSetting {
    param([Parameter(Mandatory)] $Settings)
    $script:Services = Get-AiDnsServiceTable $Settings
}

<#
.SYNOPSIS
    The log directory from the settings as an absolute path; a relative one is taken from the folder of the launchers.
.OUTPUTS
    System.String, or $null when no directory is configured.
#>
function Resolve-SettingsLogDirectory {
    param([Parameter(Mandatory)] $Settings)

    if ([string]::IsNullOrWhiteSpace($Settings.LogDirectory)) { return $null }
    # Path.Combine, unlike Join-Path, returns an absolute second path unchanged.
    try { return [IO.Path]::GetFullPath([IO.Path]::Combine((Split-Path -Parent $script:Paths.Settings), $Settings.LogDirectory)) }
    catch { return $null }
}

function Test-SettingFlag {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Action)
    return [bool]$Settings.Flags.$Name -and $script:SettingFlags[$Name] -contains $Action
}

<#
.SYNOPSIS
    Removes user-added domains and switches built-in services off.
#>
function Remove-AiDnsServiceCheck {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string[]] $Ids)

    foreach ($id in $Ids) {
        $custom = @($Settings.CustomServices | Where-Object { (Get-CustomServiceId $_.Domain) -eq $id })
        foreach ($entry in $custom) { $null = $Settings.CustomServices.Remove($entry) }
        if ($Settings.Modes.Contains($id)) { $Settings.Modes[$id] = 'Off' }
        $null = $Settings.Blocking.Remove($id)
    }
}

function Set-AiDnsServiceMode {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Id, [Parameter(Mandatory)] [ValidateSet('Required', 'Preferred', 'Off')] [string] $Mode)

    if ($Settings.Modes.Contains($Id)) { $Settings.Modes[$Id] = $Mode }
    foreach ($entry in @($Settings.CustomServices | Where-Object { (Get-CustomServiceId $_.Domain) -eq $Id })) { $entry.Mode = $Mode }
    if ($Mode -ne 'Required') { $null = $Settings.Blocking.Remove($Id) }
}
