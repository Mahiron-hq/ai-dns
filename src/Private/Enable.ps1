# The enable action: discover resolvers, probe them, pick the best, apply it and verify through the system resolver.

$script:MaxCandidates = 1024

function New-Candidate {
    param([Parameter(Mandatory)] [string] $Address, [AllowNull()] $Provider)

    [pscustomobject]@{
        Address     = $Address
        Provider    = $Provider
        Alive       = $false
        DnsMs       = $null
        Dns         = @{}
        Verdicts    = @{}
        WebCount    = 0
        ApiCount    = 0
        TlsMs       = $null
        Score       = [double]::MinValue
        Mask        = ''
        DohTemplate = $null
    }
}

function Get-MostCommonReason {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates, [Parameter(Mandatory)] $Service)

    $top = @($Candidates | Where-Object { $null -ne $_.Verdicts[$Service.Id] } | ForEach-Object { Format-Verdict $_.Verdicts[$Service.Id] }) |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    if ($null -eq $top) { return Get-Text 'Verdict.NoData' }
    return $top.Name
}

function Format-Mark {
    param([bool] $Value)
    if ($Value) { '+' } else { '-' }
}

<#
.SYNOPSIS
    The services to probe: every service that is checked, plus switched-off services that a checked
    one takes its region from.
#>
function Get-ProbedService {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Services)

    $active = @($Services | Where-Object { $_.Mode -ne 'Off' })
    $ids = @($active | ForEach-Object { $_.Id })
    $extra = @($Services | Where-Object {
        $id = $_.Id
        $ids -notcontains $id -and @($active | Where-Object { $_.RegionFrom -eq $id }).Count -gt 0
    })
    return @($active) + @($extra)
}

function Show-CandidateTable {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates, [Parameter(Mandatory)] [object[]] $Services)

    $active = @($Services | Where-Object { $_.Mode -ne 'Off' })
    $gating = @(Get-GatingService $Services)
    $api = @($active | Where-Object { $_.Group -eq 'Api' })
    $code = @($active | Where-Object { $_.ClaudeCode })
    Write-RawLine ''
    foreach ($c in @($Candidates | Sort-Object Score -Descending)) {
        $color = if ($c.WebCount -eq $gating.Count) { 'Green' } elseif ($c.WebCount -gt 0) { 'Yellow' } else { 'DarkGray' }
        $latency = $null
        if ($null -ne $c.DnsMs) { $latency = $c.DnsMs + $(if ($null -ne $c.TlsMs) { $c.TlsMs } else { 0 }) }
        $latencyText = if ($null -ne $latency) { Get-Text 'Format.Milliseconds' @($latency) } else { '-' }
        $marks = (@($gating | ForEach-Object { '{0} {1}' -f (ConvertTo-SafeText $_.Name 24), (Format-Mark $c.Verdicts[$_.Id].Ok) }) -join '  ')
        $extras = ''
        if ($code.Count) { $extras += '  Claude Code {0}' -f (Format-Mark (@($code | Where-Object { -not $c.Verdicts[$_.Id].Ok }).Count -eq 0)) }
        if ($api.Count) { $extras += '  API {0}/{1}' -f @($api | Where-Object { $c.Verdicts[$_.Id].Ok }).Count, $api.Count }
        $line = '  {0,-15} {1,-15} {2}{3}  {4,7}{5}' -f (ConvertTo-SafeText $c.Provider.Name 15), $c.Address, $marks, $extras,
            $latencyText, $(if ($c.DohTemplate) { '  DoH' } else { '' })
        Write-RawLine $line $color 'TEST'

        foreach ($s in $active) {
            $verdict = $c.Verdicts[$s.Id]
            $text = '      {0}: {1}{2}' -f (Get-ServiceLabel $s), $(if ($verdict.Ok) { 'OK, ' } else { '' }), (Format-Verdict $verdict)
            $visible = -not $verdict.Ok -and $c.WebCount -gt 0 -and ($gating -contains $s -or $s.ClaudeCode)
            if ($visible) { Write-RawLine $text DarkGray 'TEST' } else { Write-LogRecord 'TEST' $text.Trim() }
        }
        if ($c.WebCount -eq 0) {
            $reasons = @($gating | ForEach-Object { Format-Verdict $c.Verdicts[$_.Id] } | Select-Object -Unique)
            Write-RawLine ('      ' + ($reasons -join ' / ')) DarkGray 'TEST'
        }
    }
}

<#
.SYNOPSIS
    After a failed search, puts adapters that still point at a dead smart DNS back to their
    original resolvers so the machine does not stay without working DNS.
#>
function Invoke-DeadDnsRecovery {
    param(
        [Parameter(Mandatory)] [object[]] $Connections,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $AliveAddresses,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $KnownAddresses
    )

    $broken = @($Connections | Where-Object {
        @(Get-AdapterDnsServer $_.Index | Where-Object { $KnownAddresses -contains $_ -and $AliveAddresses -notcontains $_ }).Count -gt 0
    })
    if ($broken.Count -eq 0) {
        Write-NoteLine 'Recovery.Untouched'
        return
    }
    Write-WarnLine 'Recovery.Restoring'
    $backup = $null
    try { $backup = Read-AiDnsBackup } catch { Write-WarnLine 'Backup.Corrupt' $_.Exception.Message }
    $state = Read-AiDnsState
    $stateServers = if ($null -ne $state) { [string[]]@($state.Servers) } else { [string[]]@() }
    foreach ($c in $broken) {
        $record = if ($null -ne $backup) { @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid }) | Select-Object -First 1 } else { $null }
        $current = [string[]]@(Get-AdapterDnsServer $c.Index)
        $action = Get-AdapterRollbackAction -Record $record -Current $current -StateServers $stateServers -Known $KnownAddresses -HasBackup:($null -ne $backup)
        if ($action -eq 'Changed') {
            Write-NoteLine 'Adapter.Changed' $c.Alias (Format-AddressList $current)
            continue
        }
        if ($action -notin @('Restore', 'Reset')) {
            Write-WarnLine 'Adapter.NotOurs' $c.Alias (Format-AddressList $current)
            continue
        }
        $static = [string[]]@()
        if ($action -eq 'Restore') { $static = [string[]]@(@(ConvertTo-AddressList $record.StaticV4) + @(ConvertTo-AddressList $record.StaticV6)) }
        try {
            Restore-AdapterDnsServer $c.Index $c.Alias $static
            Write-OkLine 'Recovery.Restored' $c.Alias (Format-AddressList $static)
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }
    }
    if ((Get-AiDnsSetting).System.Nrpt) {
        foreach ($rule in @(Get-AiDnsNrptRule)) {
            try { Remove-AiDnsNrptRule $rule } catch { Write-FailLine 'Nrpt.RemoveFailed' $rule.Name $_.Exception.Message }
        }
    }
    Clear-DnsCache
}

<#
.SYNOPSIS
    Resolves every service through the system resolver and runs the same checks on the answers.
.OUTPUTS
    A candidate-shaped object whose Verdicts reflect what applications will actually get.
#>
function Test-SystemResolver {
    param([Parameter(Mandatory)] $Context)

    $system = New-Candidate 'system' $null
    $tasks = @{}
    foreach ($s in $Context.Services) { $tasks[$s.Id] = [Net.Dns]::GetHostAddressesAsync($s.Domain) }
    try { $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values), 8000) }
    catch { Write-TraceLine "system resolver: $($_.Exception.GetBaseException().Message)" }

    foreach ($s in $Context.Services) {
        $task = $tasks[$s.Id]
        $query = New-DnsQuery 'system' $s.Domain $s.Id
        if ($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled) {
            $addresses = [string[]]@($task.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
            $usable = [string[]]@($addresses | Where-Object { $_ -ne '0.0.0.0' -and -not $_.StartsWith('127.') })
            $query.Addresses = $usable
            $query.RCode = 0
            $query.Error = if ($usable.Count) { [AiDns.ProbeError]::None } elseif ($addresses.Count) { [AiDns.ProbeError]::Blackholed } else { [AiDns.ProbeError]::EmptyAnswer }
        }
        Write-TraceLine ('system dns {0} -> {1} ({2})' -f $s.Domain, ($query.Addresses -join ','), $query.Error)
        $system.Dns[$s.Id] = $query
    }

    $probes = [Collections.Generic.List[object]]::new()
    foreach ($s in $Context.Services) {
        $answer = $system.Dns[$s.Id]
        if (-not $answer.Ok) { continue }
        foreach ($check in $s.Checks) {
            $key = Get-CheckKey $answer.Addresses[0] $s.Domain $check.Path
            if ($Context.Https.ContainsKey($key)) { continue }
            $probe = New-HttpsProbe $answer.Addresses[0] $s.Domain $check $key
            $Context.Https[$key] = $probe
            $probes.Add($probe)
        }
    }
    Invoke-HttpsBatch $probes.ToArray()
    foreach ($s in $Context.Services) { $system.Verdicts[$s.Id] = Test-ServiceAccess $s $system $Context }
    return $system
}

<#
.SYNOPSIS
    Resolves every service through the reference resolvers.
.OUTPUTS
    A hashtable mapping each domain to the addresses the reference resolvers returned.
#>
function Get-ReferenceAnswer {
    param([Parameter(Mandatory)] [string[]] $Domains, [AllowEmptyCollection()] [object[]] $ExtraQueries = @())

    $queries = @(foreach ($d in $Domains) { foreach ($r in $script:ReferenceResolvers) { New-DnsQuery $r $d 'reference' } })
    Invoke-DnsBatch (@($queries) + @($ExtraQueries))
    $reference = @{}
    foreach ($d in $Domains) {
        $reference[$d] = [string[]]@($queries | Where-Object { $_.Name -eq $d -and $_.Ok } | ForEach-Object { $_.Addresses } | Select-Object -Unique)
    }
    return $reference
}

<#
.SYNOPSIS
    Explains that a required service left no usable resolver and asks what to do about it.
.OUTPUTS
    System.String: Remove, Optional or Exit. Exit without an interactive console.
#>
function Read-RequiredFailureChoice {
    param([Parameter(Mandatory)] [object[]] $Missing, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates)

    $labels = @($Missing | ForEach-Object { Get-ServiceLabel $_ }) -join ', '
    Write-RawLine ''
    Write-FailLine 'Required.NoResolver' $labels
    foreach ($s in $Missing) { Write-NoteLine 'Plan.CommonReason' (Get-ServiceLabel $s) (Get-MostCommonReason $Candidates $s) }
    $custom = @($Missing | Where-Object { $_.Group -eq 'Custom' }).Count -gt 0
    Write-NoteLine $(if ($custom) { 'Required.CustomHint' } else { 'Required.SettingsHint' })

    try {
        if ([Console]::IsInputRedirected) { return 'Exit' }
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
    }
    catch { return 'Exit' }
    Write-RawLine ''
    Write-RawLine ('  ' + (Get-Text $(if ($custom) { 'Required.KeyRemove' } else { 'Required.KeyOff' }))) White
    Write-RawLine ('  ' + (Get-Text 'Required.KeyOptional')) White
    Write-RawLine ('  ' + (Get-Text 'Required.KeyExit')) White
    while ($true) {
        $key = [Console]::ReadKey($true).Key
        $choice = switch ($key) {
            { $_ -in @('D1', 'NumPad1') } { 'Remove' }
            { $_ -in @('D2', 'NumPad2') } { 'Optional' }
            'Escape' { 'Exit' }
            default { $null }
        }
        if ($null -ne $choice) {
            Write-LogRecord 'INFO' "Required service choice: $choice"
            return $choice
        }
    }
}

<#
.SYNOPSIS
    Applies the choice made for unreachable required services to the settings and to this run.
.OUTPUTS
    The updated service table.
#>
function Resolve-RequiredFailure {
    param([Parameter(Mandatory)] [string] $Choice, [Parameter(Mandatory)] [object[]] $Missing)

    $settings = Get-AiDnsSetting
    $ids = [string[]]@($Missing | ForEach-Object { $_.Id })
    if ($Choice -eq 'Remove') { Remove-AiDnsServiceCheck $settings $ids }
    else { foreach ($id in $ids) { Set-AiDnsServiceMode $settings $id 'Preferred' } }
    if (Save-AiDnsSetting $settings -Explicit) { Write-OkLine $(if ($Choice -eq 'Remove') { 'Required.Removed' } else { 'Required.MadeOptional' }) }
    else { Write-WarnLine 'Required.SaveFailed' $script:Paths.Settings }
    Use-AiDnsSetting $settings
    return $script:Services
}

function Set-BlockingService {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Ids, [switch] $ReadOnly)

    if ($ReadOnly) { return }
    $settings = Get-AiDnsSetting
    if ((@($settings.Blocking) -join ',') -eq ($Ids -join ',')) { return }
    $settings.Blocking.Clear()
    foreach ($id in $Ids) { $settings.Blocking.Add($id) }
    $null = Save-AiDnsSetting $settings
}

<#
.SYNOPSIS
    Explains that backup.json cannot be read and asks whether to set it aside and start a new one.
    Without an interactive console the answer is no.
.OUTPUTS
    System.Boolean. True when the damaged file was set aside and enable may continue.
#>
function Confirm-DamagedBackup {
    param([Parameter(Mandatory)] [string] $Problem)

    Write-WarnLine 'Backup.Corrupt' $Problem
    Write-NoteLine 'Backup.CorruptExplain'
    $aside = Join-Path $script:Paths.Root ('backup.broken-{0:yyyyMMdd_HHmmss}.json' -f (Get-Date))
    $proceed = $false
    if (Test-InteractiveConsole) {
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
        Write-RawLine ''
        Write-RawLine ('  ' + (Get-Text 'Backup.CorruptKeys' @($aside))) White
        while ($true) {
            $key = [Console]::ReadKey($true).Key
            if ($key -eq 'Enter') { $proceed = $true; break }
            if ($key -eq 'Escape') { break }
        }
    }
    if (-not $proceed) {
        Write-FailLine 'Backup.CorruptStopped' $script:Paths.Backup
        return $false
    }
    $null = Invoke-SystemChange "Move $($script:Paths.Backup) to $aside" { Move-Item -LiteralPath $script:Paths.Backup -Destination $aside -ErrorAction Stop }
    Write-NoteLine 'Backup.CorruptMoved' $aside
    return $true
}

<#
.SYNOPSIS
    Records an adapter's DNS configuration as it is before the first change.
.PARAMETER PreviousState
    state.json of the last enable. Static servers equal to what it applied are leftovers of a run
    whose backup is gone, so the original is unknown and DHCP is assumed.
#>
function New-AdapterBackupRecord {
    param([Parameter(Mandatory)] $Connection, [AllowNull()] $PreviousState)

    $v4 = [string[]]@(Get-AdapterStaticServer $Connection.Guid 4)
    $v6 = [string[]]@(Get-AdapterStaticServer $Connection.Guid 6)
    if ($null -ne $PreviousState -and $v4.Count -gt 0 -and (Test-SameAddressSet $v4 @($PreviousState.Servers))) { $v4 = [string[]]@() }
    $ipv6 = Get-Ipv6BindingState $Connection.AdapterName
    [pscustomobject]@{
        Guid = $Connection.Guid; Name = $Connection.AdapterName; StaticV4 = ($v4 -join ','); StaticV6 = ($v6 -join ',')
        IPv6Enabled = ($ipv6 -eq $true); Ipv6DisabledByUs = $false; AppliedV4 = ''
    }
}

<#
.SYNOPSIS
    Replaces the AI-DNS NRPT rules with the plan's routes. With NRPT switched off nothing is touched,
    and rules left by an earlier run are only reported.
.OUTPUTS
    System.String[]. The ids of the services routed.
#>
function Update-AiDnsNrptRule {
    param([switch] $Enabled, [AllowEmptyCollection()] [object[]] $Routes = @())

    $added = [Collections.Generic.List[string]]::new()
    if (-not $Enabled) {
        $stale = @(Get-AiDnsNrptRule)
        if ($stale.Count) { Write-NoteLine 'Apply.NrptStale' $stale.Count }
        return , $added.ToArray()
    }
    foreach ($rule in @(Get-AiDnsNrptRule)) {
        try { Remove-AiDnsNrptRule $rule } catch { Write-FailLine 'Nrpt.RemoveFailed' $rule.Name $_.Exception.Message }
    }
    foreach ($route in $Routes) {
        try {
            Add-AiDnsNrptRule $route.Namespaces $route.Servers
            $added.Add($route.Service.Id)
            Write-OkLine 'Apply.Route' (Get-ServiceLabel $route.Service) ($route.Servers -join ', ')
        }
        catch { Write-FailLine 'Apply.RouteFailed' (Get-ServiceLabel $route.Service) $_.Exception.Message }
    }
    return , $added.ToArray()
}

<#
.SYNOPSIS
    Runs the enable action.
.PARAMETER TestOnly
    Stop after ranking; change nothing.
.PARAMETER Refresh
    Download every provider feed regardless of the cache age.
.PARAMETER Offline
    Use the bundled catalog and cached feeds only.
.OUTPUTS
    System.Int32 exit code: 0 success, 1 failure, 2 no working resolver, 3 applied with problems.
#>
function Invoke-AiDnsEnable {
    param([switch] $TestOnly, [switch] $Refresh, [switch] $Offline)

    $settings = Get-AiDnsSetting
    $system = $settings.System
    $services = @($script:Services)
    $probed = @(Get-ProbedService $services)
    # A test or a dry run writes nothing but the log: no cached engine, feeds or settings.
    $readOnly = $TestOnly -or $script:Run.DryRun
    if ($TestOnly) { Write-WarnLine 'Enable.TestOnly' }
    $skipped = @($script:SystemToggles | Where-Object { -not $system.$_ } | ForEach-Object { Get-Text "System.$_" })
    if ($skipped.Count) { Write-NoteLine 'Enable.SystemSkipped' ($skipped -join ', ') }

    Write-StepLine 'Step.Prepare'
    $connections = @(Get-NetworkConnection)
    $active = @($connections | Where-Object { -not $_.Virtual })
    foreach ($c in @($connections | Where-Object { $_.Virtual })) { Write-NoteLine 'Prepare.VirtualSkipped' $c.Alias }
    if ($active.Count -eq 0) { $active = $connections }
    if ($active.Count -eq 0) {
        Write-FailLine 'Prepare.NoConnection'
        return 1
    }
    foreach ($c in $active) { Write-OkLine 'Prepare.CurrentDns' $c.Alias (Format-AddressList (Get-AdapterDnsServer $c.Index)) }
    $vpn = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $script:VpnProcessPattern } |
        ForEach-Object { $_.ProcessName } | Select-Object -Unique)
    foreach ($name in $vpn) { Write-WarnLine 'Prepare.VpnRunning' $name }
    try { Initialize-ProbeEngine -InMemory:$readOnly }
    catch {
        Write-FailLine 'Prepare.EngineFailed' $_.Exception.Message
        return 1
    }
    Write-OkLine 'Prepare.EngineReady'

    Write-StepLine 'Step.Catalog'
    $catalog = Get-ProviderCatalog -Refresh:$Refresh -Offline:$Offline -NoCacheWrite:$readOnly
    foreach ($feed in $catalog.Feeds) {
        $count = if ($null -ne $feed.Parsed) { @($feed.Parsed.Providers).Count } else { 0 }
        switch ($feed.Origin) {
            'Remote'      { Write-OkLine 'Catalog.FeedRemote' $feed.Feed.Id $count }
            'Cache'       { Write-OkLine 'Catalog.FeedCache' $feed.Feed.Id $count }
            'StaleCache'  { Write-WarnLine 'Catalog.FeedStale' $feed.Feed.Id $count }
            'Unavailable' { Write-WarnLine 'Catalog.FeedUnavailable' $feed.Feed.Id }
        }
    }
    $addressCount = @($catalog.Providers | ForEach-Object { $_.Ipv4 } | Select-Object -Unique).Count
    Write-OkLine 'Catalog.Summary' (@($catalog.Providers).Count) $addressCount
    $providers = @($catalog.Providers | Where-Object { $settings.BlockedProviders -notcontains $_.Id })

    Write-StepLine 'Step.Reference'
    $domains = [string[]]@(@($probed | ForEach-Object { $_.Domain }) + $script:ProbeDomain | Select-Object -Unique)
    $discoveryQueries = @(foreach ($p in $providers) {
        foreach ($h in $p.Hosts) { foreach ($r in $script:ReferenceResolvers[0..1]) { New-DnsQuery $r $h "discover|$($p.Id)" } }
    })
    $reference = Get-ReferenceAnswer $domains $discoveryQueries
    $gatingAll = @(Get-GatingService $services)
    $referenced = @($gatingAll | Where-Object { @($reference[$_.Domain]).Count -gt 0 }).Count
    if ($referenced -eq 0) { Write-WarnLine 'Reference.Intercepted' } else { Write-OkLine 'Reference.Received' $referenced $gatingAll.Count }

    $candidates = [ordered]@{}
    $excluded = 0
    foreach ($p in $providers) {
        foreach ($ip in $p.Ipv4) {
            if ($settings.BlockedAddresses -contains $ip) { $excluded++; continue }
            if (-not $candidates.Contains($ip) -and $candidates.Count -lt $script:MaxCandidates) { $candidates[$ip] = New-Candidate $ip $p }
        }
    }
    $discovered = 0
    foreach ($q in @($discoveryQueries | Where-Object { $_.Ok })) {
        $providerId = $q.Tag.Substring('discover|'.Length)
        $provider = @($providers | Where-Object { $_.Id -eq $providerId }) | Select-Object -First 1
        foreach ($ip in $q.Addresses) {
            if ($settings.BlockedAddresses -contains $ip) { continue }
            if ((Test-PublicIPv4 $ip) -and -not $candidates.Contains($ip) -and $candidates.Count -lt $script:MaxCandidates) {
                $candidates[$ip] = New-Candidate $ip $provider
                $discovered++
            }
        }
    }
    Write-OkLine 'Reference.Candidates' $candidates.Count $discovered
    $blockedCount = @($catalog.Providers).Count - $providers.Count
    if ($blockedCount -gt 0 -or $excluded -gt 0) { Write-NoteLine 'Reference.Excluded' $blockedCount $excluded }

    Write-StepLine 'Step.Probe'
    $queries = [Collections.Generic.List[object]]::new()
    $latency = @{}
    foreach ($c in $candidates.Values) {
        $samples = @(for ($i = 0; $i -lt $script:Timing.LatencySamples; $i++) { New-DnsQuery $c.Address $script:ProbeDomain 'latency' })
        $latency[$c.Address] = $samples
        foreach ($q in $samples) { $queries.Add($q) }
        foreach ($s in $probed) {
            $q = New-DnsQuery $c.Address $s.Domain $s.Id
            $c.Dns[$s.Id] = $q
            $queries.Add($q)
        }
    }
    Invoke-DnsBatch $queries.ToArray()
    foreach ($c in $candidates.Values) {
        $own = @($latency[$c.Address]) + @($c.Dns.Values)
        $c.Alive = @($own | Where-Object { $_.Answered }).Count -gt 0
        $c.DnsMs = Get-Median @($own | Where-Object { $_.Ok } | ForEach-Object { $_.RttMs })
    }
    $alive = @($candidates.Values | Where-Object { $_.Alive })
    $dead = @($candidates.Values | Where-Object { -not $_.Alive })
    Write-OkLine 'Probe.Alive' $alive.Count $candidates.Count
    if ($dead.Count) { Write-DetailLine 'Probe.Dead' (($dead | ForEach-Object { "$($_.Address) ($($_.Provider.Name))" }) -join ', ') }
    if ($alive.Count -eq 0) { Write-FailLine 'Probe.NoneAlive' }

    Write-StepLine 'Step.Https'
    $https = @{}
    $probes = [Collections.Generic.List[object]]::new()
    $dohProbes = [Collections.Generic.List[object]]::new()
    foreach ($c in $alive) {
        foreach ($s in $probed) {
            $answer = $c.Dns[$s.Id]
            if (-not $answer.Ok) { continue }
            foreach ($check in $s.Checks) {
                $key = Get-CheckKey $answer.Addresses[0] $s.Domain $check.Path
                if ($https.ContainsKey($key)) { continue }
                $probe = New-HttpsProbe $answer.Addresses[0] $s.Domain $check $key
                $https[$key] = $probe
                $probes.Add($probe)
            }
        }
        foreach ($template in $c.Provider.Doh) { $dohProbes.Add((New-DohProbe $c.Address $template $c.Address)) }
    }
    Invoke-HttpsBatch $probes.ToArray() $dohProbes.ToArray()
    Write-OkLine 'Https.Done' ($probes.Count + $dohProbes.Count)

    $context = [pscustomobject]@{ Services = $probed; Reference = $reference; Https = $https }
    foreach ($c in $alive) { Measure-Candidate $c $context $dohProbes.ToArray() }
    Show-CandidateTable $alive $services

    $previousState = Read-AiDnsState
    $known = [string[]]@(@(Get-KnownSmartDnsAddress $catalog $previousState) + @($candidates.Keys) | Select-Object -Unique)
    $useNrpt = $system.Nrpt -and (Test-NrptSupport)
    if ($system.Nrpt -and -not $useNrpt) { Write-NoteLine 'Apply.NoNrpt' }
    $plan = Select-AiDnsPlan $alive $services -NoRoutes:(-not $useNrpt) -PinnedProvider $settings.PinnedProvider

    while ($null -ne $plan -and @($plan.Missing).Count -gt 0) {
        Set-BlockingService ([string[]]@($plan.Missing | ForEach-Object { $_.Id })) -ReadOnly:$readOnly
        $choice = Read-RequiredFailureChoice @($plan.Missing) $alive
        if ($choice -eq 'Exit') {
            if (-not $TestOnly) { Invoke-DeadDnsRecovery $active ([string[]]@($alive | ForEach-Object { $_.Address })) $known }
            return 2
        }
        $services = @(Resolve-RequiredFailure $choice @($plan.Missing))
        foreach ($c in $alive) { Update-CandidateScore $c $services }
        $plan = Select-AiDnsPlan $alive $services -NoRoutes:(-not $useNrpt) -PinnedProvider $settings.PinnedProvider
    }
    $gating = @(Get-GatingService $services)
    $activeServices = @($services | Where-Object { $_.Mode -ne 'Off' })
    $code = @($activeServices | Where-Object { $_.ClaudeCode })
    $api = @($activeServices | Where-Object { $_.Group -eq 'Api' })

    if ($null -eq $plan) {
        Write-RawLine ''
        Write-FailLine 'Plan.NoneWorks'
        foreach ($s in $gating) { Write-NoteLine 'Plan.CommonReason' (Get-ServiceLabel $s) (Get-MostCommonReason $alive $s) }
        $filtered = @($alive | ForEach-Object { $_.Verdicts.Values } | Where-Object { $_.Reason -in @('TlsBlocked', 'TlsForged') })
        if ($filtered.Count -gt 0) { Write-WarnLine 'Plan.SniFiltering' }
        if (-not $TestOnly) {
            Invoke-DeadDnsRecovery $active ([string[]]@($alive | ForEach-Object { $_.Address })) $known
        }
        return 2
    }
    Set-BlockingService ([string[]]@()) -ReadOnly:$readOnly

    Write-RawLine ''
    Write-OkLine 'Plan.Primary' $plan.Primary.Address $plan.Primary.Provider.Name
    if ($null -ne $plan.Secondary) { Write-OkLine 'Plan.Secondary' $plan.Secondary.Address $plan.Secondary.Provider.Name }
    if ($plan.Pinned -eq 'Used') { Write-NoteLine 'Plan.PinnedUsed' $plan.Primary.Provider.Name }
    elseif ($plan.Pinned -eq 'Failed') { Write-WarnLine 'Plan.PinnedFailed' $settings.PinnedProvider }
    foreach ($route in $plan.Routes) {
        Write-OkLine 'Plan.Route' (Get-ServiceLabel $route.Service) ($route.Servers -join ', ') $route.Candidates[0].Provider.Name
    }
    foreach ($s in $gating) {
        $routed = @($plan.Routes | Where-Object { $_.Service.Id -eq $s.Id }).Count -gt 0
        if (-not $plan.Primary.Verdicts[$s.Id].Ok -and -not $routed) { Write-WarnLine 'Plan.NotCovered' (Get-ServiceLabel $s) (Get-MostCommonReason $alive $s) }
    }
    foreach ($s in $code) {
        $routed = @($plan.Routes | Where-Object { $_.Service.Id -eq $s.Id }).Count -gt 0
        if (-not $plan.Primary.Verdicts[$s.Id].Ok -and -not $routed) {
            Write-WarnLine 'Plan.CodeBroken' $s.Domain (Format-Verdict $plan.Primary.Verdicts[$s.Id])
        }
    }
    if ($TestOnly) {
        Write-OkLine 'Enable.TestDone' (Format-ElapsedTime)
        return 0
    }

    Write-StepLine 'Step.Backup'
    $backup = $null
    try { $backup = Read-AiDnsBackup }
    catch {
        if (-not (Confirm-DamagedBackup $_.Exception.Message)) { return 1 }
    }
    if ($null -eq $backup) { $backup = New-AiDnsBackup } else { Write-NoteLine 'Backup.Kept' $backup.Created }
    foreach ($c in $active) {
        if (@($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid }).Count -gt 0) { continue }
        $record = New-AdapterBackupRecord $c $previousState
        $backup.Adapters.Add($record)
        if ($record.StaticV4) { Write-OkLine 'Backup.Static' $c.Alias ($record.StaticV4 -replace ',', ', ') } else { Write-OkLine 'Backup.Dhcp' $c.Alias }
    }
    # Templates registered by 3.1.0 and earlier are recorded only in state.json, which this run replaces.
    foreach ($address in @(if ($null -ne $previousState) { $previousState.DohAdded })) {
        if (@($backup.Doh | Where-Object { $_.Address -eq $address }).Count -gt 0) { continue }
        $entry = @(Get-DohTemplateEntry $address) | Select-Object -First 1
        if ($null -ne $entry) { $backup.Doh.Add([pscustomobject]@{ Address = $address; Template = [string]$entry.DohTemplate }) }
    }
    Save-AiDnsBackup $backup
    Write-OkLine 'Backup.Saved' $script:Paths.Backup

    Write-StepLine 'Step.Apply'
    foreach ($c in $active) {
        try {
            Set-AdapterDnsServer $c.Index $c.Alias $plan.Servers
            foreach ($record in @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid })) { $record.AppliedV4 = $plan.Servers -join ',' }
            Write-OkLine 'Apply.Dns' $c.Alias ($plan.Servers -join ', ')
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }

        # Smart DNS answers A records only; a working IPv6 path would let AAAA answers from the ISP bypass the proxy.
        if ($system.DisableIpv6 -and (Get-Ipv6BindingState $c.AdapterName) -eq $true) {
            try {
                Set-Ipv6Binding $c.AdapterName $false
                foreach ($record in @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid })) { $record.Ipv6DisabledByUs = $true }
                Write-OkLine 'Apply.Ipv6Off' $c.Alias
            }
            catch { Write-FailLine 'Apply.Ipv6Failed' $c.Alias $_.Exception.Message }
        }
    }
    Save-AiDnsBackup $backup

    # Adapters without a gateway or virtual ones: put back only what an earlier run of AI-DNS set on them.
    foreach ($c in @($connections | Where-Object { $active -notcontains $_ })) {
        $record = @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid }) | Select-Object -First 1
        $current = [string[]]@(Get-AdapterDnsServer $c.Index)
        $action = Get-AdapterRollbackAction -Record $record -Current $current -Known $known -HasBackup
        if ($action -eq 'NotOurs') { Write-NoteLine 'Adapter.NotOurs' $c.Alias (Format-AddressList $current) }
        if ($action -ne 'Restore') { continue }
        try {
            Restore-AdapterDnsServer $c.Index $c.Alias ([string[]]@(@(ConvertTo-AddressList $record.StaticV4) + @(ConvertTo-AddressList $record.StaticV6)))
            $record.AppliedV4 = ''
            Write-OkLine 'Apply.LeftoverRemoved' $c.Alias
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }
    }

    $nrptAdded = @(Update-AiDnsNrptRule -Enabled:$useNrpt -Routes @($plan.Routes))

    $dohAdded = [Collections.Generic.List[string]]::new()
    if ($system.Doh -and (Test-DohSupport)) {
        $withDoh = @(@($plan.Primary, $plan.Secondary) + @($plan.Routes | ForEach-Object { $_.Candidates }) |
            Where-Object { $null -ne $_ -and $_.DohTemplate } | Sort-Object Address -Unique)
        foreach ($c in $withDoh) {
            # An existing template is left alone: either ours from an earlier run, or someone else's.
            if (@(Get-DohTemplateEntry $c.Address).Count -gt 0) { continue }
            try {
                Add-DohTemplate $c.Address $c.DohTemplate
                $dohAdded.Add($c.Address)
                if (@($backup.Doh | Where-Object { $_.Address -eq $c.Address }).Count -eq 0) {
                    $backup.Doh.Add([pscustomobject]@{ Address = $c.Address; Template = $c.DohTemplate })
                }
            }
            catch { Write-NoteLine 'Apply.DohSkipped' $c.Address $_.Exception.Message }
        }
        if ($dohAdded.Count) {
            Save-AiDnsBackup $backup
            Write-OkLine 'Apply.Doh' ($dohAdded -join ', ')
        }
    }

    if ($system.Hosts) {
        try {
            $disabled = Disable-ManagedHostsEntry
            if ($disabled -gt 0) {
                $backup.HostsModified = $true
                Write-OkLine 'Apply.Hosts' $disabled
            }
        }
        catch { Write-WarnLine 'Apply.HostsFailed' $_.Exception.Message }
    }

    if ($system.BrowserPolicies) {
        $policyErrors = 0
        foreach ($policy in $script:BrowserPolicies) {
            try { Set-BrowserPolicy $policy $backup.Policies }
            catch {
                Write-FailLine 'Apply.PolicyFailed' "$($policy.Key)\$($policy.Name)" $_.Exception.Message
                $policyErrors++
            }
        }
        if ($policyErrors -eq 0) { Write-OkLine 'Apply.Browsers' }
    }

    Save-AiDnsBackup $backup
    Save-AiDnsState ([pscustomobject]@{
        SchemaVersion   = $script:BackupSchemaVersion
        Applied         = (Get-Date).ToString('s')
        Servers         = $plan.Servers
        Primary         = $plan.Primary.Address
        PrimaryProvider = $plan.Primary.Provider.Name
        Nrpt            = [string[]]$nrptAdded
        DohAdded        = $dohAdded.ToArray()
        AllCandidateIps = $known
    })

    Write-StepLine 'Step.Verify'
    if ($script:Run.DryRun) {
        Write-NoteLine 'Verify.DryRun'
        return 0
    }
    Clear-DnsCache
    $systemResult = Test-SystemResolver $context
    $working = 0
    foreach ($s in $gating) {
        $verdict = $systemResult.Verdicts[$s.Id]
        if ($verdict.Ok) {
            Write-OkLine 'Verify.Works' (Get-ServiceLabel $s) (Format-Verdict $verdict)
            $working++
        }
        else { Write-WarnLine 'Verify.Fails' (Get-ServiceLabel $s) (Format-Verdict $verdict) }
    }
    $codeProblems = @($code | Where-Object { -not $systemResult.Verdicts[$_.Id].Ok })
    if ($code.Count -and $codeProblems.Count -eq 0) { Write-OkLine 'Verify.CodeOk' }
    elseif ($codeProblems.Count) {
        Write-WarnLine 'Verify.CodeProblems'
        foreach ($s in $codeProblems) { Write-NoteLine 'Verify.CodeItem' $s.Domain (Format-Verdict $systemResult.Verdicts[$s.Id]) }
    }
    if ($api.Count) { Write-NoteLine 'Verify.Api' @($api | Where-Object { $systemResult.Verdicts[$_.Id].Ok }).Count $api.Count }
    $requiredFailed = @($activeServices | Where-Object { $_.Mode -eq 'Required' -and -not $systemResult.Verdicts[$_.Id].Ok })

    Write-RawLine ''
    if ($script:Run.Errors -eq 0 -and $working -gt 0 -and $requiredFailed.Count -eq 0) {
        $suffix = if ($code.Count -eq 0) { '' } elseif ($codeProblems.Count) { Get-Text 'Verify.SuffixCodeProblems' } else { Get-Text 'Verify.SuffixCodeOk' }
        Write-OkLine 'Verify.Done' (Format-ElapsedTime) $working $gating.Count $suffix
        Write-NoteLine 'Common.RestartBrowser'
        Write-NoteLine 'Verify.HowToUndo'
        return 0
    }
    if ($requiredFailed.Count) { Write-WarnLine 'Verify.RequiredFails' (@($requiredFailed | ForEach-Object { Get-ServiceLabel $_ }) -join ', ') }
    Write-WarnLine 'Common.CompletedWithIssues' $script:Run.Errors
    return 3
}
