# The interactive settings menu behind AI-DNS-Settings.bat. Every change is saved to settings.json at once.

# The -Language the menu was opened with; Auto lets a language chosen in the menu take effect at once.
$script:MenuLanguage = 'Auto'

function New-MenuItem {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [Parameter(Mandatory)] [string] $Label,
        [string] $Value = '',
        [ConsoleColor] $ValueColor = 'Gray',
        [string] $Hint = '',
        [string] $Mark = ''
    )
    [pscustomobject]@{ Id = $Id; Label = $Label; Value = $Value; ValueColor = $ValueColor; Hint = $Hint; Mark = $Mark }
}

function New-MenuMessage {
    param([Parameter(Mandatory)] [string] $Text, [ConsoleColor] $Color = 'Green')
    [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Get-MenuWidth {
    try { return [Math]::Max(40, [Console]::WindowWidth - 1) } catch { return 100 }
}

function Write-MenuText {
    param([AllowEmptyString()] [string] $Text, [ConsoleColor] $Color = 'Gray', [switch] $NoNewline)

    $width = Get-MenuWidth
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width - 1) + [char]0x2026 }
    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}

function Format-Toggle {
    param([bool] $Value)
    if ($Value) { '[x]' } else { '[ ]' }
}

function Format-Choice {
    param([Parameter(Mandatory)] [string] $Text)
    '{0} {1} {2}' -f [char]0x2039, $Text, [char]0x203A
}

function Show-MenuFrame {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [object[]] $Items,
        [Parameter(Mandatory)] [int] $Index,
        [Parameter(Mandatory)] [string] $Help,
        [AllowNull()] $Message
    )

    [Console]::Clear()
    $width = Get-MenuWidth
    Write-MenuText ''
    Write-MenuText ('  AI-DNS {0} {1} {2}' -f $script:ModuleVersion, [char]0x00B7, (Get-Text 'Menu.Title')) DarkCyan
    Write-MenuText ('  ' + $Title) Cyan
    Write-MenuText ''

    $labelWidth = [Math]::Min(46, ($Items | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $number = if ($i -lt 9) { [string]($i + 1) } else { ' ' }
        $head = '  {0} {1}  {2}' -f $(if ($i -eq $Index) { '>' } else { ' ' }), $number, $item.Label.PadRight($labelWidth)
        if ($i -eq $Index) {
            $line = ('{0}  {1}' -f $head, $item.Value).TrimEnd()
            if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
            Write-Host $line.PadRight($width) -ForegroundColor White -BackgroundColor DarkCyan -NoNewline
            Write-Host ''
        }
        else {
            Write-MenuText $head Gray -NoNewline
            Write-Host ('  ' + $item.Value) -ForegroundColor $item.ValueColor -NoNewline
            Write-Host ''
        }
        if ($item.Mark) { Write-MenuText ('        ' + $item.Mark) Red }
    }

    Write-MenuText ''
    $hint = $Items[$Index].Hint
    if ($hint) {
        foreach ($chunk in @(Split-MenuText $hint ($width - 4))) { Write-MenuText ('  ' + $chunk) DarkGray }
        Write-MenuText ''
    }
    Write-MenuText ('  ' + $Help) DarkGray
    if ($null -ne $Message) {
        Write-MenuText ''
        foreach ($chunk in @(Split-MenuText $Message.Text ($width - 4))) { Write-MenuText ('  ' + $chunk) $Message.Color }
    }
}

function Split-MenuText {
    param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [int] $Width)

    $lines = [Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ($Text -split ' ')) {
        if ($current -and ($current.Length + 1 + $word.Length) -gt $Width) {
            $lines.Add($current)
            $current = $word
        }
        else { $current = if ($current) { "$current $word" } else { $word } }
    }
    if ($current) { $lines.Add($current) }
    return $lines.ToArray()
}

<#
.SYNOPSIS
    Runs one menu screen until Esc or until the handler returns 'Back'.
.PARAMETER Items
    Produces the items to show; called again after every key, so it always reflects the current settings.
.PARAMETER Handler
    Receives the selected item and the action (Enter, Left, Right or Delete). Returns $null, a
    message from New-MenuMessage, or 'Back'.
#>
function Show-MenuScreen {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [scriptblock] $Items,
        [Parameter(Mandatory)] [scriptblock] $Handler,
        [string] $Help
    )

    if (-not $Help) { $Help = Get-Text 'Menu.HelpList' }
    $index = 0
    $message = $null
    while ($true) {
        $list = @(& $Items)
        if ($list.Count -eq 0) { return }
        $index = [Math]::Min([Math]::Max($index, 0), $list.Count - 1)
        Show-MenuFrame -Title $Title -Items $list -Index $index -Help $Help -Message $message
        $message = $null

        $info = [Console]::ReadKey($true)
        $action = $null
        switch ($info.Key) {
            'UpArrow'    { $index = ($index - 1 + $list.Count) % $list.Count }
            'DownArrow'  { $index = ($index + 1) % $list.Count }
            'Home'       { $index = 0 }
            'End'        { $index = $list.Count - 1 }
            'Enter'      { $action = 'Enter' }
            'Spacebar'   { $action = 'Enter' }
            'LeftArrow'  { $action = 'Left' }
            'RightArrow' { $action = 'Right' }
            'Delete'     { $action = 'Delete' }
            'Backspace'  { $action = 'Delete' }
            'Escape'     { return }
        }
        $digit = [int][char]$info.KeyChar - [int][char]'0'
        if ($null -eq $action -and $digit -ge 1 -and $digit -le [Math]::Min(9, $list.Count)) {
            $index = $digit - 1
            $action = 'Enter'
        }
        if ($null -eq $action) { continue }

        $result = & $Handler $list[$index] $action
        if ($result -is [string] -and $result -eq 'Back') { return }
        if ($null -ne $result) { $message = $result }
    }
}

function Read-MenuInput {
    param([Parameter(Mandatory)] [string] $Prompt)

    Write-MenuText ''
    Write-MenuText ('  ' + $Prompt) Cyan
    Write-Host '  > ' -NoNewline -ForegroundColor Cyan
    try { [Console]::CursorVisible = $true } catch { Write-Verbose 'The cursor cannot be shown.' }
    $line = [Console]::ReadLine()
    try { [Console]::CursorVisible = $false } catch { Write-Verbose 'The cursor cannot be hidden.' }
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

function Wait-MenuKey {
    Write-MenuText ''
    Write-MenuText ('  ' + (Get-Text 'Menu.PressKey')) DarkGray
    while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
    $null = [Console]::ReadKey($true)
}

function Save-MenuSetting {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Text)

    if (Save-AiDnsSetting $Settings) { return New-MenuMessage $Text }
    return New-MenuMessage (Get-Text 'Menu.SaveFailed' @($script:Paths.Settings)) Yellow
}

function Get-ModeColor {
    param([Parameter(Mandatory)] [string] $Mode)
    switch ($Mode) { 'Required' { 'Green' } 'Preferred' { 'Cyan' } default { 'DarkGray' } }
}

function Get-NextMode {
    param([Parameter(Mandatory)] [string] $Mode, [int] $Step = 1)
    $modes = $script:ServiceModes
    $modes[([Array]::IndexOf($modes, $Mode) + $Step + $modes.Count) % $modes.Count]
}

<#
.SYNOPSIS
    Tests that a domain has an A record, asking the reference resolvers first and then the system resolver.
#>
function Test-DomainResolution {
    param([Parameter(Mandatory)] [string] $Domain)

    foreach ($server in @($script:ReferenceResolvers[0], $script:ReferenceResolvers[2], '')) {
        $query = @{ Name = $Domain; Type = 'A'; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
        if ($server) { $query.Server = $server }
        try {
            $records = @(Resolve-DnsName @query | Where-Object { $null -ne $_.PSObject.Properties['IP4Address'] -and $_.IP4Address })
            if ($records.Count -gt 0) { return $true }
        }
        catch { Write-Verbose "Resolve $Domain via '$server': $($_.Exception.Message)" }
    }
    return $false
}

<#
.SYNOPSIS
    Validates a domain typed by the user and adds it as a required service.
.OUTPUTS
    A menu message describing the result.
#>
function Add-MenuDomain {
    $settings = Get-AiDnsSetting
    if ($settings.CustomServices.Count -ge $script:CustomServiceLimit) {
        return New-MenuMessage (Get-Text 'Menu.DomainLimit' @($script:CustomServiceLimit)) Yellow
    }
    $text = Read-MenuInput (Get-Text 'Menu.DomainPrompt')
    if (-not $text) { return $null }
    $domain = ConvertTo-AiDnsDomain $text
    if ($null -eq $domain) { return New-MenuMessage (Get-Text 'Menu.DomainInvalid' @($text)) Yellow }
    $overlap = Find-ServiceOverlap $domain @(Get-AiDnsServiceTable $settings)
    if ($null -ne $overlap) { return New-MenuMessage (Get-Text 'Menu.DomainOverlap' @($domain, (Get-ServiceLabel $overlap))) Yellow }
    Write-MenuText ('  ' + (Get-Text 'Menu.DomainChecking' @($domain))) DarkGray
    if (-not (Test-DomainResolution $domain)) { return New-MenuMessage (Get-Text 'Menu.DomainUnresolved' @($domain)) Yellow }
    $settings.CustomServices.Add([pscustomobject]@{ Domain = $domain; Mode = 'Required' })
    return Save-MenuSetting $settings (Get-Text 'Menu.DomainAdded' @($domain))
}

function Show-ServiceMenu {
    $items = {
        $settings = Get-AiDnsSetting
        $table = @(Get-AiDnsServiceTable $settings)
        $blocking = @($table | Where-Object { $settings.Blocking -contains $_.Id })
        if ($blocking.Count) {
            New-MenuItem 'fix' (Get-Text 'Menu.FixBlocking') (@($blocking | ForEach-Object { Get-ServiceLabel $_ }) -join ', ') Red (Get-Text 'Menu.FixBlockingHint')
        }
        foreach ($s in $table) {
            $label = if ($s.Group -eq 'Custom') { Get-Text 'Menu.CustomLabel' @($s.Name) } else { Get-ServiceLabel $s }
            $hint = if ($s.Group -eq 'Custom') { Get-Text 'Menu.CustomHint' } else { Get-Text "Menu.Group.$($s.Group)" }
            $mark = if ($settings.Blocking -contains $s.Id) { Get-Text 'Menu.BlockingMark' } else { '' }
            New-MenuItem "service:$($s.Id)" $label (Format-Choice (Get-Text "Mode.$($s.Mode)")) (Get-ModeColor $s.Mode) $hint $mark
        }
        New-MenuItem 'add' (Get-Text 'Menu.AddDomain') '' Gray (Get-Text 'Menu.AddDomainHint')
    }
    $handler = {
        param($Item, $Action)
        $settings = Get-AiDnsSetting
        if ($Item.Id -eq 'add') { if ($Action -eq 'Enter') { return Add-MenuDomain }; return $null }
        if ($Item.Id -eq 'fix') {
            if ($Action -ne 'Enter') { return $null }
            $ids = [string[]]@($settings.Blocking)
            Remove-AiDnsServiceCheck $settings $ids
            return Save-MenuSetting $settings (Get-Text 'Menu.FixedBlocking')
        }
        $id = $Item.Id.Substring('service:'.Length)
        $service = @(Get-AiDnsServiceTable $settings | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
        if ($null -eq $service) { return $null }
        if ($Action -eq 'Delete') {
            if ($service.Group -ne 'Custom') { return New-MenuMessage (Get-Text 'Menu.BuiltInNoDelete') Yellow }
            Remove-AiDnsServiceCheck $settings @($id)
            return Save-MenuSetting $settings (Get-Text 'Menu.DomainRemoved' @($service.Name))
        }
        $step = if ($Action -eq 'Left') { -1 } else { 1 }
        Set-AiDnsServiceMode $settings $id (Get-NextMode $service.Mode $step)
        return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
    }
    Show-MenuScreen (Get-Text 'Menu.Services') $items $handler (Get-Text 'Menu.HelpServices')
}

function Show-FlagMenu {
    $items = {
        $settings = Get-AiDnsSetting
        foreach ($name in $script:SettingFlags.Keys) {
            $on = [bool]$settings.Flags.$name
            New-MenuItem $name (Get-Text "Flag.$name") (Format-Toggle $on) $(if ($on) { 'Green' } else { 'DarkGray' }) (Get-Text "Flag.$name.Hint")
        }
    }
    $handler = {
        param($Item, $Action)
        if ($Action -eq 'Delete') { return $null }
        $settings = Get-AiDnsSetting
        $settings.Flags.($Item.Id) = -not $settings.Flags.($Item.Id)
        return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
    }
    Show-MenuScreen (Get-Text 'Menu.Flags') $items $handler (Get-Text 'Menu.HelpToggles')
}

function Show-SystemMenu {
    $items = {
        $settings = Get-AiDnsSetting
        foreach ($name in $script:SystemToggles) {
            $on = [bool]$settings.System.$name
            New-MenuItem $name (Get-Text "System.$name") (Format-Toggle $on) $(if ($on) { 'Green' } else { 'DarkGray' }) (Get-Text "System.$name.Hint")
        }
    }
    $handler = {
        param($Item, $Action)
        if ($Action -eq 'Delete') { return $null }
        $settings = Get-AiDnsSetting
        $settings.System.($Item.Id) = -not $settings.System.($Item.Id)
        return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
    }
    Show-MenuScreen (Get-Text 'Menu.System') $items $handler (Get-Text 'Menu.HelpToggles')
}

function Get-MenuProvider {
    try { return @((Get-ProviderCatalog -Offline).Providers | Sort-Object Name) }
    catch { return @() }
}

function Format-ProviderName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Id, [AllowEmptyCollection()] [object[]] $Providers = @())

    if (-not $Id) { return Get-Text 'Common.None' }
    $provider = @($Providers | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if ($null -ne $provider) { return $provider.Name }
    return $Id
}

function Show-PinMenu {
    $providers = @(Get-MenuProvider)
    $items = {
        $settings = Get-AiDnsSetting
        $none = Get-Text 'Menu.PinNone'
        New-MenuItem 'pin:' $none $(if (-not $settings.PinnedProvider) { '*' } else { '' }) Green (Get-Text 'Menu.PinNoneHint')
        foreach ($p in $providers) {
            $value = if ($settings.PinnedProvider -eq $p.Id) { '*' } else { '' }
            New-MenuItem "pin:$($p.Id)" $p.Name $value Green (@($p.Ipv4) -join ', ')
        }
    }
    $handler = {
        param($Item, $Action)
        if ($Action -ne 'Enter') { return $null }
        $settings = Get-AiDnsSetting
        $settings.PinnedProvider = $Item.Id.Substring('pin:'.Length)
        $null = Save-MenuSetting $settings (Get-Text 'Menu.Saved')
        return 'Back'
    }
    Show-MenuScreen (Get-Text 'Menu.Pin') $items $handler
}

function Show-BlockedProviderMenu {
    $providers = @(Get-MenuProvider | Where-Object { $_.Id -ne 'custom' })
    $items = {
        $settings = Get-AiDnsSetting
        foreach ($p in $providers) {
            $blocked = $settings.BlockedProviders -contains $p.Id
            New-MenuItem $p.Id $p.Name (Format-Toggle $blocked) $(if ($blocked) { 'Red' } else { 'DarkGray' }) (@($p.Ipv4) -join ', ')
        }
    }
    $handler = {
        param($Item, $Action)
        if ($Action -eq 'Delete') { return $null }
        $settings = Get-AiDnsSetting
        if (-not $settings.BlockedProviders.Remove($Item.Id)) { $settings.BlockedProviders.Add($Item.Id) }
        return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
    }
    Show-MenuScreen (Get-Text 'Menu.BlockedProviders') $items $handler (Get-Text 'Menu.HelpToggles')
}

function Add-MenuAddress {
    param([Parameter(Mandatory)] [Collections.Generic.List[string]] $List)

    if ($List.Count -ge $script:ListLimit) { return New-MenuMessage (Get-Text 'Menu.ListLimit' @($script:ListLimit)) Yellow }
    $text = Read-MenuInput (Get-Text 'Menu.AddressPrompt')
    if (-not $text) { return $null }
    if (-not (Test-PublicIPv4 $text)) { return New-MenuMessage (Get-Text 'Menu.AddressInvalid' @($text)) Yellow }
    if ($List.Contains($text)) { return $null }
    $List.Add($text)
    return New-MenuMessage (Get-Text 'Menu.Saved')
}

function Show-ResolverMenu {
    $items = {
        $settings = Get-AiDnsSetting
        $providers = @(Get-MenuProvider)
        New-MenuItem 'pin' (Get-Text 'Menu.Pin') (Format-ProviderName $settings.PinnedProvider $providers) Cyan (Get-Text 'Menu.PinHint')
        New-MenuItem 'providers' (Get-Text 'Menu.BlockedProviders') ([string]$settings.BlockedProviders.Count) Cyan (Get-Text 'Menu.BlockedProvidersHint')
        New-MenuItem 'add-own' (Get-Text 'Menu.AddOwn') '' Gray (Get-Text 'Menu.AddOwnHint')
        foreach ($ip in $settings.CustomResolvers) { New-MenuItem "own:$ip" (Get-Text 'Menu.OwnLabel' @($ip)) '' Gray (Get-Text 'Menu.DeleteHint') }
        New-MenuItem 'add-blocked' (Get-Text 'Menu.AddBlocked') '' Gray (Get-Text 'Menu.AddBlockedHint')
        foreach ($ip in $settings.BlockedAddresses) { New-MenuItem "blocked:$ip" (Get-Text 'Menu.BlockedLabel' @($ip)) '' Red (Get-Text 'Menu.DeleteHint') }
    }
    $handler = {
        param($Item, $Action)
        $settings = Get-AiDnsSetting
        $kind, $value = $Item.Id -split ':', 2
        switch ($kind) {
            'pin' { if ($Action -eq 'Enter') { Show-PinMenu }; if ($Action -eq 'Delete') { $settings.PinnedProvider = ''; return Save-MenuSetting $settings (Get-Text 'Menu.Saved') } }
            'providers' { if ($Action -eq 'Enter') { Show-BlockedProviderMenu } }
            'add-own' {
                if ($Action -ne 'Enter') { return $null }
                $message = Add-MenuAddress $settings.CustomResolvers
                if ($null -ne $message -and $message.Color -eq 'Green') { return Save-MenuSetting $settings $message.Text }
                return $message
            }
            'add-blocked' {
                if ($Action -ne 'Enter') { return $null }
                $message = Add-MenuAddress $settings.BlockedAddresses
                if ($null -ne $message -and $message.Color -eq 'Green') { return Save-MenuSetting $settings $message.Text }
                return $message
            }
            'own' { if ($Action -eq 'Delete') { $null = $settings.CustomResolvers.Remove($value); return Save-MenuSetting $settings (Get-Text 'Menu.Saved') } }
            'blocked' { if ($Action -eq 'Delete') { $null = $settings.BlockedAddresses.Remove($value); return Save-MenuSetting $settings (Get-Text 'Menu.Saved') } }
        }
        return $null
    }
    Show-MenuScreen (Get-Text 'Menu.Resolvers') $items $handler (Get-Text 'Menu.HelpLists')
}

function Show-GeneralMenu {
    $items = {
        $settings = Get-AiDnsSetting
        $log = if ($settings.LogDirectory) { $settings.LogDirectory } else { Get-Text 'Menu.LogDefault' @($script:Paths.Logs) }
        New-MenuItem 'language' (Get-Text 'Menu.Language') (Format-Choice (Get-Text "Language.$($settings.Language)")) Cyan (Get-Text 'Menu.LanguageHint')
        New-MenuItem 'log' (Get-Text 'Menu.LogDirectory') $log Cyan (Get-Text 'Menu.LogDirectoryHint')
        New-MenuItem 'wait' (Get-Text 'Menu.Wait') (Format-Choice (Get-Text 'Format.WholeSeconds' @($settings.WaitSeconds))) Cyan (Get-Text 'Menu.WaitHint')
        New-MenuItem 'updates' (Get-Text 'Menu.Updates') (Format-Toggle $settings.CheckUpdates) $(if ($settings.CheckUpdates) { 'Green' } else { 'DarkGray' }) (Get-Text 'Menu.UpdatesHint')
    }
    $handler = {
        param($Item, $Action)
        $settings = Get-AiDnsSetting
        $step = if ($Action -eq 'Left') { -1 } else { 1 }
        switch ($Item.Id) {
            'language' {
                if ($Action -eq 'Delete') { return $null }
                $choices = @('Auto', 'ru', 'en')
                $settings.Language = $choices[([Array]::IndexOf($choices, $settings.Language) + $step + $choices.Count) % $choices.Count]
                $message = Save-MenuSetting $settings (Get-Text 'Menu.Saved')
                Import-AiDnsStringTable (Resolve-AiDnsLanguage $script:MenuLanguage)
                return $message
            }
            'log' {
                if ($Action -eq 'Delete') { $settings.LogDirectory = ''; return Save-MenuSetting $settings (Get-Text 'Menu.Saved') }
                if ($Action -ne 'Enter') { return $null }
                $text = Read-MenuInput (Get-Text 'Menu.LogPrompt')
                if (-not $text) { return $null }
                $previous = $settings.LogDirectory
                $settings.LogDirectory = $text
                if ($null -eq (Resolve-SettingsLogDirectory $settings) -or $text.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
                    $settings.LogDirectory = $previous
                    return New-MenuMessage (Get-Text 'Menu.LogInvalid' @($text)) Yellow
                }
                return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
            }
            'wait' {
                if ($Action -eq 'Delete') { return $null }
                $choices = $script:WaitChoices
                $settings.WaitSeconds = $choices[([Array]::IndexOf($choices, $settings.WaitSeconds) + $step + $choices.Count) % $choices.Count]
                return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
            }
            'updates' {
                if ($Action -eq 'Delete') { return $null }
                $settings.CheckUpdates = -not $settings.CheckUpdates
                return Save-MenuSetting $settings (Get-Text 'Menu.Saved')
            }
        }
        return $null
    }
    Show-MenuScreen (Get-Text 'Menu.General') $items $handler (Get-Text 'Menu.HelpGeneral')
}

<#
.SYNOPSIS
    Starts an action in a new elevated window and waits for it.
.OUTPUTS
    System.Int32. The action's exit code, or 1223 when elevation was refused.
#>
function Start-ElevatedAction {
    param([Parameter(Mandatory)] [ValidateSet('Enable', 'Disable', 'Update')] [string] $Action, [switch] $TestOnly)

    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-ProcessArgument $script:Paths.Launcher),
        '-Action', $Action, '-NoUpdateCheck')
    if ($TestOnly) { $arguments += '-TestOnly' }
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return $process.ExitCode
    }
    catch [InvalidOperationException] { return 1223 }
    catch {
        Write-MenuText ('  ' + (Get-Text 'Error.Unexpected' @($_.Exception.Message))) Red
        Wait-MenuKey
        return 1
    }
}

function Show-RunMenu {
    $items = {
        New-MenuItem 'enable' (Get-Text 'Menu.RunEnable') '' Gray (Get-Text 'Menu.RunEnableHint')
        New-MenuItem 'test' (Get-Text 'Menu.RunTest') '' Gray (Get-Text 'Menu.RunTestHint')
        New-MenuItem 'update' (Get-Text 'Menu.RunUpdate') '' Gray (Get-Text 'Menu.RunUpdateHint')
        New-MenuItem 'disable' (Get-Text 'Menu.RunDisable') '' Gray (Get-Text 'Menu.RunDisableHint')
    }
    $handler = {
        param($Item, $Action)
        if ($Action -ne 'Enter') { return $null }
        $code = switch ($Item.Id) {
            'enable'  { Start-ElevatedAction Enable }
            'test'    { Start-ElevatedAction Enable -TestOnly }
            'update'  { Start-ElevatedAction Update }
            'disable' { Start-ElevatedAction Disable }
        }
        $null = Get-AiDnsSetting -Reload
        if ($code -eq 1223) { return New-MenuMessage (Get-Text 'Elevation.Cancelled') Yellow }
        $color = if ($code -eq 0) { 'Green' } else { 'Yellow' }
        return New-MenuMessage (Get-Text 'Menu.RunFinished' @($code, (Get-Text "ExitCode.$(if ($code -in 0, 1, 2, 3) { $code } else { 1 })"))) $color
    }
    Show-MenuScreen (Get-Text 'Menu.Run') $items $handler
}

function Show-StatusScreen {
    [Console]::Clear()
    try { [Console]::CursorVisible = $true } catch { Write-Verbose 'The cursor cannot be shown.' }
    $null = Invoke-AiDns -Action Status -Language $script:MenuLanguage
    Wait-MenuKey
    try { [Console]::CursorVisible = $false } catch { Write-Verbose 'The cursor cannot be hidden.' }
}

function Reset-MenuSetting {
    Write-MenuText ''
    Write-MenuText ('  ' + (Get-Text 'Menu.ResetConfirm')) Yellow
    while ($true) {
        $key = [Console]::ReadKey($true).Key
        if ($key -eq 'Escape') { return $null }
        if ($key -eq 'Enter') { break }
    }
    $current = Get-AiDnsSetting
    $fresh = New-AiDnsSetting
    # The update notice must not come back for a release the user has already seen.
    $fresh.DismissedVersion = $current.DismissedVersion
    $fresh.LastUpdateCheck = $current.LastUpdateCheck
    return Save-MenuSetting $fresh (Get-Text 'Menu.ResetDone')
}

<#
.SYNOPSIS
    Opens the interactive settings menu.
.PARAMETER Language
    Menu language; Auto follows the settings and then Windows.
.OUTPUTS
    System.Int32. 0, or 1 when there is no interactive console.
#>
function Start-AiDnsSettingsMenu {
    param([ValidateSet('Auto', 'en', 'ru')] [string] $Language = 'Auto')

    $script:MenuLanguage = $Language
    $null = Get-AiDnsSetting -Reload
    Import-AiDnsStringTable (Resolve-AiDnsLanguage $Language)
    try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose 'Console encoding is fixed by the host.' }
    try { $interactive = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected } catch { $interactive = $false }
    if (-not $interactive) {
        Write-Host (Get-Text 'Menu.NotInteractive') -ForegroundColor Yellow
        return 1
    }
    try { $Host.UI.RawUI.WindowTitle = 'AI-DNS ' + (Get-Text 'Menu.Title') } catch { Write-Verbose 'The window title cannot be set.' }
    try { [Console]::CursorVisible = $false } catch { Write-Verbose 'The cursor cannot be hidden.' }

    $problem = $script:SettingsProblem
    $items = {
        $settings = Get-AiDnsSetting
        $table = @(Get-AiDnsServiceTable $settings)
        $required = @($table | Where-Object { $_.Mode -eq 'Required' }).Count
        $flags = @($script:SettingFlags.Keys | Where-Object { $settings.Flags.$_ }).Count
        $system = @($script:SystemToggles | Where-Object { $settings.System.$_ }).Count
        $servicesMark = if ($settings.Blocking.Count) { Get-Text 'Menu.BlockingMark' } else { '' }
        New-MenuItem 'services' (Get-Text 'Menu.Services') (Get-Text 'Menu.ServicesValue' @($required, $settings.CustomServices.Count)) Cyan (Get-Text 'Menu.ServicesHint') $servicesMark
        New-MenuItem 'flags' (Get-Text 'Menu.Flags') (Get-Text 'Menu.CountOn' @($flags)) Cyan (Get-Text 'Menu.FlagsHint')
        New-MenuItem 'system' (Get-Text 'Menu.System') (Get-Text 'Menu.CountOf' @($system, $script:SystemToggles.Count)) Cyan (Get-Text 'Menu.SystemHint')
        New-MenuItem 'resolvers' (Get-Text 'Menu.Resolvers') '' Cyan (Get-Text 'Menu.ResolversHint')
        New-MenuItem 'general' (Get-Text 'Menu.General') '' Cyan (Get-Text 'Menu.GeneralHint')
        New-MenuItem 'status' (Get-Text 'Menu.Status') '' Cyan (Get-Text 'Menu.StatusHint')
        New-MenuItem 'run' (Get-Text 'Menu.Run') '' Cyan (Get-Text 'Menu.RunHint')
        New-MenuItem 'reset' (Get-Text 'Menu.Reset') '' Cyan (Get-Text 'Menu.ResetHint')
    }
    $handler = {
        param($Item, $Action)
        if ($Action -ne 'Enter') { return $null }
        switch ($Item.Id) {
            'services'  { Show-ServiceMenu }
            'flags'     { Show-FlagMenu }
            'system'    { Show-SystemMenu }
            'resolvers' { Show-ResolverMenu }
            'general'   { Show-GeneralMenu }
            'status'    { Show-StatusScreen }
            'run'       { Show-RunMenu }
            'reset'     { return Reset-MenuSetting }
        }
        return $null
    }
    try {
        if ($null -ne $problem) {
            [Console]::Clear()
            Write-MenuText ''
            Write-MenuText ('  ' + (Get-Text 'Settings.Damaged' @($script:Paths.Settings, $problem))) Yellow
            Wait-MenuKey
        }
        Show-MenuScreen (Get-Text 'Menu.Main') $items $handler (Get-Text 'Menu.HelpMain')
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { Write-Verbose 'The cursor cannot be shown.' }
        [Console]::Clear()
    }
    return 0
}
