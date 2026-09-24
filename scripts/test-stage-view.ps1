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
try {
    function az {
        $global:LabTestAzCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') { return '' }
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
        throw 'Unexpected Azure CLI command in read-only build status.'
    }
    $report = Show-LabStage 'build-status' '' $settings *>&1 | Out-String
    if ($report -notmatch 'ActiveStages=20,30' -or $report -match 'FakeOnly-123!') {
        throw 'Build status did not show both active stages safely.'
    }
    if (@($global:LabTestAzCalls | Where-Object { $_ -match 'invoke' }).Count) {
        throw 'Build status must not invoke a command inside the busy host.'
    }
    Write-Host 'PowerShell stage-view regression checks passed.'
}
finally {
    Remove-Variable LabTestAzCalls -Scope Global -ErrorAction SilentlyContinue
}
