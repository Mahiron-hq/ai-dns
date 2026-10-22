# Public entry points: the action dispatcher, elevation and the end-of-run pause.

function Show-AiDnsBanner {
    param([Parameter(Mandatory)] [string] $Action)

    $title = 'AI-DNS {0} {1} {2}' -f $script:ModuleVersion, [char]0x00B7, (Get-Text "Banner.$Action")
    $width = $title.Length + 6
    $edge = [string][char]0x2550 * $width
    Write-RawLine ''
    Write-RawLine ('  {0}{1}{2}' -f [char]0x2554, $edge, [char]0x2557) DarkCyan
    Write-RawLine ('  {0}   {1}   {2}' -f [char]0x2551, $title, [char]0x2551) DarkCyan
    Write-RawLine ('  {0}{1}{2}' -f [char]0x255A, $edge, [char]0x255D) DarkCyan
}

<#
.SYNOPSIS
    Runs the update action: a complete rollback, removal of every cached artefact, then a fresh enable
    with all provider lists downloaded again.
#>
function Invoke-AiDnsUpdate {
    param([switch] $Full, [switch] $EnableIPv6, [switch] $Offline)

    Write-StepLine 'Step.UpdateRollback'
    $rollback = Invoke-AiDnsDisable -Full:$Full -EnableIPv6:$EnableIPv6 -KeepLogs
    if ($rollback.ExitCode -ne 0) { Write-WarnLine 'Update.RollbackIssues' }

    Write-StepLine 'Step.UpdateCache'
    Clear-AiDnsCache
    Write-OkLine 'Update.CacheCleared'

    Write-StepLine 'Step.UpdateEnable'
    $script:Run.Errors = 0
    $code = Invoke-AiDnsEnable -Refresh -Offline:$Offline
    if ($code -eq 0 -and $rollback.ExitCode -ne 0) { return 3 }
    return $code
}

<#
.SYNOPSIS
    Tests whether the current process runs with administrator rights.
#>
function Test-AiDnsElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Quotes one argument for the Windows command-line parser, including backslashes before quotes.
function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

<#
.SYNOPSIS
    Restarts the given script elevated through the UAC prompt and waits for it.
.PARAMETER ScriptPath
    The script to run elevated.
.PARAMETER Parameters
    The caller's bound parameters, forwarded unchanged.
.PARAMETER Language
    UI language for the message shown when elevation is refused.
.OUTPUTS
    System.Int32. The elevated process's exit code, or 1223 when elevation was cancelled.
#>
function Request-AiDnsElevation {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [Collections.IDictionary] $Parameters,
        [ValidateSet('Auto', 'en', 'ru')] [string] $Language = 'Auto'
    )

    Import-AiDnsStringTable (Resolve-AiDnsLanguage $Language)
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($item in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-ProcessArgument $ScriptPath))) {
        $arguments.Add($item)
    }
    foreach ($entry in $Parameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $arguments.Add("-$($entry.Key)") }
            continue
        }
        $arguments.Add("-$($entry.Key)")
        $arguments.Add((ConvertTo-ProcessArgument ([string]$entry.Value)))
    }

    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments.ToArray() `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return $process.ExitCode
    }
    catch [InvalidOperationException] {
        Write-Host ('  [x] ' + (Get-Text 'Elevation.Cancelled')) -ForegroundColor Red
        Wait-AiDnsExit -ExitCode 1223
        return 1223
    }
    catch {
        Write-Host ('  [x] ' + (Get-Text 'Error.Unexpected' @($_.Exception.Message))) -ForegroundColor Red
        Wait-AiDnsExit -ExitCode 1
        return 1
    }
}

<#
.SYNOPSIS
    Keeps the console window open so the result can be read: for the configured time after success
    (20 seconds by default), two minutes after a failure, or until a key is pressed. Does nothing
    without an interactive console.
#>
function Wait-AiDnsExit {
    param([Parameter(Mandatory)] [int] $ExitCode)

    $seconds = if ($ExitCode -eq 0) { (Get-AiDnsSetting).WaitSeconds } else { 120 }
    if ($seconds -le 0) { return }
    try {
        if ([Console]::IsInputRedirected) { return }
        while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
    }
    catch { return }

    Write-Host ''
    for ($left = $seconds; $left -gt 0; $left--) {
        Write-Host -NoNewline ("`r" + (Get-Text 'Exit.Countdown' @($left)) + '    ') -ForegroundColor DarkGray
        for ($tick = 0; $tick -lt 10; $tick++) {
            if ([Console]::KeyAvailable) {
                $null = [Console]::ReadKey($true)
                Write-Host ''
                return
            }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
}

function Write-RunHeader {
    param([Parameter(Mandatory)] [Collections.IDictionary] $Parameters)

    $os = [Environment]::OSVersion.Version
    $options = @($Parameters.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-LogRecord 'INFO' "AI-DNS $script:ModuleVersion, Windows $os, PowerShell $($PSVersionTable.PSVersion), .NET $([Environment]::Version), UI $([Globalization.CultureInfo]::CurrentUICulture.Name)"
    Write-LogRecord 'INFO' "Options: $options"
    $modes = @($script:Services | ForEach-Object { "$($_.Id)=$($_.Mode)" }) -join ' '
    Write-LogRecord 'INFO' "Services: $modes"
    if ($null -ne $script:Run.LogFile) { Write-NoteLine 'Log.Path' $script:Run.LogFile }
    if ($null -ne $script:SettingsProblem) { Write-WarnLine 'Settings.Damaged' $script:Paths.Settings $script:SettingsProblem }
    if ($script:Run.DryRun) { Write-WarnLine 'DryRun.Active' }
}

<#
.SYNOPSIS
    Runs an AI-DNS action. Every action except Status requires administrator rights.
.DESCRIPTION
    Switches set to on in settings.json are added to the ones given here, for the actions that accept them.
.PARAMETER Action
    Enable  find the best smart DNS and apply it.
    Disable roll everything back to the state saved before the first enable.
    Update  Disable, clear every cache, then Enable with freshly downloaded provider lists.
    Status  show what is configured now and check every service through the system resolver.
.PARAMETER TestOnly
    Enable only: rank the resolvers and stop without changing anything.
.PARAMETER DryRun
    Perform every check but only log the changes instead of making them.
.PARAMETER Trace
    Log every probe and every change with its before and after state.
.PARAMETER Full
    Disable and Update: reset all adapters to DHCP, delete the commented-out hosts entries and
    remove the data directory even after errors.
.PARAMETER ResetNetwork
    Disable only: also reset Winsock and TCP/IP (a restart is required).
.PARAMETER EnableIPv6
    Disable and Update: enable IPv6 on every adapter, not only where AI-DNS disabled it.
.PARAMETER Offline
    Enable and Update: do not download provider lists; use the bundled list and the cache.
.PARAMETER Language
    Console language: Auto (the settings, then the Windows UI language), en or ru.
.PARAMETER LogDirectory
    Where to write the log. Defaults to the settings, then %ProgramData%\AIDNS\logs; a chosen
    directory is never removed.
.OUTPUTS
    System.Int32 exit code: 0 success, 1 failure, 2 no working resolver found, 3 finished with problems.
#>
function Invoke-AiDns {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'DNS is an acronym, not a plural.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Enable', 'Disable', 'Update', 'Status')] [string] $Action,
        [switch] $TestOnly,
        [switch] $DryRun,
        [switch] $Trace,
        [switch] $Full,
        [switch] $ResetNetwork,
        [switch] $EnableIPv6,
        [switch] $Offline,
        [ValidateSet('Auto', 'en', 'ru')] [string] $Language = 'Auto',
        [string] $LogDirectory
    )

    $settings = Get-AiDnsSetting -Reload
    Import-AiDnsStringTable (Resolve-AiDnsLanguage $Language)
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose 'Console encoding is fixed by the host.' }
    Use-AiDnsSetting $settings

    $optionError = $null
    if ($TestOnly -and $Action -ne 'Enable') { $optionError = Get-Text 'Error.OptionAction' @('-TestOnly', 'Enable') }
    elseif ($ResetNetwork -and $Action -ne 'Disable') { $optionError = Get-Text 'Error.OptionAction' @('-ResetNetwork', 'Disable') }
    $TestOnly = $TestOnly -or (Test-SettingFlag $settings 'TestOnly' $Action)
    $DryRun = $DryRun -or (Test-SettingFlag $settings 'DryRun' $Action)
    $Trace = $Trace -or (Test-SettingFlag $settings 'Trace' $Action)
    $Full = $Full -or (Test-SettingFlag $settings 'Full' $Action)
    $ResetNetwork = $ResetNetwork -or (Test-SettingFlag $settings 'ResetNetwork' $Action)
    $EnableIPv6 = $EnableIPv6 -or (Test-SettingFlag $settings 'EnableIPv6' $Action)
    $Offline = $Offline -or (Test-SettingFlag $settings 'Offline' $Action)
    $effective = [ordered]@{
        Action = $Action; TestOnly = $TestOnly; DryRun = $DryRun; Trace = $Trace; Full = $Full; ResetNetwork = $ResetNetwork
        EnableIPv6 = $EnableIPv6; Offline = $Offline; Language = $Language
    }

    if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Resolve-SettingsLogDirectory $settings }
    $explicitLog = -not [string]::IsNullOrWhiteSpace($LogDirectory)
    if (-not $explicitLog) { $LogDirectory = $script:Paths.Logs }
    $effective.LogDirectory = $LogDirectory
    Initialize-AiDnsRun -Action $Action -LogDirectory $LogDirectory -Trace:$Trace -DryRun:$DryRun

    $exitCode = 1
    try {
        if ($Action -ne 'Status' -and -not (Test-AiDnsElevation)) { throw (Get-Text 'Error.NotElevated') }
        if ($null -ne $optionError) { throw $optionError }

        # Status runs without elevation and so cannot secure the data directory; it logs only where asked to.
        if ($Action -ne 'Status') {
            Initialize-DataDirectory
            Open-AiDnsLog
        }
        elseif ($explicitLog) { Open-AiDnsLog }
        Show-AiDnsBanner $Action
        Write-RunHeader $effective

        # Logs inside the data directory survive its removal only when the run was asked to keep a log.
        $logsInData = $script:Run.LogDirectory.StartsWith($script:Paths.Root, [StringComparison]::OrdinalIgnoreCase)
        $keepLogs = $logsInData -and ($Trace -or $explicitLog)
        $output = @(switch ($Action) {
            'Enable'  { Invoke-AiDnsEnable -TestOnly:$TestOnly -Offline:$Offline }
            'Disable' { (Invoke-AiDnsDisable -Full:$Full -ResetNetwork:$ResetNetwork -EnableIPv6:$EnableIPv6 -KeepLogs:$keepLogs).ExitCode }
            'Update'  { Invoke-AiDnsUpdate -Full:$Full -EnableIPv6:$EnableIPv6 -Offline:$Offline }
            'Status'  { Invoke-AiDnsStatus }
        })
        # The exit code is the last value; anything before it is output that leaked from a helper.
        if ($output.Count -gt 1) { Write-LogRecord 'WARN' "Unexpected pipeline output: $(Format-StateValue $output[0..($output.Count - 2)])" }
        $exitCode = [int]$output[-1]
    }
    catch {
        Write-FailLine 'Error.Unexpected' $_.Exception.Message
        Write-LogRecord 'ERROR' $_.ScriptStackTrace
        $exitCode = 1
    }
    finally {
        Write-LogRecord 'INFO' "Exit code $exitCode after $($script:Run.Clock.Elapsed.TotalSeconds) s"
        if ($exitCode -ne 0 -and $null -ne $script:Run.LogFile -and $null -ne $script:Run.Writer) {
            Write-NoteLine 'Log.Path' $script:Run.LogFile
        }
        Close-AiDnsLog
    }
    return [int]$exitCode
}
