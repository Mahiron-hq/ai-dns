# The disable action: put back everything enable changed and remove the tool's data.

<#
.SYNOPSIS
    Deletes the data directory. Logs survive when KeepLogs is set; otherwise the run log is closed
    first because an open file cannot be deleted.
.OUTPUTS
    System.Int32. The number of entries that could not be deleted.
#>
function Remove-AiDnsData {
    param([switch] $KeepLogs)

    $root = $script:Paths.Root
    if (-not (Test-Path -LiteralPath $root)) { return 0 }
    $failures = [Collections.Generic.List[int]]::new()
    $null = Invoke-SystemChange "Delete $root$(if ($KeepLogs) { ' (except logs)' })" {
        if ($KeepLogs) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ne 'logs' })) {
                $failures.Add((Remove-TreeSafely $entry.FullName))
            }
            return
        }
        if ($null -ne $script:Run.LogFile -and $script:Run.LogFile.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Close-AiDnsLog }
        $failures.Add((Remove-TreeSafely $root))
    }
    $total = 0
    foreach ($count in $failures) { $total += $count }
    return $total
}

<#
.SYNOPSIS
    Deletes regenerable data: downloaded feeds and compiled engines, including the 2.x layout.
#>
function Clear-AiDnsCache {
    $targets = @(Get-Item -LiteralPath $script:Paths.Cache -Force -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -LiteralPath $script:Paths.Root -Filter 'probe_*.dll' -File -Force -ErrorAction SilentlyContinue)
    foreach ($target in @($targets | Where-Object { $null -ne $_ })) {
        $null = Invoke-SystemChange "Delete $($target.FullName)" { $null = Remove-TreeSafely $target.FullName }
    }
}

<#
.SYNOPSIS
    Runs the disable action.
.PARAMETER Full
    Reset every adapter to DHCP, delete the commented-out hosts entries and remove the data
    directory even after errors.
.PARAMETER ResetNetwork
    Also reset Winsock and TCP/IP; a restart is required afterwards.
.PARAMETER EnableIPv6
    Enable IPv6 on every adapter, not only where enable turned it off.
.PARAMETER KeepLogs
    Keep the log directory when the data directory is removed.
.OUTPUTS
    An object with ExitCode (0 clean, 3 finished with problems) and RestartRequired.
#>
function Invoke-AiDnsDisable {
    param([switch] $Full, [switch] $ResetNetwork, [switch] $EnableIPv6, [switch] $KeepLogs)

    if ($Full) { Write-WarnLine 'Disable.FullMode' }

    Write-StepLine 'Step.FindBackup'
    $backup = $null
    try { $backup = Read-AiDnsBackup } catch { Write-FailLine 'Backup.Corrupt' $_.Exception.Message }
    $state = Read-AiDnsState
    $catalog = Get-ProviderCatalog -Offline
    $known = Get-KnownSmartDnsAddress $catalog $state
    if ($null -ne $backup) { Write-OkLine 'Disable.BackupFound' $backup.Created } else { Write-WarnLine 'Disable.NoBackup' }
    $records = @()
    if ($null -ne $backup) { $records = @($backup.Adapters) }
    $stateServers = if ($null -ne $state) { [string[]]@($state.Servers) } else { [string[]]@() }

    Write-StepLine 'Step.Adapters'
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $leftAlone = [Collections.Generic.List[string]]::new()
    $adapterChanges = 0
    $fullHint = $false
    foreach ($record in $records) {
        if ($null -eq (@($adapters | Where-Object { $_.InterfaceGuid -eq $record.Guid }) | Select-Object -First 1)) {
            Write-NoteLine 'Disable.AdapterMissing' $record.Name
        }
    }
    foreach ($nic in $adapters) {
        $guid = [string]$nic.InterfaceGuid
        $record = @($records | Where-Object { $_.Guid -eq $guid }) | Select-Object -First 1
        $current = [string[]]@(Get-AdapterDnsServer $nic.ifIndex)
        $action = Get-AdapterRollbackAction -Record $record -Current $current -StateServers $stateServers -Known $known `
            -HasBackup:($null -ne $backup) -Full:$Full
        if ($action -eq 'None') { continue }
        if ($action -eq 'Changed') {
            Write-NoteLine 'Adapter.Changed' $nic.Name (Format-AddressList $current)
            $leftAlone.Add($guid)
            continue
        }
        if ($action -eq 'NotOurs') {
            Write-WarnLine 'Adapter.NotOurs' $nic.Name (Format-AddressList $current)
            $leftAlone.Add($guid)
            $fullHint = $true
            continue
        }
        $static = [string[]]@()
        if ($action -eq 'Restore' -and -not $Full) {
            $static = [string[]]@(@(ConvertTo-AddressList $record.StaticV4) + @(ConvertTo-AddressList $record.StaticV6))
        }
        try {
            Restore-AdapterDnsServer $nic.ifIndex $nic.Name $static
            if ($static.Count) { Write-OkLine 'Disable.AdapterStatic' $nic.Name ($static -join ', ') }
            elseif ($action -eq 'Reset') { Write-OkLine 'Disable.AdapterReset' $nic.Name ($current -join ', ') }
            else { Write-OkLine 'Disable.AdapterDhcp' $nic.Name }
            $adapterChanges++
        }
        catch { Write-FailLine 'Adapter.Failed' $nic.Name $_.Exception.Message }
    }
    if ($fullHint) { Write-NoteLine 'Disable.FullHint' }

    $ipv6Hint = $false
    foreach ($nic in $adapters) {
        if ((Get-Ipv6BindingState $nic.Name) -ne $false) { continue }
        $record = @($records | Where-Object { $_.Guid -eq $nic.InterfaceGuid }) | Select-Object -First 1
        $ours = $null -ne $record -and $record.Ipv6DisabledByUs
        if (-not $ours -and -not $EnableIPv6) {
            $ipv6Hint = $true
            continue
        }
        try {
            Set-Ipv6Binding $nic.Name $true
            Write-OkLine 'Disable.Ipv6On' $nic.Name
        }
        catch { Write-FailLine 'Disable.Ipv6Failed' $nic.Name $_.Exception.Message }
    }
    if ($ipv6Hint) { Write-NoteLine 'Disable.Ipv6Hint' }

    Write-StepLine 'Step.Nrpt'
    if (Test-NrptSupport) {
        $rules = @(Get-AiDnsNrptRule)
        foreach ($rule in $rules) {
            try {
                Remove-AiDnsNrptRule $rule
                Write-OkLine 'Disable.NrptRemoved' (@($rule.Namespace) -join ', ')
            }
            catch { Write-FailLine 'Nrpt.RemoveFailed' $rule.Name $_.Exception.Message }
        }
        if ($rules.Count -eq 0) { Write-OkLine 'Disable.NrptNone' }
    }
    else { Write-OkLine 'Disable.NrptUnsupported' }

    if (Test-DohSupport) {
        Write-StepLine 'Step.Doh'
        $removed = Remove-OwnedDohTemplate -Owned (Get-OwnedDohRecord $backup $state) -Known $known
        if ($removed -eq 0) { Write-OkLine 'Disable.DohNone' }
    }

    Write-StepLine 'Step.Policies'
    $restored = Restore-BrowserPolicy @(if ($null -ne $backup) { $backup.Policies })
    if ($restored -gt 0) { Write-OkLine 'Disable.PoliciesRestored' $restored } else { Write-OkLine 'Disable.PoliciesNone' }

    Write-StepLine 'Step.Hosts'
    try {
        $count = Restore-ManagedHostsEntry -Delete:$Full
        if ($count -eq 0) { Write-OkLine 'Disable.HostsNone' }
        elseif ($Full) { Write-OkLine 'Disable.HostsDeleted' $count }
        else { Write-OkLine 'Disable.HostsRestored' $count }
    }
    catch { Write-FailLine 'Disable.HostsFailed' $_.Exception.Message }

    Write-StepLine 'Step.Caches'
    try {
        Clear-NetworkCache
        Write-OkLine 'Disable.CachesCleared'
    }
    catch { Write-WarnLine 'Disable.CachesFailed' $_.Exception.Message }

    $restart = $false
    if ($ResetNetwork) {
        Write-StepLine 'Step.ResetNetwork'
        if (Reset-NetworkStack) { Write-OkLine 'Disable.ResetDone' } else { Write-FailLine 'Disable.ResetFailed' }
        $restart = $true
    }

    Write-StepLine 'Step.Data'
    if (-not (Test-Path -LiteralPath $script:Paths.Root)) { Write-OkLine 'Disable.DataNone' }
    elseif ($script:Run.Errors -gt 0 -and -not $Full) { Write-WarnLine 'Disable.DataKept' $script:Paths.Root }
    else {
        $failures = Remove-AiDnsData -KeepLogs:$KeepLogs
        if ($failures -gt 0) { Write-WarnLine 'Disable.DataLocked' $script:Paths.Root }
        elseif ($KeepLogs) { Write-OkLine 'Disable.DataRemovedKeepLogs' $script:Paths.Logs }
        else { Write-OkLine 'Disable.DataRemoved' $script:Paths.Root }
    }

    Write-StepLine 'Step.Summary'
    # Nothing was changed in a dry run, so the adapters still showing smart DNS is the expected outcome.
    if ($script:Run.DryRun) {
        Write-OkLine 'Disable.DryRunDone' $adapterChanges
        return [pscustomobject]@{ ExitCode = $(if ($script:Run.Errors -eq 0) { 0 } else { 3 }); RestartRequired = $false }
    }
    $remaining = 0
    foreach ($c in @(Get-NetworkConnection)) {
        $current = @(Get-AdapterDnsServer $c.Index)
        if (-not $leftAlone.Contains($c.Guid) -and @($current | Where-Object { $known -contains $_ }).Count -gt 0) {
            $remaining++
            Write-WarnLine 'Disable.Remaining' $c.Alias ($current -join ', ')
        }
        else { Write-OkLine 'Disable.AdapterNow' $c.Alias (Format-AddressList $current) }
    }
    try {
        $null = Resolve-DnsName -Name $script:ProbeDomain -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        Write-OkLine 'Disable.DnsWorks'
    }
    catch { Write-WarnLine 'Disable.DnsNotYet' }

    Write-RawLine ''
    $clean = $script:Run.Errors -eq 0 -and $remaining -eq 0
    if ($clean) { Write-OkLine 'Disable.Clean' } else { Write-WarnLine 'Common.CompletedWithIssues' $script:Run.Errors }
    Write-NoteLine 'Common.RestartBrowser'
    if ($restart) { Write-WarnLine 'Disable.RestartNeeded' }
    return [pscustomobject]@{ ExitCode = $(if ($clean) { 0 } else { 3 }); RestartRequired = $restart }
}
