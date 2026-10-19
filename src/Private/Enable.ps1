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

    $top = @($Candidates | ForEach-Object { Format-Verdict $_.Verdicts[$Service.Id] }) |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    if ($null -eq $top) { return Get-Text 'Verdict.NoData' }
    return $top.Name
}

function Format-Mark {
    param([bool] $Value)
    if ($Value) { '+' } else { '-' }
}

function Show-CandidateTable {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates, [Parameter(Mandatory)] [object[]] $Services)

    $web = @($Services | Where-Object { $_.Group -eq 'Web' })
    $api = @($Services | Where-Object { $_.Group -eq 'Api' })
    $code = @($Services | Where-Object { $_.ClaudeCode })
    Write-RawLine ''
    foreach ($c in @($Candidates | Sort-Object Score -Descending)) {
        $color = if ($c.WebCount -eq $web.Count) { 'Green' } elseif ($c.WebCount -gt 0) { 'Yellow' } else { 'DarkGray' }
        $codeOk = @($code | Where-Object { -not $c.Verdicts[$_.Id].Ok }).Count -eq 0
        $apiOk = @($api | Where-Object { $c.Verdicts[$_.Id].Ok }).Count
        $latency = $null
        if ($null -ne $c.DnsMs) { $latency = $c.DnsMs + $(if ($null -ne $c.TlsMs) { $c.TlsMs } else { 0 }) }
        $latencyText = if ($null -ne $latency) { Get-Text 'Format.Milliseconds' @($latency) } else { '-' }
        $marks = (@($web | ForEach-Object { '{0} {1}' -f $_.Name, (Format-Mark $c.Verdicts[$_.Id].Ok) }) -join '  ')
        $line = '  {0,-15} {1,-15} {2}  Claude Code {3}  API {4}/{5}  {6,7}{7}' -f (ConvertTo-SafeText $c.Provider.Name 15),
            $c.Address, $marks, (Format-Mark $codeOk), $apiOk, $api.Count, $latencyText, $(if ($c.DohTemplate) { '  DoH' } else { '' })
        Write-RawLine $line $color 'TEST'

        foreach ($s in $Services) {
            $verdict = $c.Verdicts[$s.Id]
            $text = '      {0}: {1}{2}' -f (Get-ServiceLabel $s), $(if ($verdict.Ok) { 'OK, ' } else { '' }), (Format-Verdict $verdict)
            $visible = -not $verdict.Ok -and $c.WebCount -gt 0 -and ($s.Group -eq 'Web' -or $s.ClaudeCode)
            if ($visible) { Write-RawLine $text DarkGray 'TEST' } else { Write-LogRecord 'TEST' $text.Trim() }
        }
        if ($c.WebCount -eq 0) {
            $reasons = @($web | ForEach-Object { Format-Verdict $c.Verdicts[$_.Id] } | Select-Object -Unique)
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
    foreach ($c in $broken) {
        $record = if ($null -ne $backup) { @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid }) | Select-Object -First 1 } else { $null }
        $static = @()
        if ($null -ne $record) { $static = @(ConvertTo-AddressList $record.StaticV4) + @(ConvertTo-AddressList $record.StaticV6) }
        $static = [string[]]@($static | Where-Object { $_ -and $KnownAddresses -notcontains $_ })
        try {
            Restore-AdapterDnsServer $c.Index $c.Alias $static
            Write-OkLine 'Recovery.Restored' $c.Alias (Format-AddressList $static)
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }
    }
    foreach ($rule in @(Get-AiDnsNrptRule)) {
        try { Remove-AiDnsNrptRule $rule } catch { Write-FailLine 'Nrpt.RemoveFailed' $rule.Name $_.Exception.Message }
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

    $services = $script:Services
    $web = @($services | Where-Object { $_.Group -eq 'Web' })
    $api = @($services | Where-Object { $_.Group -eq 'Api' })
    $code = @($services | Where-Object { $_.ClaudeCode })
    if ($TestOnly) { Write-WarnLine 'Enable.TestOnly' }

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
    try { Initialize-ProbeEngine }
    catch {
        Write-FailLine 'Prepare.EngineFailed' $_.Exception.Message
        return 1
    }
    Write-OkLine 'Prepare.EngineReady'

    Write-StepLine 'Step.Catalog'
    $catalog = Get-ProviderCatalog -Refresh:$Refresh -Offline:$Offline
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

    Write-StepLine 'Step.Reference'
    $domains = @($services | ForEach-Object { $_.Domain }) + $script:ProbeDomain
    $referenceQueries = @(foreach ($d in $domains) { foreach ($r in $script:ReferenceResolvers) { New-DnsQuery $r $d 'reference' } })
    $discoveryQueries = @(foreach ($p in $catalog.Providers) {
        foreach ($h in $p.Hosts) { foreach ($r in $script:ReferenceResolvers[0..1]) { New-DnsQuery $r $h "discover|$($p.Id)" } }
    })
    Invoke-DnsBatch (@($referenceQueries) + @($discoveryQueries))

    $reference = @{}
    foreach ($d in $domains) {
        $reference[$d] = [string[]]@($referenceQueries | Where-Object { $_.Name -eq $d -and $_.Ok } | ForEach-Object { $_.Addresses } |
            Select-Object -Unique)
    }
    $referenced = @($web | Where-Object { @($reference[$_.Domain]).Count -gt 0 }).Count
    if ($referenced -eq 0) { Write-WarnLine 'Reference.Intercepted' } else { Write-OkLine 'Reference.Received' $referenced $web.Count }

    $candidates = [ordered]@{}
    foreach ($p in $catalog.Providers) {
        foreach ($ip in $p.Ipv4) {
            if (-not $candidates.Contains($ip) -and $candidates.Count -lt $script:MaxCandidates) { $candidates[$ip] = New-Candidate $ip $p }
        }
    }
    $discovered = 0
    foreach ($q in @($discoveryQueries | Where-Object { $_.Ok })) {
        $providerId = $q.Tag.Substring('discover|'.Length)
        $provider = @($catalog.Providers | Where-Object { $_.Id -eq $providerId }) | Select-Object -First 1
        foreach ($ip in $q.Addresses) {
            if ((Test-PublicIPv4 $ip) -and -not $candidates.Contains($ip) -and $candidates.Count -lt $script:MaxCandidates) {
                $candidates[$ip] = New-Candidate $ip $provider
                $discovered++
            }
        }
    }
    Write-OkLine 'Reference.Candidates' $candidates.Count $discovered

    Write-StepLine 'Step.Probe'
    $queries = [Collections.Generic.List[object]]::new()
    $latency = @{}
    foreach ($c in $candidates.Values) {
        $samples = @(for ($i = 0; $i -lt $script:Timing.LatencySamples; $i++) { New-DnsQuery $c.Address $script:ProbeDomain 'latency' })
        $latency[$c.Address] = $samples
        foreach ($q in $samples) { $queries.Add($q) }
        foreach ($s in $services) {
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
        foreach ($s in $services) {
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

    $context = [pscustomobject]@{ Services = $services; Reference = $reference; Https = $https }
    foreach ($c in $alive) { Measure-Candidate $c $context $dohProbes.ToArray() }
    Show-CandidateTable $alive $services

    $previousState = Read-AiDnsState
    $known = [string[]]@(@(Get-KnownSmartDnsAddress $catalog $previousState) + @($candidates.Keys) | Select-Object -Unique)
    $plan = Select-AiDnsPlan $alive $services

    if ($null -eq $plan) {
        Write-RawLine ''
        Write-FailLine 'Plan.NoneWorks'
        foreach ($s in $web) { Write-NoteLine 'Plan.CommonReason' (Get-ServiceLabel $s) (Get-MostCommonReason $alive $s) }
        $filtered = @($alive | ForEach-Object { $_.Verdicts.Values } | Where-Object { $_.Reason -in @('TlsBlocked', 'TlsForged') })
        if ($filtered.Count -gt 0) { Write-WarnLine 'Plan.SniFiltering' }
        if (-not $TestOnly) {
            Invoke-DeadDnsRecovery $active ([string[]]@($alive | ForEach-Object { $_.Address })) $known
        }
        return 2
    }

    Write-RawLine ''
    Write-OkLine 'Plan.Primary' $plan.Primary.Address $plan.Primary.Provider.Name
    if ($null -ne $plan.Secondary) { Write-OkLine 'Plan.Secondary' $plan.Secondary.Address $plan.Secondary.Provider.Name }
    foreach ($route in $plan.Routes) {
        Write-OkLine 'Plan.Route' (Get-ServiceLabel $route.Service) ($route.Servers -join ', ') $route.Candidates[0].Provider.Name
    }
    foreach ($s in $web) {
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
    try { $backup = Read-AiDnsBackup } catch { Write-WarnLine 'Backup.Corrupt' $_.Exception.Message }
    if ($null -eq $backup) { $backup = New-AiDnsBackup } else { Write-NoteLine 'Backup.Kept' $backup.Created }
    foreach ($c in $active) {
        if (@($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid }).Count -gt 0) { continue }
        $v4 = @(Get-AdapterStaticServer $c.Guid 4)
        $v6 = @(Get-AdapterStaticServer $c.Guid 6)
        # Static servers that are already ours are leftovers of an unrecorded run, not the user's configuration.
        if (@($v4 | Where-Object { $known -contains $_ }).Count -gt 0) { $v4 = @() }
        $ipv6 = Get-Ipv6BindingState $c.AdapterName
        $backup.Adapters.Add([pscustomobject]@{
            Guid = $c.Guid; Name = $c.AdapterName; StaticV4 = ($v4 -join ','); StaticV6 = ($v6 -join ',')
            IPv6Enabled = ($ipv6 -eq $true); Ipv6DisabledByUs = $false
        })
        if ($v4.Count) { Write-OkLine 'Backup.Static' $c.Alias ($v4 -join ', ') } else { Write-OkLine 'Backup.Dhcp' $c.Alias }
    }
    Save-AiDnsBackup $backup
    Write-OkLine 'Backup.Saved' $script:Paths.Backup

    Write-StepLine 'Step.Apply'
    foreach ($c in $active) {
        try {
            Set-AdapterDnsServer $c.Index $c.Alias $plan.Servers
            Write-OkLine 'Apply.Dns' $c.Alias ($plan.Servers -join ', ')
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }

        # Smart DNS answers A records only; a working IPv6 path would let AAAA answers from the ISP bypass the proxy.
        if ((Get-Ipv6BindingState $c.AdapterName) -eq $true) {
            try {
                Set-Ipv6Binding $c.AdapterName $false
                foreach ($record in @($backup.Adapters | Where-Object { $_.Guid -eq $c.Guid })) { $record.Ipv6DisabledByUs = $true }
                Write-OkLine 'Apply.Ipv6Off' $c.Alias
            }
            catch { Write-FailLine 'Apply.Ipv6Failed' $c.Alias $_.Exception.Message }
        }
    }
    Save-AiDnsBackup $backup

    foreach ($c in @($connections | Where-Object { $active -notcontains $_ })) {
        if (@(Get-AdapterDnsServer $c.Index | Where-Object { $known -contains $_ }).Count -eq 0) { continue }
        try {
            Restore-AdapterDnsServer $c.Index $c.Alias
            Write-OkLine 'Apply.LeftoverRemoved' $c.Alias
        }
        catch { Write-FailLine 'Adapter.Failed' $c.Alias $_.Exception.Message }
    }

    $nrptAdded = [Collections.Generic.List[string]]::new()
    if (Test-NrptSupport) {
        foreach ($rule in @(Get-AiDnsNrptRule)) {
            try { Remove-AiDnsNrptRule $rule } catch { Write-FailLine 'Nrpt.RemoveFailed' $rule.Name $_.Exception.Message }
        }
        foreach ($route in $plan.Routes) {
            try {
                Add-AiDnsNrptRule $route.Namespaces $route.Servers
                $nrptAdded.Add($route.Service.Id)
                Write-OkLine 'Apply.Route' (Get-ServiceLabel $route.Service) ($route.Servers -join ', ')
            }
            catch { Write-FailLine 'Apply.RouteFailed' (Get-ServiceLabel $route.Service) $_.Exception.Message }
        }
    }
    elseif ($plan.Routes.Count) { Write-WarnLine 'Apply.NoNrpt' }

    $dohAdded = [Collections.Generic.List[string]]::new()
    if (Test-DohSupport) {
        $withDoh = @(@($plan.Primary, $plan.Secondary) + @($plan.Routes | ForEach-Object { $_.Candidates }) |
            Where-Object { $null -ne $_ -and $_.DohTemplate } | Sort-Object Address -Unique)
        foreach ($c in $withDoh) {
            if (@(Get-DohTemplateEntry $c.Address).Count -gt 0) { continue }
            try {
                Add-DohTemplate $c.Address $c.DohTemplate
                $dohAdded.Add($c.Address)
            }
            catch { Write-NoteLine 'Apply.DohSkipped' $c.Address $_.Exception.Message }
        }
        if ($dohAdded.Count) { Write-OkLine 'Apply.Doh' ($dohAdded -join ', ') }
    }

    try {
        $disabled = Disable-ManagedHostsEntry
        if ($disabled -gt 0) {
            $backup.HostsModified = $true
            Write-OkLine 'Apply.Hosts' $disabled
        }
    }
    catch { Write-WarnLine 'Apply.HostsFailed' $_.Exception.Message }

    $policyErrors = 0
    foreach ($policy in $script:BrowserPolicies) {
        try { Set-BrowserPolicy $policy $backup.Policies }
        catch {
            Write-FailLine 'Apply.PolicyFailed' "$($policy.Key)\$($policy.Name)" $_.Exception.Message
            $policyErrors++
        }
    }
    if ($policyErrors -eq 0) { Write-OkLine 'Apply.Browsers' }

    Save-AiDnsBackup $backup
    Save-AiDnsState ([pscustomobject]@{
        SchemaVersion   = $script:BackupSchemaVersion
        Applied         = (Get-Date).ToString('s')
        Servers         = $plan.Servers
        Primary         = $plan.Primary.Address
        PrimaryProvider = $plan.Primary.Provider.Name
        Nrpt            = $nrptAdded.ToArray()
        DohAdded        = $dohAdded.ToArray()
        AllCandidateIps = $known
    })

    Write-StepLine 'Step.Verify'
    if ($script:Run.DryRun) {
        Write-NoteLine 'Verify.DryRun'
        return 0
    }
    Clear-DnsCache
    $system = Test-SystemResolver $context
    $working = 0
    foreach ($s in $web) {
        $verdict = $system.Verdicts[$s.Id]
        if ($verdict.Ok) {
            Write-OkLine 'Verify.Works' (Get-ServiceLabel $s) (Format-Verdict $verdict)
            $working++
        }
        else { Write-WarnLine 'Verify.Fails' (Get-ServiceLabel $s) (Format-Verdict $verdict) }
    }
    $codeProblems = @($code | Where-Object { -not $system.Verdicts[$_.Id].Ok })
    if ($codeProblems.Count -eq 0) { Write-OkLine 'Verify.CodeOk' }
    else {
        Write-WarnLine 'Verify.CodeProblems'
        foreach ($s in $codeProblems) { Write-NoteLine 'Verify.CodeItem' $s.Domain (Format-Verdict $system.Verdicts[$s.Id]) }
    }
    $apiWorking = @($api | Where-Object { $system.Verdicts[$_.Id].Ok }).Count
    Write-NoteLine 'Verify.Api' $apiWorking $api.Count

    Write-RawLine ''
    if ($script:Run.Errors -eq 0 -and $working -gt 0) {
        $suffix = if ($codeProblems.Count) { Get-Text 'Verify.SuffixCodeProblems' } else { Get-Text 'Verify.SuffixCodeOk' }
        Write-OkLine 'Verify.Done' (Format-ElapsedTime) $working $web.Count $suffix
        Write-NoteLine 'Common.RestartBrowser'
        Write-NoteLine 'Verify.HowToUndo'
        return 0
    }
    Write-WarnLine 'Common.CompletedWithIssues' $script:Run.Errors
    return 3
}
