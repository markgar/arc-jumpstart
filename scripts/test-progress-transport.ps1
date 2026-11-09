$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'progress-proof.ps1')
$current = 'current-attempt'
$first = New-LabProofFrame $current 1
$last = New-LabProofFrame $current 3
$foreign = New-LabProofFrame 'old-attempt' 3
$decoded = Read-LabProofFrames -Output "$first`n$foreign`nAJPROOF|invalid%`n$last" -RunId $current
if ($decoded.Frames.Count -ne 2 -or $decoded.Foreign -ne 1 -or $decoded.Rejected -ne 1) {
    throw 'Reject stale generations and malformed frames explicitly.'
}
$noisy = ('PROOF_NOISE_' * 1200) + "`n$last"
$tail = $noisy.Substring($noisy.Length - 4096)
if ((Read-LabProofFrames -Output $tail -RunId $current).Frames[0].sequence -ne 3) {
    throw 'A complete latest frame must survive output-tail truncation.'
}
$partial = Read-LabProofFrames -Output $last.Substring(0, $last.Length - 5) -RunId $current
if ($partial.Frames.Count -or $partial.Rejected -ne 1) { throw 'Never accept a partial frame.' }
$invalidJson = 'AJPROOF|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{invalid'))
if ((Read-LabProofFrames -Output $invalidJson -RunId $current).Rejected -ne 1) { throw 'Report invalid JSON explicitly.' }
$progress = @{ state = 'Succeeded'; exit = 0; generation = $current; start = 'new-start' }
if (-not (Test-LabProofCompletion $progress $current 'old-start' 3)) { throw 'Accept complete fresh proof evidence.' }
foreach ($change in @(@{ state = 'Running' }, @{ exit = 1 }, @{ exit = $null }, @{ generation = 'old-attempt' }, @{ start = 'old-start' })) {
    $invalid = $progress.Clone()
    foreach ($key in $change.Keys) { $invalid[$key] = $change[$key] }
    if (Test-LabProofCompletion $invalid $current 'old-start' 3) { throw 'Never infer successful execution from a progress message.' }
}
if (Test-LabProofCompletion $progress $current 'old-start' 2) { throw 'Require the final frame.' }
$observations = @(
    @{ sequence = 1; reportedState = 'Running'; observedAt = '2026-11-06T23:24:00Z' },
    @{ sequence = 2; reportedState = 'Running'; observedAt = '2026-11-06T23:25:06Z' })
$live = @(Get-LabProofLiveSequences $observations '2026-11-06T23:25:05Z')
if ($live.Count -ne 1 -or $live[0] -ne 1) { throw 'A stale Running label after native completion does not prove live delivery.' }
if (@(Get-LabProofLiveSequences $observations '').Count) { throw 'Require a real native end time before classifying live observations.' }
foreach ($file in @('progress-proof.ps1', 'prove-progress-transport.ps1')) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "`n") }
}
function Test-ProofSafetyGuard {
    param([ValidateSet('ActiveHost', 'ProcessTimeout', 'FailedBuild')][string]$Case)
    $scriptPath = Join-Path $PSScriptRoot 'prove-progress-transport.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
    $main = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
    $body = [scriptblock]::Create('$PSScriptRoot = $args[0]' + "`n" + ($main.Body.Statements.Extent.Text -join "`n"))
    $Mode = 'Canary'; $AfterProcessId = if ($Case -eq 'ActiveHost') { 0 } else { 42 }
    $fixture = New-TemporaryFile
    $CompletionLog = $fixture.FullName; $SuccessMarker = 'BUILD_OK'
    $ReportPath = Join-Path ([IO.Path]::GetTempPath()) 'test.transport-proof.json'
    $report = @{ observations = @(); attempts = @() }
    $calls = [Collections.Generic.List[string]]::new()
    function Get-LabEnvironmentFile { 'unused.env' }
    function Read-LabSettings { @{ AZURE_SUBSCRIPTION_ID = 'test'; AZURE_RESOURCE_GROUP = 'test'; NAME_PREFIX = 'test' } }
    function Assert-LabSettings { }
    function Save-ProofReport { }
    function Get-ProofExecution { @{ state = 'Running' } }
    function Invoke-LabAz {
        param([string[]]$Arguments)
        $prefix = ($Arguments | Select-Object -First 3) -join ' '
        $calls.Add($prefix)
        if ($prefix -eq 'vm run-command list') { return @{ Output = '["active-build"]' } }
        if ($prefix -eq 'account set --subscription') { return @{ Output = '' } }
        throw "Unexpected Azure operation: $prefix"
    }
    function Get-Process {
        param([int]$Id)
        $fake = [pscustomobject]@{}
        if ($Case -eq 'ProcessTimeout') { $fake | Add-Member ScriptMethod WaitForExit { param($Timeout) $false } }
        else { $fake | Add-Member ScriptMethod WaitForExit { param($Timeout) $true } }
        return $fake
    }
    try {
        Set-Content -LiteralPath $fixture.FullName -Value 'BUILD_FAILED'
        $caught = ''
        try { & $body $PSScriptRoot } catch { $caught = $_.Exception.Message }
        $expected = switch ($Case) {
            'ActiveHost' { '*not terminal*' }
            'ProcessTimeout' { '*two hours*' }
            'FailedBuild' { '*expected success marker*' }
        }
        if ($caught -notlike $expected -or $calls.Contains('deployment group create')) {
            throw "Safety guard $Case did not prevent host execution: $caught"
        }
        if ($Case -ne 'ActiveHost' -and $calls.Count) { throw 'A queued proof must not contact Azure before the deployment succeeds.' }
    }
    finally { Remove-Item -LiteralPath $fixture.FullName -Force }
}
Test-ProofSafetyGuard ActiveHost
Test-ProofSafetyGuard ProcessTimeout
Test-ProofSafetyGuard FailedBuild
Write-Host 'Progress framing, UTF-8, stale-attempt, truncation and completion-gate checks passed.'
