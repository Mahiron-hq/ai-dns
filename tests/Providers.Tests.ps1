BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest
    $script:CatalogJson = [IO.File]::ReadAllText((Join-Path $script:SourceRoot 'providers.json'))
}

Describe 'Bundled catalog' {
    BeforeAll {
        $script:Raw = $script:CatalogJson | ConvertFrom-Json
        $script:Catalog = InModuleScope AIDNS -Parameters @{ Json = $script:CatalogJson } {
            ConvertFrom-ProviderCatalog -Json $Json -Source 'bundled'
        }
    }

    It 'keeps every provider through validation' {
        @($script:Catalog.Providers).Count | Should -Be @($script:Raw.providers).Count
    }

    It 'keeps every address through validation' {
        $raw = @($script:Raw.providers | ForEach-Object { $_.ipv4 })
        $parsed = @($script:Catalog.Providers | ForEach-Object { $_.Ipv4 })
        $parsed.Count | Should -Be $raw.Count
    }

    It 'has unique ids and addresses' {
        $ids = @($script:Raw.providers | ForEach-Object { $_.id })
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        $addresses = @($script:Raw.providers | ForEach-Object { $_.ipv4 })
        @($addresses | Select-Object -Unique).Count | Should -Be $addresses.Count
    }

    It 'uses DoH hosts as discovery names' {
        $comss = @($script:Catalog.Providers | Where-Object { $_.Id -eq 'comss' })[0]
        $comss.Hosts | Should -Contain 'dns.comss.one'
        $comss.Hosts | Should -Contain 'router.comss.one'
    }

    It 'rejects an unsupported schema version' {
        { InModuleScope AIDNS { ConvertFrom-ProviderCatalog -Json '{"schemaVersion": 2, "providers": []}' -Source 'test' } } |
            Should -Throw
    }
}

Describe 'Provider entry validation' {
    It 'drops private addresses, bad hosts and non-https templates' {
        $entry = InModuleScope AIDNS {
            New-ProviderEntry -Id 'x' -Name 'X' -Source 'test' -Ipv4 @('10.0.0.1', '8.8.4.4', '8.8.4.4', 'junk') `
                -Hosts @('Good.Example.COM.', 'bad_host', '') -Doh @('http://a.example/dns-query', 'https://b.example/dns-query{?dns}')
        }
        $entry.Ipv4 -join ',' | Should -Be '8.8.4.4'
        $entry.Doh -join ',' | Should -Be 'https://b.example/dns-query'
        $entry.Hosts -join ',' | Should -Be 'good.example.com,b.example'
    }

    It 'returns nothing when no address or host survives' {
        InModuleScope AIDNS { New-ProviderEntry -Id 'x' -Name 'X' -Source 'test' -Ipv4 @('192.168.0.1') } | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-DnsSwitchPreset' {
    It 'parses entries and skips comments and malformed lines' {
        $text = @(
            '# comment'
            'geohide | GeoHide | ChatGPT | 159.194.200.33, 37.230.192.51 | https://dns.geohide.ru/dns-query'
            'mafioznik | Mafioznik | via Comss | 103.27.157.38 |'
            'broken line without separators'
            'private | Private | x | 192.168.1.1 |'
        ) -join "`r`n"
        $providers = @(InModuleScope AIDNS -Parameters @{ Text = $text } { ConvertFrom-DnsSwitchPreset -Text $Text })
        ($providers | ForEach-Object { $_.Id }) -join ',' | Should -Be 'dnsswitch-geohide,dnsswitch-mafioznik'
        $providers[0].Ipv4 -join ',' | Should -Be '159.194.200.33,37.230.192.51'
        $providers[0].Doh -join ',' | Should -Be 'https://dns.geohide.ru/dns-query'
        @($providers[1].Doh).Count | Should -Be 0
    }
}

Describe 'Merge-ProviderList' {
    It 'folds entries that share an id, address or host into the first one' {
        $merged = @(InModuleScope AIDNS {
            $a = New-ProviderEntry -Id 'geohide' -Name 'GeoHide' -Source 'bundled' -Ipv4 @('159.194.200.33') -Hosts @('dns.geohide.ru')
            $b = New-ProviderEntry -Id 'dnsswitch-geohide2' -Name 'GeoHide 2' -Source 'feed' -Ipv4 @('159.194.200.33', '193.233.112.67')
            $c = New-ProviderEntry -Id 'dnsswitch-other' -Name 'Other' -Source 'feed' -Ipv4 @('1.0.0.1')
            $d = New-ProviderEntry -Id 'geohide' -Name 'Renamed' -Source 'remote' -Ipv4 @('46.8.158.6')
            Merge-ProviderList -Providers @($a, $b, $c, $d)
        })
        $merged.Count | Should -Be 2
        $merged[0].Name | Should -Be 'GeoHide'
        $merged[0].Ipv4 -join ',' | Should -Be '159.194.200.33,193.233.112.67,46.8.158.6'
        $merged[1].Id | Should -Be 'dnsswitch-other'
    }
}

Describe 'ConvertTo-DohTemplate' {
    It 'normalizes <Template>' -ForEach @(
        @{ Template = ' https://DNS.Comss.One/dns-query '; Expected = 'https://dns.comss.one/dns-query' }
        @{ Template = 'https://x.example/dns-query{?dns}'; Expected = 'https://x.example/dns-query' }
        @{ Template = 'https://x.example:8443/dns-query'; Expected = $null }
        @{ Template = 'https://x.example'; Expected = $null }
        @{ Template = 'tls://x.example'; Expected = $null }
    ) {
        InModuleScope AIDNS -Parameters @{ Template = $Template } { ConvertTo-DohTemplate $Template } | Should -Be $Expected
    }
}
