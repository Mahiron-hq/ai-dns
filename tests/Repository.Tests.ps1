BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:En = Import-PowerShellDataFile (Join-Path $script:SourceRoot 'en-US\AIDNS.Strings.psd1')
    $script:Ru = Import-PowerShellDataFile (Join-Path $script:SourceRoot 'ru-RU\AIDNS.Strings.psd1')
    $script:Files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\(\.git|logs)\\' })

    function Get-PlaceholderSet([string] $Text) {
        (@([regex]::Matches($Text, '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) -join ','
    }
}

Describe 'String tables' {
    It 'have the same keys in every language' {
        $missing = @($script:En.Keys | Where-Object { -not $script:Ru.ContainsKey($_) }) +
                   @($script:Ru.Keys | Where-Object { -not $script:En.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty
    }

    It 'use the same placeholders in every language' {
        $mismatched = @($script:En.Keys | Where-Object { $script:Ru.ContainsKey($_) -and (Get-PlaceholderSet $script:En[$_]) -ne (Get-PlaceholderSet $script:Ru[$_]) })
        $mismatched | Should -BeNullOrEmpty
    }

    It 'cover every key used in the code' {
        $code = (Get-ChildItem (Join-Path $script:SourceRoot 'Private') -Filter '*.ps1' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        $used = @([regex]::Matches($code, "(?:Write-(?:Step|Ok|Warn|Fail|Note|Detail)Line|Get-Text)\s+'([A-Za-z0-9.-]+)'") |
            ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches($code, "New-Verdict \`$(?:true|false) '([A-Za-z]+)'") | ForEach-Object { "Verdict.$($_.Groups[1].Value)" })
        $enum = [regex]::Match([IO.File]::ReadAllText((Join-Path $script:SourceRoot 'Probe.cs')), 'enum ProbeError\s*\{([^}]*)\}').Groups[1].Value
        $used += @($enum -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { "ProbeError.$_" })
        @($used | Sort-Object -Unique | Where-Object { -not $script:En.ContainsKey($_) }) | Should -BeNullOrEmpty
    }
}

Describe 'File encodings and line endings' {
    It '<Name> is ASCII with CRLF line endings' -ForEach @(
        Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) -Recurse -Filter '*.bat' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        ($text -replace "`r`n", '') | Should -Not -Match "`n"
    }

    It 'PowerShell files with non-ASCII text start with a UTF-8 BOM' {
        $offenders = @($script:Files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | Where-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            -not $hasBom -and @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
        } | ForEach-Object { $_.Name })
        $offenders | Should -BeNullOrEmpty
    }

    It 'Markdown uses en dashes and hyphens only' {
        $offenders = @($script:Files | Where-Object { $_.Extension -eq '.md' } |
            Where-Object { [IO.File]::ReadAllText($_.FullName).Contains([string][char]0x2014) } | ForEach-Object { $_.Name })
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Module manifest' {
    It 'is valid and exports only the public entry points' {
        $manifest = Test-ModuleManifest (Join-Path $script:SourceRoot 'AIDNS.psd1')
        @($manifest.ExportedFunctions.Keys | Sort-Object) -join ',' |
            Should -Be 'Invoke-AiDns,Invoke-AiDnsVersionCheck,Request-AiDnsElevation,Start-AiDnsSettingsMenu,Test-AiDnsElevation,Wait-AiDnsExit'
    }
}

Describe 'Launchers' {
    It '<Name> starts AI-DNS.ps1 with -Action <Action>' -ForEach @(
        @{ Name = 'AI-DNS-Enable.bat'; Action = 'Enable' }
        @{ Name = 'AI-DNS-Disable.bat'; Action = 'Disable' }
        @{ Name = 'AI-DNS-Update.bat'; Action = 'Update' }
        @{ Name = 'AI-DNS-Settings.bat'; Action = 'Settings' }
    ) {
        $text = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) $Name))
        $text | Should -Match ([regex]::Escape('-File "%~dp0AI-DNS.ps1" -Action ' + $Action + ' %*'))
    }
}

Describe 'Provider catalog schema' {
    It 'validates against providers.schema.json' -Skip:($null -eq (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        $json = [IO.File]::ReadAllText((Join-Path $script:SourceRoot 'providers.json'))
        $schema = [IO.File]::ReadAllText((Join-Path $script:SourceRoot 'providers.schema.json'))
        Test-Json -Json $json -Schema $schema | Should -BeTrue
    }
}
