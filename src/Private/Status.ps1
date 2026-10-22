# The status action: what AI-DNS has configured and whether every service opens through the system resolver now.
# It changes nothing and runs without administrator rights.

<#
.SYNOPSIS
    Runs the status action.
.OUTPUTS
    System.Int32 exit code: 0 when every required service works, 3 otherwise, 1 when the check could not run.
#>
function Invoke-AiDnsStatus {
    $services = @($script:Services | Where-Object { $_.Mode -ne 'Off' })
    $probed = @(Get-ProbedService $script:Services)

    Write-StepLine 'Step.StatusConfig'
    $state = Read-AiDnsState
    if ($null -ne $state -and $state.Primary) { Write-OkLine 'Status.Enabled' $state.Applied $state.Primary $state.PrimaryProvider }
    else { Write-NoteLine 'Status.NotEnabled' }
    $catalog = Get-ProviderCatalog -Offline
    $known = Get-KnownSmartDnsAddress $catalog $state
    foreach ($c in @(Get-NetworkConnection | Where-Object { -not $_.Virtual })) {
        $current = @(Get-AdapterDnsServer $c.Index)
        $ours = @($current | Where-Object { $known -contains $_ }).Count -gt 0
        Write-OkLine $(if ($ours) { 'Status.AdapterOurs' } else { 'Status.AdapterOther' }) $c.Alias (Format-AddressList $current)
    }
    foreach ($rule in @(Get-AiDnsNrptRule)) { Write-NoteLine 'Status.Route' (@($rule.Namespace) -join ', ') (@($rule.NameServers) -join ', ') }

    Write-StepLine 'Step.StatusCheck'
    try { Initialize-ProbeEngine }
    catch {
        Write-FailLine 'Prepare.EngineFailed' $_.Exception.Message
        return 1
    }
    $domains = [string[]]@($probed | ForEach-Object { $_.Domain } | Select-Object -Unique)
    $context = [pscustomobject]@{ Services = $probed; Reference = (Get-ReferenceAnswer $domains); Https = @{} }
    Clear-DnsCacheIfElevated
    $result = Test-SystemResolver $context

    $failedRequired = 0
    foreach ($s in $services) {
        $verdict = $result.Verdicts[$s.Id]
        $mode = Get-Text "Mode.$($s.Mode)"
        if ($verdict.Ok) { Write-OkLine 'Status.Works' (Get-ServiceLabel $s) $mode (Format-Verdict $verdict) }
        elseif ($s.Mode -eq 'Required') {
            Write-FailLine 'Status.Fails' (Get-ServiceLabel $s) $mode (Format-Verdict $verdict)
            $failedRequired++
        }
        else { Write-WarnLine 'Status.Fails' (Get-ServiceLabel $s) $mode (Format-Verdict $verdict) }
    }

    Write-RawLine ''
    $working = @($services | Where-Object { $result.Verdicts[$_.Id].Ok }).Count
    if ($failedRequired -eq 0) {
        Write-OkLine 'Status.Summary' $working $services.Count
        return 0
    }
    Write-WarnLine 'Status.SummaryRequired' $failedRequired
    Write-NoteLine 'Status.Hint'
    return 3
}

# A cached answer from before the last change would hide the current state; flushing needs elevation.
function Clear-DnsCacheIfElevated {
    if (-not (Test-AiDnsElevation)) { return }
    try { Clear-DnsCache } catch { Write-TraceLine "status: cache flush failed: $($_.Exception.Message)" }
}
