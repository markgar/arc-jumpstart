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
try {
    function az {
        $global:LabTestAzCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') { return '' }
        if ($args -notcontains '--only-show-errors') {
            return "WARNING: CLI update available`n{}"
        }
        if ($args[2] -eq 'list') {
            return (@(
                @{ name = 'stage20-host-network'; instanceView = @{
                    executionState = 'Running'; startTime = '2026-09-23T21:00:00Z'
                    output = 'phase FakeOnly-123!'; error = '' } },
                @{ name = 'stage30-images'; instanceView = @{
                    executionState = 'Running'; startTime = '2026-09-23T21:00:00Z'
                    output = 'download active'; error = '' } }
            ) | ConvertTo-Json -Depth 5 -Compress)
        }
        if ($args[2] -eq 'show') {
            return (@{ state = 'Running'; start = '2026-09-23T21:00:00Z'
                output = 'install active'; error = '' } | ConvertTo-Json -Compress)
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
    if (@($global:LabTestAzCalls | Where-Object { $_ -match 'invoke' }).Count) {
        throw 'Build status must not invoke a command inside the busy host.'
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
}
