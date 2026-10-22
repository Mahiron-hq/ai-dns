BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest

    # Builds a candidate whose every service resolves to $Address, plus HTTPS results keyed like the real run.
    # $Responses maps "<domain><path>" to a hashtable of AiDns.HttpsProbe field values.
    function New-TestCase([string] $Address = '203.0.114.10', [hashtable] $Responses = @{}, [hashtable] $Reference = @{}) {
        InModuleScope AIDNS -Parameters @{ Address = $Address; Responses = $Responses; Reference = $Reference } {
            $candidate = New-Candidate $Address ([pscustomobject]@{ Id = 'test'; Name = 'Test'; Doh = [string[]]@() })
            $https = @{}
            foreach ($service in $script:Services) {
                $query = New-DnsQuery $Address $service.Domain $service.Id
                $query.Addresses = [string[]]@($Address)
                $query.RCode = 0
                $query.Error = [AiDns.ProbeError]::None
                $candidate.Dns[$service.Id] = $query
                foreach ($check in $service.Checks) {
                    $fields = $Responses["$($service.Domain)$($check.Path)"]
                    if ($null -eq $fields) { continue }
                    $probe = New-HttpsProbe $Address $service.Domain $check
                    $probe.TcpOk = $true
                    $probe.TlsOk = $true
                    foreach ($name in $fields.Keys) { $probe.$name = $fields[$name] }
                    $https[(Get-CheckKey $Address $service.Domain $check.Path)] = $probe
                }
            }
            [pscustomobject]@{
                Candidate = $candidate
                Context   = [pscustomobject]@{ Services = $script:Services; Reference = $Reference; Https = $https }
            }
        }
    }

    function Test-Service([string] $Id, $Subject) {
        InModuleScope AIDNS -Parameters @{ Id = $Id; Subject = $Subject } {
            $service = @($script:Services | Where-Object { $_.Id -eq $Id })[0]
            Test-ServiceAccess $service $Subject.Candidate $Subject.Context
        }
    }

    $script:Ok200 = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`n" }
}

Describe 'Test-ServiceAccess for Cloudflare services' {
    It 'accepts a supported region' {
        $subject = New-TestCase -Responses @{
            'chatgpt.com/cdn-cgi/trace' = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`nfl=1`nloc=DE`nwarp=off`n" }
            'chatgpt.com/'              = $script:Ok200
        }
        $verdict = Test-Service 'chatgpt' $subject
        $verdict.Ok | Should -BeTrue
        $verdict.Reason | Should -Be 'Region'
        $verdict.Arguments[0] | Should -Be 'DE'
    }

    It 'rejects a blocked region' {
        $subject = New-TestCase -Responses @{
            'claude.ai/cdn-cgi/trace' = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`nloc=RU`n" }
            'claude.ai/'              = $script:Ok200
        }
        (Test-Service 'claude' $subject).Reason | Should -Be 'RegionBlocked'
    }

    It 'reports <Case>' -ForEach @(
        @{ Case = 'an SNI reset'; Fields = @{ TlsOk = $false; Error = 'TlsReset' }; Reason = 'TlsBlocked' }
        @{ Case = 'a forged certificate'; Fields = @{ TlsOk = $false; Error = 'CertificateInvalid'; Detail = 'RemoteCertificateNameMismatch' }; Reason = 'TlsForged' }
        @{ Case = 'a DPI stall'; Fields = @{ Stalled = $true; Status = 200; Detail = '16 KB' }; Reason = 'Stalled' }
        @{ Case = 'an unreachable proxy'; Fields = @{ TcpOk = $false; TlsOk = $false; Error = 'ConnectTimeout' }; Reason = 'Unreachable' }
    ) {
        $subject = New-TestCase -Responses @{ 'chatgpt.com/cdn-cgi/trace' = $Fields; 'chatgpt.com/' = $script:Ok200 }
        (Test-Service 'chatgpt' $subject).Reason | Should -Be $Reason
    }

    It 'reports a blackholed answer' {
        $subject = New-TestCase
        InModuleScope AIDNS -Parameters @{ Subject = $subject } {
            $Subject.Candidate.Dns['chatgpt'].Addresses = [string[]]@()
            $Subject.Candidate.Dns['chatgpt'].Error = [AiDns.ProbeError]::Blackholed
        }
        (Test-Service 'chatgpt' $subject).Reason | Should -Be 'Blackholed'
    }
}

Describe 'Test-ServiceAccess for APIs' {
    It 'treats 401 from a proxied Anthropic API as working' {
        $subject = New-TestCase -Responses @{ 'api.anthropic.com/v1/models' = @{ Status = 401 } } -Reference @{ 'api.anthropic.com' = @('160.79.104.10') }
        (Test-Service 'anthropic-api' $subject).Reason | Should -Be 'ApiResponds'
    }

    It 'rejects the direct Anthropic address' {
        $subject = New-TestCase -Address '160.79.104.10' -Responses @{ 'api.anthropic.com/v1/models' = @{ Status = 401 } } `
            -Reference @{ 'api.anthropic.com' = @('160.79.104.10') }
        (Test-Service 'anthropic-api' $subject).Reason | Should -Be 'AnthropicDirect'
    }

    It 'detects an unsupported OpenAI country' {
        $subject = New-TestCase -Responses @{ 'api.openai.com/v1/models' = @{ Status = 403; Head = '{"error":{"code":"unsupported_country_region_territory"}}' } }
        (Test-Service 'openai-api' $subject).Reason | Should -Be 'OpenAiRegion'
    }

    It 'derives the Gemini web verdict from the Gemini API region: <Case>' -ForEach @(
        @{ Case = 'supported'; Head = '{"error":{"message":"API key not valid. Please pass a valid API key."}}'; Ok = $true; Reason = 'GoogleRegionOk' }
        @{ Case = 'unsupported'; Head = '{"error":{"message":"User location is not supported for the API use."}}'; Ok = $false; Reason = 'GoogleRegionBlocked' }
    ) {
        $subject = New-TestCase -Responses @{
            'gemini.google.com/' = $script:Ok200
            'generativelanguage.googleapis.com/v1beta/models?key=AIzaSyAIDNS-geo-probe-not-a-real-key00' = @{ Status = 400; Head = $Head }
        }
        $verdict = Test-Service 'gemini' $subject
        $verdict.Ok | Should -Be $Ok
        $verdict.Reason | Should -Be $Reason
    }

    It 'rejects a direct Google address when the region is unknown' {
        $subject = New-TestCase -Address '142.250.74.46' -Responses @{ 'gemini.google.com/' = $script:Ok200 }
        (Test-Service 'gemini' $subject).Reason | Should -Be 'DirectGoogle'
    }
}

Describe 'Test-ServiceAccess for user-added domains' {
    BeforeAll {
        # Probes example.org through $Address; $Responses maps a check path to AiDns.HttpsProbe field values.
        function Test-Strict([hashtable] $Responses, [string] $Address = '203.0.114.20', [hashtable] $Reference = @{}) {
            InModuleScope AIDNS -Parameters @{ Responses = $Responses; Address = $Address; Reference = $Reference } {
                $service = New-CustomService 'example.org'
                $candidate = New-Candidate $Address $null
                $query = New-DnsQuery $Address $service.Domain $service.Id
                $query.Addresses = [string[]]@($Address)
                $query.RCode = 0
                $query.Error = [AiDns.ProbeError]::None
                $candidate.Dns[$service.Id] = $query
                $https = @{}
                foreach ($check in $service.Checks) {
                    $fields = $Responses[$check.Path]
                    if ($null -eq $fields) { continue }
                    $probe = New-HttpsProbe $Address $service.Domain $check
                    $probe.TcpOk = $true
                    $probe.TlsOk = $true
                    foreach ($name in $fields.Keys) { $probe.$name = $fields[$name] }
                    $https[(Get-CheckKey $Address $service.Domain $check.Path)] = $probe
                }
                Test-ServiceAccess $service $candidate ([pscustomobject]@{ Services = @($service); Reference = $Reference; Https = $https })
            }
        }
        $script:NotCloudflare = @{ Status = 404; Head = "HTTP/1.1 404 Not Found`r`n`r`n" }
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'a Cloudflare site in a supported region'; Trace = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`nloc=DE`n" }; Page = @{ Status = 200 }; Reason = 'Region' }
        @{ Case = 'a Cloudflare bot challenge'; Trace = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`nloc=NL`n" }; Page = @{ Status = 403; Head = "HTTP/1.1 403 Forbidden`r`ncf-mitigated: challenge`r`n`r`n" }; Reason = 'Region' }
    ) {
        $verdict = Test-Strict @{ '/cdn-cgi/trace' = $Trace; '/' = $Page }
        $verdict.Ok | Should -BeTrue
        $verdict.Reason | Should -Be $Reason
    }

    It 'tells a proxied answer from a direct one' {
        $reference = @{ 'example.org' = @('198.51.100.7') }
        (Test-Strict @{ '/cdn-cgi/trace' = $script:NotCloudflare; '/' = @{ Status = 200 } } -Reference $reference).Reason | Should -Be 'Proxied'
        (Test-Strict @{ '/cdn-cgi/trace' = $script:NotCloudflare; '/' = @{ Status = 200 } } -Address '198.51.100.9' -Reference $reference).Reason | Should -Be 'Direct'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'HTTP 403'; Trace = $null; Page = @{ Status = 403; Head = "HTTP/1.1 403 Forbidden`r`n`r`n" }; Reason = 'BlockedStatus' }
        @{ Case = 'HTTP 451'; Trace = $null; Page = @{ Status = 451 }; Reason = 'BlockedStatus' }
        @{ Case = 'a server error'; Trace = $null; Page = @{ Status = 503 }; Reason = 'HttpStatus' }
        @{ Case = 'a blocked Cloudflare region'; Trace = @{ Status = 200; Head = "HTTP/1.1 200 OK`r`n`r`nloc=RU`n" }; Page = @{ Status = 200 }; Reason = 'RegionBlocked' }
        @{ Case = 'a page that never answers'; Trace = $null; Page = @{ Status = 0; Error = 'NoResponse' }; Reason = 'NoHttp' }
        @{ Case = 'a stalled page'; Trace = $null; Page = @{ Status = 200; Stalled = $true; Detail = '16 KB' }; Reason = 'Stalled' }
    ) {
        $trace = if ($null -ne $Trace) { $Trace } else { $script:NotCloudflare }
        $verdict = Test-Strict @{ '/cdn-cgi/trace' = $trace; '/' = $Page }
        $verdict.Ok | Should -BeFalse
        $verdict.Reason | Should -Be $Reason
    }
}

Describe 'Update-CandidateScore' {
    It 'ranks a resolver that opens every required service above one that opens all the others' {
        $scores = InModuleScope AIDNS {
            $services = @(Get-AiDnsServiceTable (New-AiDnsSetting))
            $both = New-Candidate '198.51.101.1' $null
            $rest = New-Candidate '198.51.101.2' $null
            foreach ($s in $services) {
                $both.Verdicts[$s.Id] = New-Verdict ($s.Mode -eq 'Required') 'Test'
                $rest.Verdicts[$s.Id] = New-Verdict ($s.Id -ne 'claude') 'Test'
            }
            foreach ($c in @($both, $rest)) { Update-CandidateScore $c $services }
            @($both.Score, $rest.Score)
        }
        $scores[0] | Should -BeGreaterThan $scores[1]
    }

    It 'ignores services that are not checked' {
        $candidate = InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.Modes['gemini'] = 'Off'
            $services = @(Get-AiDnsServiceTable $settings)
            $c = New-Candidate '198.51.101.3' $null
            foreach ($s in $services) { $c.Verdicts[$s.Id] = New-Verdict ($s.Id -eq 'gemini') 'Test' }
            Update-CandidateScore $c $services
            $c
        }
        $candidate.WebCount | Should -Be 0
        $candidate.Mask | Should -Be '00'
    }
}

Describe 'Select-AiDnsPlan' {
    BeforeAll {
        # Each spec: Address, Provider, Working (service ids that open) and Ms (DNS latency).
        function Invoke-Plan([object[]] $Specs, [hashtable] $Modes = @{}, [switch] $NoRoutes, [string] $Pinned = '') {
            InModuleScope AIDNS -Parameters @{ Specs = $Specs; Modes = $Modes; NoRoutes = [bool]$NoRoutes; Pinned = $Pinned } {
                $settings = New-AiDnsSetting
                foreach ($id in $Modes.Keys) { $settings.Modes[$id] = $Modes[$id] }
                $services = @(Get-AiDnsServiceTable $settings)
                $candidates = @(foreach ($spec in $Specs) {
                    $c = New-Candidate $spec.Address ([pscustomobject]@{ Id = $spec.Provider; Name = $spec.Provider; Doh = [string[]]@() })
                    foreach ($s in $services) { $c.Verdicts[$s.Id] = New-Verdict (@($spec.Working) -contains $s.Id) 'Test' }
                    $c.DnsMs = $spec.Ms
                    $c.TlsMs = 0
                    Update-CandidateScore $c $services
                    $c
                })
                Select-AiDnsPlan $candidates $services -NoRoutes:$NoRoutes -PinnedProvider $Pinned
            }
        }
        $script:All = @('chatgpt', 'claude', 'gemini', 'openai-api', 'anthropic-api', 'gemini-api', 'code-login', 'code-site', 'code-updates')
        $script:NoGemini = @($script:All | Where-Object { $_ -ne 'gemini' })
    }

    It 'prefers a resolver that opens every required service and routes the rest' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'a'; Working = $script:NoGemini; Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'b'; Working = @('chatgpt', 'gemini'); Ms = 20 }
            @{ Address = '198.51.101.3'; Provider = 'c'; Working = $script:NoGemini; Ms = 30 }
        )
        $plan.Primary.Address | Should -Be '198.51.101.1'
        $plan.Secondary.Address | Should -Be '198.51.101.3'
        @($plan.Routes).Count | Should -Be 1
        $plan.Routes[0].Service.Id | Should -Be 'gemini'
        $plan.Routes[0].Servers -join ',' | Should -Be '198.51.101.2'
        $plan.Routes[0].Namespaces | Should -Contain 'gemini.google.com'
        @($plan.Missing).Count | Should -Be 0
    }

    It 'routes a required service that the primary cannot open' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'a'; Working = @('chatgpt', 'gemini', 'openai-api'); Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'b'; Working = @('claude'); Ms = 20 }
        )
        $plan.Primary.Address | Should -Be '198.51.101.1'
        @($plan.Routes | Where-Object { $_.Service.Id -eq 'claude' }).Count | Should -Be 1
        $plan.Routes[0].Namespaces | Should -Contain '.claude.ai'
        @($plan.Missing).Count | Should -Be 0
    }

    It 'reports a required service that no resolver opens' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'a'; Working = @('chatgpt'); Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'b'; Working = @('chatgpt', 'gemini'); Ms = 20 }
        )
        (@($plan.Missing | ForEach-Object { $_.Id }) -join ',') | Should -Be 'claude'
    }

    It 'leaves a required service uncovered without NRPT' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'a'; Working = @('chatgpt', 'gemini'); Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'b'; Working = @('claude'); Ms = 20 }
        ) -NoRoutes
        @($plan.Routes).Count | Should -Be 0
        (@($plan.Missing | ForEach-Object { $_.Id }) -join ',') | Should -Be 'claude'
    }

    It 'uses a pinned provider that opens every required service' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'fast'; Working = $script:All; Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'mine'; Working = $script:All; Ms = 900 }
        ) -Pinned 'mine'
        $plan.Primary.Address | Should -Be '198.51.101.2'
        $plan.Pinned | Should -Be 'Used'
    }

    It 'falls back when the pinned provider misses a required service' {
        $plan = Invoke-Plan @(
            @{ Address = '198.51.101.1'; Provider = 'fast'; Working = $script:All; Ms = 10 }
            @{ Address = '198.51.101.2'; Provider = 'mine'; Working = @('chatgpt'); Ms = 5 }
        ) -Pinned 'mine'
        $plan.Primary.Address | Should -Be '198.51.101.1'
        $plan.Pinned | Should -Be 'Failed'
    }

    It 'returns nothing when no checked web service works anywhere' {
        Invoke-Plan @(@{ Address = '198.51.101.9'; Provider = 'x'; Working = @('gemini', 'openai-api'); Ms = 10 }) -Modes @{ gemini = 'Off' } |
            Should -BeNullOrEmpty
    }
}
