# backup.json (the pre-change snapshot) and state.json (what the last enable applied).
# Field names are kept from the 2.x format so a machine enabled by 2.x can be rolled back by 3.x.

$script:BackupSchemaVersion = 3

function Test-DnsServerAddress {
    param([AllowNull()] [AllowEmptyString()] [string] $Address)

    $parsed = $null
    if ([string]::IsNullOrWhiteSpace($Address) -or -not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { return $Address -match $script:Ipv4Pattern }
    return $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6
}

function ConvertTo-AddressList {
    param([AllowNull()] $Value)

    $items = if ($Value -is [string]) { $Value -split '[,\s]+' } else { @($Value) }
    [string[]]@($items | ForEach-Object { [string]$_ } | Where-Object { Test-DnsServerAddress $_ } | Select-Object -Unique)
}

function Format-AddressList {
    param([AllowNull()] [AllowEmptyCollection()] [string[]] $Addresses)
    if ($null -eq $Addresses -or $Addresses.Count -eq 0) { return (Get-Text 'Common.None') }
    return ($Addresses -join ', ')
}

function New-AiDnsBackup {
    [pscustomobject]@{
        SchemaVersion = $script:BackupSchemaVersion
        Created       = (Get-Date).ToString('s')
        Computer      = $env:COMPUTERNAME
        Adapters      = [Collections.Generic.List[object]]::new()
        Policies      = [Collections.Generic.List[object]]::new()
        HostsModified = $false
    }
}

<#
.SYNOPSIS
    Reads backup.json and keeps only well-formed entries.
.OUTPUTS
    The backup, or $null when there is none. Throws when the file exists but is not valid JSON.
#>
function Read-AiDnsBackup {
    $raw = Read-JsonFile $script:Paths.Backup
    if ($null -eq $raw) { return $null }

    $backup = New-AiDnsBackup
    $backup.Created = [string](Get-JsonProperty $raw 'Created' '')
    $backup.Computer = ConvertTo-SafeText ([string](Get-JsonProperty $raw 'Computer' '')) 64
    $backup.HostsModified = [bool](Get-JsonProperty $raw 'HostsModified' $false)
    foreach ($entry in @(Get-JsonProperty $raw 'Adapters' @())) {
        $guid = [string](Get-JsonProperty $entry 'Guid' '')
        if ($guid -notmatch $script:GuidPattern) { continue }
        $backup.Adapters.Add([pscustomobject]@{
            Guid             = $guid
            Name             = ConvertTo-SafeText ([string](Get-JsonProperty $entry 'Name' '')) 256
            StaticV4         = (ConvertTo-AddressList (Get-JsonProperty $entry 'StaticV4' '')) -join ','
            StaticV6         = (ConvertTo-AddressList (Get-JsonProperty $entry 'StaticV6' '')) -join ','
            IPv6Enabled      = [bool](Get-JsonProperty $entry 'IPv6Enabled' $true)
            Ipv6DisabledByUs = [bool](Get-JsonProperty $entry 'Ipv6DisabledByUs' $false)
        })
    }
    foreach ($record in @(Select-ValidPolicyRecord @(Get-JsonProperty $raw 'Policies' @()))) { $backup.Policies.Add($record) }
    return $backup
}

function Save-AiDnsBackup {
    param([Parameter(Mandatory)] $Backup)

    $document = [pscustomobject]@{
        SchemaVersion = $Backup.SchemaVersion
        Created       = $Backup.Created
        Computer      = $Backup.Computer
        Adapters      = @($Backup.Adapters)
        Policies      = @($Backup.Policies)
        HostsModified = $Backup.HostsModified
    }
    $null = Invoke-SystemChange "Write $($script:Paths.Backup)" { Write-JsonFile $script:Paths.Backup $document }
}

<#
.SYNOPSIS
    Reads state.json. Returns $null when it is missing or unreadable; the state is advisory only.
#>
function Read-AiDnsState {
    try { $raw = Read-JsonFile $script:Paths.State }
    catch {
        Write-TraceLine "state.json unreadable: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $raw) { return $null }
    [pscustomobject]@{
        Applied         = [string](Get-JsonProperty $raw 'Applied' '')
        Servers         = ConvertTo-AddressList (Get-JsonProperty $raw 'Servers' @())
        Primary         = [string](Get-JsonProperty $raw 'Primary' '')
        PrimaryProvider = ConvertTo-SafeText ([string](Get-JsonProperty $raw 'PrimaryProvider' ''))
        Nrpt            = [string[]]@(Get-JsonProperty $raw 'Nrpt' @() | ForEach-Object { ConvertTo-SafeText ([string]$_) })
        DohAdded        = ConvertTo-AddressList (Get-JsonProperty $raw 'DohAdded' @())
        AllCandidateIps = ConvertTo-AddressList (Get-JsonProperty $raw 'AllCandidateIps' @())
    }
}

function Save-AiDnsState {
    param([Parameter(Mandatory)] $State)

    $document = $State
    $null = Invoke-SystemChange "Write $($script:Paths.State)" { Write-JsonFile $script:Paths.State $document }
}

<#
.SYNOPSIS
    Every address this tool may have configured: the catalog, retired addresses and whatever the
    last enable recorded. Used to recognise our own settings on adapters and in DoH templates.
#>
function Get-KnownSmartDnsAddress {
    param([Parameter(Mandatory)] $Catalog, [AllowNull()] $State)

    $all = @($Catalog.Providers | ForEach-Object { $_.Ipv4 }) + @($Catalog.Retired)
    if ($null -ne $State) { $all += @($State.Servers) + @($State.AllCandidateIps) + @($State.DohAdded) }
    [string[]]@($all | Where-Object { Test-PublicIPv4 $_ } | Select-Object -Unique)
}
