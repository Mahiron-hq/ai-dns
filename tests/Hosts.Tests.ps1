BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest
    $script:Marker = '# AIDNS-disabled: '
    $script:Original = [string[]]@(
        '127.0.0.1 localhost'
        '1.2.3.4 chatgpt.com'
        '# 1.2.3.4 claude.ai'
        '5.6.7.8 notchatgpt.com'
        "9.9.9.9`tapi.openai.com # pinned"
        '4.4.4.4 example.org Gemini.Google.com.'
        ''
    )
}

Describe 'Test-ManagedHostsLine' {
    It 'matches <Line>: <Expected>' -ForEach @(
        @{ Line = '1.2.3.4 chatgpt.com'; Expected = $true }
        @{ Line = '1.2.3.4 cdn.oaistatic.com'; Expected = $true }
        @{ Line = '1.2.3.4 notchatgpt.com'; Expected = $false }
        @{ Line = '1.2.3.4'; Expected = $false }
        @{ Line = '# 1.2.3.4 chatgpt.com'; Expected = $false }
        @{ Line = ''; Expected = $false }
    ) {
        InModuleScope AIDNS -Parameters @{ Line = $Line } { Test-ManagedHostsLine $Line (Get-ManagedDomain) } | Should -Be $Expected
    }
}

Describe 'Edit-HostsContent' {
    It 'comments out only active managed entries' {
        $edit = InModuleScope AIDNS -Parameters @{ Lines = $script:Original; Marker = $script:Marker } {
            Edit-HostsContent -Lines $Lines -Mode Disable -Marker $Marker -Domains (Get-ManagedDomain)
        }
        $edit.Changed | Should -Be 3
        $edit.Lines[1] | Should -Be ($script:Marker + '1.2.3.4 chatgpt.com')
        $edit.Lines[2] | Should -Be '# 1.2.3.4 claude.ai'
        $edit.Lines[3] | Should -Be '5.6.7.8 notchatgpt.com'
        $edit.Lines[4] | Should -Be ($script:Marker + "9.9.9.9`tapi.openai.com # pinned")
        $edit.Lines[5] | Should -BeLike "$script:Marker*"
    }

    It 'restores exactly what it disabled and is idempotent' {
        $restored = InModuleScope AIDNS -Parameters @{ Lines = $script:Original; Marker = $script:Marker } {
            $disabled = Edit-HostsContent -Lines $Lines -Mode Disable -Marker $Marker -Domains (Get-ManagedDomain)
            $again = Edit-HostsContent -Lines $disabled.Lines -Mode Disable -Marker $Marker -Domains (Get-ManagedDomain)
            if ($again.Changed -ne 0) { throw 'second disable changed lines' }
            (Edit-HostsContent -Lines $disabled.Lines -Mode Restore -Marker $Marker).Lines
        }
        ($restored -join "`n") | Should -Be ($script:Original -join "`n")
    }

    It 'deletes disabled entries in Delete mode' {
        $result = InModuleScope AIDNS -Parameters @{ Lines = $script:Original; Marker = $script:Marker } {
            $disabled = Edit-HostsContent -Lines $Lines -Mode Disable -Marker $Marker -Domains (Get-ManagedDomain)
            Edit-HostsContent -Lines $disabled.Lines -Mode Delete -Marker $Marker
        }
        $result.Changed | Should -Be 3
        $result.Lines.Count | Should -Be ($script:Original.Count - 3)
    }
}

Describe 'Read-HostsFile and Write-HostsFile' {
    It 'preserves the bytes of a <Case> file' -ForEach @(
        @{ Case = 'CRLF without a trailing newline'; Bytes = [Text.Encoding]::ASCII.GetBytes("a`r`nb") }
        @{ Case = 'LF with a trailing newline'; Bytes = [Text.Encoding]::ASCII.GetBytes("a`nb`n") }
        @{ Case = 'UTF-8 with BOM'; Bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("# $([char]0x442)`r`n1.1.1.1 x`r`n") }
        @{ Case = 'legacy ANSI'; Bytes = [byte[]]@(0x23, 0x20, 0xFF, 0xE9, 0x0D, 0x0A) }
        @{ Case = 'empty'; Bytes = [byte[]]@() }
    ) {
        $path = Join-Path $TestDrive 'hosts'
        [IO.File]::WriteAllBytes($path, [byte[]]$Bytes)
        InModuleScope AIDNS -Parameters @{ Path = $path } {
            $file = Read-HostsFile $Path
            Write-HostsFile $Path $file $file.Lines
        }
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -Be ([Convert]::ToBase64String([byte[]]$Bytes))
    }
}
