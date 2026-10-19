BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-AiDnsForTest

    function ConvertTo-DnsName([string] $Name) {
        $bytes = [Collections.Generic.List[byte]]::new()
        foreach ($label in $Name.Split('.')) {
            $bytes.Add([byte]$label.Length)
            $bytes.AddRange([Text.Encoding]::ASCII.GetBytes($label))
        }
        $bytes.Add(0)
        return , $bytes.ToArray()
    }

    # Builds a response to an A query for $Name with the given answer addresses, using name compression.
    function New-DnsResponse([int] $Id, [string] $Name, [string[]] $Answers = @(), [int] $RCode = 0) {
        $packet = [Collections.Generic.List[byte]]::new()
        $packet.AddRange([byte[]]@((($Id -shr 8) -band 0xFF), ($Id -band 0xFF), 0x81, (0x80 -bor $RCode), 0, 1, 0, $Answers.Count, 0, 0, 0, 0))
        $packet.AddRange((ConvertTo-DnsName $Name))
        $packet.AddRange([byte[]]@(0, 1, 0, 1))
        foreach ($answer in $Answers) {
            $packet.AddRange([byte[]]@(0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4))
            $packet.AddRange([byte[]]($answer.Split('.') | ForEach-Object { [byte]$_ }))
        }
        return , $packet.ToArray()
    }
}

Describe 'DnsWire.BuildQuery' {
    It 'encodes a recursive A/IN query' {
        $query = [AiDns.DnsWire]::BuildQuery('chatgpt.com', 0x1234)
        $expected = [byte[]]@(0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0) + (ConvertTo-DnsName 'chatgpt.com') + [byte[]]@(0, 1, 0, 1)
        $query | Should -Be $expected
    }

    It 'ignores a trailing dot' {
        [AiDns.DnsWire]::BuildQuery('ya.ru.', 1) | Should -Be ([AiDns.DnsWire]::BuildQuery('ya.ru', 1))
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an empty name'; Name = '' }
        @{ Case = 'an empty label'; Name = 'a..b' }
        @{ Case = 'a label over 63 bytes'; Name = ('a' * 64) + '.com' }
        @{ Case = 'non-ASCII text'; Name = "caf$([char]0xE9).com" }
    ) {
        { [AiDns.DnsWire]::BuildQuery($Name, 1) } | Should -Throw
    }
}

Describe 'DnsWire.Parse and Classify' {
    It 'reads id, question and A records through compression pointers' {
        $packet = New-DnsResponse -Id 0xBEEF -Name 'claude.ai' -Answers @('1.2.3.4', '5.6.7.8')
        $response = [AiDns.DnsWire]::Parse($packet, 0, $packet.Length)
        $response.Id | Should -Be 0xBEEF
        $response.QuestionName | Should -Be 'claude.ai'
        ($response.Addresses -join ',') | Should -Be '1.2.3.4,5.6.7.8'
    }

    It 'classifies <Case>' -ForEach @(
        @{ Case = 'a normal answer'; Answers = @('0.0.0.0', '9.9.9.9'); RCode = 0; Expected = 'None'; Usable = @('9.9.9.9') }
        @{ Case = 'a blackhole'; Answers = @('0.0.0.0', '127.0.0.1'); RCode = 0; Expected = 'Blackholed'; Usable = @() }
        @{ Case = 'NXDOMAIN'; Answers = @(); RCode = 3; Expected = 'ServerFailure'; Usable = @() }
        @{ Case = 'an empty answer'; Answers = @(); RCode = 0; Expected = 'EmptyAnswer'; Usable = @() }
    ) {
        $packet = New-DnsResponse -Id 7 -Name 'chatgpt.com' -Answers $Answers -RCode $RCode
        $actual = $null
        $result = [AiDns.DnsWire]::Classify([AiDns.DnsWire]::Parse($packet, 0, $packet.Length), [ref]$actual)
        $result | Should -Be $Expected
        ($actual -join ',') | Should -Be ($Usable -join ',')
    }

    It 'returns null for a packet shorter than the header' {
        $bytes = [byte[]]@(1, 2, 3)
        [AiDns.DnsWire]::Parse($bytes, 0, $bytes.Length) | Should -BeNullOrEmpty
    }

    It 'returns null for a query instead of a response' {
        $bytes = [AiDns.DnsWire]::BuildQuery('ya.ru', 1)
        [AiDns.DnsWire]::Parse($bytes, 0, $bytes.Length) | Should -BeNullOrEmpty
    }

    It 'stops on a compression pointer loop instead of hanging' {
        $packet = [Collections.Generic.List[byte]]::new()
        $packet.AddRange((New-DnsResponse -Id 1 -Name 'ya.ru'))
        $packet[7] = 1
        $loopAt = $packet.Count
        $packet.AddRange([byte[]]@(0xC0, $loopAt))
        $bytes = $packet.ToArray()
        $response = [AiDns.DnsWire]::Parse($bytes, 0, $bytes.Length)
        $response.QuestionName | Should -Be 'ya.ru'
        $response.Addresses.Count | Should -Be 0
    }
}

Describe 'DnsBatch.Run' {
    It 'returns immediately for an empty batch' {
        { [AiDns.DnsBatch]::Run([AiDns.DnsQuery[]]@(), 100, 1) } | Should -Not -Throw
    }

    It 'rejects a query without an IPv4 server' {
        $query = [AiDns.DnsQuery]::new()
        $query.Server = 'not-an-ip'
        $query.Name = 'ya.ru'
        { [AiDns.DnsBatch]::Run([AiDns.DnsQuery[]]@($query), 100, 1) } | Should -Throw
    }
}
