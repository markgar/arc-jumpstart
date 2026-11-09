param(
    [ValidateSet('Observe', 'Canary')][string]$Mode = 'Observe',
    [ValidateSet('10', '20', '30', '40', '45', '50', '60', 'ssms')][string]$Stage = '50',
    [int]$AfterProcessId = 0,
    [string]$CompletionLog = '',
    [string]$SuccessMarker = '',
    [string]$ReportPath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
. (Join-Path $PSScriptRoot 'progress-proof.ps1')
$settings = $null
$report = @{ version = 1; status = 'preparing'; observations = @(); attempts = @() }

function Save-ProofReport {
    $report.updatedAt = [datetimeoffset]::UtcNow.ToString('o')
    $temporary = "$ReportPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Protect-LabPath $temporary
        [IO.File]::Move($temporary, $ReportPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-ProofExecution {
    param([string]$Name)
    $result = Invoke-LabAz @('vm', 'run-command', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--vm-name', "$($settings.NAME_PREFIX)-host",
        '--name', $Name, '--expand', 'instanceView', '--query',
        "{state:instanceView.executionState,exit:instanceView.exitCode,start:instanceView.startTime,end:instanceView.endTime,output:instanceView.output,generation:parameters[?name == 'RunId'].value | [0]}",
        '--output', 'json', '--only-show-errors')
    return $result.Output | ConvertFrom-Json -ErrorAction Stop
}

try {
    $environment = Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot)
    $settings = Read-LabSettings $environment
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if (-not $ReportPath) { $ReportPath = [IO.Path]::ChangeExtension($environment, 'transport-proof.json') }
    $ReportPath = [IO.Path]::GetFullPath($ReportPath)
    if (-not $ReportPath.EndsWith('.transport-proof.json')) { throw 'ReportPath must end in .transport-proof.json, never .env or .build-status.json.' }
    $report.resourceGroup = $settings.AZURE_RESOURCE_GROUP
    $report.mode = $Mode
    if ($AfterProcessId) {
        if ($Mode -ne 'Canary' -or -not $CompletionLog -or -not $SuccessMarker) {
            throw 'Queued canaries require a completion log and an explicit success marker.'
        }
        $process = Get-Process -Id $AfterProcessId -ErrorAction Stop
        $report.status = 'waiting-for-deployment'
        $report.afterProcessId = $AfterProcessId
        Save-ProofReport
        Write-Host "Proof queued behind process $AfterProcessId. Report: $ReportPath"
        if (-not $process.WaitForExit(7200000)) { throw 'Deployment has not exited within two hours; no canary was submitted.' }
        $lastLine = @(Get-Content -LiteralPath $CompletionLog -Tail 30 | Where-Object { $_.Trim() })[-1]
        if (-not $lastLine.StartsWith($SuccessMarker, [StringComparison]::Ordinal)) {
            throw 'Deployment did not finish with its expected success marker; no canary was submitted.'
        }
    }
    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    if ($Mode -eq 'Observe') {
        $progress = Get-ProofExecution $labCommands[$Stage]
        $output = Protect-LabOutput ([string]$progress.output) $settings
        $report.observations = @(@{
            at = [datetimeoffset]::UtcNow.ToString('o'); stage = $Stage
            state = $progress.state; start = $progress.start
            outputBytes = [Text.Encoding]::UTF8.GetByteCount($output)
            outputPresentWhileRunning = ($progress.state -eq 'Running' -and $output.Length -gt 0)
        })
        $report.status = 'observed'
        Save-ProofReport
        Write-Host ($report.observations[0] | ConvertTo-Json -Compress)
        Write-Host 'This observes existing output only; structured framing and truncation remain a separate canary.'
        exit 0
    }
    $names = (Invoke-LabAz @('vm', 'run-command', 'list', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--vm-name', "$($settings.NAME_PREFIX)-host",
        '--query', '[].name', '--output', 'json', '--only-show-errors')).Output |
        ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    if ($names -isnot [array]) { throw 'Cannot establish that the host is idle.' }
    foreach ($name in $names) {
        $existing = Get-ProofExecution $name
        if ($existing.state -notin @('Succeeded', 'Failed', 'Canceled', 'TimedOut')) {
            throw "Host command $name is not terminal; no competing canary was submitted."
        }
    }
    $command = 'progress-proof-' + [guid]::NewGuid().ToString('N')
    $report.commandName = $command
    $report.status = 'running'
    Save-ProofReport
    $previousStart = ''
    foreach ($attempt in 1..2) {
        $runId = [guid]::NewGuid().ToString('N')
        $entry = @{
            runId = $runId; number = $attempt; latestSequence = 0
            observedLive = @(); frameObservations = @(); foreignFrames = 0; rejectedFrames = 0
            latestSnapshotAfterNoise = $false; observations = @()
        }
        $report.attempts += $entry
        $parameters = New-LabParameterFile @{
            namePrefix = $settings.NAME_PREFIX; location = $settings.AZURE_LOCATION
            commandName = $command; runId = $runId
        }
        try {
            [void](Invoke-LabAz @('deployment', 'group', 'create', '--resource-group',
                $settings.AZURE_RESOURCE_GROUP, '--name', "$command-$attempt",
                '--template-file', (Join-Path $PSScriptRoot '../infra/stages/progress-proof/main.bicep'),
                '--parameters', "@$parameters", '--output', 'none', '--only-show-errors'))
        }
        finally { Remove-Item -LiteralPath $parameters -Force }
        $deadline = [datetimeoffset]::UtcNow.AddMinutes(6)
        do {
            $progress = Get-ProofExecution $command
            $decoded = Read-LabProofFrames -Output ([string]$progress.output) -RunId $runId
            $entry.foreignFrames += $decoded.Foreign
            $entry.rejectedFrames += $decoded.Rejected
            $observedAt = [datetimeoffset]::UtcNow.ToString('o')
            foreach ($frame in $decoded.Frames) {
                if ($frame.sequence -gt $entry.latestSequence) { $entry.latestSequence = $frame.sequence }
                if ($frame.sequence -notin @($entry.frameObservations | ForEach-Object sequence)) {
                    $entry.frameObservations += @{
                        sequence = $frame.sequence; emittedAt = $frame.at
                        observedAt = $observedAt; reportedState = $progress.state
                    }
                }
                if ($frame.sequence -ge 2 -and $progress.output.Contains('PROOF_NOISE_')) {
                    $entry.latestSnapshotAfterNoise = $true
                }
            }
            $entry.observations += @{
                at = $observedAt; state = $progress.state
                outputBytes = [Text.Encoding]::UTF8.GetByteCount([string]$progress.output)
                latestSequence = $entry.latestSequence
            }
            Save-ProofReport
            if ($progress.state -in @('Succeeded', 'Failed', 'Canceled', 'TimedOut') -and
                $progress.generation -ceq $runId -and [string]$progress.start -ne $previousStart) { break }
            if ([datetimeoffset]::UtcNow -ge $deadline) {
                throw "Canary observation timed out. Preserve command $command; do not delete or restart an active operation."
            }
            Start-Sleep -Seconds 10
        } while ($true)
        $entry.nativeStart = $progress.start
        $entry.nativeEnd = if ($progress.end) { ([datetimeoffset]$progress.end).ToUniversalTime().ToString('o') } else { '' }
        $entry.observedLive = @(Get-LabProofLiveSequences $entry.frameObservations $entry.nativeEnd)
        $entry.nativeSuccess = Test-LabProofCompletion $progress $runId $previousStart $entry.latestSequence
        $entry.passed = $entry.nativeSuccess -and 1 -in $entry.observedLive -and
            2 -in $entry.observedLive -and $entry.latestSnapshotAfterNoise
        Save-ProofReport
        if (-not $entry.passed) {
            throw 'The output channel did not satisfy live delivery, post-noise snapshot recovery and fresh native completion. Do not treat this transport as proven.'
        }
        $previousStart = [string]$progress.start
    }
    $report.status = 'passed'
    Save-ProofReport
    Write-Host "Progress transport proof passed twice. Synthetic command retained as evidence: $command"
}
catch {
    $report.status = 'blocked-or-failed'
    $report.error = if ($settings) { Protect-LabOutput $_.Exception.Message $settings } else { $_.Exception.Message }
    if ($ReportPath -and $ReportPath.EndsWith('.transport-proof.json')) { Save-ProofReport }
    Write-Error $report.error
    exit 1
}
