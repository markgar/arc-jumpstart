$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
. (Join-Path $PSScriptRoot 'dashboard-state.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) "arc-dashboard-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $directory | Out-Null
$originalEnvironment = $env:ENV_FILE
try {
    $env:ENV_FILE = Join-Path $directory 'lab.env'
    $private = 'HOST_ADMIN_PASSWORD=never-display-this'
    Set-Content -LiteralPath $env:ENV_FILE -Value $private
    $settings = @{
        AZURE_RESOURCE_GROUP = 'test-infra'; AZURE_LOCATION = 'westus2'
        WINDOWS_SERVER_VERSION = '2025'; INCLUDE_LINUX = 'false'
        INCLUDE_APPLIANCE_VM = 'true'; HOST_ADMIN_PASSWORD = 'never-display-this'
        IMAGE_SOURCE_SAS_TOKEN = 'sig=secret-signature'; INSTALL_HOST_SSMS = 'false'
    }
    if (-not (Write-LabDashboardStage -Settings $settings -NewBuild)) { throw 'Initialize evidence.' }
    $path = Get-LabDashboardPath
    if ($path -eq $env:ENV_FILE -or -not $path.EndsWith('.build-status.json')) { throw 'Never overwrite the private environment.' }
    $state = Get-Content $path -Raw | ConvertFrom-Json
    if ($state.stages.'45'.status -ne 'not-started' -or $state.stages.ssms.status -ne 'skipped') { throw 'Preserve planned and excluded states.' }
    foreach ($step in @(
        @('30', 'running', 'Attempt one'), @('20', 'running', 'Independent networking'),
        @('30', 'failed', 'Password never-display-this and sig=secret-signature'),
        @('30', 'running', 'Attempt two'), @('30', 'completed', 'All boot files verified'))) {
        if (-not (Write-LabDashboardStage -Settings $settings -Stage $step[0] -Status $step[1] -Detail $step[2])) {
            throw 'Persist progress.'
        }
    }
    $json = Get-Content $path -Raw
    if ($json.Contains('never-display-this') -or $json.Contains('secret-signature') -or $json.Contains('HOST_ADMIN_PASSWORD')) {
        throw 'Evidence must never contain settings or known secrets.'
    }
    $state = $json | ConvertFrom-Json
    if ($state.stages.'20'.status -ne 'running' -or $state.stages.'30'.status -ne 'completed' -or
        @($state.events | Where-Object status -eq 'failed').Count -ne 1) {
        throw 'Preserve parallel execution and recovery history independently.'
    }
    if (-not $state.stages.'30'.startedAt -or -not $state.stages.'30'.endedAt) { throw 'Capture stage timing.' }
    [void](Write-LabDashboardStage -Settings $settings -Stage 30 -Status failed -ObservationStartedAt '2000-01-01T00:00:00Z')
    if ((Get-Content $path -Raw | ConvertFrom-Json).stages.'30'.status -ne 'completed') {
        throw 'A stale snapshot must not overwrite newer runner evidence.'
    }
    function Invoke-LabAz {
        param([string[]]$Arguments)
        $prefix = ($Arguments | Select-Object -First 3) -join ' '
        $output = switch ($prefix) {
            'account set --subscription' { '' }
            'deployment group list' {
                '[{"name":"arc-jumpstart-00-foundation","state":"Succeeded"},{"name":"arc-jumpstart-10-hyperv-host","state":"Succeeded"},{"name":"arc-jumpstart-30-images","state":"Succeeded"},{"name":"arc-jumpstart-45-sql-install","state":"Succeeded"},{"name":"arc-jumpstart-40-nested-vms","state":"Succeeded"},{"name":"arc-jumpstart-60-sql-ag","state":"Succeeded"}]'
            }
            'vm run-command list' { '[{"name":"stage30-images"},{"name":"stage45-sql-install"},{"name":"stage40-nested-vms"},{"name":"stage60-sql-ag"}]' }
            'vm run-command show' {
                $command = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
                switch ($command) {
                    'stage30-images' { '{"state":"Succeeded","exit":0}' }
                    'stage45-sql-install' { '{"state":"Succeeded","exit":1}' }
                    'stage40-nested-vms' { '{"state":"Running","exit":0}' }
                    'stage60-sql-ag' { '{"state":"Succeeded","exit":null}' }
                    default { throw "Unexpected snapshot command $command." }
                }
            }
            default { throw "Unexpected Azure call $prefix." }
        }
        @{ Output = $output; Success = $true }
    }
    $settings.AZURE_SUBSCRIPTION_ID = 'test-subscription'
    $settings.NAME_PREFIX = 'test'
    $snapshotAz = ${function:Invoke-LabAz}
    function Invoke-LabAz {
        param([string[]]$Arguments)
        $result = & $snapshotAz $Arguments
        $prefix = ($Arguments | Select-Object -First 3) -join ' '
        if ($prefix -eq 'deployment group list') {
            $records = $result.Output | ConvertFrom-Json -AsHashtable
            foreach ($record in $records) { $record.runId = '20261106000000' }
            $result.Output = ConvertTo-Json -InputObject @($records) -Depth 8
        }
        elseif ($prefix -eq 'vm run-command show') {
            $record = $result.Output | ConvertFrom-Json -AsHashtable
            $record.start = '2026-11-06T00:00:01Z'
            $record.generation = '20261106000000'
            $result.Output = $record | ConvertTo-Json
        }
        return $result
    }
    Save-LabDashboardSnapshot $settings
    $snapshot = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($expected in @(@('00', 'completed'), @('30', 'completed'), @('45', 'failed'),
        @('40', 'running'), @('60', 'unverified'), @('10', 'unverified'),
        @('ssms', 'skipped'), @('sql-media', 'skipped'), @('50', 'not-started'))) {
        if ($snapshot.stages.($expected[0]).status -ne $expected[1]) { throw "Snapshot evidence mismatch for $($expected[0])." }
    }
    if ((Get-Content $env:ENV_FILE -Raw).Trim() -cne $private) { throw 'Private configuration changed.' }
    if (-not $IsWindows -and ([IO.File]::GetUnixFileMode($path).ToString() -match 'Other|Group')) { throw 'Evidence must be owner-only.' }
    $script:dashboardFailureWarning = ''
    & {
        function Write-Warning { param($Message) $script:dashboardFailureWarning = $Message }
        Set-Content -LiteralPath $path -Value '{"version":999}'
        if (Write-LabDashboardStage -Settings $settings -Stage 30 -Status completed) { throw 'Reject an unsupported file.' }
    }
    if ($script:dashboardFailureWarning -notlike '*Dashboard update failed*') { throw 'Telemetry failures must be explicit, not silent.' }
    foreach ($file in @('dashboard-state.ps1', 'dashboard.ps1', 'deploy.ps1')) {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$null, [ref]$errors)
        if ($errors) { throw ($errors.Message -join "`n") }
    }
    Write-Host 'Dashboard evidence checks passed.'
}
finally {
    $env:ENV_FILE = $originalEnvironment
    Remove-Item -LiteralPath $directory -Recurse -Force
}
