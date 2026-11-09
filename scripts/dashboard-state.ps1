$dashboardStages = [ordered]@{
    '00' = 'Foundation'; '10' = 'Hyper-V host'; 'sql-media' = 'Licensed SQL media'; '20' = 'Nested networking'
    '30' = 'Windows base image'; '40' = 'Guest creation and readiness'
    '45' = 'SQL and SSAS installation'; '50' = 'Active Directory'
    '60' = 'SQL availability group'; 'ssms' = 'Host management tools'
    'arc-launchers' = 'Arc launchers'; 'bastion' = 'Bastion access'
}

function Get-LabDashboardPath {
    $environment = Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot)
    [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($environment), 'build-status.json')
}

function New-LabDashboardState {
    param([hashtable]$Settings, [switch]$NewBuild)
    $stages = [ordered]@{}
    foreach ($id in $dashboardStages.Keys) {
        $stages[$id] = [ordered]@{
            id = $id; title = $dashboardStages[$id]
            status = $(if ($NewBuild) { 'not-started' } else { 'unknown' })
            detail = ''; output = ''; attempt = ''; startedAt = ''; endedAt = ''
        }
    }
    foreach ($option in @(
        @('DEPLOY_BASTION', 'bastion'), @('INSTALL_HOST_SSMS', 'ssms'),
        @('PREPARE_ARC_LAUNCHERS', 'arc-launchers'))) {
        if ($Settings[$option[0]] -eq 'false') { $stages[$option[1]].status = 'skipped' }
    }
    if ($Settings.SQL_EDITION_MODE -ne 'licensed') { $stages['sql-media'].status = 'skipped' }
    @{
        version = 1
        lab = @{
            resourceGroup = $Settings.AZURE_RESOURCE_GROUP; region = $Settings.AZURE_LOCATION
            windowsVersion = Get-LabWindowsServerVersion $Settings
            includeLinux = ($Settings.INCLUDE_LINUX -ne 'false')
            includeAppliance = ($Settings.INCLUDE_APPLIANCE_VM -eq 'true')
        }
        source = 'deployment-runner'; updatedAt = ''; stages = $stages; events = @()
    }
}

function Write-LabDashboardStage {
    param(
        [hashtable]$Settings, [string]$Stage,
        [ValidateSet('unknown', 'not-started', 'running', 'waiting', 'submitted',
            'completed', 'failed', 'skipped', 'unverified')][string]$Status,
        [string]$Detail = '', [string]$Output = '', [string]$Attempt = '',
        [string]$StartedAt = '', [string]$EndedAt = '',
        [switch]$NewBuild, [string]$Source = 'deployment-runner',
        [string]$ObservationStartedAt = ''
    )
    $lock = $null
    $temporary = $null
    try {
        $path = Get-LabDashboardPath
        $lockPath = "$path.lock"
        $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        Protect-LabPath $lockPath
        $state = if (-not $NewBuild -and (Test-Path -LiteralPath $path)) {
            Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        else { New-LabDashboardState $Settings -NewBuild:$NewBuild }
        if ($state.version -ne 1 -or $state.lab.resourceGroup -ne $Settings.AZURE_RESOURCE_GROUP) {
            throw 'The dashboard file belongs to a different lab or unsupported schema; preserve it and investigate.'
        }
        $now = [datetimeoffset]::UtcNow.ToString('o')
        if ($Stage) {
            if (-not $state.stages.Contains($Stage)) { throw "Unknown dashboard stage: $Stage" }
            $entry = $state.stages[$Stage]
            if ($ObservationStartedAt -and $entry.progressAt -and
                [datetimeoffset]$entry.progressAt -gt [datetimeoffset]$ObservationStartedAt) { return $true }
            $safeDetail = Protect-LabOutput $Detail $Settings
            $safeOutput = Protect-LabOutput $Output $Settings
            if ($safeOutput.Length -gt 8000) { $safeOutput = $safeOutput.Substring($safeOutput.Length - 8000) }
            $changed = $entry.status -ne $Status -or $entry.detail -ne $safeDetail -or
                ($Attempt -and $entry.attempt -ne $Attempt)
            if (($Attempt -and $entry.attempt -ne $Attempt) -or
                ($Status -in @('running', 'waiting') -and $entry.status -notin @('running', 'waiting'))) {
                $entry.startedAt = if ($StartedAt) { $StartedAt } else { $now }
                $entry.endedAt = ''
                $entry.output = ''
            }
            $entry.status = $Status
            $entry.detail = $safeDetail
            if ($safeOutput) { $entry.output = $safeOutput }
            if ($Attempt) { $entry.attempt = $Attempt }
            if ($StartedAt) { $entry.startedAt = $StartedAt }
            if ($EndedAt) { $entry.endedAt = $EndedAt }
            elseif ($Status -in @('completed', 'failed', 'skipped') -and -not $entry.endedAt) { $entry.endedAt = $now }
            if ($changed) {
                $entry.progressAt = $now
                $state.events = @(@($state.events) + @{
                    at = $now; stage = $Stage; status = $Status; detail = $safeDetail
                    attempt = $entry.attempt
                } | Select-Object -Last 150)
            }
        }
        $state.updatedAt = $now
        $state.source = $Source
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Protect-LabPath $temporary
        [IO.File]::Move($temporary, $path, $true)
    }
    catch {
        Write-Warning ("Dashboard update failed; deployment behavior is unchanged: " +
            (Protect-LabOutput $_.Exception.Message $Settings))
        return $false
    }
    finally {
        if ($lock) { $lock.Dispose() }
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $true
}

function Save-LabDashboardSnapshot {
    param([hashtable]$Settings)
    $observationStarted = [datetimeoffset]::UtcNow.ToString('o')
    [void](Invoke-LabAz @('account', 'set', '--subscription', $Settings.AZURE_SUBSCRIPTION_ID))
    $deployments = (Invoke-LabAz @('deployment', 'group', 'list', '--resource-group',
        $Settings.AZURE_RESOURCE_GROUP, '--query',
        '[].{name:name,state:properties.provisioningState,runId:properties.parameters.runId.value,action:properties.parameters.action.value}', '--output', 'json', '--only-show-errors')).Output |
        ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    $hostArguments = @('--resource-group', $Settings.AZURE_RESOURCE_GROUP,
        '--vm-name', "$($Settings.NAME_PREFIX)-host")
    $commands = (Invoke-LabAz (@('vm', 'run-command', 'list') + $hostArguments +
        @('--output', 'json', '--only-show-errors'))).Output | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    if ($deployments -isnot [array] -or $commands -isnot [array]) {
        throw 'Dashboard snapshot requires complete Azure deployment and Run Command arrays.'
    }
    $deploymentNames = @{
        '00' = '00-foundation'; '10' = '10-hyperv-host'; '20' = '20-host-network'
        '30' = '30-images'; '40' = '40-nested-vms'; '45' = '45-sql-install'
        '50' = '50-domain'; '60' = '60-sql-ag'; 'ssms' = 'ssms'
        'arc-launchers' = 'arc-launchers'; 'bastion' = 'bastion'; 'sql-media' = 'sql-media'
    }
    foreach ($id in $dashboardStages.Keys) {
        $deployment = @($deployments | Where-Object name -eq "arc-jumpstart-$($deploymentNames[$id])")
        $command = if ($id -eq 'arc-launchers') { 'stage-arc-launchers' }
            elseif ($id -eq 'sql-media') { 'stage-sql-media' } else { $labCommands[$id] }
        $matching = @($commands | Where-Object name -eq $command)
        if ($deployment.Count -gt 1 -or $matching.Count -gt 1) { throw "Duplicate Azure records for stage $id." }
        $status = 'not-started'; $detail = 'No deployment or execution receipt found.'
        $output = ''; $start = ''; $end = ''
        if ($deployment.Count) {
            switch ($deployment[0].state) {
                'Succeeded' {
                    $status = if ($id -in @('00', 'bastion')) { 'completed' } else { 'unverified' }
                    $detail = 'Azure deployment succeeded; guest execution must also be verified.'
                }
                'Failed' { $status = 'failed'; $detail = 'Azure deployment failed; inspect the redacted stage log.' }
                'Canceled' { $status = 'failed'; $detail = 'Azure deployment was canceled.' }
                default { $status = 'running'; $detail = "Azure deployment: $($deployment[0].state)." }
            }
        }
        if ($matching.Count) {
            $progress = (Invoke-LabAz (@('vm', 'run-command', 'show') + $hostArguments +
                @('--name', $command, '--expand', 'instanceView', '--query',
                "{state:instanceView.executionState,exit:instanceView.exitCode,start:instanceView.startTime,end:instanceView.endTime,output:instanceView.output,error:instanceView.error,generation:parameters[?name == 'RunId'].value | [0]}",
                '--output', 'json', '--only-show-errors'))).Output | ConvertFrom-Json -ErrorAction Stop
            $start = if ($progress.start) { ([datetimeoffset]$progress.start).ToUniversalTime().ToString('o') } else { '' }
            $end = if ($progress.end) { ([datetimeoffset]$progress.end).ToUniversalTime().ToString('o') } else { '' }
            $output = @($progress.output, $progress.error) -join "`n"
            $expectedStart = [datetimeoffset]::MinValue
            $currentExecution = $deployment.Count -and $deployment[0].runId -and
                $deployment[0].runId -eq $progress.generation -and $start -and
                [datetimeoffset]::TryParseExact($deployment[0].runId, 'yyyyMMddHHmmss',
                    [globalization.CultureInfo]::InvariantCulture, [globalization.DateTimeStyles]::AssumeUniversal,
                    [ref]$expectedStart) -and [datetimeoffset]$start -ge $expectedStart
            if (-not $currentExecution) {
                if ($status -ne 'failed' -and $status -ne 'running') { $status = 'unverified' }
                $detail = 'Execution evidence has not been matched to the latest deployment attempt.'
                $output = ''; $start = ''; $end = ''
            }
            elseif ($progress.state -eq 'Succeeded' -and $null -ne $progress.exit -and
                $progress.exit -eq 0 -and $deployment.Count -and $deployment[0].state -eq 'Succeeded') {
                if ($id -eq 'sql-media' -and $deployment[0].action -eq 'prepare') {
                    $status = 'waiting'; $detail = 'Upload launcher prepared; waiting for authorized user media and saved continuation.'
                }
                else { $status = 'completed'; $detail = 'Latest Azure deployment and matching host execution both passed.' }
            }
            elseif ($progress.state -in @('Failed', 'Canceled', 'TimedOut') -or
                ($progress.state -eq 'Succeeded' -and $null -ne $progress.exit -and $progress.exit -ne 0)) {
                $status = 'failed'; $detail = "Host execution: $($progress.state), exit $($progress.exit)."
            }
            elseif ($progress.state -in @('Running', 'Pending')) {
                $status = 'running'; $detail = "Host execution: $($progress.state)."
            }
        }
        if (-not $deployment.Count -and -not $matching.Count) {
            $option = @{ bastion = 'DEPLOY_BASTION'; ssms = 'INSTALL_HOST_SSMS'; 'arc-launchers' = 'PREPARE_ARC_LAUNCHERS' }[$id]
            if (($option -and $Settings[$option] -eq 'false') -or
                ($id -eq 'sql-media' -and $Settings.SQL_EDITION_MODE -ne 'licensed')) {
                $status = 'skipped'; $detail = 'Excluded by this lab configuration.'
            }
        }
        if (-not (Write-LabDashboardStage -Settings $Settings -Stage $id -Status $status `
            -Detail $detail -Output $output -StartedAt $start -EndedAt $end -Attempt $start `
            -Source 'azure-snapshot' -ObservationStartedAt $observationStarted)) {
            throw "Could not save dashboard stage $id."
        }
    }
}
