# Turns raw probe results into per-service verdicts, scores candidates and picks the plan.

function New-Verdict {
    param(
        [Parameter(Mandatory, Position = 0)] [bool] $Ok,
        [Parameter(Mandatory, Position = 1)] [string] $Reason,
        [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments
    )
    if ($null -eq $Arguments) { $Arguments = @() }
    [pscustomobject]@{ Ok = $Ok; Reason = $Reason; Arguments = $Arguments }
}

function Format-Verdict {
    param([Parameter(Mandatory)] $Verdict)
    Get-Text "Verdict.$($Verdict.Reason)" $Verdict.Arguments
}

function Format-ProbeError {
    param([Parameter(Mandatory)] $ProbeError, [AllowNull()] [AllowEmptyString()] [string] $Detail)

    $text = Get-Text "ProbeError.$ProbeError"
    if ([string]::IsNullOrEmpty($Detail)) { return $text }
    return "$text ($Detail)"
}

function Get-CheckKey {
    param([string] $Address, [string] $Domain, [string] $Path)
    "$Address|$Domain|$Path"
}

function Get-Net16 {
    param([Parameter(Mandatory)] [string] $Address)
    ($Address.Split('.')[0..1]) -join '.'
}

<#
.SYNOPSIS
    Tests whether the resolver answered with its own proxy rather than the service's real address.
.DESCRIPTION
    The comparison is by /16 network: an address in the same /16 as any reference answer for the
    domain, or in a Google front-end network, is the real service and therefore not proxied.
#>
function Test-ProxiedAddress {
    param(
        [Parameter(Mandatory)] [string[]] $Addresses,
        [Parameter(Mandatory)] [string] $Domain,
        [Parameter(Mandatory)] [hashtable] $Reference
    )

    $nets = @(@($Reference[$Domain]) | Where-Object { $_ } | ForEach-Object { Get-Net16 $_ }) + $script:GooglePrefixes
    foreach ($address in $Addresses) {
        if ($nets -contains (Get-Net16 $address)) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
    Extracts the Cloudflare edge region ("loc=XX") from a /cdn-cgi/trace response, or $null.
#>
function Get-CloudflareRegion {
    param([AllowNull()] $Probe)

    if ($null -eq $Probe -or $Probe.Status -ne 200) { return $null }
    if ($Probe.Head -cmatch '(?m)^loc=([A-Z0-9]{2})\s*$') { return $Matches[1] }
    return $null
}

<#
.SYNOPSIS
    Tests for a Cloudflare bot challenge: such a site answers 403 to every client that does not run
    JavaScript, which says nothing about the region.
#>
function Test-CloudflareChallenge {
    param([AllowNull()] $Probe)
    return $null -ne $Probe -and $Probe.Head -match '(?im)^cf-mitigated:\s*challenge'
}

<#
.SYNOPSIS
    Decides whether Service works through Candidate.
.PARAMETER Candidate
    An object whose Dns property maps service ids to AiDns.DnsQuery results from the candidate.
.PARAMETER Context
    Services (the service table), Reference (domain -> reference addresses) and Https
    (check key -> AiDns.HttpsProbe).
.OUTPUTS
    A verdict with Ok, Reason (a Verdict.* string key) and Arguments.
#>
function Test-ServiceAccess {
    param([Parameter(Mandatory)] $Service, [Parameter(Mandatory)] $Candidate, [Parameter(Mandatory)] $Context)

    $answer = $Candidate.Dns[$Service.Id]
    if ($null -eq $answer) { return New-Verdict $false 'NoData' }
    if (-not $answer.Ok) {
        if ($answer.Error -eq 'Blackholed') { return New-Verdict $false 'Blackholed' }
        return New-Verdict $false 'DnsNoAnswer' (Format-ProbeError $answer.Error)
    }

    $address = $answer.Addresses[0]
    $results = [Collections.Generic.List[object]]::new()
    foreach ($check in $Service.Checks) { $results.Add($Context.Https[(Get-CheckKey $address $Service.Domain $check.Path)]) }

    foreach ($r in $results) {
        if ($null -eq $r) { return New-Verdict $false 'NotChecked' }
        if (-not $r.TcpOk) { return New-Verdict $false 'Unreachable' $address (Format-ProbeError $r.Error $r.Detail) }
        if (-not $r.TlsOk) {
            if ($r.Error -eq 'CertificateInvalid') { return New-Verdict $false 'TlsForged' $r.Detail }
            return New-Verdict $false 'TlsBlocked' (Format-ProbeError $r.Error $r.Detail)
        }
        if ($r.Stalled) { return New-Verdict $false 'Stalled' $r.Detail }
        if ($r.Status -eq 0) { return New-Verdict $false 'NoHttp' (Format-ProbeError $r.Error $r.Detail) }
    }
    $first = $results[0]

    switch ($Service.Kind) {
        'Cloudflare' {
            $region = Get-CloudflareRegion $first
            if (-not $region) { return New-Verdict $false 'NoCloudflare' $first.Status }
            if ($script:BlockedRegions -contains $region) { return New-Verdict $false 'RegionBlocked' $region }
            if ($results.Count -gt 1 -and $results[1].Status -ge 500) { return New-Verdict $false 'HttpStatus' $results[1].Status }
            return New-Verdict $true 'Region' $region
        }
        'GoogleWeb' {
            if ($first.Status -ge 400) { return New-Verdict $false 'HttpStatus' $first.Status }
            if ($Service.RegionFrom) {
                $geo = @($Context.Services | Where-Object { $_.Id -eq $Service.RegionFrom }) | Select-Object -First 1
                if ($null -ne $geo) {
                    $api = Test-ServiceAccess $geo $Candidate $Context
                    if ($api.Ok) { return New-Verdict $true 'GoogleRegionOk' }
                    if ($api.Reason -eq 'GoogleRegionBlocked') { return New-Verdict $false 'GoogleRegionBlocked' }
                }
            }
            if (Test-ProxiedAddress @($address) $Service.Domain $Context.Reference) { return New-Verdict $true 'Proxied' }
            return New-Verdict $false 'DirectGoogle'
        }
        'OpenAiApi' {
            if ($first.Head -match 'unsupported_country') { return New-Verdict $false 'OpenAiRegion' }
            if ($first.Status -eq 401) { return New-Verdict $true 'ApiResponds' }
            return New-Verdict $false 'HttpStatus' $first.Status
        }
        'AnthropicApi' {
            if (-not (Test-ProxiedAddress @($address) $Service.Domain $Context.Reference)) { return New-Verdict $false 'AnthropicDirect' }
            if ($first.Status -eq 401) { return New-Verdict $true 'ApiResponds' }
            if ($first.Status -eq 403) { return New-Verdict $false 'AnthropicRegion' }
            return New-Verdict $false 'HttpStatus' $first.Status
        }
        'GoogleApi' {
            if ($first.Head -match 'location is not supported') { return New-Verdict $false 'GoogleRegionBlocked' }
            if ($first.Head -match 'API key not valid|API_KEY_INVALID') { return New-Verdict $true 'ApiResponds' }
            return New-Verdict $false 'HttpStatus' $first.Status
        }
        'Generic' {
            $region = Get-CloudflareRegion $first
            if ($region) {
                if ($script:BlockedRegions -contains $region) { return New-Verdict $false 'RegionBlocked' $region }
                if ($results.Count -gt 1 -and $results[1].Status -ge 500) { return New-Verdict $false 'HttpStatus' $results[1].Status }
                return New-Verdict $true 'Region' $region
            }
            if (Test-ProxiedAddress @($address) $Service.Domain $Context.Reference) { return New-Verdict $true 'Proxied' }
            if (@($results | Where-Object { $_.Status -eq 403 -or $_.Status -eq 451 }).Count -gt 0) {
                return New-Verdict $false 'NotProxiedStatus' $first.Status
            }
            return New-Verdict $true 'Direct'
        }
        'Strict' {
            $page = $results[$results.Count - 1]
            $region = Get-CloudflareRegion $first
            if ($region -and $script:BlockedRegions -contains $region) { return New-Verdict $false 'RegionBlocked' $region }
            if ($page.Status -in @(403, 451) -and -not (Test-CloudflareChallenge $page)) { return New-Verdict $false 'BlockedStatus' $page.Status }
            if ($page.Status -ge 500) { return New-Verdict $false 'HttpStatus' $page.Status }
            if ($region) { return New-Verdict $true 'Region' $region }
            if (Test-ProxiedAddress @($address) $Service.Domain $Context.Reference) { return New-Verdict $true 'Proxied' }
            return New-Verdict $true 'Direct'
        }
        default { throw "Unknown service kind '$($Service.Kind)'." }
    }
}

<#
.SYNOPSIS
    Fills in the verdicts, the TLS latency and the working DoH template, then scores the candidate.
#>
function Measure-Candidate {
    param([Parameter(Mandatory)] $Candidate, [Parameter(Mandatory)] $Context, [AllowEmptyCollection()] [object[]] $DohProbes = @())

    $tls = [Collections.Generic.List[object]]::new()
    foreach ($service in $Context.Services) {
        $verdict = Test-ServiceAccess $service $Candidate $Context
        $Candidate.Verdicts[$service.Id] = $verdict
        if (-not $verdict.Ok -or $service.Mode -eq 'Off') { continue }
        $address = $Candidate.Dns[$service.Id].Addresses[0]
        foreach ($check in $service.Checks) {
            $probe = $Context.Https[(Get-CheckKey $address $service.Domain $check.Path)]
            if ($null -ne $probe -and $null -ne $probe.TlsMs) { $tls.Add($probe.TlsMs) }
        }
    }
    $Candidate.TlsMs = Get-Median $tls.ToArray()

    foreach ($template in $Candidate.Provider.Doh) {
        $hit = @($DohProbes | Where-Object { $_.Address -eq $Candidate.Address -and $_.Template -eq $template -and $_.Ok })
        if ($hit.Count -gt 0) { $Candidate.DohTemplate = $template; break }
    }
    Update-CandidateScore $Candidate $Context.Services
}

<#
.SYNOPSIS
    The services that decide whether a resolver is usable at all: the checked web and user-added
    services, or every checked service when all of those are switched off.
#>
function Get-GatingService {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Services)

    $active = @($Services | Where-Object { $_.Mode -ne 'Off' })
    $gating = @($active | Where-Object { $_.Group -eq 'Web' -or $_.Group -eq 'Custom' })
    if ($gating.Count -gt 0) { return $gating }
    return $active
}

<#
.SYNOPSIS
    Recomputes the score, the gating counter and the service mask from the existing verdicts, so a
    change of service modes needs no new probes.
.DESCRIPTION
    Score orders by the summed weight of working services first, a required service weighing
    RequiredWeight; DNS and TLS latency only break ties, and an unmeasured latency costs 3 s.
#>
function Update-CandidateScore {
    param([Parameter(Mandatory)] $Candidate, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Services)

    $gating = @(Get-GatingService $Services | ForEach-Object { $_.Id })
    $weight = 0
    $Candidate.WebCount = 0
    $Candidate.ApiCount = 0
    foreach ($service in @($Services | Where-Object { $_.Mode -ne 'Off' })) {
        $verdict = $Candidate.Verdicts[$service.Id]
        if ($null -eq $verdict -or -not $verdict.Ok) { continue }
        $weight += $(if ($service.Mode -eq 'Required') { $script:RequiredWeight } else { $service.Weight })
        if ($gating -contains $service.Id) { $Candidate.WebCount++ }
        elseif ($service.Group -eq 'Api') { $Candidate.ApiCount++ }
    }
    $dnsCost = if ($null -ne $Candidate.DnsMs) { $Candidate.DnsMs } else { 3000 }
    $tlsCost = if ($null -ne $Candidate.TlsMs) { $Candidate.TlsMs } else { 3000 }
    $Candidate.Score = $weight * 10000 - $dnsCost - $tlsCost
    $Candidate.Mask = -join @($gating | ForEach-Object { if ($null -ne $Candidate.Verdicts[$_] -and $Candidate.Verdicts[$_].Ok) { '1' } else { '0' } })
}

<#
.SYNOPSIS
    Chooses the primary and secondary resolver and NRPT routes for services the primary cannot open.
.PARAMETER NoRoutes
    NRPT is not used, so whatever the primary cannot open stays unavailable.
.PARAMETER PinnedProvider
    Provider id that takes the primary whenever one of its resolvers opens every required service.
.OUTPUTS
    The plan, or $null when no candidate opens any gating service. Missing lists the required
    services the plan leaves uncovered; Pinned is 'Used', 'Failed' or empty.
#>
function Select-AiDnsPlan {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [object[]] $Services,
        [switch] $NoRoutes,
        [string] $PinnedProvider
    )

    $active = @($Services | Where-Object { $_.Mode -ne 'Off' })
    $required = @($active | Where-Object { $_.Mode -eq 'Required' })
    $ranked = @($Candidates | Sort-Object Score -Descending)
    $good = @($ranked | Where-Object { $_.WebCount -gt 0 })
    if ($good.Count -eq 0) { return $null }

    $complete = @($good | Where-Object {
        $verdicts = $_.Verdicts
        @($required | Where-Object { -not $verdicts[$_.Id].Ok }).Count -eq 0
    })
    $pinned = ''
    $primary = $null
    if ($PinnedProvider) {
        $primary = @($complete | Where-Object { $null -ne $_.Provider -and $_.Provider.Id -eq $PinnedProvider }) | Select-Object -First 1
        $pinned = if ($null -ne $primary) { 'Used' } else { 'Failed' }
    }
    if ($null -eq $primary) { $primary = if ($complete.Count -gt 0) { $complete[0] } else { $good[0] } }

    # Prefer a secondary that opens the same services, so a failover does not silently change what works.
    $secondary = @($good | Where-Object { $_.Address -ne $primary.Address -and $_.Mask -eq $primary.Mask }) | Select-Object -First 1
    if ($null -eq $secondary) { $secondary = @($good | Where-Object { $_.Address -ne $primary.Address }) | Select-Object -First 1 }

    $routes = [Collections.Generic.List[object]]::new()
    $used = [Collections.Generic.List[string]]::new()
    foreach ($service in $active) {
        if ($NoRoutes -or @($service.Namespaces).Count -eq 0 -or $primary.Verdicts[$service.Id].Ok) { continue }
        $alternatives = @($ranked | Where-Object { $_.Verdicts[$service.Id].Ok } | Select-Object -First 2)
        $namespaces = @($service.Namespaces | Where-Object { -not $used.Contains($_) })
        if ($alternatives.Count -eq 0 -or $namespaces.Count -eq 0) { continue }
        foreach ($ns in $namespaces) { $used.Add($ns) }
        $routes.Add([pscustomobject]@{
            Service    = $service
            Namespaces = [string[]]$namespaces
            Servers    = [string[]]@($alternatives | ForEach-Object { $_.Address })
            Candidates = $alternatives
        })
    }

    $routed = @($routes | ForEach-Object { $_.Service.Id })
    $missing = @($required | Where-Object { -not $primary.Verdicts[$_.Id].Ok -and $routed -notcontains $_.Id })
    $servers = @($primary.Address)
    if ($null -ne $secondary) { $servers += $secondary.Address }
    return [pscustomobject]@{
        Primary   = $primary
        Secondary = $secondary
        Servers   = [string[]]$servers
        Routes    = $routes.ToArray()
        Missing   = $missing
        Pinned    = $pinned
    }
}
