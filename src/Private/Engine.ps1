# PowerShell side of the C# probe engine (Probe.cs).

<#
.SYNOPSIS
    Loads the probe engine, compiling Probe.cs on first use. The compiled assembly is cached in the
    administrator-only data directory under a name derived from the source hash, so an edited
    Probe.cs is recompiled automatically.
.OUTPUTS
    None. Throws when the engine can be neither loaded nor compiled.
#>
function Initialize-ProbeEngine {
    if ($null -ne ('AiDns.DnsBatch' -as [type])) { return }

    $source = [IO.File]::ReadAllText($script:Paths.Engine)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source)) } finally { $sha.Dispose() }
    $hash = -join ($digest[0..5] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $script:Paths.Cache "probe_$hash.dll"
    $null = New-Item -ItemType Directory -Path $script:Paths.Cache -Force

    if (Test-Path -LiteralPath $dll -PathType Leaf) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            Write-TraceLine "engine: loaded $dll"
            return
        }
        catch {
            Write-TraceLine "engine: cached assembly rejected: $($_.Exception.Message)"
            $null = Remove-TreeSafely $dll
        }
    }

    foreach ($old in @(Get-ChildItem -LiteralPath $script:Paths.Cache -Filter 'probe_*.dll' -File -ErrorAction SilentlyContinue)) {
        $null = Remove-TreeSafely $old.FullName
    }
    try {
        Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $dll -OutputType Library -ErrorAction Stop
    }
    catch { Write-TraceLine "engine: compiling to disk failed: $($_.Exception.Message)" }

    if ($null -eq ('AiDns.DnsBatch' -as [type]) -and (Test-Path -LiteralPath $dll -PathType Leaf)) {
        Add-Type -Path $dll -ErrorAction Stop
    }
    if ($null -eq ('AiDns.DnsBatch' -as [type])) {
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    }
    Write-TraceLine "engine: compiled $dll"
}

function New-DnsQuery {
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [string] $Name, [string] $Tag = '')

    $query = [AiDns.DnsQuery]::new()
    $query.Server = $Server
    $query.Name = $Name
    $query.Tag = $Tag
    return $query
}

function New-HttpsProbe {
    param(
        [Parameter(Mandatory)] [string] $Address,
        [Parameter(Mandatory)] [string] $HostName,
        [Parameter(Mandatory)] $Check,
        [string] $Tag = ''
    )

    $probe = [AiDns.HttpsProbe]::new()
    $probe.Address = $Address
    $probe.Host = $HostName
    $probe.Path = $Check.Path
    $probe.MaxBytes = $Check.MaxBytes
    $probe.Headers = [string[]]@($Check.Headers)
    $probe.Tag = $Tag
    return $probe
}

function New-DohProbe {
    param([Parameter(Mandatory)] [string] $Address, [Parameter(Mandatory)] [string] $Template, [string] $Tag = '')

    $probe = [AiDns.DohProbe]::new()
    $probe.Address = $Address
    $probe.Template = $Template
    $probe.Tag = $Tag
    return $probe
}

function Format-Duration {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '-' }
    return ('{0:N0}' -f [double]$Value)
}

<#
.SYNOPSIS
    Runs all queries in one batch; see AiDns.DnsBatch for the timing guarantees.
#>
function Invoke-DnsBatch {
    param([AllowEmptyCollection()] [object[]] $Queries)

    $list = [AiDns.DnsQuery[]]@($Queries | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return }
    [AiDns.DnsBatch]::Run($list, $script:Timing.DnsTimeoutMs, $script:Timing.DnsAttempts)
    if (-not $script:Run.Trace) { return }
    foreach ($q in $list) {
        Write-TraceLine ('dns {0,-15} {1,-36} {2,-13} rtt={3} rcode={4} tries={5} tag={6} {7}' -f $q.Server, $q.Name,
            $q.Error, (Format-Duration $q.RttMs), $q.RCode, $q.Attempts, $q.Tag, ($q.Addresses -join ','))
    }
}

<#
.SYNOPSIS
    Runs HTTPS and DoH probes concurrently; see AiDns.HttpsBatch.
#>
function Invoke-HttpsBatch {
    param([AllowEmptyCollection()] [object[]] $Probes = @(), [AllowEmptyCollection()] [object[]] $DohProbes = @())

    $https = [AiDns.HttpsProbe[]]@($Probes | Where-Object { $null -ne $_ })
    $doh = [AiDns.DohProbe[]]@($DohProbes | Where-Object { $null -ne $_ })
    if ($https.Count -eq 0 -and $doh.Count -eq 0) { return }
    [AiDns.HttpsBatch]::Run($https, $doh, $script:Timing.HttpsParallelism, $script:Timing.ConnectTimeoutMs, $script:Timing.IoTimeoutMs)
    if (-not $script:Run.Trace) { return }
    foreach ($p in $https) {
        Write-TraceLine ('https {0,-15} {1}{2} status={3} tcp={4} tls={5} ms={6}/{7} bytes={8} complete={9} error={10} {11}' -f
            $p.Address, $p.Host, $p.Path, $p.Status, $p.TcpOk, $p.TlsOk, (Format-Duration $p.ConnectMs),
            (Format-Duration $p.TlsMs), $p.Bytes, $p.Complete, $p.Error, $p.Detail)
    }
    foreach ($d in $doh) {
        Write-TraceLine ('doh {0,-15} {1} error={2} rtt={3} answer={4}' -f $d.Address, $d.Template, $d.Error,
            (Format-Duration $d.RttMs), ($d.Addresses -join ','))
    }
}
