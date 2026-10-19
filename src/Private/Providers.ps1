# Provider catalog: the bundled list, remote feeds with a local cache, parsing and merging.

<#
.SYNOPSIS
    Normalizes a DoH template to https://host/path, or returns $null when it is unusable.
    The RFC 8484 "{?dns}" suffix is dropped because Windows expects a bare template.
#>
function ConvertTo-DohTemplate {
    param([AllowNull()] [AllowEmptyString()] [string] $Template)

    if ([string]::IsNullOrWhiteSpace($Template)) { return $null }
    $value = $Template.Trim() -replace '\{\?dns\}$', ''
    if ($value -notmatch '^https://([^/\s:?#]+)(/[^\s?#{}]*)$') { return $null }
    $hostName = $Matches[1].ToLowerInvariant()
    if (-not (Test-Hostname $hostName)) { return $null }
    return "https://$hostName$($Matches[2])"
}

function Get-DohHost {
    param([Parameter(Mandatory)] [string] $Template)
    if ($Template -match '^https://([^/]+)/') { return $Matches[1] }
    return $null
}

<#
.SYNOPSIS
    Builds a validated provider entry. Invalid addresses, hosts and templates are dropped
    silently; an entry with nothing left to test yields $null.
#>
function New-ProviderEntry {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [AllowNull()] [AllowEmptyString()] [string] $Name,
        [object[]] $Hosts = @(),
        [object[]] $Ipv4 = @(),
        [object[]] $Doh = @(),
        [Parameter(Mandatory)] [string] $Source
    )

    $max = $script:Limits.AddressesPerList
    $templates = @($Doh | ForEach-Object { ConvertTo-DohTemplate ([string]$_) } | Where-Object { $_ } |
        Select-Object -Unique | Select-Object -First $script:Limits.DohPerProvider)
    # A DoH host usually resolves to the same resolvers, so it doubles as a discovery name.
    $names = @(@($Hosts) + @($templates | ForEach-Object { Get-DohHost $_ }) |
        ForEach-Object { ([string]$_).Trim().TrimEnd('.').ToLowerInvariant() } |
        Where-Object { Test-Hostname $_ } | Select-Object -Unique | Select-Object -First $max)
    $addresses = @($Ipv4 | ForEach-Object { ([string]$_).Trim() } | Where-Object { Test-PublicIPv4 $_ } |
        Select-Object -Unique | Select-Object -First $max)
    if ($addresses.Count -eq 0 -and $names.Count -eq 0) { return $null }

    $label = ConvertTo-SafeText $Name $script:Limits.ProviderNameLength
    if (-not $label) { $label = $Id }
    return [pscustomobject]@{
        Id     = $Id
        Name   = $label
        Hosts  = [string[]]$names
        Ipv4   = [string[]]$addresses
        Doh    = [string[]]$templates
        Source = $Source
    }
}

<#
.SYNOPSIS
    Parses a catalog in the providers.json format.
.OUTPUTS
    An object with Providers (validated entries) and Retired (addresses recognised during rollback only).
    Throws when the document is not JSON or has an unsupported schemaVersion.
#>
function ConvertFrom-ProviderCatalog {
    param([Parameter(Mandatory)] [string] $Json, [Parameter(Mandatory)] [string] $Source)

    $document = ConvertFrom-Json -InputObject $Json
    $version = Get-JsonProperty $document 'schemaVersion'
    if ($version -ne 1) { throw (Get-Text 'Error.CatalogVersion' @($Source, $version)) }

    $providers = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-JsonProperty $document 'providers' @())) {
        if ($providers.Count -ge $script:Limits.Providers) { break }
        $id = [string](Get-JsonProperty $entry 'id' '')
        if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{0,31}$') { continue }
        $provider = New-ProviderEntry -Id $id -Name ([string](Get-JsonProperty $entry 'name' $id)) -Source $Source `
            -Hosts @(Get-JsonProperty $entry 'hosts' @()) -Ipv4 @(Get-JsonProperty $entry 'ipv4' @()) `
            -Doh @(Get-JsonProperty $entry 'doh' @())
        if ($null -ne $provider) { $providers.Add($provider) }
    }
    $retired = @(@(Get-JsonProperty $document 'retiredIpv4' @()) | ForEach-Object { [string]$_ } |
        Where-Object { Test-PublicIPv4 $_ } | Select-Object -Unique)
    return [pscustomobject]@{ Providers = $providers.ToArray(); Retired = [string[]]$retired }
}

<#
.SYNOPSIS
    Parses the DnsSwitch presets.txt format: "id | name | description | ip1, ip2 | DoH template".
.OUTPUTS
    Validated provider entries with ids prefixed by "dnsswitch-".
#>
function ConvertFrom-DnsSwitchPreset {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [string] $Source = 'dnsswitch')

    $providers = [Collections.Generic.List[object]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($providers.Count -ge $script:Limits.Providers) { break }
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = @($trimmed -split '\|' | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 4) { continue }
        $slug = $parts[0].ToLowerInvariant() -replace '[^a-z0-9-]', ''
        if (-not $slug) { continue }
        $id = ('dnsswitch-' + $slug)
        if ($id.Length -gt 32) { $id = $id.Substring(0, 32).TrimEnd('-') }
        $doh = @()
        if ($parts.Count -ge 5) { $doh = @($parts[4]) }
        $provider = New-ProviderEntry -Id $id -Name $parts[1] -Ipv4 @($parts[3] -split '[,;\s]+') -Doh $doh -Source $Source
        if ($null -ne $provider) { $providers.Add($provider) }
    }
    return $providers.ToArray()
}

<#
.SYNOPSIS
    Merges provider lists in priority order. Entries with the same id, or sharing an address,
    host or DoH template with an earlier entry, are folded into it so a resolver is attributed
    to one provider only.
#>
function Merge-ProviderList {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Providers)

    $merged = [Collections.Generic.List[object]]::new()
    foreach ($incoming in $Providers) {
        if ($null -eq $incoming) { continue }
        $target = $null
        foreach ($existing in $merged) {
            if ($existing.Id -eq $incoming.Id -or
                @($existing.Ipv4 | Where-Object { $incoming.Ipv4 -contains $_ }).Count -gt 0 -or
                @($existing.Hosts | Where-Object { $incoming.Hosts -contains $_ }).Count -gt 0 -or
                @($existing.Doh | Where-Object { $incoming.Doh -contains $_ }).Count -gt 0) {
                $target = $existing
                break
            }
        }
        if ($null -eq $target) {
            if ($merged.Count -lt $script:Limits.Providers) {
                $merged.Add([pscustomobject]@{
                    Id = $incoming.Id; Name = $incoming.Name; Hosts = $incoming.Hosts; Ipv4 = $incoming.Ipv4
                    Doh = $incoming.Doh; Source = $incoming.Source
                })
            }
            continue
        }
        $max = $script:Limits.AddressesPerList
        $target.Ipv4 = [string[]]@(@($target.Ipv4) + @($incoming.Ipv4) | Select-Object -Unique | Select-Object -First $max)
        $target.Hosts = [string[]]@(@($target.Hosts) + @($incoming.Hosts) | Select-Object -Unique | Select-Object -First $max)
        $target.Doh = [string[]]@(@($target.Doh) + @($incoming.Doh) | Select-Object -Unique | Select-Object -First $script:Limits.DohPerProvider)
    }
    return $merged.ToArray()
}

function Get-FeedCachePath {
    param([Parameter(Mandatory)] $Feed)
    Join-Path $script:Paths.Cache "feed-$($Feed.Id).txt"
}

function ConvertFrom-FeedText {
    param([Parameter(Mandatory)] $Feed, [Parameter(Mandatory)] [string] $Text)

    switch ($Feed.Format) {
        'AiDnsJson' {
            $catalog = ConvertFrom-ProviderCatalog -Json $Text -Source $Feed.Id
            return [pscustomobject]@{ Providers = $catalog.Providers; Retired = $catalog.Retired }
        }
        'DnsSwitchPresets' {
            return [pscustomobject]@{ Providers = @(ConvertFrom-DnsSwitchPreset -Text $Text -Source $Feed.Id); Retired = [string[]]@() }
        }
        default { throw "Unknown feed format '$($Feed.Format)'." }
    }
}

<#
.SYNOPSIS
    Returns the parsed content of every feed, downloading the ones whose cache is missing or older
    than the TTL. A failed download falls back to the stale cache; a document that does not parse
    or contains no providers never replaces a good cache.
.PARAMETER Refresh
    Ignore the TTL and download every feed.
.PARAMETER Offline
    Use cached copies only.
#>
function Get-FeedProvider {
    param([switch] $Refresh, [switch] $Offline)

    $results = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.List[object]]::new()
    foreach ($feed in $script:Feeds) {
        $cachePath = Get-FeedCachePath $feed
        $cache = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
        $fresh = $null -ne $cache -and ((Get-Date) - $cache.LastWriteTime) -lt $script:FeedTtl
        if ($Offline -or ($fresh -and -not $Refresh)) {
            if ($null -ne $cache) {
                try {
                    $parsed = ConvertFrom-FeedText $feed ([IO.File]::ReadAllText($cachePath))
                    $results.Add([pscustomobject]@{ Feed = $feed; Origin = 'Cache'; Parsed = $parsed })
                }
                catch { Write-TraceLine "feed $($feed.Id): cache unreadable: $($_.Exception.Message)" }
            }
            continue
        }
        $pending.Add([pscustomobject]@{ Feed = $feed; CachePath = $cachePath; Cache = $cache })
    }
    if ($pending.Count -eq 0) { return $results.ToArray() }

    $urls = [string[]]@($pending | ForEach-Object { $_.Feed.Urls })
    $agent = "AI-DNS/$script:ModuleVersion (+$script:RepositoryUrl)"
    $fetched = @([AiDns.Fetcher]::FetchAll($urls, $script:FeedTimeoutMs, $script:FeedMaxBytes, $agent))
    foreach ($f in $fetched) {
        Write-TraceLine ('fetch {0} ok={1} status={2} ms={3:N0} bytes={4} {5}' -f $f.Url, $f.Ok, $f.Status, $f.Ms,
            $(if ($f.Ok) { $f.Content.Length } else { 0 }), $f.Error)
    }

    foreach ($item in $pending) {
        $feed = $item.Feed
        $parsed = $null
        foreach ($url in $feed.Urls) {
            $hit = $fetched | Where-Object { $_.Url -eq $url -and $_.Ok } | Select-Object -First 1
            if ($null -eq $hit) { continue }
            try {
                $candidate = ConvertFrom-FeedText $feed $hit.Content
                if (@($candidate.Providers).Count -eq 0) { throw 'no providers' }
                $parsed = $candidate
                $null = New-Item -ItemType Directory -Path $script:Paths.Cache -Force
                [IO.File]::WriteAllText($item.CachePath, $hit.Content, [Text.UTF8Encoding]::new($false))
                break
            }
            catch { Write-TraceLine "feed $($feed.Id): $url rejected: $($_.Exception.Message)" }
        }
        if ($null -ne $parsed) {
            $results.Add([pscustomobject]@{ Feed = $feed; Origin = 'Remote'; Parsed = $parsed })
            continue
        }
        if ($null -ne $item.Cache) {
            try {
                $stale = ConvertFrom-FeedText $feed ([IO.File]::ReadAllText($item.CachePath))
                $results.Add([pscustomobject]@{ Feed = $feed; Origin = 'StaleCache'; Parsed = $stale })
                continue
            }
            catch { Write-TraceLine "feed $($feed.Id): stale cache unreadable: $($_.Exception.Message)" }
        }
        $results.Add([pscustomobject]@{ Feed = $feed; Origin = 'Unavailable'; Parsed = $null })
    }
    return $results.ToArray()
}

<#
.SYNOPSIS
    Assembles the provider catalog from the bundled providers.json and the remote feeds.
.OUTPUTS
    An object with Providers (merged, bundled entries first), Retired addresses and Feeds (per-feed origin).
    Throws only when the bundled catalog itself is missing or invalid.
#>
function Get-ProviderCatalog {
    param([switch] $Refresh, [switch] $Offline)

    $bundled = ConvertFrom-ProviderCatalog -Json ([IO.File]::ReadAllText($script:Paths.Catalog)) -Source 'bundled'
    $feeds = @()
    if (-not $Offline -or (Test-Path -LiteralPath $script:Paths.Cache)) {
        $feeds = @(Get-FeedProvider -Refresh:$Refresh -Offline:$Offline)
    }

    $all = @($bundled.Providers)
    $retired = @($bundled.Retired)
    foreach ($feed in $feeds) {
        if ($null -eq $feed.Parsed) { continue }
        $all += @($feed.Parsed.Providers)
        $retired += @($feed.Parsed.Retired)
    }
    return [pscustomobject]@{
        Providers = @(Merge-ProviderList -Providers $all)
        Retired   = [string[]]@($retired | Select-Object -Unique)
        Feeds     = $feeds
    }
}
