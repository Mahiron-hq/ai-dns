# Localized console text. Strings live in <culture>\AIDNS.Strings.psd1 next to the module.

$script:SupportedLanguages = @('en', 'ru')
$script:Strings = @{}

<#
.SYNOPSIS
    Resolves the UI language: an explicit choice, then the settings, then Russian for Russian-speaking
    Windows, otherwise English.
#>
function Resolve-AiDnsLanguage {
    param([ValidateSet('Auto', 'en', 'ru')] [string] $Language = 'Auto')

    if ($Language -ne 'Auto') { return $Language }
    $configured = (Get-AiDnsSetting).Language
    if ($configured -ne 'Auto') { return $configured }
    $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if ($ui -in @('ru', 'be', 'kk', 'ky', 'tg')) { return 'ru' }
    return 'en'
}

<#
.SYNOPSIS
    Loads the string table for the given language into module scope.
.OUTPUTS
    None. Throws if the table cannot be found or parsed.
#>
function Import-AiDnsStringTable {
    param([Parameter(Mandatory)] [ValidateSet('en', 'ru')] [string] $Language)

    $culture = if ($Language -eq 'ru') { 'ru-RU' } else { 'en-US' }
    $table = Import-LocalizedData -BaseDirectory $script:ModuleRoot -FileName 'AIDNS.Strings.psd1' -UICulture $culture -ErrorAction Stop
    $script:Strings = $table
}

<#
.SYNOPSIS
    Returns the localized string for Key, formatted with Arguments. A missing key yields the key itself,
    so an incomplete translation degrades to readable identifiers instead of failing the run.
#>
function Get-Text {
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Key,
        [Parameter(Position = 1)] [object[]] $Arguments = @()
    )

    $template = $script:Strings[$Key]
    if ($null -eq $template) { $template = $Key }
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) { return [string]$template }
    return [string]::Format([Globalization.CultureInfo]::CurrentCulture, [string]$template, $Arguments)
}

function Get-ServiceLabel {
    param([Parameter(Mandatory)] $Service)

    $key = "Service.$($Service.Id)"
    if ($script:Strings.ContainsKey($key)) { return [string]$script:Strings[$key] }
    return $Service.Name
}
