$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')

$settings = @{
    AZURE_SUBSCRIPTION_ID = 'mock-sub'
    AZURE_RESOURCE_GROUP = 'mock-rg'
    NAME_PREFIX = 'mock'
    HOST_ADMIN_PASSWORD = 'FakeOnly-123!'
    IMAGE_SOURCE_SAS_TOKEN = 'sig=fake%2Bsignature'
}
$raw = "Host Application: powershell.exe -Password old-secret`nwrapped old-secret`n" +
    "**********************`nphase FakeOnly-123! sig=fake%2Bsignature"
$safe = Protect-LabOutput $raw $settings
if ($safe -match 'old-secret|FakeOnly-123!|fake%2Bsignature') {
    throw 'Stage output leaked a configured secret or transcript header.'
}
if ($safe -notmatch 'header suppressed' -or $safe -notmatch 'phase') {
    throw 'Stage output lost useful diagnostics.'
}
$encoded = Protect-LabOutput 'sig=fake%2bsignature' $settings
if ($encoded -match 'fake%2b') { throw 'Encoded SAS signature was not redacted.' }

$global:LabTestAzCalls = [System.Collections.Generic.List[string]]::new()
$global:LabTestScriptPath = ''
$global:LabTestCommands = @(
    @{ name = 'stage20-host-network' },
    @{ name = 'stage30-images' },
    @{ name = 'stage45-sql-install' },
    @{ name = 'stage-ssms' },
    @{ name = 'unrelated-command' }
)
$global:LabTestViews = @{
    'stage20-host-network' = @{ state = 'Running'; start = '2026-09-23T21:00:00Z'
        output = 'phase FakeOnly-123!'; error = '' }
    'stage30-images' = @{ state = 'Running'; start = '2026-09-23T21:01:00Z'
        output = 'download active'; error = '' }
    'stage45-sql-install' = @{ state = 'Succeeded'; start = '2026-09-23T20:00:00Z'
        output = 'install active'; error = '' }
}
try {
    function az {
        $global:LabTestAzCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') { return '' }
        if ($args -notcontains '--only-show-errors') {
            return "WARNING: CLI update available`n{}"
        }
        if ($args[2] -eq 'list') {
            return (ConvertTo-Json -InputObject @($global:LabTestCommands) -Compress)
        }
        if ($args[2] -eq 'show') {
            $index = [Array]::IndexOf($args, '--name')
            if ($index -lt 0 -or $args -notcontains '--expand' -or
                $args -notcontains 'instanceView') {
                throw 'Stage view must show the named command with its instance view.'
            }
            $name = $args[$index + 1]
            if (-not $global:LabTestViews.ContainsKey($name)) {
                throw "Mock show failed for $name"
            }
            return (ConvertTo-Json -InputObject $global:LabTestViews[$name] -Compress)
        }
        if ($args[2] -eq 'invoke') {
            $index = [Array]::IndexOf($args, '--scripts')
            if ($index -lt 0 -or $args[$index + 1] -notlike '@*.ps1') {
                throw 'Stage log must pass a local script file to Azure CLI.'
            }
            $global:LabTestScriptPath = $args[$index + 1].Substring(1)
            $text = [IO.File]::ReadAllText($global:LabTestScriptPath)
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            if ($errors.Count -or $text -notmatch 'function Remove-TranscriptStartupHeader' -or
                $text -notmatch 'Select-Object -Last 200') {
                throw 'Stage log script was truncated or is not parseable.'
            }
            if ($IsWindows) {
                $acl = Get-Acl -LiteralPath $global:LabTestScriptPath
                $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
                if (-not $acl.AreAccessRulesProtected -or
                    @($acl.Access | Where-Object { $_.IdentityReference.Translate(
                        [Security.Principal.SecurityIdentifier]) -ne $owner }).Count) {
                    throw 'Temporary script is not restricted to the current user.'
                }
            }
            return 'redacted transcript tail'
        }
        throw 'Unexpected Azure CLI command in read-only build status.'
    }
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    if ($report -notmatch 'ActiveStages=20,30' -or $report -match 'FakeOnly-123!') {
        throw 'Build status did not show both active stages safely.'
    }
    if ($report -notmatch 'Stage=20' -or $report -notmatch 'Stage=30' -or
        $report -match 'Stage=45' -or $report -notmatch '\[REDACTED\]') {
        throw 'Build status did not use redacted per-stage show responses.'
    }
    if (@($global:LabTestAzCalls | Where-Object { $_ -match 'vm run-command show' }).Count -ne 3) {
        throw 'Build status did not show exactly the discovered numbered stages.'
    }
    if (@($global:LabTestAzCalls | Where-Object { $_ -match 'invoke' }).Count) {
        throw 'Build status must not invoke a command inside the busy host.'
    }
    $global:LabTestCommands = @(
        'stage10-init-host', 'stage20-host-network', 'stage30-images',
        'stage40-nested-vms', 'stage45-sql-install', 'stage50-domain',
        'stage60-sql-ag', 'stage-ssms'
    ) | ForEach-Object { @{ name = $_ } }
    foreach ($name in @('stage10-init-host', 'stage40-nested-vms',
            'stage50-domain', 'stage60-sql-ag')) {
        $global:LabTestViews[$name] = @{ state = 'Succeeded'
            start = '2026-09-23T19:00:00Z'; output = ''; error = '' }
    }
    $showsBefore = @($global:LabTestAzCalls | Where-Object { $_ -match 'vm run-command show' }).Count
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    $showsAfter = @($global:LabTestAzCalls | Where-Object { $_ -match 'vm run-command show' }).Count
    if ($showsAfter - $showsBefore -ne 7 -or $report -notmatch 'ActiveStages=20,30') {
        throw 'Build status must inspect all seven numbered stages, not independent SSMS.'
    }
    $global:LabTestViews['stage20-host-network'].state = 'Unknown'
    $global:LabTestViews['stage30-images'].state = 'Succeeded'
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    if ($report -notmatch 'BuildState=Running' -or
        $report -notmatch 'ActiveStages=20' -or
        $report -notmatch 'ExecutionState=Unknown' -or
        $report -match 'BuildState=NoActiveStage|LatestStage=') {
        throw 'Unknown Azure state must remain visible and nonterminal.'
    }
    $global:LabTestCommands = @(
        @{ name = 'stage20-host-network' },
        @{ name = 'stage30-images' },
        @{ name = 'stage45-sql-install' }
    )
    $global:LabTestViews['stage20-host-network'].state = 'Succeeded'
    $global:LabTestViews['stage30-images'].state = 'TimedOut'
    $global:LabTestViews['stage45-sql-install'].start = '2026-09-23T22:00:00Z'
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    if ($report -notmatch 'BuildState=NoActiveStage' -or
        $report -notmatch 'LatestStage=45' -or $report -notmatch 'Stage=45' -or
        $report -match 'Stage=20|Stage=30') {
        throw 'Build status did not select the most recently started terminal stage.'
    }
    $global:LabTestCommands = @()
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    if ($report -notmatch 'BuildState=NotStarted' -or
        $report -match 'LatestStage=|Stage=45') {
        throw 'Empty command list should report no canonical stages.'
    }
    $global:LabTestCommands = @(@{ name = 'stage20-host-network' })
    $global:LabTestViews['stage20-host-network'].start = 'invalid date'
    try {
        Show-LabStage 'build-status' '' $settings *>&1 | Out-Null
        throw 'Expected invalid instance-view start time failure'
    }
    catch {
        if ($_.Exception.Message -notmatch 'stage20-host-network.*invalid instance-view start time') { throw }
    }
    $global:LabTestViews['stage20-host-network'].start = '2026-09-23T21:00:00Z'
    $global:LabTestViews['stage20-host-network'].Remove('state')
    try {
        Show-LabStage 'build-status' '' $settings *>&1 | Out-Null
        throw 'Expected missing instance-view state failure'
    }
    catch {
        if ($_.Exception.Message -notmatch 'stage20-host-network.*no valid instance-view') { throw }
    }
    $global:LabTestViews['stage20-host-network'].state = 'not-a-state'
    try {
        Show-LabStage 'build-status' '' $settings *>&1 | Out-Null
        throw 'Expected invalid instance-view state failure'
    }
    catch {
        if ($_.Exception.Message -notmatch 'stage20-host-network.*no valid instance-view') { throw }
    }
    $global:LabTestViews.Remove('stage20-host-network')
    try {
        Show-LabStage 'build-status' '' $settings *>&1 | Out-Null
        throw 'Expected Azure CLI show failure'
    }
    catch {
        if ($_.Exception.Message -ne 'Mock show failed for stage20-host-network') { throw }
    }
    if (@($global:LabTestAzCalls | Where-Object { $_ -match 'invoke' }).Count) {
        throw 'Build status must never invoke a VM command, including on failure.'
    }
    $progress = Show-LabStage 'stage-progress' '45' $settings *>&1 | Out-String
    if ($progress -notmatch 'Stage=45' -or $progress -notmatch 'install active') {
        throw 'Structured stage progress could not parse Azure CLI JSON.'
    }
    $report = Show-LabStage 'stage-log' '45' $settings *>&1 | Out-String
    if ($report -notmatch 'redacted transcript tail' -or
        (Test-Path -LiteralPath $global:LabTestScriptPath)) {
        throw 'Stage log failed to display output or clean up its script.'
    }
    function Invoke-LabAz {
        param([string[]]$Arguments)
        if ($Arguments -contains 'invoke') {
            $global:LabTestScriptPath = $Arguments[([Array]::IndexOf($Arguments, '--scripts') + 1)].Substring(1)
            if (-not (Test-Path -LiteralPath $global:LabTestScriptPath)) {
                throw 'Temporary script was missing before Azure CLI failure.'
            }
            throw 'Mock Azure CLI failure'
        }
        @{ Output = '' }
    }
    try {
        Show-LabStage 'stage-log' '45' $settings *>&1 | Out-Null
        throw 'Expected stage-log failure'
    }
    catch {
        if ($_.Exception.Message -ne 'Mock Azure CLI failure') { throw }
    }
    if (Test-Path -LiteralPath $global:LabTestScriptPath) {
        throw 'Stage log left a temporary script after Azure CLI failed.'
    }
    Write-Host 'PowerShell stage-view regression checks passed.'
}
finally {
    Remove-Variable LabTestAzCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable LabTestScriptPath -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable LabTestCommands -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable LabTestViews -Scope Global -ErrorAction SilentlyContinue
}
