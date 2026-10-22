BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest
}

Describe 'ConvertTo-AiDnsDomain' {
    It 'normalizes <Text>' -ForEach @(
        @{ Text = 'https://www.Perplexity.ai/search?q=1'; Expected = 'perplexity.ai' }
        @{ Text = 'chat.mistral.ai.'; Expected = 'chat.mistral.ai' }
        @{ Text = '*.example.com'; Expected = 'example.com' }
        @{ Text = 'example.com:8443/path'; Expected = 'example.com' }
        @{ Text = '  Example.COM  '; Expected = 'example.com' }
        @{ Text = 'пример.рф'; Expected = 'xn--e1afmkfd.xn--p1ai' }
    ) {
        InModuleScope AIDNS -Parameters @{ Text = $Text } { ConvertTo-AiDnsDomain $Text } | Should -Be $Expected
    }

    It 'rejects <Text>' -ForEach @(
        @{ Text = '' }
        @{ Text = 'localhost' }
        @{ Text = 'a..b' }
        @{ Text = 'exa mple.com' }
        @{ Text = '-bad.com' }
        @{ Text = '1.2.3.4' }
    ) {
        InModuleScope AIDNS -Parameters @{ Text = $Text } { ConvertTo-AiDnsDomain $Text } | Should -BeNullOrEmpty
    }
}

Describe 'Find-ServiceOverlap' {
    It 'finds <Domain> inside <Expected>' -ForEach @(
        @{ Domain = 'openai.com'; Expected = 'chatgpt' }
        @{ Domain = 'api.anthropic.com'; Expected = 'claude' }
        @{ Domain = 'google.com'; Expected = 'gemini' }
    ) {
        $found = InModuleScope AIDNS -Parameters @{ Domain = $Domain } { Find-ServiceOverlap $Domain $script:BuiltInServices }
        $found.Id | Should -Be $Expected
    }

    It 'accepts an unrelated domain' {
        InModuleScope AIDNS { Find-ServiceOverlap 'perplexity.ai' $script:BuiltInServices } | Should -BeNullOrEmpty
    }
}

Describe 'settings.json parsing' {
    It 'keeps valid values and replaces invalid ones with defaults' {
        $settings = InModuleScope AIDNS {
            $json = @'
{
  "language": "de",
  "waitSeconds": 7,
  "checkUpdates": false,
  "flags": { "trace": true, "testOnly": "yes" },
  "system": { "disableIpv6": false },
  "services": { "chatgpt": "off", "claude": "bogus", "gemini": "required" },
  "customServices": [
    { "domain": "https://perplexity.ai/", "mode": "preferred" },
    { "domain": "perplexity.ai", "mode": "required" },
    { "domain": "chatgpt.com", "mode": "required" },
    { "domain": "not a domain", "mode": "required" },
    { "domain": "mistral.ai", "mode": "sometimes" }
  ],
  "customResolvers": ["1.1.1.1", "10.0.0.1", "x", "1.1.1.1"],
  "blockedProviders": ["geohide", "GeoHide", "bad id!"],
  "pinnedProvider": "comss",
  "dismissedVersion": "not-a-version"
}
'@
            ConvertFrom-AiDnsSettingsDocument (ConvertFrom-Json $json)
        }
        $settings.Language | Should -Be 'Auto'
        $settings.WaitSeconds | Should -Be 20
        $settings.CheckUpdates | Should -BeFalse
        $settings.Flags.Trace | Should -BeTrue
        $settings.Flags.TestOnly | Should -BeFalse
        $settings.Flags.DryRun | Should -BeFalse
        $settings.System.DisableIpv6 | Should -BeFalse
        $settings.System.Nrpt | Should -BeTrue
        $settings.Modes['chatgpt'] | Should -Be 'Off'
        $settings.Modes['claude'] | Should -Be 'Required'
        $settings.Modes['gemini'] | Should -Be 'Required'
        @($settings.CustomServices).Count | Should -Be 1
        $settings.CustomServices[0].Domain | Should -Be 'perplexity.ai'
        $settings.CustomServices[0].Mode | Should -Be 'Preferred'
        ($settings.CustomResolvers -join ',') | Should -Be '1.1.1.1'
        ($settings.BlockedProviders -join ',') | Should -Be 'geohide'
        $settings.PinnedProvider | Should -Be 'comss'
        $settings.DismissedVersion | Should -Be ''
    }

    It 'survives a round trip through JSON' {
        $result = InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.Language = 'ru'
            $settings.WaitSeconds = 5
            $settings.Flags.Trace = $true
            $settings.System.Hosts = $false
            $settings.Modes['gemini'] = 'Off'
            $settings.CustomServices.Add([pscustomobject]@{ Domain = 'perplexity.ai'; Mode = 'Required' })
            $settings.CustomResolvers.Add('203.0.114.1')
            $settings.BlockedAddresses.Add('203.0.114.2')
            $settings.Blocking.Add('custom-perplexity.ai')
            $first = ConvertTo-Json (ConvertTo-AiDnsSettingsDocument $settings) -Depth 8
            $second = ConvertTo-Json (ConvertTo-AiDnsSettingsDocument (ConvertFrom-AiDnsSettingsDocument (ConvertFrom-Json $first))) -Depth 8
            @($first, $second)
        }
        $result[1] | Should -Be $result[0]
    }

    It 'falls back to the defaults when the file is damaged' {
        $path = Join-Path $TestDrive 'settings.json'
        Set-Content -LiteralPath $path -Value '{ "language": ' -Encoding UTF8
        $outcome = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $saved = $script:Paths.Settings
            try {
                $script:Paths.Settings = $Path
                $settings = Get-AiDnsSetting -Reload
                [pscustomobject]@{ Language = $settings.Language; Problem = $script:SettingsProblem }
            }
            finally {
                $script:Paths.Settings = $saved
                $null = Get-AiDnsSetting -Reload
            }
        }
        $outcome.Language | Should -Be 'Auto'
        $outcome.Problem | Should -Not -BeNullOrEmpty
    }

    It 'saves and reads back the settings' {
        $path = Join-Path $TestDrive 'saved.json'
        $read = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $saved = $script:Paths.Settings
            try {
                $script:Paths.Settings = $Path
                $settings = New-AiDnsSetting
                $settings.PinnedProvider = 'geohide'
                $null = Save-AiDnsSetting $settings
                (Get-AiDnsSetting -Reload).PinnedProvider
            }
            finally {
                $script:Paths.Settings = $saved
                $null = Get-AiDnsSetting -Reload
            }
        }
        $read | Should -Be 'geohide'
    }
}

Describe 'Service table' {
    It 'applies the modes and appends user domains as strict services' {
        $table = InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.Modes['gemini'] = 'Off'
            $settings.CustomServices.Add([pscustomobject]@{ Domain = 'perplexity.ai'; Mode = 'Required' })
            Get-AiDnsServiceTable $settings
        }
        ($table | Where-Object Id -eq 'chatgpt').Mode | Should -Be 'Required'
        ($table | Where-Object Id -eq 'gemini').Mode | Should -Be 'Off'
        $custom = $table | Where-Object Id -eq 'custom-perplexity.ai'
        $custom.Kind | Should -Be 'Strict'
        $custom.Group | Should -Be 'Custom'
        $custom.Namespaces | Should -Contain '.perplexity.ai'
    }

    It 'does not change the built-in table' {
        InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.Modes['chatgpt'] = 'Off'
            $null = Get-AiDnsServiceTable $settings
            ($script:BuiltInServices | Where-Object Id -eq 'chatgpt').Mode
        } | Should -Be 'Required'
    }

    It 'removes user domains and switches built-in services off' {
        $settings = InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.CustomServices.Add([pscustomobject]@{ Domain = 'perplexity.ai'; Mode = 'Required' })
            $settings.Blocking.Add('custom-perplexity.ai')
            $settings.Blocking.Add('claude')
            Remove-AiDnsServiceCheck $settings @('custom-perplexity.ai', 'claude')
            $settings
        }
        @($settings.CustomServices).Count | Should -Be 0
        $settings.Modes['claude'] | Should -Be 'Off'
        @($settings.Blocking).Count | Should -Be 0
    }

    It 'resolves the log folder from the settings' {
        $result = InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.LogDirectory = 'C:\Logs\ai-dns'
            $absolute = Resolve-SettingsLogDirectory $settings
            $settings.LogDirectory = 'logs'
            $relative = Resolve-SettingsLogDirectory $settings
            @($absolute, $relative, (Split-Path -Parent $script:Paths.Settings))
        }
        $result[0] | Should -Be 'C:\Logs\ai-dns'
        $result[1] | Should -Be (Join-Path $result[2] 'logs')
    }

    It 'applies a default switch only to the actions that accept it' {
        InModuleScope AIDNS {
            $settings = New-AiDnsSetting
            $settings.Flags.TestOnly = $true
            $settings.Flags.Trace = $true
            @(
                (Test-SettingFlag $settings 'TestOnly' 'Enable')
                (Test-SettingFlag $settings 'TestOnly' 'Disable')
                (Test-SettingFlag $settings 'Trace' 'Update')
                (Test-SettingFlag $settings 'Full' 'Disable')
            ) -join ','
        } | Should -Be 'True,False,True,False'
    }
}

Describe 'Strings for the settings' {
    It 'exist for every switch, system toggle and mode in every language' {
        $keys = InModuleScope AIDNS {
            @($script:SettingFlags.Keys | ForEach-Object { "Flag.$_"; "Flag.$_.Hint" }) +
            @($script:SystemToggles | ForEach-Object { "System.$_"; "System.$_.Hint" }) +
            @($script:ServiceModes | ForEach-Object { "Mode.$_" }) +
            @($script:BuiltInServices | ForEach-Object { "Menu.Group.$($_.Group)" } | Select-Object -Unique)
        }
        foreach ($culture in 'en-US', 'ru-RU') {
            $table = Import-PowerShellDataFile (Join-Path $script:SourceRoot "$culture\AIDNS.Strings.psd1")
            @($keys | Where-Object { -not $table.ContainsKey($_) }) | Should -BeNullOrEmpty -Because $culture
        }
    }
}

Describe 'New version notice' {
    It 'reads a release of this repository' {
        $release = InModuleScope AIDNS {
            ConvertFrom-ReleaseInfo ([pscustomobject]@{ tag_name = 'v3.2.0'; html_url = 'https://github.com/Mahiron-hq/ai-dns/releases/tag/v3.2.0' })
        }
        $release.Version | Should -Be ([version]'3.2.0')
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a foreign link'; Tag = 'v3.2.0'; Url = 'https://example.com/releases/tag/v3.2.0' }
        @{ Case = 'a malformed tag'; Tag = 'latest'; Url = 'https://github.com/Mahiron-hq/ai-dns/releases/tag/latest' }
    ) {
        InModuleScope AIDNS -Parameters @{ Tag = $Tag; Url = $Url } {
            ConvertFrom-ReleaseInfo ([pscustomobject]@{ tag_name = $Tag; html_url = $Url })
        } | Should -BeNullOrEmpty
    }

    It 'announces <Latest> after <Dismissed>: <Expected>' -ForEach @(
        @{ Latest = '99.0.0'; Dismissed = ''; Expected = $true }
        @{ Latest = '99.0.0'; Dismissed = '99.0.0'; Expected = $false }
        @{ Latest = '99.1.0'; Dismissed = '99.0.0'; Expected = $true }
        @{ Latest = '0.1.0'; Dismissed = ''; Expected = $false }
    ) {
        InModuleScope AIDNS -Parameters @{ Latest = $Latest; Dismissed = $Dismissed } {
            Test-NewerRelease ([version]$Latest) $Dismissed
        } | Should -Be $Expected
    }
}
