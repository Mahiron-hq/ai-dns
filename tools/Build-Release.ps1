#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the release archive dist\ai-dns-<version>.zip and its SHA-256 checksum file.

.DESCRIPTION
    The archive contains only what is needed to run AI-DNS: the four launchers, AI-DNS.ps1, src\,
    LICENSE, NOTICE and a short README.txt in English and Russian. Every file must be committed and
    unmodified, so a release always matches a commit and never carries personal settings or logs.

.PARAMETER OutputDirectory
    Where to write the archive. Defaults to dist\ in the repository.

.EXAMPLE
    .\tools\Build-Release.ps1
#>
[CmdletBinding()]
param([string] $OutputDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }

$version = (Import-PowerShellDataFile (Join-Path $root 'src\AIDNS.psd1')).ModuleVersion
$name = "ai-dns-$version"
$paths = @('AI-DNS-Enable.bat', 'AI-DNS-Disable.bat', 'AI-DNS-Update.bat', 'AI-DNS-Settings.bat', 'AI-DNS.ps1', 'LICENSE', 'NOTICE', 'src')

$files = @(& git -C $root ls-files -- @paths)
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw 'git ls-files failed; run this from a clone of the repository.' }
$dirty = @(& git -C $root status --porcelain -- @paths)
if ($dirty.Count -gt 0) { throw "Commit these changes first:`n$($dirty -join "`n")" }
$stamp = [DateTimeOffset]::FromUnixTimeSeconds([long](& git -C $root log -1 --format=%ct))

$readme = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'release\README.txt')).Replace('{version}', $version)
$readme = $readme -replace "`r?`n", "`r`n"

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$zipPath = Join-Path $OutputDirectory "$name.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $root $file), "$name/$file",
            [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $stamp
    }
    $entry = $archive.CreateEntry("$name/README.txt", [IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $stamp
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($true))
    try { $writer.Write($readme) } finally { $writer.Dispose() }
}
finally { $archive.Dispose() }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = "$zipPath.sha256"
[IO.File]::WriteAllText($checksum, "$hash  $name.zip`n", [Text.UTF8Encoding]::new($false))

Write-Host "$zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB)) KB, $($files.Count + 1) files)"
Write-Host "SHA-256 $hash"
