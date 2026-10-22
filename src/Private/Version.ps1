# The new-version notice: shown at most once per release, before Enable, Disable or Update start working.

<#
.SYNOPSIS
    Reads a GitHub "latest release" document.
.OUTPUTS
    An object with Version and Url, or $null when the document is not a release of this repository.
#>
function ConvertFrom-ReleaseInfo {
    param([AllowNull()] $Release)

    $tag = [string](Get-JsonProperty $Release 'tag_name' '')
    $url = [string](Get-JsonProperty $Release 'html_url' '')
    $match = [regex]::Match($tag, '^v?(\d+\.\d+\.\d+)$')
    if (-not $match.Success) { return $null }
    if (-not $url.StartsWith("$script:RepositoryUrl/releases/", [StringComparison]::Ordinal)) { return $null }
    return [pscustomobject]@{ Version = [version]$match.Groups[1].Value; Url = $url }
}

<#
.SYNOPSIS
    Asks GitHub for the latest release, giving up after UpdateCheckTimeoutMs so a slow network
    never delays the run noticeably.
.OUTPUTS
    The release (see ConvertFrom-ReleaseInfo), or $null.
#>
function Get-AiDnsLatestRelease {
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = [Net.Http.HttpClient]::new()
        try {
            $client.Timeout = [TimeSpan]::FromMilliseconds($script:UpdateCheckTimeoutMs)
            $client.DefaultRequestHeaders.UserAgent.ParseAdd("AI-DNS/$script:ModuleVersion")
            $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
            # HttpClient starts the request on the thread pool, so even name resolution is bounded by this wait.
            $task = $client.GetStringAsync($script:LatestReleaseApi)
            if (-not $task.Wait($script:UpdateCheckTimeoutMs)) { return $null }
            return ConvertFrom-ReleaseInfo (ConvertFrom-Json -InputObject $task.Result)
        }
        finally { $client.Dispose() }
    }
    catch {
        Write-Verbose "Update check failed: $($_.Exception.GetBaseException().Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Tests whether Latest is newer than this copy and than the version the user was already told about.
#>
function Test-NewerRelease {
    param([Parameter(Mandatory)] [version] $Latest, [AllowEmptyString()] [string] $Dismissed)

    if ($Latest -le $script:ModuleVersion) { return $false }
    $seen = $null
    if ($Dismissed -and [version]::TryParse($Dismissed, [ref]$seen) -and $Latest -le $seen) { return $false }
    return $true
}

<#
.SYNOPSIS
    Checks for a new release at most once a day and, if there is one the user has not seen, offers
    to open its page. Whatever the answer, that release is never announced again.
.PARAMETER Language
    UI language of the notice.
#>
function Invoke-AiDnsVersionCheck {
    param([ValidateSet('Auto', 'en', 'ru')] [string] $Language = 'Auto')

    $settings = Get-AiDnsSetting
    if (-not $settings.CheckUpdates) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }

    $now = [DateTime]::UtcNow
    $last = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::RoundtripKind
    if ([DateTime]::TryParse($settings.LastUpdateCheck, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$last) -and
        ($now - $last.ToUniversalTime()) -lt $script:UpdateCheckInterval -and $last.ToUniversalTime() -le $now) { return }

    $release = Get-AiDnsLatestRelease
    $settings.LastUpdateCheck = $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if ($null -ne $release -and (Test-NewerRelease $release.Version $settings.DismissedVersion)) {
        Import-AiDnsStringTable (Resolve-AiDnsLanguage $Language)
        try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose 'Console encoding is fixed by the host.' }
        Write-Host ''
        Write-Host ('  [i] ' + (Get-Text 'UpdateCheck.Available' @($release.Version, $script:ModuleVersion))) -ForegroundColor Cyan
        Write-Host ('      ' + (Get-Text 'UpdateCheck.Keys')) -ForegroundColor Gray
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
        while ($true) {
            $key = [Console]::ReadKey($true).Key
            if ($key -eq 'Escape') { break }
            if ($key -eq 'Enter') {
                try { Start-Process $release.Url } catch { Write-Host ('      ' + $release.Url) -ForegroundColor Gray }
                break
            }
        }
        $settings.DismissedVersion = $release.Version.ToString()
    }
    $null = Save-AiDnsSetting $settings
}
