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
        @{ Case = 'an SNI reset'; Fields = @{ TlsOk = $false; Error = [AiDns.ProbeError]::TlsReset }; Reason = 'TlsBlocked' }
        @{ Case = 'a forged certificate'; Fields = @{ TlsOk = $false; Error = [AiDns.ProbeError]::CertificateInvalid; Detail = 'RemoteCertificateNameMismatch' }; Reason = 'TlsForged' }
        @{ Case = 'a DPI stall'; Fields = @{ Stalled = $true; Status = 200; Detail = '16 KB' }; Reason = 'Stalled' }
        @{ Case = 'an unreachable proxy'; Fields = @{ TcpOk = $false; TlsOk = $false; Error = [AiDns.ProbeError]::ConnectTimeout }; Reason = 'Unreachable' }
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

Describe 'Select-AiDnsPlan' {
    It 'picks the best resolver and routes services it cannot open' {
        $plan = InModuleScope AIDNS {
            function New-Ranked([string] $Address, [double] $Score, [string[]] $Working) {
                $c = New-Candidate $Address ([pscustomobject]@{ Id = $Address; Name = $Address; Doh = [string[]]@() })
                foreach ($s in $script:Services) { $c.Verdicts[$s.Id] = New-Verdict ($Working -contains $s.Id) 'Test' }
                $c.Score = $Score
                $c.WebCount = @($script:Services | Where-Object { $_.Group -eq 'Web' -and $Working -contains $_.Id }).Count
                $c.Mask = -join @($script:Services | Where-Object { $_.Group -eq 'Web' } | ForEach-Object { if ($Working -contains $_.Id) { '1' } else { '0' } })
                $c
            }
            $all = @($script:Services | ForEach-Object { $_.Id })
            $candidates = @(
                (New-Ranked '198.51.101.1' 2000000 @($all | Where-Object { $_ -ne 'claude' }))
                (New-Ranked '198.51.101.2' 1000000 @('claude', 'chatgpt'))
                (New-Ranked '198.51.101.3' 1500000 @($all | Where-Object { $_ -ne 'claude' }))
            )
            Select-AiDnsPlan $candidates $script:Services
        }
        $plan.Primary.Address | Should -Be '198.51.101.1'
        $plan.Secondary.Address | Should -Be '198.51.101.3'
        @($plan.Routes).Count | Should -Be 1
        $plan.Routes[0].Service.Id | Should -Be 'claude'
        $plan.Routes[0].Servers -join ',' | Should -Be '198.51.101.2'
        $plan.Routes[0].Namespaces | Should -Contain '.claude.ai'
    }

    It 'returns nothing when no web service works anywhere' {
        InModuleScope AIDNS {
            $c = New-Candidate '198.51.101.9' ([pscustomobject]@{ Id = 'x'; Name = 'x'; Doh = [string[]]@() })
            Select-AiDnsPlan @($c) $script:Services
        } | Should -BeNullOrEmpty
    }
}
