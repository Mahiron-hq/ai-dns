# Console and file output. Every console line is mirrored to the log; trace lines go to the log only.

$script:Run = $null

<#
.SYNOPSIS
    Creates the per-run context that output, dry-run and counters depend on.
#>
function Initialize-AiDnsRun {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $LogDirectory,
        [switch] $Trace,
        [switch] $DryRun
    )

    $script:Run = [pscustomobject]@{
        Action       = $Action
        Trace        = [bool]$Trace
        DryRun       = [bool]$DryRun
        Clock        = [Diagnostics.Stopwatch]::StartNew()
        Errors       = 0
        Warnings     = 0
        LogDirectory = $LogDirectory
        LogFile      = $null
        Writer       = $null
    }
}

<#
.SYNOPSIS
    Opens the run log and prunes old logs of the same action. A log that cannot be opened is
    reported once and the run continues with console output only.
#>
function Open-AiDnsLog {
    $run = $script:Run
    try {
        $null = New-Item -ItemType Directory -Path $run.LogDirectory -Force
        $prefix = $run.Action.ToLowerInvariant()
        $file = Join-Path $run.LogDirectory ('{0}_{1:yyyyMMdd_HHmmss}.log' -f $prefix, (Get-Date))
        $stream = [IO.FileStream]::new($file, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($true))
        $writer.AutoFlush = $true
        $run.Writer = $writer
        $run.LogFile = $file

        Get-ChildItem -LiteralPath $run.LogDirectory -Filter "${prefix}_*.log" -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $script:LogRetention |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host ('  [!] ' + (Get-Text 'Log.Unavailable' @($_.Exception.Message))) -ForegroundColor Yellow
    }
}

function Close-AiDnsLog {
    if ($null -eq $script:Run -or $null -eq $script:Run.Writer) { return }
    try { $script:Run.Writer.Dispose() }
    finally { $script:Run.Writer = $null }
}

function Write-LogRecord {
    param([string] $Level, [string] $Text)

    if ($null -eq $script:Run -or $null -eq $script:Run.Writer) { return }
    try {
        $script:Run.Writer.WriteLine(('{0:HH:mm:ss.fff} {1,-5} {2}' -f (Get-Date), $Level, $Text))
    }
    catch {
        # A full disk or a removed directory must not abort a half-applied network change.
        $script:Run.Writer = $null
    }
}

function Write-ConsoleLine {
    param([string] $Text, [ConsoleColor] $Color, [string] $Level)

    Write-Host $Text -ForegroundColor $Color
    Write-LogRecord $Level $Text.Trim()
}

function Format-ElapsedTime {
    if ($null -eq $script:Run) { return '' }
    Get-Text 'Format.Seconds' @($script:Run.Clock.Elapsed.TotalSeconds)
}

function Write-StepLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    Write-ConsoleLine ("`n==> {0}  ({1})" -f (Get-Text $Key $Arguments), (Format-ElapsedTime)) Cyan 'STEP'
}

function Write-OkLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    Write-ConsoleLine ('  [+] ' + (Get-Text $Key $Arguments)) Green 'OK'
}

function Write-WarnLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    if ($null -ne $script:Run) { $script:Run.Warnings++ }
    Write-ConsoleLine ('  [!] ' + (Get-Text $Key $Arguments)) Yellow 'WARN'
}

function Write-FailLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    if ($null -ne $script:Run) { $script:Run.Errors++ }
    Write-ConsoleLine ('  [x] ' + (Get-Text $Key $Arguments)) Red 'ERROR'
}

function Write-NoteLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    Write-ConsoleLine ('      ' + (Get-Text $Key $Arguments)) DarkGray 'INFO'
}

<#
.SYNOPSIS
    Writes an already formatted line, used for tables and banners.
#>
function Write-RawLine {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [ConsoleColor] $Color = 'Gray', [string] $Level = 'INFO')
    Write-ConsoleLine $Text $Color $Level
}

<#
.SYNOPSIS
    Writes a localized line to the log only. Used for details that would clutter the console.
#>
function Write-DetailLine {
    param([Parameter(Mandatory, Position = 0)] [string] $Key, [Parameter(ValueFromRemainingArguments)] [object[]] $Arguments)
    Write-LogRecord 'INFO' (Get-Text $Key $Arguments)
}

<#
.SYNOPSIS
    Writes a technical, untranslated line to the log when the run was started with -Trace.
#>
function Write-TraceLine {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ($null -ne $script:Run -and $script:Run.Trace) { Write-LogRecord 'TRACE' $Text }
}
