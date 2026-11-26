BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest
}

Describe 'Set-BrowserPolicy (W-001)' {
    It 'records the original value on the first enable, when the backup has no policy records yet' {
        $count = InModuleScope AIDNS {
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null } }
            Mock Get-MissingRegistryKey { @('HKLM:\SOFTWARE\Policies\Google\Chrome') }
            Mock Invoke-SystemChange { $true }
            $backup = New-AiDnsBackup
            Set-BrowserPolicy $script:BrowserPolicies[0] $backup.Policies
            $backup.Policies.Count
        }
        $count | Should -Be 1
    }
}

Describe 'Restore-BrowserPolicy (W-002)' {
    BeforeAll {
        $script:Chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
    }

    It 'leaves a policy that has the AI-DNS value but no record' {
        InModuleScope AIDNS {
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = 'off' } } -ParameterFilter { $Name -eq 'DnsOverHttpsMode' }
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null } }
            Mock Invoke-SystemChange { $true }
            Mock Remove-RegistryKeyIfEmpty { }
            Restore-BrowserPolicy @() | Should -Be 0
            Should -Invoke Invoke-SystemChange -Times 0 -Exactly
        }
    }

    It 'removes a value it created that still holds the AI-DNS value' {
        InModuleScope AIDNS -Parameters @{ Key = $script:Chrome } {
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = 'off' } }
            Mock Invoke-SystemChange { $true }
            Mock Remove-RegistryKeyIfEmpty { }
            $record = [pscustomobject]@{ Key = $Key; Name = 'DnsOverHttpsMode'; Type = 'String'; ValueExisted = $false; OldValue = $null; CreatedKeys = @($Key) }
            Restore-BrowserPolicy @($record) | Should -Be 1
            Should -Invoke Invoke-SystemChange -Times 1 -Exactly -ParameterFilter { $ChangeDescription -like 'Remove policy*' }
            Should -Invoke Remove-RegistryKeyIfEmpty -Times 1 -Exactly -ParameterFilter { $Path -eq $Key }
        }
    }

    It 'puts back the original value' {
        InModuleScope AIDNS -Parameters @{ Key = $script:Chrome } {
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = 'off' } }
            Mock Invoke-SystemChange { $true }
            Mock Remove-RegistryKeyIfEmpty { }
            $record = [pscustomobject]@{ Key = $Key; Name = 'DnsOverHttpsMode'; Type = 'String'; ValueExisted = $true; OldValue = 'secure'; CreatedKeys = @() }
            Restore-BrowserPolicy @($record) | Should -Be 1
            Should -Invoke Invoke-SystemChange -Times 1 -Exactly -ParameterFilter { $ChangeDescription -like 'Restore policy*secure*' }
        }
    }

    It 'leaves a value that was changed after enable' {
        InModuleScope AIDNS -Parameters @{ Key = $script:Chrome } {
            Mock Get-RegistryValueInfo { [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = 'automatic' } }
            Mock Invoke-SystemChange { $true }
            Mock Remove-RegistryKeyIfEmpty { }
            $record = [pscustomobject]@{ Key = $Key; Name = 'DnsOverHttpsMode'; Type = 'String'; ValueExisted = $false; OldValue = $null; CreatedKeys = @() }
            Restore-BrowserPolicy @($record) | Should -Be 0
            Should -Invoke Invoke-SystemChange -Times 0 -Exactly
        }
    }
}

Describe 'Remove-OwnedDohTemplate (W-003)' {
    BeforeAll {
        $script:Entries = @(
            [pscustomobject]@{ ServerAddress = '203.0.114.1'; DohTemplate = 'https://dns.one.example/dns-query' }
            [pscustomobject]@{ ServerAddress = '203.0.114.2'; DohTemplate = 'https://own.example/dns-query' }
            [pscustomobject]@{ ServerAddress = '203.0.114.3'; DohTemplate = 'https://changed.example/dns-query' }
            [pscustomobject]@{ ServerAddress = '203.0.114.4'; DohTemplate = 'https://old.example/dns-query' }
        )
    }

    It 'removes only templates AI-DNS registered and that are unchanged' {
        InModuleScope AIDNS -Parameters @{ Entries = $script:Entries } {
            Mock Get-DohTemplateEntry { $Entries }
            Mock Remove-DohTemplate { }
            $owned = @(
                [pscustomobject]@{ Address = '203.0.114.1'; Template = 'https://dns.one.example/dns-query' }
                [pscustomobject]@{ Address = '203.0.114.3'; Template = 'https://dns.three.example/dns-query' }
                [pscustomobject]@{ Address = '203.0.114.4'; Template = $null }
            )
            Remove-OwnedDohTemplate -Owned $owned -Known @('203.0.114.1', '203.0.114.2', '203.0.114.3', '203.0.114.4') | Should -Be 2
            Should -Invoke Remove-DohTemplate -Times 1 -Exactly -ParameterFilter { $Address -eq '203.0.114.1' }
            Should -Invoke Remove-DohTemplate -Times 1 -Exactly -ParameterFilter { $Address -eq '203.0.114.4' }
            Should -Invoke Remove-DohTemplate -Times 0 -Exactly -ParameterFilter { $Address -in @('203.0.114.2', '203.0.114.3') }
        }
    }

    It 'takes the addresses an older state.json recorded' {
        $owned = InModuleScope AIDNS {
            $backup = New-AiDnsBackup
            $backup.Doh.Add([pscustomobject]@{ Address = '203.0.114.1'; Template = 'https://a.example/dns-query' })
            $state = [pscustomobject]@{ DohAdded = @('203.0.114.1', '203.0.114.9') }
            Get-OwnedDohRecord $backup $state
        }
        @($owned).Count | Should -Be 2
        ($owned | Where-Object Address -eq '203.0.114.9').Template | Should -BeNullOrEmpty
        ($owned | Where-Object Address -eq '203.0.114.1').Template | Should -Be 'https://a.example/dns-query'
    }
}

Describe 'New-AdapterBackupRecord (W-004)' {
    It 'keeps a mixed static list exactly: <Case>' -ForEach @(
        @{ Case = 'known and corporate'; Static = @('203.0.114.1', '10.0.0.53'); Applied = @('203.0.114.1', '203.0.114.2'); Expected = '203.0.114.1,10.0.0.53' }
        @{ Case = 'own smart DNS';       Static = @('203.0.114.1');              Applied = @('203.0.114.5');                Expected = '203.0.114.1' }
        @{ Case = 'last applied list';   Static = @('203.0.114.2', '203.0.114.1'); Applied = @('203.0.114.1', '203.0.114.2'); Expected = '' }
    ) {
        $record = InModuleScope AIDNS -Parameters @{ Static = $Static; Applied = $Applied } {
            Mock Get-AdapterStaticServer { if ($Family -eq 4) { $Static } else { @() } }
            Mock Get-Ipv6BindingState { $true }
            $connection = [pscustomobject]@{ Guid = '{00000000-0000-0000-0000-000000000001}'; AdapterName = 'Ethernet' }
            New-AdapterBackupRecord $connection ([pscustomobject]@{ Servers = $Applied })
        }
        $record.StaticV4 | Should -Be $Expected
        $record.AppliedV4 | Should -Be ''
    }
}

Describe 'Get-AdapterRollbackAction (W-005)' {
    BeforeAll {
        $script:Known = @('203.0.114.1', '203.0.114.2', '203.0.114.3')
    }

    It '<Case>: <Expected>' -ForEach @(
        @{ Case = 'record, unchanged since enable';         Applied = '203.0.114.1,203.0.114.2'; Current = @('203.0.114.2', '203.0.114.1'); HasBackup = $true; Full = $false; Expected = 'Restore' }
        @{ Case = 'record, changed after enable';           Applied = '203.0.114.1,203.0.114.2'; Current = @('9.9.9.9');                     HasBackup = $true; Full = $false; Expected = 'Changed' }
        @{ Case = 'record, changed, with -Full';            Applied = '203.0.114.1';             Current = @('9.9.9.9');                     HasBackup = $true; Full = $true;  Expected = 'Restore' }
        @{ Case = 'old record, smart DNS only';             Applied = '';                        Current = @('203.0.114.3');                 HasBackup = $true; Full = $false; Expected = 'Restore' }
        @{ Case = 'old record, other DNS';                  Applied = '';                        Current = @('203.0.114.3', '9.9.9.9');      HasBackup = $true; Full = $false; Expected = 'Changed' }
        @{ Case = 'no record, user set a known resolver';   Applied = $null;                     Current = @('203.0.114.1');                 HasBackup = $true; Full = $false; Expected = 'NotOurs' }
        @{ Case = 'no record, no backup, state proves it';  Applied = $null;                     Current = @('203.0.114.1', '203.0.114.2'); HasBackup = $false; Full = $false; Expected = 'Reset' }
        @{ Case = 'no record, no backup, other list';       Applied = $null;                     Current = @('203.0.114.1');                 HasBackup = $false; Full = $false; Expected = 'NotOurs' }
        @{ Case = 'no record, unrelated DNS';               Applied = $null;                     Current = @('9.9.9.9');                     HasBackup = $true; Full = $false; Expected = 'None' }
        @{ Case = 'no record, -Full';                       Applied = $null;                     Current = @('9.9.9.9');                     HasBackup = $true; Full = $true;  Expected = 'Reset' }
    ) {
        $action = InModuleScope AIDNS -Parameters @{ Applied = $Applied; Current = $Current; HasBackup = $HasBackup; Full = $Full; Known = $script:Known } {
            $record = if ($null -ne $Applied) { [pscustomobject]@{ StaticV4 = ''; StaticV6 = ''; AppliedV4 = $Applied } } else { $null }
            Get-AdapterRollbackAction -Record $record -Current $Current -StateServers @('203.0.114.1', '203.0.114.2') -Known $Known -HasBackup:$HasBackup -Full:$Full
        }
        $action | Should -Be $Expected
    }

    It 'accepts missing state and known lists' {
        $action = InModuleScope AIDNS {
            Get-AdapterRollbackAction -Record $null -Current @('9.9.9.9') -StateServers $null -Known $null
        }
        $action | Should -Be 'None'
    }
}

Describe 'backup.json' {
    It 'reads a 3.1.0 backup without the ownership fields' {
        $path = Join-Path $TestDrive 'backup-v3.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value (@{
            SchemaVersion = 3; Created = '2026-11-03T11:38:30'; Computer = 'PC'; HostsModified = $false; Policies = @()
            Adapters = @(@{ Guid = '{00000000-0000-0000-0000-000000000001}'; Name = 'Wi-Fi'; StaticV4 = ''; StaticV6 = ''; IPv6Enabled = $true; Ipv6DisabledByUs = $true })
        } | ConvertTo-Json -Depth 4)
        $backup = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $saved = $script:Paths.Backup
            try { $script:Paths.Backup = $Path; Read-AiDnsBackup } finally { $script:Paths.Backup = $saved }
        }
        @($backup.Adapters).Count | Should -Be 1
        $backup.Adapters[0].AppliedV4 | Should -Be ''
        $backup.Adapters[0].Ipv6DisabledByUs | Should -BeTrue
        @($backup.Doh).Count | Should -Be 0
    }

    It 'keeps the ownership records through a save and a read' {
        $path = Join-Path $TestDrive 'backup-v4.json'
        $backup = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $saved = $script:Paths.Backup
            $savedRun = $script:Run
            try {
                $script:Paths.Backup = $Path
                $script:Run = [pscustomobject]@{ DryRun = $false; Trace = $false; Errors = 0; Warnings = 0; Writer = $null }
                $original = New-AiDnsBackup
                $original.Adapters.Add([pscustomobject]@{
                    Guid = '{00000000-0000-0000-0000-000000000001}'; Name = 'Wi-Fi'; StaticV4 = '10.0.0.53'; StaticV6 = ''
                    IPv6Enabled = $true; Ipv6DisabledByUs = $false; AppliedV4 = '203.0.114.1,203.0.114.2'
                })
                $original.Doh.Add([pscustomobject]@{ Address = '203.0.114.1'; Template = 'https://dns.example/dns-query' })
                $original.Doh.Add([pscustomobject]@{ Address = '10.0.0.1'; Template = 'https://private.example/dns-query' })
                Save-AiDnsBackup $original
                Read-AiDnsBackup
            }
            finally { $script:Paths.Backup = $saved; $script:Run = $savedRun }
        }
        $backup.Adapters[0].AppliedV4 | Should -Be '203.0.114.1,203.0.114.2'
        @($backup.Doh).Count | Should -Be 1
        $backup.Doh[0].Template | Should -Be 'https://dns.example/dns-query'
    }
}

Describe 'Confirm-DamagedBackup (W-006)' {
    It 'stops without touching the file when nobody can answer' {
        $path = Join-Path $TestDrive 'backup.json'
        Set-Content -LiteralPath $path -Value '{ "Adapters": ' -Encoding UTF8
        $answer = InModuleScope AIDNS -Parameters @{ Path = $path } {
            Mock Test-InteractiveConsole { $false }
            Mock Invoke-SystemChange { $true }
            $saved = $script:Paths.Backup
            try { $script:Paths.Backup = $Path; Confirm-DamagedBackup 'broken' } finally { $script:Paths.Backup = $saved }
            Should -Invoke Invoke-SystemChange -Times 0 -Exactly
        }
        $answer | Should -BeFalse
        Test-Path -LiteralPath $path | Should -BeTrue
    }
}

Describe 'Test-AiDnsElevationNeeded (W-008)' {
    It '<Action> TestOnly=<TestOnly> FromSettings=<FromSettings>: <Expected>' -ForEach @(
        @{ Action = 'Enable';   TestOnly = $false; FromSettings = $false; Expected = $true }
        @{ Action = 'Enable';   TestOnly = $true;  FromSettings = $false; Expected = $false }
        @{ Action = 'Enable';   TestOnly = $false; FromSettings = $true;  Expected = $false }
        @{ Action = 'Disable';  TestOnly = $false; FromSettings = $true;  Expected = $true }
        @{ Action = 'Update';   TestOnly = $false; FromSettings = $false; Expected = $true }
        @{ Action = 'Status';   TestOnly = $false; FromSettings = $false; Expected = $false }
        @{ Action = 'Settings'; TestOnly = $false; FromSettings = $false; Expected = $false }
    ) {
        $needed = InModuleScope AIDNS -Parameters @{ Action = $Action; TestOnly = $TestOnly; FromSettings = $FromSettings } {
            Mock Get-AiDnsSetting {
                $settings = New-AiDnsSetting
                $settings.Flags.TestOnly = $FromSettings
                $settings
            }
            Test-AiDnsElevationNeeded -Action $Action -TestOnly:$TestOnly
        }
        $needed | Should -Be $Expected
    }
}

Describe 'Damaged settings.json (W-009, W-014)' {
    It 'is not overwritten by an automatic save' {
        $path = Join-Path $TestDrive 'auto\settings.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Set-Content -LiteralPath $path -Value '{ "language": "ru", ' -Encoding UTF8
        $before = Get-Content -LiteralPath $path -Raw
        $saved = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $original = $script:Paths.Settings
            try {
                $script:Paths.Settings = $Path
                $settings = Get-AiDnsSetting -Reload
                $settings.LastUpdateCheck = '2026-11-26T00:00:00Z'
                Save-AiDnsSetting $settings
            }
            finally {
                $script:Paths.Settings = $original
                $null = Get-AiDnsSetting -Reload
            }
        }
        $saved | Should -BeFalse
        Get-Content -LiteralPath $path -Raw | Should -Be $before
    }

    It 'is replaced by an explicit save, and a copy of it is kept' {
        $folder = Join-Path $TestDrive 'explicit'
        $path = Join-Path $folder 'settings.json'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Set-Content -LiteralPath $path -Value '[1, 2]' -Encoding UTF8
        $result = InModuleScope AIDNS -Parameters @{ Path = $path } {
            $original = $script:Paths.Settings
            try {
                $script:Paths.Settings = $Path
                $settings = Get-AiDnsSetting -Reload
                $problem = $script:SettingsProblem
                $settings.PinnedProvider = 'comss'
                [pscustomobject]@{ Problem = $problem; Saved = (Save-AiDnsSetting $settings -Explicit); Pinned = (Get-AiDnsSetting -Reload).PinnedProvider }
            }
            finally {
                $script:Paths.Settings = $original
                $null = Get-AiDnsSetting -Reload
            }
        }
        $result.Problem | Should -Not -BeNullOrEmpty
        $result.Saved | Should -BeTrue
        $result.Pinned | Should -Be 'comss'
        @(Get-ChildItem -LiteralPath $folder -Filter 'settings.broken-*.json').Count | Should -Be 1
    }

    It 'reports a failure inside the parser instead of throwing' {
        $result = InModuleScope AIDNS {
            Mock ConvertFrom-AiDnsSettingsDocument { throw 'parser failure' }
            Mock Read-JsonFile { [pscustomobject]@{ language = 'en' } }
            $settings = Get-AiDnsSetting -Reload
            [pscustomobject]@{ Language = $settings.Language; Problem = $script:SettingsProblem }
        }
        $result.Language | Should -Be 'Auto'
        $result.Problem | Should -Be 'parser failure'
        InModuleScope AIDNS { $null = Get-AiDnsSetting -Reload }
    }
}

Describe 'waitSeconds (W-010, W-013)' {
    It 'falls back to 20 for <Json>' -ForEach @(
        @{ Json = '{ "waitSeconds": 2147483648 }' }
        @{ Json = '{ "waitSeconds": 1e100 }' }
        @{ Json = '{ "waitSeconds": 5.4 }' }
        @{ Json = '{ "waitSeconds": "30" }' }
        @{ Json = '{ "waitSeconds": true }' }
        @{ Json = '{ "waitSeconds": 15 }' }
    ) {
        $wait = InModuleScope AIDNS -Parameters @{ Json = $Json } { (ConvertFrom-AiDnsSettingsDocument (ConvertFrom-Json $Json)).WaitSeconds }
        $wait | Should -Be 20
    }

    It 'accepts <Json>' -ForEach @(
        @{ Json = '{ "waitSeconds": 60 }'; Expected = 60 }
        @{ Json = '{ "waitSeconds": 5.0 }'; Expected = 5 }
        @{ Json = '{ "waitSeconds": 0 }'; Expected = 0 }
    ) {
        $wait = InModuleScope AIDNS -Parameters @{ Json = $Json } { (ConvertFrom-AiDnsSettingsDocument (ConvertFrom-Json $Json)).WaitSeconds }
        $wait | Should -Be $Expected
    }
}

Describe 'Update-AiDnsNrptRule (W-011)' {
    It 'touches no rule when NRPT is switched off' {
        $added = InModuleScope AIDNS {
            Mock Get-AiDnsNrptRule { @([pscustomobject]@{ Name = '{rule}'; Namespace = @('.chatgpt.com') }) }
            Mock Remove-AiDnsNrptRule { }
            Mock Add-AiDnsNrptRule { }
            $route = [pscustomobject]@{ Service = $script:BuiltInServices[0]; Namespaces = @('chatgpt.com'); Servers = @('203.0.114.1') }
            Update-AiDnsNrptRule -Routes @($route)
            Should -Invoke Remove-AiDnsNrptRule -Times 0 -Exactly
            Should -Invoke Add-AiDnsNrptRule -Times 0 -Exactly
        }
        @($added).Count | Should -Be 0
    }

    It 'replaces the AI-DNS rules when NRPT is on' {
        $added = InModuleScope AIDNS {
            Mock Get-AiDnsNrptRule { @([pscustomobject]@{ Name = '{rule}'; Namespace = @('.chatgpt.com') }) }
            Mock Remove-AiDnsNrptRule { }
            Mock Add-AiDnsNrptRule { }
            $route = [pscustomobject]@{ Service = $script:BuiltInServices[0]; Namespaces = @('chatgpt.com'); Servers = @('203.0.114.1') }
            Update-AiDnsNrptRule -Enabled -Routes @($route)
            Should -Invoke Remove-AiDnsNrptRule -Times 1 -Exactly
            Should -Invoke Add-AiDnsNrptRule -Times 1 -Exactly
        }
        @($added) | Should -Be @('chatgpt')
    }
}
