param([ValidateSet('infra', 'full')][string]$Profile = 'infra')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $settings = Read-LabSettings (Get-LabEnvironmentFile $repoRoot)
    Assert-LabSettings $settings @(
        'AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'HOST_VM_SIZE',
        'IMAGE_SOURCE_URL', 'SQL_DOWNLOAD_URL', 'AUTO_SHUTDOWN_ENABLED',
        'AUTO_SHUTDOWN_TIME', 'AUTO_SHUTDOWN_TIME_ZONE')
    if ($settings.AUTO_SHUTDOWN_ENABLED -cnotin @('true', 'false')) {
        throw 'AUTO_SHUTDOWN_ENABLED must be explicitly set to true or false.'
    }
    if ($settings.AUTO_SHUTDOWN_TIME -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
        throw 'AUTO_SHUTDOWN_TIME must use 24-hour HHmm format.'
    }

    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    $identity = Invoke-LabAz @('account', 'show', '--query', 'user.type', '--output', 'tsv')
    if ($identity.Output -ne 'user') { throw 'Sign in to Azure CLI as an interactive user.' }

    $failed = $false
    $providers = @(
        'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage',
        'Microsoft.Authorization', 'Microsoft.ManagedIdentity', 'Microsoft.DevTestLab')
    if ($Profile -eq 'full') {
        $providers += @(
            'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration',
            'Microsoft.HybridConnectivity', 'Microsoft.AzureArcData',
            'Microsoft.OffAzure', 'Microsoft.Migrate', 'Microsoft.Sql',
            'Microsoft.KeyVault', 'Microsoft.Insights')
        $graph = Invoke-LabAz @('extension', 'show', '--name', 'resource-graph', '--output', 'none') -AllowFailure
        if (-not $graph.Success) {
            Write-Warning 'Azure CLI extension missing: resource-graph (install with: az extension add --name resource-graph).'
            $failed = $true
        }
    }
    foreach ($provider in $providers) {
        $state = Invoke-LabAz @('provider', 'show', '--namespace', $provider,
            '--query', 'registrationState', '--output', 'tsv') -AllowFailure
        if ($state.Output -eq 'Registering') {
            Write-Host "Provider registration is propagating: $provider"
        }
        elseif ($state.Output -ne 'Registered' -or -not $state.Success) {
            Write-Warning "Provider not registered: $provider ($($state.Output))."
            $failed = $true
        }
    }
    $feature = Invoke-LabAz @('feature', 'show', '--namespace', 'Microsoft.Compute',
        '--name', 'UseStandardSecurityType', '--query', 'properties.state', '--output', 'tsv') -AllowFailure
    if ($feature.Output -eq 'Registering') {
        Write-Host 'Feature registration is propagating: Microsoft.Compute/UseStandardSecurityType'
    }
    elseif ($feature.Output -ne 'Registered' -or -not $feature.Success) {
        Write-Warning "Feature not registered: Microsoft.Compute/UseStandardSecurityType ($($feature.Output))."
        $failed = $true
    }
    $skuArgs = @('vm', 'list-skus', '--location', $settings.AZURE_LOCATION,
        '--resource-type', 'virtualMachines', '--size', $settings.HOST_VM_SIZE)
    $restriction = Invoke-LabAz ($skuArgs + @('--query',
        "[0].restrictions[?type == 'Location'].reasonCode", '--output', 'tsv')) -AllowFailure
    $available = Invoke-LabAz ($skuArgs + @('--query', '[0].name', '--output', 'tsv'))
    if (-not $restriction.Success) { throw 'Could not check VM SKU restrictions.' }
    if ($restriction.Output) {
        Write-Warning "$($settings.HOST_VM_SIZE) is restricted in $($settings.AZURE_LOCATION): $($restriction.Output)."
        $failed = $true
    }
    elseif (-not $available.Output) {
        Write-Warning "$($settings.HOST_VM_SIZE) is not available in $($settings.AZURE_LOCATION)."
        $failed = $true
    }

    $base = $settings.IMAGE_SOURCE_URL.TrimEnd('/')
    $token = if ($settings['IMAGE_SOURCE_SAS_TOKEN']) {
        $settings['IMAGE_SOURCE_SAS_TOKEN'].TrimStart('?')
    } else { '' }
    foreach ($name in @(
        $(if ($settings.WINDOWS_IMAGE_FILE_NAME) { $settings.WINDOWS_IMAGE_FILE_NAME } else { 'ArcBox-Win2K22.vhdx' }),
        $(if ($settings.LINUX_IMAGE_FILE_NAME) { $settings.LINUX_IMAGE_FILE_NAME } else { 'ArcBox-Ubuntu-01.vhdx' }),
        'SQL Server 2025 Enterprise Developer media source')) {
        $uri = if ($name -like 'SQL Server*') { $settings.SQL_DOWNLOAD_URL } else {
            "$base/$name" + $(if ($token) { "?$token" } else { '' })
        }
        try {
            $response = Invoke-WebRequest -Uri $uri -Method Head -TimeoutSec 30
            $size = [long]@($response.Headers['Content-Length'])[0]
            Write-Host ('Download reachable: {0} ({1:N1} GiB)' -f $name, ($size / 1GB))
        }
        catch {
            # Do not include the exception: HTTP errors may echo a SAS-bearing URL.
            Write-Warning "Download unavailable: $name ($($_.Exception.GetType().Name))."
            $failed = $true
        }
    }
    Write-Host "Cost gate: this lab can run a $($settings.HOST_VM_SIZE) VM, a 1-TiB Premium SSD,"
    Write-Host 'Azure Bastion, assessment collectors, and a temporary SQL Managed Instance.'
    Write-Host "Review current prices and quota in $($settings.AZURE_LOCATION) before deploying."
    if ($failed) { exit 1 }
    Write-Host "Azure target preflight completed for the $Profile profile."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
