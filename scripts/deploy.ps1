param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('00', '10', '20', '30', '40', '45', '50', '60',
        '20-30', 'all', 'os-only', 'continue', 'sql-media', 'bastion', 'auto-shutdown', 'arc-launchers', 'ssms')]
    [string]$Stage
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
. (Join-Path $PSScriptRoot 'dashboard-state.ps1')
$script:dashboardInitialized = $false
$script:dashboardCurrentStage = ''
$script:dashboardRunOutput = ''

$stageNames = @{
    '00' = '00-foundation'; '10' = '10-hyperv-host'; '20' = '20-host-network'
    '30' = '30-images'; '40' = '40-nested-vms'; '45' = '45-sql-install'
    '50' = '50-domain'; '60' = '60-sql-ag'
}
$commandNames = @{
    '10' = 'stage10-init-host'; '20' = 'stage20-host-network'
    '30' = 'stage30-images'; '40' = 'stage40-nested-vms'
    '45' = 'stage45-sql-install'; '50' = 'stage50-domain'
    '60' = 'stage60-sql-ag'
}
$repoRoot = Split-Path -Parent $PSScriptRoot
$imagesSubmitted = $false
$imagePreviousStart = ''
$bastionNotice = ''

function Get-Setting {
    param([string]$Key, [string]$Default = '')
    if ($settings[$Key]) { return $settings[$Key] }
    return $Default
}

function Assert-Choice {
    param([string]$Name)
    if ($settings[$Name] -cnotin @('true', 'false')) {
        throw "$Name must be true or false."
    }
}

function Get-AzValue {
    param([string[]]$Arguments)
    $result = Invoke-LabAz $Arguments -AllowFailure
    if ($result.Success) { return $result.Output.Trim() }
    return ''
}

function Assert-Deployment {
    param([string]$Number)
    $name = "arc-jumpstart-$($stageNames[$Number])"
    $state = Get-AzValue @('deployment', 'group', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', $name, '--query',
        'properties.provisioningState', '--output', 'tsv')
    if ($state -ne 'Succeeded') {
        throw "Stage $Number must complete successfully before this stage can run."
    }
}

function Assert-Foundation {
    $state = Get-AzValue @('network', 'vnet', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-vnet",
        '--query', 'provisioningState', '--output', 'tsv')
    if ($state -ne 'Succeeded') {
        throw 'The foundation virtual network must complete before this deployment can run.'
    }
}

function Get-RunStatus {
    param([string]$Command)
    $value = Get-AzValue @('vm', 'run-command', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--vm-name', "$($settings.NAME_PREFIX)-host",
        '--name', $Command, '--expand', 'instanceView', '--query',
        "[instanceView.executionState, to_string(instanceView.exitCode), instanceView.startTime, not_null(instanceView.output, '')] | join('|', @)",
        '--output', 'tsv', '--only-show-errors')
    $parts = $value.Split('|', 4)
    $script:dashboardRunOutput = if ($parts.Count -eq 4) { $parts[3] } else { '' }
    return ($parts | Select-Object -First 3) -join '|'
}

function Assert-RunSucceeded {
    param([string]$Command)
    $status = Get-RunStatus $Command
    if ($status -notmatch '^Succeeded\|0\|') {
        throw "Run Command $Command has not completed successfully (status: $status)."
    }
    if ($script:dashboardInitialized) {
        $id = ($commandNames.GetEnumerator() | Where-Object Value -eq $Command | Select-Object -First 1).Key
        if ($id) {
            [void](Write-LabDashboardStage -Settings $settings -Stage $id -Status completed `
                -Detail 'Predecessor host execution verified successfully.' -Output $script:dashboardRunOutput)
        }
    }
}

function Wait-RunCommand {
    param([string]$Command, [string]$PreviousStart = '')
    for ($attempt = 1; $attempt -le 600; $attempt++) {
        $status = @(Get-RunStatus $Command) -join ''
        $parts = $status.Split('|')
        $state = if ($parts.Count -ge 1) { $parts[0] } else { '' }
        $code = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $start = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        if (-not $start -or $start -eq $PreviousStart) { $state = 'Pending' }
        $id = if ($Command -eq 'stage-ssms') { 'ssms' } else {
            ($commandNames.GetEnumerator() | Where-Object Value -eq $Command | Select-Object -First 1).Key
        }
        if ($script:dashboardInitialized -and $id) {
            $script:dashboardCurrentStage = $id
            $dashboardStatus = switch ($state) {
                'Succeeded' { if ($code -eq '0') { 'completed' } else { 'failed' } }
                { $_ -in @('Failed', 'Canceled', 'TimedOut') } { 'failed' }
                'Pending' { 'waiting' }
                default { 'running' }
            }
            [void](Write-LabDashboardStage -Settings $settings -Stage $id -Status $dashboardStatus `
                -Detail "Host execution: $state; exit $code." `
                -Output $(if ($state -ne 'Pending') { $script:dashboardRunOutput }) `
                -StartedAt $(if ($state -ne 'Pending') { $start }))
        }
        if ($state -eq 'Succeeded') {
            if ($code -eq '0') { $script:dashboardCurrentStage = ''; return }
            throw "Run Command $Command exited with code $code."
        }
        if ($state -in @('Failed', 'Canceled', 'TimedOut')) {
            throw "Run Command $Command ended in state $state with exit code $code."
        }
        if ($attempt % 10 -eq 0) { Write-Host "Waiting for Run Command $Command ($state)..." }
        if ($attempt -eq 600) { throw "Timed out waiting for Run Command $Command." }
        Start-Sleep -Seconds 30
    }
}

function Assert-Predecessors {
    param([string]$Number)
    switch ($Number) {
        '10' { Assert-Foundation }
        '20' { Assert-Deployment '10' }
        '30' { Assert-Deployment '10' }
        '40' {
            Assert-Deployment '20'
            Assert-Deployment '30'
            Assert-RunSucceeded 'stage30-images'
        }
        '45' { Assert-Deployment '40' }
        '50' {
            Assert-Deployment '45'
            Assert-RunSucceeded 'stage45-sql-install'
        }
        '60' { Assert-Deployment '50' }
    }
}

function Get-HostSubnetId {
    $id = Get-AzValue @('deployment', 'group', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', 'arc-jumpstart-00-foundation',
        '--query', 'properties.outputs.hostSubnetId.value', '--output', 'tsv')
    if ($id -and $id -ne 'null') { return $id }
    $id = (Invoke-LabAz @('network', 'vnet', 'subnet', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--vnet-name', "$($settings.NAME_PREFIX)-vnet",
        '--name', 'snet-host', '--query', 'id', '--output', 'tsv')).Output
    if (-not $id) { throw 'Foundation host subnet ID is unavailable.' }
    return $id
}

function Wait-HostAgent {
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $common = @('vm', 'get-instance-view', '--resource-group',
            $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host")
        $power = Get-AzValue ($common + @('--query',
            "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]", '--output', 'tsv'))
        $agent = Get-AzValue ($common + @('--query',
            'instanceView.vmAgent.statuses[0].code', '--output', 'tsv'))
        if ($power -eq 'PowerState/running' -and $agent -eq 'ProvisioningState/succeeded') { return }
        if ($attempt -eq 60) { throw "Timed out waiting for VM agent on $($settings.NAME_PREFIX)-host." }
        Start-Sleep -Seconds 15
    }
}

function Invoke-Deployment {
    param([string]$Name, [string]$Template, [hashtable]$Parameters, [switch]$NoWait,
        [switch]$AllowFailure)
    $parameterFile = New-LabParameterFile $Parameters
    try {
        $id = ($stageNames.GetEnumerator() | Where-Object Value -eq $Template | Select-Object -First 1).Key
        if ($Template -in @('ssms', 'arc-launchers', 'bastion', 'sql-media')) { $id = $Template }
        $script:dashboardCurrentStage = $id
        if ($script:dashboardInitialized -and $id) {
            [void](Write-LabDashboardStage -Settings $settings -Stage $id -Status running `
                -Detail 'Submitting the saved Bicep deployment.' -Attempt $Parameters.runId)
        }
        $arguments = @('deployment', 'group', 'create', '--name', $Name,
            '--resource-group', $settings.AZURE_RESOURCE_GROUP, '--template-file',
            (Join-Path $repoRoot "infra/stages/$Template/main.bicep"),
            '--parameters', "@$parameterFile", '--output', 'table')
        if ($NoWait) { $arguments += @('--no-wait') }
        if ($AllowFailure) {
            $allowedResult = Invoke-LabAz $arguments -AllowFailure
            if ($script:dashboardInitialized -and $id) {
                [void](Write-LabDashboardStage -Settings $settings -Stage $id `
                    -Status $(if ($allowedResult.Success) { 'submitted' } else { 'failed' }) `
                    -Detail $(if ($allowedResult.Success) { 'Submitted independently; no completion gate.' } else { 'Optional deployment submission failed.' }))
            }
            $script:dashboardCurrentStage = ''
            return $allowedResult
        }
        $result = Invoke-LabAz $arguments
        if ($result.Output) { Write-Host $result.Output }
        if ($Template -eq '00-foundation' -and $script:dashboardInitialized) {
            [void](Write-LabDashboardStage -Settings $settings -Stage '00' -Status completed -Detail 'Foundation deployment passed.')
            $script:dashboardCurrentStage = ''
        }
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction Stop
    }
}

function Invoke-Bastion {
    Write-Host '==> Optional Bastion: submitting independently (not waiting for provisioning)'
    return Invoke-Deployment 'arc-jumpstart-bastion' 'bastion' @{
        location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
    } -NoWait -AllowFailure
}

function Invoke-AutoShutdown {
    Assert-Deployment '10'
    Write-Host "==> Optional auto-shutdown: $($settings.AUTO_SHUTDOWN_ENABLED) at $($settings.AUTO_SHUTDOWN_TIME) ($($settings.AUTO_SHUTDOWN_TIME_ZONE))"
    Invoke-Deployment 'arc-jumpstart-auto-shutdown' 'auto-shutdown' @{
        location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
        enabled = ($settings.AUTO_SHUTDOWN_ENABLED -eq 'true')
        shutdownTime = $settings.AUTO_SHUTDOWN_TIME
        timeZoneId = $settings.AUTO_SHUTDOWN_TIME_ZONE
    }
}

function Invoke-ArcLaunchers {
    Assert-Deployment '60'
    Write-Host '==> Arc launchers: preparing dedicated resource group and guest desktops'
    [void](Invoke-LabAz @('group', 'create', '--name', $arcResourceGroup,
        '--location', $arcLocation, '--tags',
        'ArcSQLServerExtensionDeployment=LicenseOnly', '--output', 'none'))
    Invoke-Deployment 'arc-jumpstart-arc-launchers' 'arc-launchers' @{
        location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
        subscriptionId = $settings.AZURE_SUBSCRIPTION_ID
        arcResourceGroup = $arcResourceGroup; arcLocation = $arcLocation
        nestedWindowsPassword = $settings.NESTED_WINDOWS_PASSWORD
        runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    }
    if ($script:dashboardInitialized) {
        [void](Write-LabDashboardStage -Settings $settings -Stage 'arc-launchers' -Status completed `
            -Detail 'Guest launchers staged successfully. Arc has not been connected.')
        $script:dashboardCurrentStage = ''
    }
}

function Invoke-HostSsms {
    Assert-Deployment '10'
    $previousStart = (Get-RunStatus 'stage-ssms').Split('|')
    $start = if ($previousStart.Count -ge 3) { $previousStart[2] } else { '' }
    Write-Host '==> Optional host SSMS 22: signed bootstrapper and minimal installation'
    Invoke-Deployment 'arc-jumpstart-ssms' 'ssms' @{
        location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
        runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    }
    Write-Host 'Waiting for the independent SSMS host installation to finish...'
    Wait-RunCommand 'stage-ssms' $start
}

function Get-SqlMediaFoundation {
    param([switch]$AllowLegacy)
    $json = (Invoke-LabAz @('deployment', 'group', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', 'arc-jumpstart-00-foundation',
        '--query', 'properties.outputs.sqlMedia.value', '--output', 'json')).Output
    $info = $json | ConvertFrom-Json -ErrorAction Stop
    if (-not $info -and $AllowLegacy) {
        Write-Host 'Legacy foundation has no private-media output; preserving its existing host-only recovery path.'
        return $null
    }
    if (-not $info -or $info.accountName -notmatch '^[a-z0-9]{3,24}$') {
        throw 'The private SQL media foundation is missing. Do not repair it with portal changes; deploy the saved foundation for this approved lab.'
    }
    return $info
}

function Invoke-SqlMedia {
    param([ValidateSet('prepare', 'check')][string]$Action)
    Assert-Deployment '10'
    $info = Get-SqlMediaFoundation
    Write-Host "SQL media target: $($info.accountName), resource group $($sqlSettings.ResourceGroup), container https://$($info.accountName).blob.core.windows.net/sql-media"
    if ($Action -eq 'prepare') {
        Write-Host "On $($settings.NAME_PREFIX)-host, use the desktop 'Upload licensed SQL media.cmd', or upload one Standard and one Enterprise ISO directly to the container root. Keep original Microsoft filenames or use SQL2025-Standard.iso and SQL2025-Enterprise.iso. The continuation creates a missing manifest."
    }
    $tenant = (Invoke-LabAz @('account', 'show', '--query', 'tenantId', '--output', 'tsv')).Output.Trim()
    $parameters = @{
        location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
        accountName = $info.accountName; tenantId = $tenant; action = $Action
        runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    }
    try {
        if ($Action -eq 'check') {
            $parameters.manifestWriteToken = (Invoke-LabAz @('account', 'get-access-token',
                '--resource', 'https://storage.azure.com/', '--query', 'accessToken', '--output', 'tsv')).Output.Trim()
            if (-not $parameters.manifestWriteToken) { throw 'The approved uploader Azure sign-in did not provide a storage token.' }
        }
        Invoke-Deployment 'arc-jumpstart-sql-media' 'sql-media' $parameters
        if ($script:dashboardInitialized) {
            [void](Write-LabDashboardStage -Settings $settings -Stage 'sql-media' `
                -Status $(if ($Action -eq 'check') { 'completed' } else { 'waiting' }) `
                -Detail $(if ($Action -eq 'check') { 'Licensed media validation passed.' } else { 'Waiting for authorized user media upload; no rebuild is required.' }))
            $script:dashboardCurrentStage = ''
        }
    }
    finally { $parameters.Remove('manifestWriteToken') | Out-Null }
}

function Invoke-Stage {
    param([string]$Number, [switch]$Defer)
    $previousStart = ''
    if ($Number -in @('30', '45')) {
        $status = Get-RunStatus $commandNames[$Number]
        $parts = $status.Split('|')
        if ($parts.Count -ge 3) { $previousStart = $parts[2] }
    }
    $parameters = @{
        location = $settings.AZURE_LOCATION
        namePrefix = $settings.NAME_PREFIX
        runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    }
    if ($Number -eq '10') {
        $hostExists = Invoke-LabAz @('vm', 'show', '--resource-group',
            $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host",
            '--output', 'none') -AllowFailure
        $parameters.hostSubnetId = Get-HostSubnetId
        $parameters.hostVmSize = Get-Setting 'HOST_VM_SIZE' 'Standard_E16s_v7'
        $parameters.windowsServerVersion = Get-LabWindowsServerVersion $settings
        $parameters.adminUsername = $settings.HOST_ADMIN_USERNAME
        $parameters.adminPassword = $settings.HOST_ADMIN_PASSWORD
        $parameters.dataDiskSizeGB = [int](Get-Setting 'HOST_DATA_DISK_SIZE_GB' '1024')
        $parameters.setStandardSecurityType = -not $hostExists.Success
        $mediaInfo = Get-SqlMediaFoundation -AllowLegacy:($sqlSettings.Mode -eq 'developer' -and $Stage -ne 'all')
        if ($mediaInfo) {
            $parameters.sqlMediaAccountName = $mediaInfo.accountName
            $parameters.sqlMediaResourceGroup = $sqlSettings.ResourceGroup
        }
    }
    if ($Number -eq '30') {
        $parameters.imageSourceUrl = Get-Setting 'IMAGE_SOURCE_URL' 'https://jumpstartprodsg.blob.core.windows.net/arcbox/prod'
        $parameters.imageFileNames = ('{0};{1}' -f
            (Get-Setting 'WINDOWS_IMAGE_FILE_NAME' 'ArcBox-Win2K22.vhdx'),
            $(if ($imageSettings.IncludeLinux) { Get-Setting 'LINUX_IMAGE_FILE_NAME' 'ArcBox-Ubuntu-01.vhdx' }))
        $parameters.imageSourceSasToken = Get-Setting 'IMAGE_SOURCE_SAS_TOKEN'
        $parameters.imageMode = $imageSettings.Mode
        if ($imageSettings.Mode -eq 'installation-media') {
            $parameters.windowsIsoUrl = $settings.WINDOWS_ISO_URL
            $parameters.windowsIsoSha256 = $settings.WINDOWS_ISO_SHA256
            $parameters.ubuntuIsoUrl = Get-Setting 'UBUNTU_ISO_URL'
            $parameters.ubuntuIsoSha256 = Get-Setting 'UBUNTU_ISO_SHA256'
            $parameters.linuxSshPublicKey = Get-Setting 'LINUX_SSH_PUBLIC_KEY'
            $parameters.nestedWindowsPassword = $settings.NESTED_WINDOWS_PASSWORD
        }
    }
    if ($Number -in @('40', '45', '50', '60')) {
        $parameters.nestedWindowsPassword = $settings.NESTED_WINDOWS_PASSWORD
    }
    if ($Number -eq '40') {
        $parameters.includeAppliance = $imageSettings.IncludeAppliance
        $parameters.windowsImageFileName = $imageSettings.WindowsFileName
        $parameters.linuxImageFileName = $imageSettings.LinuxFileName
        $parameters.windowsLicenseMode = $imageSettings.LicenseMode
        $parameters.imageMode = $imageSettings.Mode
        if ($imageSettings.Mode -eq 'installation-media') {
            $parameters.ubuntuIsoSha256 = Get-Setting 'UBUNTU_ISO_SHA256'
            $parameters.linuxSshPublicKey = Get-Setting 'LINUX_SSH_PUBLIC_KEY'
        }
    }
    if ($Number -in @('30', '40')) {
        $parameters.includeLinux = $imageSettings.IncludeLinux
        $parameters.windowsServerVersion = $imageSettings.WindowsServerVersion
    }
    if ($Number -eq '45') {
        $parameters.sqlSaPassword = $settings.SQL_SA_PASSWORD
        $parameters.sqlEditionMode = $sqlSettings.Mode
        if ($sqlSettings.Mode -eq 'licensed') {
            $parameters.sqlDownloadUrl = ''
            $parameters.sqlMediaAccountName = (Get-SqlMediaFoundation).accountName
        }
        else {
            Assert-LabSettings $settings @('SQL_DOWNLOAD_URL')
            $parameters.sqlDownloadUrl = $settings.SQL_DOWNLOAD_URL
        }
    }
    if ($Number -eq '50') { $parameters.safeModePassword = $settings.SAFE_MODE_PASSWORD }
    if ($Number -in @('50', '60')) {
        $parameters.sqlServiceAccountPassword = $settings.SQL_SERVICE_ACCOUNT_PASSWORD
    }
    Write-Host "==> Stage ${Number}: $($stageNames[$Number])"
    Invoke-Deployment "arc-jumpstart-$($stageNames[$Number])" $stageNames[$Number] $parameters
    $scriptNames = @{
        '10' = '10-init-host'; '20' = '20-host-network'
        '30' = '30-download-images'; '40' = '40-create-nested-vms'
        '45' = '45-install-sql'; '50' = '50-configure-domain'
        '60' = '60-configure-sql-ag'
    }
    Write-Host "Host transcript: C:\ArcJumpstart\Logs\$($scriptNames[$Number])-$($parameters.runId).log"
    if ($Number -eq '10') {
        Write-Host 'Restarting the Hyper-V host to activate the installed roles...'
        [void](Invoke-LabAz @('vm', 'restart', '--resource-group',
            $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host", '--output', 'none'))
        Wait-HostAgent
    }
    elseif ($Number -in @('30', '45')) {
        if ($Number -eq '30' -and $Defer) {
            $script:imagePreviousStart = $previousStart
            $script:imagesSubmitted = $true
            Write-Host 'Image downloads are running independently; configuring the nested network while they continue.'
        }
        else {
            Write-Host "Waiting for the stage $Number Run Command to complete..."
            Wait-RunCommand $commandNames[$Number] $previousStart
        }
    }
    if ($script:dashboardInitialized -and $Number -notin @('30', '45')) {
        [void](Write-LabDashboardStage -Settings $settings -Stage $Number -Status completed `
            -Detail $(if ($Number -eq '10') { 'Host initialization, controlled restart and VM-agent readiness passed.' }
                else { 'Synchronous host execution passed its stage readiness gates.' }))
        $script:dashboardCurrentStage = ''
    }
}

try {
    $settings = Read-LabSettings (Get-LabEnvironmentFile $repoRoot)
    $sqlSettings = Get-LabSqlSettings $settings
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION',
        'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if ($Stage -in @('all', 'continue', '45')) {
        Assert-LabSqlSaPassword $settings
    }
    if ($Stage -in @('all', 'os-only', 'continue', '20-30', '30', '40')) {
        $imageSettings = Get-LabImageSettings $settings
    }
    if ($Stage -notin @('bastion', 'auto-shutdown', 'ssms')) {
        Assert-LabSettings $settings @('HOST_ADMIN_USERNAME', 'HOST_ADMIN_PASSWORD',
            'NESTED_WINDOWS_PASSWORD', 'SAFE_MODE_PASSWORD', 'SQL_SERVICE_ACCOUNT_PASSWORD')
        foreach ($key in @('HOST_ADMIN_PASSWORD', 'SAFE_MODE_PASSWORD', 'SQL_SERVICE_ACCOUNT_PASSWORD')) {
            $value = $settings[$key]
            $classes = @(
                ($value -cmatch '[a-z]'), ($value -cmatch '[A-Z]'),
                ($value -match '[0-9]'), ($value -match '[^a-zA-Z0-9]')) |
                Where-Object { $_ }
            if ($value.Length -lt 8 -or @($classes).Count -lt 3) {
                throw "$key must be at least 8 characters and use at least three character classes."
            }
        }
        if ($Stage -in @('all', 'os-only') -and $settings.NESTED_WINDOWS_PASSWORD -cne 'JS123!!') {
            throw 'New lab guests use the fixed lab-only NESTED_WINDOWS_PASSWORD documented in deploy.env.example. Existing labs retain their saved credentials for recovery.'
        }
    }
    if ($Stage -in @('all', 'os-only', 'continue', 'auto-shutdown')) {
        Assert-LabSettings $settings @('AUTO_SHUTDOWN_ENABLED', 'AUTO_SHUTDOWN_TIME', 'AUTO_SHUTDOWN_TIME_ZONE')
        Assert-Choice 'AUTO_SHUTDOWN_ENABLED'
        if ($settings.AUTO_SHUTDOWN_TIME -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
            throw 'AUTO_SHUTDOWN_TIME must use 24-hour HHmm format.'
        }
    }
    $arcResourceGroup = Get-Setting 'ARC_RESOURCE_GROUP' "$($settings.AZURE_RESOURCE_GROUP)-arc"
    $arcLocation = Get-Setting 'ARC_LOCATION' $settings.AZURE_LOCATION
    if ($Stage -eq 'arc-launchers' -or ($Stage -in @('all', 'continue') -and
        (Get-Setting 'PREPARE_ARC_LAUNCHERS' 'true') -eq 'true')) {
        if ($arcResourceGroup -eq 'CHANGEME' -or $arcLocation -eq 'CHANGEME') {
            throw 'ARC_RESOURCE_GROUP and ARC_LOCATION must be valid for arc-launchers.'
        }
    }
    foreach ($option in @('PREPARE_ARC_LAUNCHERS', 'DEPLOY_BASTION', 'INSTALL_HOST_SSMS')) {
        if ($settings[$option]) { Assert-Choice $option }
    }
    $env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    $identity = Invoke-LabAz @('account', 'show', '--query', 'user.type', '--output', 'tsv')
    if ($identity.Output -ne 'user') {
        throw 'This lab requires Azure CLI authentication as an interactive user.'
    }
    if ($Stage -in @('all', 'os-only')) {
        Assert-NewLabResourceGroups $settings
        if (-not $settings.SQL_MEDIA_RESOURCE_GROUP) {
            $mediaExists = (Invoke-LabAz @('group', 'exists', '--name', $sqlSettings.ResourceGroup,
                '--subscription', $settings.AZURE_SUBSCRIPTION_ID, '--output', 'tsv')).Output.Trim()
            if ($mediaExists -notin @('true', 'false')) { throw 'Could not determine whether the private media group exists.' }
            if ($mediaExists -eq 'true') {
                throw 'Private media group already exists. Approve reuse explicitly with SQL_MEDIA_RESOURCE_GROUP or choose a new root; no implicit reuse is allowed.'
            }
        }
    }
    if ($Stage -in @('all', 'os-only', '00')) {
        Write-Host 'Ensuring Microsoft.DataMigration is registered for later migration exercises...'
        [void](Invoke-LabAz @('provider', 'register', '--namespace', 'Microsoft.DataMigration',
            '--subscription', $settings.AZURE_SUBSCRIPTION_ID, '--wait', '--output', 'none'))
    }
    $script:dashboardInitialized = Write-LabDashboardStage -Settings $settings -NewBuild:($Stage -in @('all', 'os-only'))
    [void](Invoke-LabAz @('group', 'create', '--name', $settings.AZURE_RESOURCE_GROUP,
        '--location', $settings.AZURE_LOCATION, '--output', 'none'))
    if ($Stage -eq 'bastion') {
        Assert-Foundation
        $result = Invoke-Bastion
        if (-not $result.Success) { throw "Bastion submission failed (Azure CLI exit $($result.ExitCode))." }
        Write-Host 'Bastion request accepted. Azure will continue provisioning it; no build wait is required.'
        exit 0
    }
    if ($Stage -eq 'auto-shutdown') { Invoke-AutoShutdown; exit 0 }
    if ($Stage -eq 'arc-launchers') { Invoke-ArcLaunchers; exit 0 }
    if ($Stage -eq 'ssms') { Invoke-HostSsms; exit 0 }
    if ($Stage -eq 'sql-media') { Invoke-SqlMedia 'prepare'; exit 0 }
    if ($Stage -eq 'continue') {
        if ($sqlSettings.Mode -ne 'licensed') { throw 'continue is only for the licensed-media pause after stage 10.' }
        Assert-Deployment '10'
        $laterStages = @('20', '30', '40', '45', '50', '60') |
            ForEach-Object { "name=='arc-jumpstart-$($stageNames[$_])'" }
        $deploymentJson = (Invoke-LabAz @('deployment', 'group', 'list', '--resource-group',
            $settings.AZURE_RESOURCE_GROUP, '--query',
            "[?$($laterStages -join ' || ')].{name:name,state:properties.provisioningState}", '--output', 'json')).Output
        if (-not $deploymentJson.Trim().StartsWith('[')) {
            throw 'Cannot establish the licensed-media checkpoint from the deployment list.'
        }
        $later = @($deploymentJson | ConvertFrom-Json -ErrorAction Stop)
        if ($later.Count -eq 0) { $resumeNumbers = @('20', '30', '40', '45', '50', '60') }
        elseif ($later.Count -eq 3 -and @($later.name | Sort-Object -Unique).Count -eq 3 -and @($later | Where-Object {
                $_.name -notin @('arc-jumpstart-20-host-network', 'arc-jumpstart-30-images', 'arc-jumpstart-40-nested-vms') -or
                $_.state -ne 'Succeeded'
            }).Count -eq 0) {
            Assert-RunSucceeded 'stage30-images'
            $resumeNumbers = @('45', '50', '60')
        }
        else {
            throw 'The media continuation has already been used. Inspect the active/failed stage and use scoped recovery, not continue or all.'
        }
        Invoke-SqlMedia 'check'
    }

    $numbers = if ($Stage -eq 'all') { @('00', '10', '20', '30', '40', '45', '50', '60') }
        elseif ($Stage -eq 'os-only') { @('00', '10', '20', '30', '40') }
        elseif ($Stage -eq 'continue') { $resumeNumbers }
        elseif ($Stage -eq '20-30') { @('20', '30') } else { @($Stage) }
    foreach ($number in $numbers) {
        if ($number -eq '00') {
            Write-Host '==> Stage 00: foundation'
            $operatorId = ''
            if ($sqlSettings.AccountName) {
                [void](Invoke-LabAz @('storage', 'container-rm', 'show',
                    '--resource-group', $sqlSettings.ResourceGroup,
                    '--storage-account', $sqlSettings.AccountName, '--name', 'sql-media', '--output', 'none'))
                Write-Host "Reusing approved SQL media account $($sqlSettings.AccountName) in $($sqlSettings.ResourceGroup); its configuration and uploads will not be redeployed."
            }
            else {
                $operatorId = (Invoke-LabAz @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv')).Output.Trim()
                if ($operatorId -notmatch '^[a-fA-F0-9-]{36}$') { throw 'Cannot determine the signed-in upload user object ID.' }
                [void](Invoke-LabAz @('group', 'create', '--name', $sqlSettings.ResourceGroup,
                    '--location', $settings.AZURE_LOCATION, '--output', 'none'))
            }
            Invoke-Deployment 'arc-jumpstart-00-foundation' '00-foundation' @{
                location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
                sqlMediaResourceGroup = $sqlSettings.ResourceGroup; operatorObjectId = $operatorId
                existingSqlMediaAccountName = $sqlSettings.AccountName ?? ''
            }
            if ((Get-Setting 'DEPLOY_BASTION' 'true') -eq 'true') {
                $result = Invoke-Bastion
                if ($result.Success) {
                    $bastionNotice = 'Bastion submitted independently. The build does not monitor or wait for it.'
                }
                else {
                    $bastionNotice = 'WARNING: Optional Bastion submission failed; retry separately with deploy.ps1 bastion.'
                    Write-Warning $bastionNotice
                }
            }
        }
        elseif ($number -eq '20' -and $Stage -in @('all', 'os-only', 'continue', '20-30')) {
            Assert-Predecessors '30'
            Invoke-Stage '30' -Defer
            Assert-Predecessors '20'
            Invoke-Stage '20'
        }
        elseif ($number -eq '30' -and $imagesSubmitted) {
            Write-Host 'Joining the image download started alongside stage 20...'
            Wait-RunCommand 'stage30-images' $imagePreviousStart
            $imagesSubmitted = $false
        }
        else {
            Assert-Predecessors $number
            Invoke-Stage $number
            if ($number -eq '10' -and $Stage -in @('all', 'os-only')) {
                Invoke-AutoShutdown
                if ($sqlSettings.Mode -eq 'licensed') {
                    if ($sqlSettings.AccountName -and $Stage -eq 'all') {
                        Invoke-SqlMedia 'check'
                    }
                    else { Invoke-SqlMedia 'prepare' }
                    if ($Stage -eq 'all' -and -not $sqlSettings.AccountName) {
                        Write-Host 'NEEDS_LICENSED_MEDIA: the host and private storage are ready. Upload authorized pre-keyed SQL Server 2025 Standard and Enterprise ISOs with the desktop launcher or directly into the configured container root. The agent should guide the chosen route and verify/create the manifest with ./scripts/deploy.ps1 continue, never all. Exit 2 means waiting for user media, not a ready lab.'
                        exit 2
                    }
                }
            }
        }
    }
    if ($Stage -eq 'os-only') {
        Write-Host 'OS_IMAGE_TEST_READY: stages 00-40 completed, including guest setup and activation. SQL, domain promotion and Arc connection have not run. In licensed mode, upload media with the host launcher or directly to the configured container root, then use deploy.ps1 continue.'
    }
    if ($bastionNotice) { Write-Host $bastionNotice }
    if ($Stage -in @('all', 'continue')) {
        $optionalFailures = @()
        if ((Get-Setting 'INSTALL_HOST_SSMS' 'true') -eq 'true') {
            try { Invoke-HostSsms }
            catch {
                $optionalFailures += "Host SSMS: $($_.Exception.Message)"
                Write-Warning "Host SSMS failed independently: $($_.Exception.Message)"
            }
        }
        if ((Get-Setting 'PREPARE_ARC_LAUNCHERS' 'true') -eq 'true') {
            try { Invoke-ArcLaunchers }
            catch {
                $optionalFailures += "Arc launchers: $($_.Exception.Message)"
                Write-Warning "Arc launchers failed independently: $($_.Exception.Message)"
            }
        }
        if ($optionalFailures.Count) {
            throw "Numbered stages finished, but optional host setup failed: $($optionalFailures -join '; '). Retry only the failed independent step."
        }
    }
}
catch {
    if ($script:dashboardInitialized -and $script:dashboardCurrentStage) {
        [void](Write-LabDashboardStage -Settings $settings -Stage $script:dashboardCurrentStage -Status failed `
            -Detail $_.Exception.Message)
    }
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($imagesSubmitted) {
        Write-Warning 'Stage 30 may outlive this wrapper. Inspect stage30-images before retrying.'
    }
}
