BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest
}

Describe 'Test-PublicIPv4' {
    It 'accepts <Address>' -ForEach @(
        @{ Address = '83.220.169.155' }
        @{ Address = '1.1.1.1' }
        @{ Address = '223.255.255.254' }
    ) {
        InModuleScope AIDNS -Parameters @{ Address = $Address } { Test-PublicIPv4 $Address } | Should -BeTrue
    }

    It 'rejects <Address>' -ForEach @(
        @{ Address = '' }
        @{ Address = '1' }
        @{ Address = '01.2.3.4' }
        @{ Address = '256.1.1.1' }
        @{ Address = '10.0.0.1' }
        @{ Address = '100.64.0.1' }
        @{ Address = '127.0.0.1' }
        @{ Address = '169.254.1.1' }
        @{ Address = '172.16.0.1' }
        @{ Address = '172.31.255.255' }
        @{ Address = '192.168.1.1' }
        @{ Address = '192.0.2.1' }
        @{ Address = '198.18.0.1' }
        @{ Address = '203.0.113.5' }
        @{ Address = '224.0.0.1' }
        @{ Address = '0.0.0.0' }
        @{ Address = '1.2.3.4 ' }
    ) {
        InModuleScope AIDNS -Parameters @{ Address = $Address } { Test-PublicIPv4 $Address } | Should -BeFalse
    }
}

Describe 'ConvertTo-SafeText' {
    It 'removes control and bidirectional characters and truncates' {
        $text = "Evil$([char]0x1B)[31m$([char]0x202E)Name   with  spaces and a long tail"
        InModuleScope AIDNS -Parameters @{ Text = $text } { ConvertTo-SafeText $Text 20 } | Should -Be 'Evil[31mName with sp'
    }
}

Describe 'ConvertTo-ProcessArgument' {
    It 'quotes <Value>' -ForEach @(
        @{ Value = 'plain'; Expected = '"plain"' }
        @{ Value = 'C:\Program Files\x\'; Expected = '"C:\Program Files\x\\"' }
        @{ Value = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Value = 'a\"b'; Expected = '"a\\\"b"' }
    ) {
        InModuleScope AIDNS -Parameters @{ Value = $Value } { ConvertTo-ProcessArgument $Value } | Should -Be $Expected
    }
}

Describe 'Get-Median' {
    It 'ignores missing values' {
        InModuleScope AIDNS { Get-Median @(30, $null, 10, 20) } | Should -Be 20
    }

    It 'returns null when nothing was measured' {
        InModuleScope AIDNS { Get-Median @($null) } | Should -BeNullOrEmpty
    }
}

Describe 'JSON files' {
    It 'round-trips through Write-JsonFile and Read-JsonFile, replacing an existing file' {
        $path = Join-Path $TestDrive 'state.json'
        InModuleScope AIDNS -Parameters @{ Path = $path } {
            Write-JsonFile $Path ([pscustomobject]@{ Servers = @('1.2.3.4') })
            Write-JsonFile $Path ([pscustomobject]@{ Servers = @('5.6.7.8', '9.9.9.9') })
            (Read-JsonFile $Path).Servers -join ','
        } | Should -Be '5.6.7.8,9.9.9.9'
        Test-Path "$path.tmp" | Should -BeFalse
    }

    It 'returns null for a missing file' {
        InModuleScope AIDNS -Parameters @{ Path = (Join-Path $TestDrive 'missing.json') } { Read-JsonFile $Path } | Should -BeNullOrEmpty
    }
}

Describe 'Remove-TreeSafely' {
    It 'deletes a directory tree and reports no failures' {
        $root = Join-Path $TestDrive 'tree'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'a\b') -Force
        Set-Content -LiteralPath (Join-Path $root 'a\b\file.txt') -Value 'x'
        InModuleScope AIDNS -Parameters @{ Path = $root } { Remove-TreeSafely $Path } | Should -Be 0
        Test-Path $root | Should -BeFalse
    }

    It 'removes a junction without deleting its target' {
        $target = Join-Path $TestDrive 'target'
        $null = New-Item -ItemType Directory -Path $target -Force
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'x'
        $link = Join-Path $TestDrive 'link'
        $null = New-Item -ItemType Junction -Path $link -Target $target
        InModuleScope AIDNS -Parameters @{ Path = $link } { Remove-TreeSafely $Path } | Should -Be 0
        Test-Path $link | Should -BeFalse
        Test-Path (Join-Path $target 'keep.txt') | Should -BeTrue
    }
}

Describe 'Test-DataDirectoryAcl' {
    It 'rejects an ACL that lets Users write' {
        InModuleScope AIDNS {
            $security = New-DataDirectoryAcl
            $rule = [Security.AccessControl.FileSystemAccessRule]::new((Get-WellKnownSid Users), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $security.AddAccessRule($rule)
            Test-DataDirectoryAcl $security
        } | Should -BeFalse
    }

    It 'accepts the ACL it creates' {
        InModuleScope AIDNS { Test-DataDirectoryAcl (New-DataDirectoryAcl) } | Should -BeTrue
    }
}

Describe 'Get-Text' {
    It 'formats arguments and falls back to the key' {
        InModuleScope AIDNS {
            (Get-Text 'Verdict.Region' @('DE')), (Get-Text 'No.Such.Key')
        } | Should -Be @('region DE', 'No.Such.Key')
    }
}
