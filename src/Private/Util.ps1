# General helpers: validation, JSON files, the change gate and safe file-system operations.

$script:Ipv4Pattern = '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$'
$script:HostnamePattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'
$script:GuidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'

<#
.SYNOPSIS
    Tests whether Address is a dotted-quad IPv4 address that is routable on the public Internet.
.OUTPUTS
    System.Boolean. False for malformed input and for private, loopback, link-local, CGNAT,
    documentation, benchmarking, multicast and reserved ranges.
#>
function Test-PublicIPv4 {
    param([AllowNull()] [AllowEmptyString()] [string] $Address)

    if ([string]::IsNullOrEmpty($Address) -or $Address -notmatch $script:Ipv4Pattern) { return $false }
    $o = [int[]]$Address.Split('.')
    $a = $o[0]; $b = $o[1]; $c = $o[2]
    if ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224) { return $false }
    if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { return $false }
    if ($a -eq 169 -and $b -eq 254) { return $false }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $false }
    if ($a -eq 192 -and $b -eq 168) { return $false }
    if ($a -eq 192 -and $b -eq 0 -and ($c -eq 0 -or $c -eq 2)) { return $false }
    if ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) { return $false }
    if ($a -eq 198 -and $b -eq 51 -and $c -eq 100) { return $false }
    if ($a -eq 203 -and $b -eq 0 -and $c -eq 113) { return $false }
    return $true
}

function Test-Hostname {
    param([AllowNull()] [AllowEmptyString()] [string] $Name)
    return (-not [string]::IsNullOrEmpty($Name)) -and ($Name -cmatch $script:HostnamePattern)
}

<#
.SYNOPSIS
    Strips control and formatting characters (including bidirectional overrides) from text that
    came from a remote list, collapses whitespace and truncates it, so it is safe to print.
#>
function ConvertTo-SafeText {
    param([AllowNull()] [AllowEmptyString()] [string] $Text, [int] $MaxLength = 40)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = ($Text -replace '\p{C}', '' -replace '\s+', ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength).TrimEnd() }
    return $clean
}

<#
.SYNOPSIS
    Reads an optional property of a deserialized JSON object without tripping strict mode.
#>
function Get-JsonProperty {
    param([AllowNull()] $Object, [Parameter(Mandatory)] [string] $Name, $Default = $null)

    if ($null -eq $Object -or $Object -isnot [psobject]) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

<#
.SYNOPSIS
    Reads and parses a JSON file. Returns $null when the file does not exist; throws when it exists but cannot be parsed.
#>
function Read-JsonFile {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { throw (Get-Text 'Error.EmptyFile' @($Path)) }
    return ConvertFrom-Json -InputObject $text
}

<#
.SYNOPSIS
    Serializes Value to Path through a temporary file, so a crash never leaves a truncated backup behind.
#>
function Write-JsonFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Value)

    $json = ConvertTo-Json -InputObject $Value -Depth 8
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

function Format-StateValue {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '<none>' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    $items = @($Value)
    if ($items.Count -eq 0) { return '<empty>' }
    if ($items[0] -is [string] -or $items[0] -is [ValueType]) { return ($items -join ', ') }
    return (ConvertTo-Json -InputObject $Value -Depth 4 -Compress)
}

<#
.SYNOPSIS
    The single gate every system modification passes through. It logs the change with the state
    before and after it and, in a dry run, logs it without executing anything.
.PARAMETER ChangeDescription
    Untranslated technical description used in the log.
.PARAMETER ChangeAction
    The modification. Its output is discarded; errors propagate to the caller.
.PARAMETER StateProbe
    Optional reader of the affected state, evaluated before and after the change.
.OUTPUTS
    System.Boolean. True when the change ran, false in a dry run.
#>
function Invoke-SystemChange {
    param(
        [Parameter(Mandatory, Position = 0)] [string] $ChangeDescription,
        [Parameter(Mandatory, Position = 1)] [scriptblock] $ChangeAction,
        [scriptblock] $StateProbe
    )

    $before = $null
    if ($null -ne $StateProbe) {
        try { $before = Format-StateValue (& $StateProbe) } catch { $before = "<unreadable: $($_.Exception.Message)>" }
    }
    $suffix = if ($null -ne $before) { " | before: $before" } else { '' }

    if ($script:Run.DryRun) {
        Write-RawLine ('      ' + (Get-Text 'DryRun.Skipped' @($ChangeDescription))) DarkMagenta 'DRY'
        if ($suffix) { Write-LogRecord 'DRY' $suffix.TrimStart(' |') }
        return $false
    }

    Write-TraceLine "change: $ChangeDescription$suffix"
    $null = & $ChangeAction
    if ($null -ne $StateProbe) {
        try { Write-TraceLine "  after: $(Format-StateValue (& $StateProbe))" }
        catch { Write-TraceLine "  after: <unreadable: $($_.Exception.Message)>" }
    }
    return $true
}

<#
.SYNOPSIS
    Runs a console program without a window and returns its exit code and combined output.
    Used instead of the call operator because Windows PowerShell turns native stderr into
    terminating errors when $ErrorActionPreference is Stop.
#>
function Invoke-NativeCommand {
    param([Parameter(Mandatory)] [string] $FilePath, [string[]] $ArgumentList = @())

    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath, ($ArgumentList -join ' '))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $oem
    $info.StandardErrorEncoding = $oem

    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $output = ($stdout.Result + "`n" + $stderr).Trim()
        Write-TraceLine "exec: $FilePath $($ArgumentList -join ' ') -> $($process.ExitCode) $($output -replace '\s+', ' ')"
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
    finally { $process.Dispose() }
}

function Get-Median {
    param([AllowNull()] [AllowEmptyCollection()] [object[]] $Values)

    $sorted = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    return [double]$sorted[[int][math]::Floor($sorted.Count / 2)]
}

function Get-RegistryValueInfo {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name)

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key -or ($key.GetValueNames() -notcontains $Name)) {
        return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
    }
    $kind = $key.GetValueKind($Name).ToString()
    $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ Exists = $true; Kind = $kind; Value = $value }
}

<#
.SYNOPSIS
    Deletes a file or directory tree without following junctions or symbolic links.
.OUTPUTS
    System.Int32. The number of entries that could not be deleted (for example, files in use).
#>
function Remove-TreeSafely {
    param([Parameter(Mandatory)] [string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return 0 }
    $failures = 0
    try {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName, $false) } else { [IO.File]::Delete($item.FullName) }
            return 0
        }
        if ($item.PSIsContainer) {
            foreach ($child in @(Get-ChildItem -LiteralPath $item.FullName -Force)) { $failures += Remove-TreeSafely $child.FullName }
            if ($failures -eq 0) { [IO.Directory]::Delete($item.FullName, $false) }
        }
        else {
            $item.Attributes = [IO.FileAttributes]::Normal
            [IO.File]::Delete($item.FullName)
        }
    }
    catch {
        Write-TraceLine "delete failed: $($item.FullName): $($_.Exception.Message)"
        $failures++
    }
    return $failures
}

function Get-WellKnownSid {
    param([Parameter(Mandatory)] [ValidateSet('System', 'Administrators', 'Users', 'TrustedInstaller')] [string] $Name)

    $value = switch ($Name) {
        'System'           { 'S-1-5-18' }
        'Administrators'   { 'S-1-5-32-544' }
        'Users'            { 'S-1-5-32-545' }
        'TrustedInstaller' { 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' }
    }
    return [Security.Principal.SecurityIdentifier]::new($value)
}

<#
.SYNOPSIS
    Tests that only SYSTEM, Administrators and TrustedInstaller can modify the directory and its contents.
#>
function Test-DataDirectoryAcl {
    param([Parameter(Mandatory)] [Security.AccessControl.FileSystemSecurity] $Security)

    $trusted = @((Get-WellKnownSid System), (Get-WellKnownSid Administrators), (Get-WellKnownSid TrustedInstaller))
    $owner = $Security.GetOwner([Security.Principal.SecurityIdentifier])
    if ($trusted -notcontains $owner) { return $false }
    if (-not $Security.AreAccessRulesProtected) { return $false }

    $writeMask = [int]([Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership')
    $genericWrite = 0x40000000 -bor 0x10000000
    foreach ($rule in $Security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $trusted -contains $rule.IdentityReference) { continue }
        $rights = [int]$rule.FileSystemRights
        if (($rights -band $writeMask) -or ($rights -band $genericWrite)) { return $false }
    }
    return $true
}

function New-DataDirectoryAcl {
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    foreach ($entry in @(@('System', 'FullControl'), @('Administrators', 'FullControl'), @('Users', 'ReadAndExecute'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new((Get-WellKnownSid $entry[0]), $entry[1], $inherit, $none, 'Allow')
        $security.AddAccessRule($rule)
    }
    $security.SetOwner((Get-WellKnownSid Administrators))
    return $security
}

<#
.SYNOPSIS
    Creates %ProgramData%\AIDNS and makes sure only administrators can write to it.
.DESCRIPTION
    %ProgramData% lets standard users create folders, and this directory holds a compiled assembly
    that an elevated process loads plus backups that drive registry restores. If the directory was
    not locked down, everything regenerable in it is discarded, because a standard user could have
    planted it, and the remaining files are re-owned so they inherit the new ACL.
.OUTPUTS
    None. Throws if the directory is a reparse point or cannot be secured.
#>
function Initialize-DataDirectory {
    $root = $script:Paths.Root
    $existed = Test-Path -LiteralPath $root
    if (-not $existed) { $null = New-Item -ItemType Directory -Path $root -Force }

    $info = Get-Item -LiteralPath $root -Force
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Get-Text 'Error.DataDirReparse' @($root)) }
    if (Test-DataDirectoryAcl $info.GetAccessControl()) { return }

    Write-TraceLine "securing $root (existed: $existed)"
    $info.SetAccessControl((New-DataDirectoryAcl))
    if (-not $existed) { return }

    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force)) {
        $keep = $entry.Name -in @('backup.json', 'state.json', 'hosts.bak', 'logs')
        if (-not $keep -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $null = Remove-TreeSafely $entry.FullName
            continue
        }
        foreach ($item in @($entry) + @(if ($entry.PSIsContainer) { Get-ChildItem -LiteralPath $entry.FullName -Recurse -Force })) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $null = Remove-TreeSafely $item.FullName; continue }
            $acl = $item.GetAccessControl()
            $acl.SetOwner((Get-WellKnownSid Administrators))
            $acl.SetAccessRuleProtection($false, $false)
            foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { $null = $acl.RemoveAccessRuleSpecific($rule) }
            $item.SetAccessControl($acl)
        }
    }
}
