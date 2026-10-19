@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # An interactive console tool: coloured Write-Host output is its user interface.
        'PSAvoidUsingWriteHost'
        # State-changing helpers go through Invoke-SystemChange, which provides dry-run and change logging.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
