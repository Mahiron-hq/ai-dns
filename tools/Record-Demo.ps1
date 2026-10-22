#Requires -Version 5.1
<#
.SYNOPSIS
    Records the demo GIF for the README from the log of a real AI-DNS run.

.DESCRIPTION
    Replays the log as the console window that wrote it, with the real pacing between lines and long
    pauses shortened. Nothing is executed and no network setting is touched, so the GIF can be made on
    any machine. Lines that only went to the log are left out; the DNS servers in use before the run,
    VPN warnings, virtual adapters and log paths are replaced or removed.

    Any log works; the trace copies in tests\manual write one with every line. Requires Python 3 with
    Pillow (pip install pillow).

.PARAMETER LogPath
    The log to replay, for example tests\manual\logs\enable_20261020_024340.log.

.PARAMETER OutputPath
    Where to write the GIF. Defaults to docs\demo-<language>.gif, with the language taken from the log.

.PARAMETER Speed
    Replay speed relative to the real run.

.EXAMPLE
    .\tools\Record-Demo.ps1 -LogPath tests\manual\logs\enable_20261020_024340.log
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $LogPath,
    [string] $OutputPath,
    [double] $Speed = 1.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$log = (Resolve-Path -LiteralPath $LogPath).ProviderPath
$language = if ([IO.File]::ReadAllText($log) -match '\p{IsCyrillic}') { 'ru' } else { 'en' }
$culture = if ($language -eq 'ru') { 'ru-RU' } else { 'en-US' }
$strings = Import-PowerShellDataFile (Join-Path $root "src\$culture\AIDNS.Strings.psd1")
$footer = [string]::Format($strings['Exit.Countdown'], 20)
$title = if ($language -eq 'ru') { 'Администратор: Windows PowerShell' } else { 'Administrator: Windows PowerShell' }
if (-not $OutputPath) { $OutputPath = Join-Path $root "docs\demo-$language.gif" }

$python = @('py', 'python', 'python3') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if ($null -eq $python) { throw 'Python 3 was not found. Install it from https://www.python.org/ and run: pip install pillow' }

$arguments = @((Join-Path $PSScriptRoot 'demo\render_demo.py'), '--log', $log, '--out', $OutputPath, '--title', $title,
    '--footer', $footer, '--speed', $Speed.ToString([Globalization.CultureInfo]::InvariantCulture))
& $python.Source @arguments
if ($LASTEXITCODE -ne 0) { throw "render_demo.py failed with exit code $LASTEXITCODE." }
