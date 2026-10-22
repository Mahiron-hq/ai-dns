# Static configuration shared by every action.

$script:RepositoryUrl = 'https://github.com/Mahiron-hq/ai-dns'
$script:LatestReleaseApi = 'https://api.github.com/repos/Mahiron-hq/ai-dns/releases/latest'
$script:UpdateCheckInterval = [TimeSpan]::FromHours(24)
$script:UpdateCheckTimeoutMs = 2000

# Remote provider lists, tried in order per feed. Both are mirrored through jsDelivr because
# raw.githubusercontent.com is intermittently unreachable from Russian networks.
$script:Feeds = @(
    [pscustomobject]@{
        Id     = 'aidns'
        Format = 'AiDnsJson'
        Urls   = @(
            'https://raw.githubusercontent.com/Mahiron-hq/ai-dns/main/src/providers.json'
            'https://cdn.jsdelivr.net/gh/Mahiron-hq/ai-dns@main/src/providers.json'
        )
    }
    [pscustomobject]@{
        Id     = 'dnsswitch'
        Format = 'DnsSwitchPresets'
        Urls   = @(
            'https://raw.githubusercontent.com/WhIteGh0s1/DnsSwitch/main/presets.txt'
            'https://cdn.jsdelivr.net/gh/WhIteGh0s1/DnsSwitch@main/presets.txt'
        )
    }
)
$script:FeedTtl       = [TimeSpan]::FromHours(6)
$script:FeedTimeoutMs = 6000
$script:FeedMaxBytes  = 1MB

$script:Limits = [pscustomobject]@{
    Providers           = 512
    AddressesPerList    = 32
    DohPerProvider      = 8
    ProviderNameLength  = 40
}

$script:Timing = [pscustomobject]@{
    DnsTimeoutMs     = 1500
    DnsAttempts      = 2
    ConnectTimeoutMs = 3000
    IoTimeoutMs      = 4000
    HttpsParallelism = 96
    LatencySamples   = 3
}

# Kind selects the verification rule in Test-ServiceAccess:
#   Cloudflare    region from /cdn-cgi/trace, then the page must not fail with 5xx
#   GoogleWeb     page must load; region taken from RegionFrom, else the IP must be proxied
#   OpenAiApi     unauthenticated API call must reach OpenAI and not report unsupported_country
#   AnthropicApi  must be proxied and answer 401 to a dummy key (403 means a closed region)
#   GoogleApi     must reject the dummy key instead of the location
#   Generic       Cloudflare region when available, otherwise proxied or plainly reachable
#   Strict        a user-added domain: every check must answer, and 403, 451 and 5xx count as blocked
$script:ServiceKinds = @('Cloudflare', 'GoogleWeb', 'OpenAiApi', 'AnthropicApi', 'GoogleApi', 'Generic', 'Strict')
# Web and Custom services decide whether a resolver is usable at all; Api and Support only add to its score.
$script:ServiceGroups = @('Web', 'Api', 'Support', 'Custom')
# Required: a resolver set is chosen only if it opens the service. Preferred: adds Weight to the score. Off: not checked.
$script:ServiceModes = @('Required', 'Preferred', 'Off')
$script:RequiredWeight = 1000
$script:CustomServiceLimit = 16

function New-ServiceCheck {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxBytes = 8192,
        [string[]] $Headers = @()
    )
    [pscustomobject]@{ Path = $Path; MaxBytes = $MaxBytes; Headers = $Headers }
}

$script:BuiltInServices = @(
    [pscustomobject]@{
        Id = 'chatgpt'; Mode = 'Required'; Name = 'ChatGPT'; Domain = 'chatgpt.com'; Weight = 100; Group = 'Web'; Kind = 'Cloudflare'
        RegionFrom = $null; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'), (New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @('chatgpt.com', '.chatgpt.com', 'openai.com', '.openai.com', 'oaistatic.com', '.oaistatic.com',
                       'oaiusercontent.com', '.oaiusercontent.com')
    }
    [pscustomobject]@{
        Id = 'claude'; Mode = 'Required'; Name = 'Claude'; Domain = 'claude.ai'; Weight = 100; Group = 'Web'; Kind = 'Cloudflare'
        RegionFrom = $null; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'), (New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @('claude.ai', '.claude.ai', 'claude.com', '.claude.com', 'anthropic.com', '.anthropic.com',
                       'claudeusercontent.com', '.claudeusercontent.com')
    }
    [pscustomobject]@{
        Id = 'gemini'; Mode = 'Preferred'; Name = 'Gemini'; Domain = 'gemini.google.com'; Weight = 100; Group = 'Web'; Kind = 'GoogleWeb'
        RegionFrom = 'gemini-api'; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @('gemini.google.com', 'gemini.google', 'bard.google.com', 'aistudio.google.com',
                       'generativelanguage.googleapis.com', 'alkalimakersuite-pa.clients6.google.com',
                       'robinfrontend-pa.googleapis.com', 'proactivebackend-pa.googleapis.com')
    }
    [pscustomobject]@{
        Id = 'openai-api'; Mode = 'Preferred'; Name = 'OpenAI API'; Domain = 'api.openai.com'; Weight = 30; Group = 'Api'; Kind = 'OpenAiApi'
        RegionFrom = $null; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/v1/models'))
        Namespaces = @('api.openai.com')
    }
    [pscustomobject]@{
        Id = 'anthropic-api'; Mode = 'Preferred'; Name = 'Anthropic API'; Domain = 'api.anthropic.com'; Weight = 60; Group = 'Api'; Kind = 'AnthropicApi'
        RegionFrom = $null; ClaudeCode = $true
        Checks     = @((New-ServiceCheck '/v1/models' -Headers @('anthropic-version: 2023-06-01', 'x-api-key: sk-ant-aidns-geo-probe')))
        Namespaces = @('api.anthropic.com')
    }
    [pscustomobject]@{
        Id = 'gemini-api'; Mode = 'Preferred'; Name = 'Gemini API'; Domain = 'generativelanguage.googleapis.com'; Weight = 30; Group = 'Api'; Kind = 'GoogleApi'
        RegionFrom = $null; ClaudeCode = $false
        Checks     = @((New-ServiceCheck '/v1beta/models?key=AIzaSyAIDNS-geo-probe-not-a-real-key00'))
        Namespaces = @('generativelanguage.googleapis.com')
    }
    # Claude Code signs in and exchanges OAuth tokens through platform.claude.com for every account
    # type, shows the login page on claude.com and updates itself from downloads.claude.ai.
    [pscustomobject]@{
        Id = 'code-login'; Mode = 'Preferred'; Name = 'platform.claude.com'; Domain = 'platform.claude.com'; Weight = 40; Group = 'Support'; Kind = 'Generic'
        RegionFrom = $null; ClaudeCode = $true
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'), (New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @('platform.claude.com')
    }
    [pscustomobject]@{
        Id = 'code-site'; Mode = 'Preferred'; Name = 'claude.com'; Domain = 'claude.com'; Weight = 10; Group = 'Support'; Kind = 'Generic'
        RegionFrom = $null; ClaudeCode = $true
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'), (New-ServiceCheck '/' -MaxBytes 65536))
        Namespaces = @('claude.com', 'www.claude.com')
    }
    [pscustomobject]@{
        Id = 'code-updates'; Mode = 'Preferred'; Name = 'downloads.claude.ai'; Domain = 'downloads.claude.ai'; Weight = 5; Group = 'Support'; Kind = 'Generic'
        RegionFrom = $null; ClaudeCode = $true
        Checks     = @((New-ServiceCheck '/cdn-cgi/trace'))
        Namespaces = @('downloads.claude.ai')
    }
)
# The table in effect for this run; Use-AiDnsSetting replaces it with the user's modes and domains.
$script:Services = $script:BuiltInServices

# A well-known domain that every working resolver answers; used to measure latency.
$script:ProbeDomain = 'ya.ru'

# Yandex first: Russian ISPs sometimes intercept port 53 towards foreign resolvers only.
$script:ReferenceResolvers = @('77.88.8.8', '77.88.8.1', '8.8.8.8', '1.1.1.1')

# Cloudflare "loc" values for which the services refuse access. T1 is Tor, XX is unknown.
$script:BlockedRegions = @('RU', 'BY', 'CN', 'HK', 'MO', 'IR', 'KP', 'CU', 'SY', 'T1', 'XX')

# Google front-end /16 networks: an answer inside them means the resolver did not proxy the domain.
$script:GooglePrefixes = @('142.250', '142.251', '172.217', '172.253', '216.58', '216.239', '74.125', '173.194',
                           '64.233', '108.177', '209.85')

# Browsers with their own DNS-over-HTTPS client ignore the system resolver, so it is switched off by policy.
$script:BrowserPolicies = @(
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome';                Name = 'DnsOverHttpsMode';        Type = 'String'; Value = 'off' }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome';                Name = 'BuiltInDnsClientEnabled'; Type = 'DWord';  Value = 0 }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';               Name = 'DnsOverHttpsMode';        Type = 'String'; Value = 'off' }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';               Name = 'BuiltInDnsClientEnabled'; Type = 'DWord';  Value = 0 }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';          Name = 'DnsOverHttpsMode';        Type = 'String'; Value = 'off' }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';          Name = 'BuiltInDnsClientEnabled'; Type = 'DWord';  Value = 0 }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Enabled';                 Type = 'DWord';  Value = 0 }
    [pscustomobject]@{ Key = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Locked';                  Type = 'DWord';  Value = 1 }
)
# Parents that may have been created only to hold the policies above, deepest first.
$script:PolicyParentKeys = @(
    'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS', 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox',
    'HKLM:\SOFTWARE\Policies\Mozilla', 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Google',
    'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'HKLM:\SOFTWARE\Policies\BraveSoftware',
    'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
)

$script:VirtualAdapterPattern = 'Radmin|Hamachi|ZeroTier|Tailscale|VirtualBox|VMware|Hyper-V|vEthernet|TAP-Windows|Wintun|' +
    'WireGuard|OpenVPN|AmneziaWG|sing-box|Happ|Clash|Xray|v2ray|Npcap|Loopback|Bluetooth'
$script:VpnProcessPattern = '^(openvpn|wireguard|amneziawg|v2rayn|nekoray|hiddify|outline|happ|happd|clash|sing-box|xray)'

$script:NrptComment = 'AIDNS'
$script:HostsMarker = '# AIDNS-disabled: '

$script:Paths = [pscustomobject]@{
    Root        = Join-Path $env:ProgramData 'AIDNS'
    Cache       = Join-Path $env:ProgramData 'AIDNS\cache'
    Logs        = Join-Path $env:ProgramData 'AIDNS\logs'
    Backup      = Join-Path $env:ProgramData 'AIDNS\backup.json'
    State       = Join-Path $env:ProgramData 'AIDNS\state.json'
    HostsBackup = Join-Path $env:ProgramData 'AIDNS\hosts.bak'
    Hosts       = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Catalog     = Join-Path $PSScriptRoot '..\providers.json'
    Engine      = Join-Path $PSScriptRoot '..\Probe.cs'
    # Next to the launchers, so Disable and Update, which delete the data directory, never touch it.
    Settings    = Join-Path $PSScriptRoot '..\..\settings.json'
    Launcher    = Join-Path $PSScriptRoot '..\..\AI-DNS.ps1'
}
foreach ($name in @('Catalog', 'Engine', 'Settings', 'Launcher')) { $script:Paths.$name = [IO.Path]::GetFullPath($script:Paths.$name) }

$script:LogRetention = 20
