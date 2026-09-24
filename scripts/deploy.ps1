param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('00', '10', '20', '30', '40', '45', '50', '60',
        '20-30', 'all', 'bastion', 'auto-shutdown', 'arc-launchers')]
    [string]$Stage
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

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
    return Get-AzValue @('vm', 'run-command', 'show', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--vm-name', "$($settings.NAME_PREFIX)-host",
        '--name', $Command, '--expand', 'instanceView', '--query',
        "[instanceView.executionState, to_string(instanceView.exitCode), instanceView.startTime] | join('|', @)",
        '--output', 'tsv')
}

function Assert-RunSucceeded {
    param([string]$Command)
    $status = Get-RunStatus $Command
    if ($status -notmatch '^Succeeded\|0\|') {
        throw "Run Command $Command has not completed successfully (status: $status)."
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
        if ($state -eq 'Succeeded') {
            if ($code -eq '0') { return }
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
        $arguments = @('deployment', 'group', 'create', '--name', $Name,
            '--resource-group', $settings.AZURE_RESOURCE_GROUP, '--template-file',
            (Join-Path $repoRoot "infra/stages/$Template/main.bicep"),
            '--parameters', "@$parameterFile", '--output', 'table')
        if ($NoWait) { $arguments += @('--no-wait') }
        if ($AllowFailure) { return Invoke-LabAz $arguments -AllowFailure }
        $result = Invoke-LabAz $arguments
        if ($result.Output) { Write-Host $result.Output }
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
        $parameters.adminUsername = $settings.HOST_ADMIN_USERNAME
        $parameters.adminPassword = $settings.HOST_ADMIN_PASSWORD
        $parameters.dataDiskSizeGB = [int](Get-Setting 'HOST_DATA_DISK_SIZE_GB' '1024')
        $parameters.setStandardSecurityType = -not $hostExists.Success
    }
    if ($Number -eq '30') {
        $parameters.imageSourceUrl = Get-Setting 'IMAGE_SOURCE_URL' 'https://jumpstartprodsg.blob.core.windows.net/arcbox/prod'
        $parameters.imageFileNames = ('{0};{1}' -f
            (Get-Setting 'WINDOWS_IMAGE_FILE_NAME' 'ArcBox-Win2K22.vhdx'),
            (Get-Setting 'LINUX_IMAGE_FILE_NAME' 'ArcBox-Ubuntu-01.vhdx'))
        $parameters.imageSourceSasToken = Get-Setting 'IMAGE_SOURCE_SAS_TOKEN'
    }
    if ($Number -in @('40', '45', '50', '60')) {
        $parameters.nestedWindowsPassword = $settings.NESTED_WINDOWS_PASSWORD
    }
    if ($Number -eq '40') {
        $parameters.windowsImageFileName = Get-Setting 'WINDOWS_IMAGE_FILE_NAME' 'ArcBox-Win2K22.vhdx'
        $parameters.linuxImageFileName = Get-Setting 'LINUX_IMAGE_FILE_NAME' 'ArcBox-Ubuntu-01.vhdx'
    }
    if ($Number -eq '45') {
        Assert-LabSettings $settings @('SQL_DOWNLOAD_URL')
        $parameters.sqlDownloadUrl = $settings.SQL_DOWNLOAD_URL
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
}

try {
    $settings = Read-LabSettings (Get-LabEnvironmentFile $repoRoot)
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION',
        'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if ($Stage -notin @('bastion', 'auto-shutdown')) {
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
    }
    if ($Stage -in @('all', 'auto-shutdown')) {
        Assert-LabSettings $settings @('AUTO_SHUTDOWN_ENABLED', 'AUTO_SHUTDOWN_TIME', 'AUTO_SHUTDOWN_TIME_ZONE')
        Assert-Choice 'AUTO_SHUTDOWN_ENABLED'
        if ($settings.AUTO_SHUTDOWN_TIME -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
            throw 'AUTO_SHUTDOWN_TIME must use 24-hour HHmm format.'
        }
    }
    $arcResourceGroup = Get-Setting 'ARC_RESOURCE_GROUP' "$($settings.AZURE_RESOURCE_GROUP)-arc"
    $arcLocation = Get-Setting 'ARC_LOCATION' $settings.AZURE_LOCATION
    if ($Stage -eq 'arc-launchers' -or ($Stage -eq 'all' -and
        (Get-Setting 'PREPARE_ARC_LAUNCHERS' 'true') -eq 'true')) {
        if ($arcResourceGroup -eq 'CHANGEME' -or $arcLocation -eq 'CHANGEME') {
            throw 'ARC_RESOURCE_GROUP and ARC_LOCATION must be valid for arc-launchers.'
        }
    }
    foreach ($option in @('PREPARE_ARC_LAUNCHERS', 'DEPLOY_BASTION')) {
        if ($settings[$option]) { Assert-Choice $option }
    }
    $env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    $identity = Invoke-LabAz @('account', 'show', '--query', 'user.type', '--output', 'tsv')
    if ($identity.Output -ne 'user') {
        throw 'This lab requires Azure CLI authentication as an interactive user.'
    }
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

    $numbers = if ($Stage -eq 'all') { @('00', '10', '20', '30', '40', '45', '50', '60') }
        elseif ($Stage -eq '20-30') { @('20', '30') } else { @($Stage) }
    foreach ($number in $numbers) {
        if ($number -eq '00') {
            Write-Host '==> Stage 00: foundation'
            Invoke-Deployment 'arc-jumpstart-00-foundation' '00-foundation' @{
                location = $settings.AZURE_LOCATION; namePrefix = $settings.NAME_PREFIX
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
        elseif ($number -eq '20' -and $Stage -in @('all', '20-30')) {
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
            if ($number -eq '10' -and $Stage -eq 'all') { Invoke-AutoShutdown }
        }
    }
    if ($bastionNotice) { Write-Host $bastionNotice }
    if ($Stage -eq 'all' -and (Get-Setting 'PREPARE_ARC_LAUNCHERS' 'true') -eq 'true') {
        Invoke-ArcLaunchers
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($imagesSubmitted) {
        Write-Warning 'Stage 30 may outlive this wrapper. Inspect stage30-images before retrying.'
    }
}
