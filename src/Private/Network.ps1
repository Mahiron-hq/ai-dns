# Reading and changing Windows network configuration. Every modification goes through Invoke-SystemChange.

<#
.SYNOPSIS
    Lists connected interfaces that have an IPv4 default gateway, flagging VPN and virtual adapters.
#>
function Get-NetworkConnection {
    $result = [Collections.Generic.List[object]]::new()
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        if ($null -eq $c.IPv4DefaultGateway -or $null -eq $c.NetAdapter -or $c.NetAdapter.Status -ne 'Up') { continue }
        $label = "$($c.InterfaceAlias) $($c.NetAdapter.InterfaceDescription)"
        $result.Add([pscustomobject]@{
            Index       = [int]$c.InterfaceIndex
            Alias       = [string]$c.InterfaceAlias
            AdapterName = [string]$c.NetAdapter.Name
            Guid        = [string]$c.NetAdapter.InterfaceGuid
            Virtual     = $label -match $script:VirtualAdapterPattern
        })
    }
    return $result.ToArray()
}

function Get-AdapterDnsServer {
    param([Parameter(Mandatory)] [int] $Index)
    [string[]]@(Get-DnsClientServerAddress -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.ServerAddresses })
}

<#
.SYNOPSIS
    Returns the statically configured DNS servers of an interface from the registry; empty means DHCP.
#>
function Get-AdapterStaticServer {
    param([Parameter(Mandatory)] [string] $Guid, [ValidateSet(4, 6)] [int] $Family = 4)

    $service = if ($Family -eq 4) { 'Tcpip' } else { 'Tcpip6' }
    $info = Get-RegistryValueInfo "HKLM:\SYSTEM\CurrentControlSet\Services\$service\Parameters\Interfaces\$Guid" 'NameServer'
    if (-not $info.Exists) { return [string[]]@() }
    [string[]]@(([string]$info.Value) -split '[,\s]+' | Where-Object { $_ })
}

function Set-AdapterDnsServer {
    param([Parameter(Mandatory)] [int] $Index, [Parameter(Mandatory)] [string] $Alias, [Parameter(Mandatory)] [string[]] $Servers)

    $null = Invoke-SystemChange "Set DNS servers of '$Alias' (#$Index) to $($Servers -join ', ')" {
        Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $Servers -ErrorAction Stop
    } -StateProbe { Get-AdapterDnsServer $Index }
}

<#
.SYNOPSIS
    Returns an interface to DHCP-assigned DNS and then applies Static, if any.
#>
function Restore-AdapterDnsServer {
    param([Parameter(Mandatory)] [int] $Index, [Parameter(Mandatory)] [string] $Alias, [string[]] $Static = @())

    $description = if ($Static.Count) { "Restore DNS servers of '$Alias' (#$Index) to $($Static -join ', ')" }
                   else { "Reset DNS servers of '$Alias' (#$Index) to DHCP" }
    $null = Invoke-SystemChange $description {
        Set-DnsClientServerAddress -InterfaceIndex $Index -ResetServerAddresses -ErrorAction Stop
        if ($Static.Count) { Set-DnsClientServerAddress -InterfaceIndex $Index -ServerAddresses $Static -ErrorAction Stop }
    } -StateProbe { Get-AdapterDnsServer $Index }
}

function Get-Ipv6BindingState {
    param([Parameter(Mandatory)] [string] $AdapterName)

    $binding = @(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape($AdapterName)) -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue) |
        Select-Object -First 1
    if ($null -eq $binding) { return $null }
    return [bool]$binding.Enabled
}

function Set-Ipv6Binding {
    param([Parameter(Mandatory)] [string] $AdapterName, [Parameter(Mandatory)] [bool] $Enabled)

    $name = [WildcardPattern]::Escape($AdapterName)
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    $null = Invoke-SystemChange "$verb IPv6 on '$AdapterName'" {
        if ($Enabled) { Enable-NetAdapterBinding -Name $name -ComponentID ms_tcpip6 -ErrorAction Stop }
        else { Disable-NetAdapterBinding -Name $name -ComponentID ms_tcpip6 -ErrorAction Stop }
    } -StateProbe { Get-Ipv6BindingState $AdapterName }
}

function Test-NrptSupport {
    $null -ne (Get-Command Add-DnsClientNrptRule -ErrorAction SilentlyContinue)
}

function Get-AiDnsNrptRule {
    if (-not (Test-NrptSupport)) { return @() }
    @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $script:NrptComment })
}

function Remove-AiDnsNrptRule {
    param([Parameter(Mandatory)] $Rule)

    $null = Invoke-SystemChange "Remove NRPT rule $($Rule.Name) for $(@($Rule.Namespace) -join ', ')" {
        Remove-DnsClientNrptRule -Name $Rule.Name -Force -ErrorAction Stop
    }
}

function Add-AiDnsNrptRule {
    param([Parameter(Mandatory)] [string[]] $Namespaces, [Parameter(Mandatory)] [string[]] $Servers)

    $null = Invoke-SystemChange "Add NRPT rule $($Namespaces -join ', ') -> $($Servers -join ', ')" {
        Add-DnsClientNrptRule -Namespace $Namespaces -NameServers $Servers -Comment $script:NrptComment -ErrorAction Stop
    }
}

# Windows 11 and Server 2022 only.
function Test-DohSupport {
    $null -ne (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
}

function Get-DohTemplateEntry {
    param([string] $Address)

    if (-not (Test-DohSupport)) { return @() }
    if ($Address) { return @(Get-DnsClientDohServerAddress -ServerAddress $Address -ErrorAction SilentlyContinue) }
    @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
}

function Add-DohTemplate {
    param([Parameter(Mandatory)] [string] $Address, [Parameter(Mandatory)] [string] $Template)

    $null = Invoke-SystemChange "Register DoH template $Template for $Address" {
        Add-DnsClientDohServerAddress -ServerAddress $Address -DohTemplate $Template -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop
    }
}

function Remove-DohTemplate {
    param([Parameter(Mandatory)] [string] $Address)

    $null = Invoke-SystemChange "Remove DoH template for $Address" {
        Remove-DnsClientDohServerAddress -ServerAddress $Address -ErrorAction Stop
    }
}

<#
.SYNOPSIS
    Returns the registry keys along Path that do not exist yet, outermost first.
#>
function Get-MissingRegistryKey {
    param([Parameter(Mandatory)] [string] $Path)

    $missing = [Collections.Generic.List[string]]::new()
    $current = $Path
    while ($current -and -not (Test-Path -LiteralPath $current)) {
        $missing.Insert(0, $current)
        $current = Split-Path -Path $current -Parent
    }
    return $missing.ToArray()
}

function Remove-RegistryKeyIfEmpty {
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path -notlike 'HKLM:\SOFTWARE\Policies\*' -or -not (Test-Path -LiteralPath $Path)) { return }
    $key = Get-Item -LiteralPath $Path
    if ($key.ValueCount -ne 0 -or $key.SubKeyCount -ne 0) { return }
    $null = Invoke-SystemChange "Remove empty registry key $Path" { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

<#
.SYNOPSIS
    Applies one browser policy, first recording the value it replaces in Records unless an earlier
    run already recorded it, so the original survives repeated enables.
#>
function Set-BrowserPolicy {
    param([Parameter(Mandatory)] $Policy, [Parameter(Mandatory)] [Collections.Generic.List[object]] $Records)

    $known = @($Records | Where-Object { $_.Key -eq $Policy.Key -and $_.Name -eq $Policy.Name }).Count -gt 0
    if (-not $known) {
        $current = Get-RegistryValueInfo $Policy.Key $Policy.Name
        $Records.Add([pscustomobject]@{
            Key          = $Policy.Key
            Name         = $Policy.Name
            Type         = $(if ($current.Exists) { $current.Kind } else { $Policy.Type })
            ValueExisted = $current.Exists
            OldValue     = $current.Value
            CreatedKeys  = [string[]]@(Get-MissingRegistryKey $Policy.Key)
        })
    }
    $null = Invoke-SystemChange "Set policy $($Policy.Key)\$($Policy.Name) = $($Policy.Value)" {
        if (-not (Test-Path -LiteralPath $Policy.Key)) { $null = New-Item -Path $Policy.Key -Force -ErrorAction Stop }
        $null = New-ItemProperty -LiteralPath $Policy.Key -Name $Policy.Name -PropertyType $Policy.Type -Value $Policy.Value -Force -ErrorAction Stop
    } -StateProbe { (Get-RegistryValueInfo $Policy.Key $Policy.Name).Value }
}

<#
.SYNOPSIS
    Keeps only backup records that describe a policy this tool manages, so a tampered backup
    cannot be used to write arbitrary registry values during rollback.
#>
function Select-ValidPolicyRecord {
    param([AllowEmptyCollection()] [object[]] $Records)

    $kinds = @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')
    foreach ($record in @($Records | Where-Object { $null -ne $_ })) {
        $key = [string](Get-JsonProperty $record 'Key' '')
        $name = [string](Get-JsonProperty $record 'Name' '')
        $managed = @($script:BrowserPolicies | Where-Object { $_.Key -eq $key -and $_.Name -eq $name }).Count -gt 0
        $type = [string](Get-JsonProperty $record 'Type' '')
        if (-not $managed -or $kinds -notcontains $type) { continue }
        $created = @(@(Get-JsonProperty $record 'CreatedKeys' @()) | ForEach-Object { [string]$_ } |
            Where-Object { $_ -like 'HKLM:\SOFTWARE\Policies\*' -and ($key -eq $_ -or $key.StartsWith("$_\")) })
        [pscustomobject]@{
            Key          = $key
            Name         = $name
            Type         = $type
            ValueExisted = [bool](Get-JsonProperty $record 'ValueExisted' $false)
            OldValue     = Get-JsonProperty $record 'OldValue'
            CreatedKeys  = [string[]]$created
        }
    }
}

<#
.SYNOPSIS
    Writes back the recorded policy values, removes values identical to the ones this tool sets
    that the user did not own, and deletes keys that were created only to hold them.
.OUTPUTS
    System.Int32. The number of values restored or removed.
#>
function Restore-BrowserPolicy {
    param([AllowEmptyCollection()] [object[]] $Records = @())

    $valid = @(Select-ValidPolicyRecord $Records)
    $changed = 0
    for ($i = $valid.Count - 1; $i -ge 0; $i--) {
        $record = $valid[$i]
        $path = "$($record.Key)\$($record.Name)"
        try {
            if ($record.ValueExisted) {
                $null = Invoke-SystemChange "Restore policy $path = $(Format-StateValue $record.OldValue)" {
                    if (-not (Test-Path -LiteralPath $record.Key)) { $null = New-Item -Path $record.Key -Force -ErrorAction Stop }
                    $null = New-ItemProperty -LiteralPath $record.Key -Name $record.Name -PropertyType $record.Type -Value $record.OldValue -Force -ErrorAction Stop
                }
                $changed++
            }
            elseif ((Get-RegistryValueInfo $record.Key $record.Name).Exists) {
                $null = Invoke-SystemChange "Remove policy $path" {
                    Remove-ItemProperty -LiteralPath $record.Key -Name $record.Name -ErrorAction Stop
                }
                $changed++
            }
        }
        catch { Write-FailLine 'Policy.RestoreFailed' $path $_.Exception.Message }
    }

    foreach ($policy in $script:BrowserPolicies) {
        $owned = @($valid | Where-Object { $_.ValueExisted -and $_.Key -eq $policy.Key -and $_.Name -eq $policy.Name }).Count -gt 0
        if ($owned) { continue }
        $current = Get-RegistryValueInfo $policy.Key $policy.Name
        if (-not $current.Exists -or "$($current.Value)" -ne "$($policy.Value)") { continue }
        $path = "$($policy.Key)\$($policy.Name)"
        try {
            $null = Invoke-SystemChange "Remove leftover policy $path" {
                Remove-ItemProperty -LiteralPath $policy.Key -Name $policy.Name -ErrorAction Stop
            }
            $changed++
        }
        catch { Write-FailLine 'Policy.RestoreFailed' $path $_.Exception.Message }
    }

    $keys = @(@($valid | ForEach-Object { $_.CreatedKeys }) + $script:PolicyParentKeys | Select-Object -Unique |
        Sort-Object { $_.Length } -Descending)
    foreach ($key in $keys) {
        try { Remove-RegistryKeyIfEmpty $key }
        catch { Write-FailLine 'Policy.RestoreFailed' $key $_.Exception.Message }
    }
    return $changed
}

<#
.SYNOPSIS
    The registrable domains whose hosts entries would override the smart DNS.
#>
function Get-ManagedDomain {
    @($script:Services | ForEach-Object { $_.Namespaces } | ForEach-Object { $_.TrimStart('.').ToLowerInvariant() } |
        Select-Object -Unique)
}

<#
.SYNOPSIS
    Tests whether an active hosts line maps any name inside Domains (the domain or a subdomain).
#>
function Test-ManagedHostsLine {
    param([AllowEmptyString()] [string] $Line, [Parameter(Mandatory)] [string[]] $Domains)

    $content = ($Line -split '#', 2)[0].Trim()
    if (-not $content) { return $false }
    $tokens = @($content -split '\s+')
    if ($tokens.Count -lt 2) { return $false }
    foreach ($token in $tokens[1..($tokens.Count - 1)]) {
        $name = $token.TrimEnd('.').ToLowerInvariant()
        foreach ($domain in $Domains) {
            if ($name -eq $domain -or $name.EndsWith(".$domain")) { return $true }
        }
    }
    return $false
}

<#
.SYNOPSIS
    Comments out, restores or deletes managed hosts entries without touching any other line.
.PARAMETER Mode
    Disable  prefixes active managed lines with Marker.
    Restore  removes Marker from lines that carry it.
    Delete   drops lines that carry Marker.
.OUTPUTS
    An object with the new Lines and the number of Changed lines.
#>
function Edit-HostsContent {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines,
        [Parameter(Mandatory)] [ValidateSet('Disable', 'Restore', 'Delete')] [string] $Mode,
        [Parameter(Mandatory)] [string] $Marker,
        [string[]] $Domains = @()
    )

    $output = [Collections.Generic.List[string]]::new()
    $count = 0
    foreach ($line in $Lines) {
        $marked = $line.StartsWith($Marker, [StringComparison]::Ordinal)
        switch ($Mode) {
            'Disable' {
                if (-not $marked -and -not $line.TrimStart().StartsWith('#') -and (Test-ManagedHostsLine $line $Domains)) {
                    $output.Add($Marker + $line); $count++
                }
                else { $output.Add($line) }
            }
            'Restore' {
                if ($marked) { $output.Add($line.Substring($Marker.Length)); $count++ } else { $output.Add($line) }
            }
            'Delete' {
                if ($marked) { $count++ } else { $output.Add($line) }
            }
        }
    }
    return [pscustomobject]@{ Lines = $output.ToArray(); Changed = $count }
}

<#
.SYNOPSIS
    Reads the hosts file keeping its encoding, line ending and trailing newline, so writing it back
    changes only the edited lines. Files without a BOM that are not valid UTF-8 are read as ANSI.
#>
function Read-HostsFile {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($true)
        $text = $encoding.GetString($bytes, 3, $bytes.Length - 3)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $true)
        $text = $encoding.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        try {
            $encoding = [Text.UTF8Encoding]::new($false, $true)
            $text = $encoding.GetString($bytes)
            $encoding = [Text.UTF8Encoding]::new($false)
        }
        catch {
            $encoding = [Text.Encoding]::Default
            $text = $encoding.GetString($bytes)
        }
    }
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailing = $text.EndsWith("`n")
    $body = if ($trailing) { $text.Substring(0, $text.Length - $newLine.Length) } else { $text }
    $lines = [string[]]@()
    if ($text.Length -gt 0) { $lines = [string[]]($body -split [regex]::Escape($newLine)) }
    return [pscustomobject]@{ Lines = $lines; Encoding = $encoding; NewLine = $newLine; TrailingNewLine = $trailing }
}

function Write-HostsFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $File, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Lines)

    $text = $Lines -join $File.NewLine
    if ($File.TrailingNewLine) { $text += $File.NewLine }
    [IO.File]::WriteAllText($Path, $text, $File.Encoding)
}

<#
.SYNOPSIS
    Comments out hosts entries that would override the smart DNS, keeping a one-time copy of the original file.
.OUTPUTS
    System.Int32. The number of entries disabled.
#>
function Disable-ManagedHostsEntry {
    $path = $script:Paths.Hosts
    $file = Read-HostsFile $path
    $edit = Edit-HostsContent -Lines $file.Lines -Mode Disable -Marker $script:HostsMarker -Domains (Get-ManagedDomain)
    if ($edit.Changed -eq 0) { return 0 }
    $null = Invoke-SystemChange "Comment out $($edit.Changed) hosts entries" {
        if (-not (Test-Path -LiteralPath $script:Paths.HostsBackup)) { Copy-Item -LiteralPath $path -Destination $script:Paths.HostsBackup -Force }
        Write-HostsFile $path $file $edit.Lines
    }
    return $edit.Changed
}

<#
.SYNOPSIS
    Reverts Disable-ManagedHostsEntry, or with -Delete drops the commented entries for good.
.OUTPUTS
    System.Int32. The number of entries restored or deleted.
#>
function Restore-ManagedHostsEntry {
    param([switch] $Delete)

    $path = $script:Paths.Hosts
    $file = Read-HostsFile $path
    $mode = if ($Delete) { 'Delete' } else { 'Restore' }
    $edit = Edit-HostsContent -Lines $file.Lines -Mode $mode -Marker $script:HostsMarker
    if ($edit.Changed -eq 0) { return 0 }
    $null = Invoke-SystemChange "$mode $($edit.Changed) hosts entries" { Write-HostsFile $path $file $edit.Lines }
    return $edit.Changed
}

function Clear-DnsCache {
    $null = Invoke-SystemChange 'Flush the DNS client cache' { Clear-DnsClientCache -ErrorAction Stop }
}

function Clear-NetworkCache {
    Clear-DnsCache
    $system = Join-Path $env:SystemRoot 'System32'
    $null = Invoke-SystemChange 'Flush the ARP cache' {
        $null = Invoke-NativeCommand (Join-Path $system 'netsh.exe') @('interface', 'ip', 'delete', 'arpcache')
    }
    $null = Invoke-SystemChange 'Purge and reload the NetBIOS name cache' {
        $null = Invoke-NativeCommand (Join-Path $system 'nbtstat.exe') @('-R')
    }
}

<#
.SYNOPSIS
    Resets Winsock and the TCP/IP stacks. Takes effect after a restart.
.OUTPUTS
    System.Boolean. True when every reset command succeeded.
#>
function Reset-NetworkStack {
    $netsh = Join-Path $env:SystemRoot 'System32
etsh.exe'
    $failed = [Collections.Generic.List[string]]::new()
    foreach ($arguments in @(@('winsock', 'reset'), @('int', 'ip', 'reset'), @('int', 'ipv6', 'reset'))) {
        $null = Invoke-SystemChange "netsh $($arguments -join ' ')" {
            $result = Invoke-NativeCommand $netsh $arguments
            if ($result.ExitCode -ne 0) { $failed.Add($arguments -join ' ') }
        }
    }
    return $failed.Count -eq 0
}
