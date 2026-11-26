#Requires -Version 5.1
<#
.SYNOPSIS
    Records a manual test session of AI-DNS: every action, the network state before and after it,
    the differences, the AI-DNS trace logs and the tester's notes.

.DESCRIPTION
    Runs from a normal console. Each action starts AI-DNS.ps1 with -Trace; actions that change the
    system ask for administrator rights through the usual UAC prompt. Everything is written to
    tests\manual\sessions\<time>\, see TESTING.md.

.EXAMPLE
    .\tests\manual\Start-TestSession.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose 'Console encoding is fixed by the host.' }

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launcher = Join-Path $repo 'AI-DNS.ps1'
$session = Join-Path $PSScriptRoot ('sessions\{0:yyyyMMdd_HHmmss}' -f (Get-Date))
$null = New-Item -ItemType Directory -Path $session -Force
$journal = Join-Path $session 'journal.txt'
$null = Start-Transcript -LiteralPath (Join-Path $session 'transcript.txt')
$policyValues = @(
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'DnsOverHttpsMode'), @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'BuiltInDnsClientEnabled'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DnsOverHttpsMode'), @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'BuiltInDnsClientEnabled'),
    @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'DnsOverHttpsMode'), @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave', 'BuiltInDnsClientEnabled'),
    @('HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS', 'Enabled'), @('HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS', 'Locked')
)
$toolPattern = 'winws|goodbyedpi|ciadpi|byedpi|spoofdpi|zapret|openvpn|wireguard|amneziawg|v2ray|nekoray|hiddify|outline|happ|clash|sing-box|xray|warp|dnscrypt|adguard|yogadns|acrylic'

function Write-JournalLine {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text
    [IO.File]::AppendAllText($journal, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
}

function Get-SafeValue {
    param([Parameter(Mandatory)] [scriptblock] $Reader)
    try { return & $Reader } catch { return "<error: $($_.Exception.Message)>" }
}

function Get-NetworkSnapshot {
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $dataRoot = Join-Path $env:ProgramData 'AIDNS'
    [ordered]@{
        Time      = (Get-Date).ToString('o')
        Adapters  = Get-SafeValue {
            @(Get-NetAdapter | Sort-Object ifIndex | ForEach-Object {
                $guid = [string]$_.InterfaceGuid
                $binding = @(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape($_.Name)) -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue) | Select-Object -First 1
                [ordered]@{
                    Name        = $_.Name
                    Description = $_.InterfaceDescription
                    Guid        = $guid
                    Status      = [string]$_.Status
                    DnsV4       = @(Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
                    DnsV6       = @(Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
                    StaticV4    = [string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction SilentlyContinue).NameServer
                    StaticV6    = [string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction SilentlyContinue).NameServer
                    IPv6        = if ($null -ne $binding) { [bool]$binding.Enabled } else { $null }
                }
            })
        }
        Routes    = Get-SafeValue {
            @(Get-NetRoute -DestinationPrefix '0.0.0.0/0', '::/0' -ErrorAction SilentlyContinue |
                ForEach-Object { '{0} via {1} if {2} ({3}) metric {4}' -f $_.DestinationPrefix, $_.NextHop, $_.ifIndex, $_.InterfaceAlias, $_.RouteMetric })
        }
        Nrpt      = Get-SafeValue {
            @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | ForEach-Object {
                [ordered]@{ Name = $_.Name; Namespace = @($_.Namespace); NameServers = @($_.NameServers); Comment = $_.Comment }
            })
        }
        Doh       = Get-SafeValue {
            if ($null -eq (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) { return 'not supported' }
            @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue | ForEach-Object {
                [ordered]@{ Address = $_.ServerAddress; Template = $_.DohTemplate; Fallback = $_.AllowFallbackToUdp; AutoUpgrade = $_.AutoUpgrade }
            })
        }
        Policies  = @(foreach ($pair in $policyValues) {
            $item = Get-ItemProperty -LiteralPath $pair[0] -Name $pair[1] -ErrorAction SilentlyContinue
            [ordered]@{ Path = "$($pair[0])\$($pair[1])"; Value = if ($null -ne $item) { [string]$item.($pair[1]) } else { '<none>' } }
        })
        Hosts     = Get-SafeValue {
            [ordered]@{
                Sha256 = (Get-FileHash -LiteralPath $hostsPath -Algorithm SHA256).Hash
                Lines  = @([IO.File]::ReadAllLines($hostsPath) | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') -or $_.StartsWith('# AIDNS') })
            }
        }
        DataDir   = Get-SafeValue {
            if (-not (Test-Path -LiteralPath $dataRoot)) { return 'absent' }
            @(Get-ChildItem -LiteralPath $dataRoot -Recurse -Force | ForEach-Object { '{0} {1}' -f $_.FullName.Substring($dataRoot.Length), $_.Length })
        }
        Backup    = Get-SafeValue { $path = Join-Path $dataRoot 'backup.json'; if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { 'absent' } }
        State     = Get-SafeValue { $path = Join-Path $dataRoot 'state.json'; if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { 'absent' } }
        Settings  = Get-SafeValue { $path = Join-Path $repo 'settings.json'; if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { 'absent' } }
        Processes = Get-SafeValue { @(Get-Process | Where-Object { $_.ProcessName -match $toolPattern } | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) }
        Services  = Get-SafeValue {
            @(Get-Service | Where-Object { $_.Name -match 'zapret|winws|goodbye|windivert|warp|adguard|dnscrypt' } | ForEach-Object { '{0} {1}' -f $_.Name, $_.Status })
        }
    }
}

function Save-Snapshot {
    param([Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)] [string] $Path)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Snapshot -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Write-SnapshotDiff {
    param([Parameter(Mandatory)] $Before, [Parameter(Mandatory)] $After, [Parameter(Mandatory)] [string] $Path)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($section in @($Before.Keys | Where-Object { $_ -ne 'Time' })) {
        $old = @((ConvertTo-Json -InputObject $Before[$section] -Depth 6) -split "`r?`n")
        $new = @((ConvertTo-Json -InputObject $After[$section] -Depth 6) -split "`r?`n")
        $changes = @(Compare-Object -ReferenceObject $old -DifferenceObject $new)
        if ($changes.Count -eq 0) { continue }
        $lines.Add("== $section")
        foreach ($change in $changes) { $lines.Add(('{0} {1}' -f $(if ($change.SideIndicator -eq '<=') { '-' } else { '+' }), $change.InputObject.Trim())) }
    }
    if ($lines.Count -eq 0) { $lines.Add('No differences.') }
    [IO.File]::WriteAllLines($Path, $lines.ToArray(), [Text.UTF8Encoding]::new($false))
    return $lines.Count
}

function Read-TesterNote {
    param([Parameter(Mandatory)] [string] $Prompt)
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host '  > ' -NoNewline -ForegroundColor Cyan
    $text = [Console]::ReadLine()
    if ($null -eq $text) { return '' }
    return $text.Trim()
}

$actions = [ordered]@{
    '1' = @{ Label = 'Enable';                         Arguments = @('-Action', 'Enable') }
    '2' = @{ Label = 'Status';                         Arguments = @('-Action', 'Status') }
    '3' = @{ Label = 'Disable';                        Arguments = @('-Action', 'Disable') }
    '4' = @{ Label = 'Update';                         Arguments = @('-Action', 'Update') }
    '5' = @{ Label = 'Enable -TestOnly';               Arguments = @('-Action', 'Enable', '-TestOnly') }
    '6' = @{ Label = 'Enable -DryRun';                 Arguments = @('-Action', 'Enable', '-DryRun') }
    '7' = @{ Label = 'Disable -DryRun';                Arguments = @('-Action', 'Disable', '-DryRun') }
    '8' = @{ Label = 'Settings';                       Arguments = @('-Action', 'Settings') }
}

Write-JournalLine "Session started. Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion), repository $repo"
$commit = & git -C $repo log -1 --format='%h %s'
$dirty = @(& git -C $repo status --porcelain).Count -gt 0
Write-JournalLine "Git: $commit$(if ($dirty) { ' (uncommitted changes)' })"
Save-Snapshot (Get-NetworkSnapshot) (Join-Path $session '00-initial.json')
$note = Read-TesterNote 'Опишите обстановку перед тестом (VPN, zapret, какая сеть):'
Write-JournalLine "Tester: $note"

$step = 0
while ($true) {
    Write-Host ''
    Write-Host '  AI-DNS: тестовая сессия' -ForegroundColor DarkCyan
    Write-Host "  $session" -ForegroundColor DarkGray
    foreach ($key in $actions.Keys) { Write-Host ('  {0}  {1}' -f $key, $actions[$key].Label) }
    Write-Host '  N  Заметка'
    Write-Host '  0  Завершить'
    $choice = (Read-TesterNote 'Выбор:').ToUpperInvariant()
    if ($choice -eq '0') { break }
    if ($choice -eq 'N') {
        Write-JournalLine "Tester: $(Read-TesterNote 'Заметка:')"
        continue
    }
    if (-not $actions.Contains($choice)) { continue }

    $step++
    $action = $actions[$choice]
    $folder = Join-Path $session ('{0:D2}-{1}' -f $step, ($action.Label -replace '[^A-Za-z]+', '-'))
    $null = New-Item -ItemType Directory -Path (Join-Path $folder 'logs') -Force
    $before = Get-NetworkSnapshot
    Save-Snapshot $before (Join-Path $folder 'before.json')
    Write-JournalLine "Step $step started: $($action.Label)"

    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher) + $action.Arguments
    if ($action.Label -ne 'Settings') { $arguments += @('-Trace', '-LogDirectory', (Join-Path $folder 'logs')) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSHOME 'powershell.exe') @arguments
    $code = $LASTEXITCODE
    Write-JournalLine ('Step {0} finished: exit code {1} after {2:N1} s' -f $step, $code, $clock.Elapsed.TotalSeconds)

    $after = Get-NetworkSnapshot
    Save-Snapshot $after (Join-Path $folder 'after.json')
    $diffLines = Write-SnapshotDiff $before $after (Join-Path $folder 'diff.txt')
    Write-JournalLine "Step $step differences: $diffLines lines, see $(Split-Path -Leaf $folder)\diff.txt"
    Write-Host ''
    Write-Host "  Код завершения $code. Различия: $(Join-Path $folder 'diff.txt')" -ForegroundColor Green
    Write-JournalLine "Tester: $(Read-TesterNote 'Что вы увидели? Открываются ли сервисы в браузере? (Enter: пропустить)')"
}

Save-Snapshot (Get-NetworkSnapshot) (Join-Path $session '99-final.json')
Write-JournalLine 'Session finished.'
$null = Stop-Transcript
Write-Host ''
Write-Host "  Сессия сохранена: $session" -ForegroundColor Green
