param([switch]$NetworkFailure, [switch]$ImageFailure,
    [switch]$BastionFailure, [switch]$BastionOnly,
    [switch]$DisableBastion, [switch]$DisableLaunchers,
    [switch]$ShutdownOnly, [switch]$MissingShutdown)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

function Assert-PrivateUnixMode {
    param([string]$Path)
    $mode = if ($IsMacOS) { & stat -f '%Lp' $Path }
        else { & stat -c '%a' $Path }
    if ($LASTEXITCODE -ne 0 -or $mode -ne '600') {
        throw 'Sensitive file is not mode 600.'
    }
}

$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-jumpstart-test-{0}" -f [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$originalEnv = $env:ENV_FILE
try {
    $env:ENV_FILE = Join-Path $directory 'lab.env'
    $config = @(
        'AZURE_SUBSCRIPTION_ID=mock-sub'
        'AZURE_LOCATION=westus2'
        'AZURE_RESOURCE_GROUP=mock-rg'
        'NAME_PREFIX=mock'
        'HOST_ADMIN_USERNAME=mockadmin'
        'HOST_ADMIN_PASSWORD=FakeOnly-123!'
        'NESTED_WINDOWS_PASSWORD=FakeOnly-123!'
        'SAFE_MODE_PASSWORD=FakeOnly-123!'
        'SQL_SERVICE_ACCOUNT_PASSWORD=FakeOnly-123!'
        'AUTO_SHUTDOWN_ENABLED=false'
        'AUTO_SHUTDOWN_TIME=2200'
        'AUTO_SHUTDOWN_TIME_ZONE=Central Standard Time'
        'SQL_DOWNLOAD_URL=https://example.invalid/fake.iso'
    )
    if ($BastionOnly) {
        $config = @($config | Where-Object {
            $_ -notmatch '^(HOST_ADMIN_USERNAME|HOST_ADMIN_PASSWORD|NESTED_WINDOWS_PASSWORD|SAFE_MODE_PASSWORD|SQL_SERVICE_ACCOUNT_PASSWORD)='
        })
    }
    if ($DisableBastion) { $config += 'DEPLOY_BASTION=false' }
    if ($DisableLaunchers) { $config += 'PREPARE_ARC_LAUNCHERS=false' }
    if ($MissingShutdown) {
        $config = @($config | Where-Object { $_ -notmatch '^AUTO_SHUTDOWN_ENABLED=' })
    }
    [System.IO.File]::WriteAllLines($env:ENV_FILE, $config)
    $settings = Read-LabSettings $env:ENV_FILE
    if ($settings.AUTO_SHUTDOWN_TIME_ZONE -ne 'Central Standard Time') {
        throw 'Literal configuration values were not preserved.'
    }
    $savedPath = $env:ENV_FILE
    $env:ENV_FILE = Join-Path (Join-Path $directory 'private') 'lab.env'
    & (Join-Path $PSScriptRoot 'init-config.ps1') | Out-Null
    $first = [System.IO.File]::ReadAllText($env:ENV_FILE)
    & (Join-Path $PSScriptRoot 'init-config.ps1') | Out-Null
    if ([System.IO.File]::ReadAllText($env:ENV_FILE) -ne $first) {
        throw 'Configuration initialization overwrote an existing file.'
    }
    if ($IsWindows) {
        $configAcl = Get-Acl -LiteralPath $env:ENV_FILE
        if (-not $configAcl.AreAccessRulesProtected) {
            throw 'Configuration file inherits permissions.'
        }
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if (@($configAcl.Access | Where-Object {
            $_.IdentityReference.Value -ne $owner
        }).Count) { throw 'Configuration file grants access outside its owner.' }
    }
    else {
        Assert-PrivateUnixMode $env:ENV_FILE
    }
    $env:ENV_FILE = $savedPath
    $parameterFile = New-LabParameterFile @{
        location = 'westus2'; secret = 'FakeOnly-123!'
        enabled = $false; size = 1024
    }
    try {
        $json = Get-Content -LiteralPath $parameterFile -Raw | ConvertFrom-Json
        if ($json.parameters.secret.value -ne 'FakeOnly-123!' -or
            $json.parameters.enabled.value -ne $false -or
            $json.parameters.size.value -ne 1024) {
            throw 'Typed deployment parameters were not preserved.'
        }
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $parameterFile
            if ($acl.AreAccessRulesProtected -ne $true) { throw 'Parameter file inherits permissions.' }
        }
        else {
            Assert-PrivateUnixMode $parameterFile
        }
    }
    finally { Remove-Item -LiteralPath $parameterFile -Force }

    $global:LabTestCalls = [System.Collections.Generic.List[object]]::new()
    $global:LabTestDeployed = [System.Collections.Generic.List[string]]::new()
    function az {
        $call = @($args)
        $global:LabTestCalls.Add($call)
        $global:LASTEXITCODE = 0
        $key = $call[0..([math]::Min(2, $call.Count - 1))] -join ' '
        $name = if ($call -contains '--name') { $call[([array]::IndexOf($call, '--name') + 1)] } else { '' }
        switch ($key) {
            'account show --query' { return 'user' }
            'deployment group create' {
                $global:LabTestDeployed.Add($name)
                $file = $call[([array]::IndexOf($call, '--parameters') + 1)].TrimStart('@')
                if (-not (Test-Path -LiteralPath $file)) { throw 'Parameter file was not available to Azure CLI.' }
                if ($name -eq 'arc-jumpstart-auto-shutdown') {
                    $enabled = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters.enabled.value
                    if ($enabled -ne $false) { throw 'Shutdown decision did not reach Bicep.' }
                }
                if ($BastionFailure -and $name -eq 'arc-jumpstart-bastion') {
                    $global:LASTEXITCODE = 7
                    return 'Mock Bastion submission failed.'
                }
                if ($NetworkFailure -and $name -eq 'arc-jumpstart-20-host-network') {
                    $global:LASTEXITCODE = 8
                    return 'Mock network stage failed.'
                }
                return ''
            }
            'deployment group show' {
                $query = $call[([array]::IndexOf($call, '--query') + 1)]
                if ($query -eq 'properties.outputs.hostSubnetId.value') { return '/mock/subnet' }
                return 'Succeeded'
            }
            'network vnet show' { return 'Succeeded' }
            'vm show --resource-group' { $global:LASTEXITCODE = 1; return '' }
            'vm get-instance-view --resource-group' {
                if ($call -join ' ' -match 'PowerState/') { return 'PowerState/running' }
                return 'ProvisioningState/succeeded'
            }
            'vm run-command show' {
                $generation = @($global:LabTestDeployed | Where-Object {
                    $_ -eq 'arc-jumpstart-30-images' -or $_ -eq 'arc-jumpstart-45-sql-install'
                }).Count
                if ($ImageFailure -and $name -eq 'stage30-images' -and $generation -gt 0) {
                    return "Failed|1|$generation"
                }
                return "Succeeded|0|$generation"
            }
            'provider show --namespace' { return 'Registered' }
            'feature show --namespace' { return 'Registered' }
            'vm list-skus --location' {
                $query = $call[([array]::IndexOf($call, '--query') + 1)]
                if ($query -eq '[0].name') { return 'Standard_E16s_v7' }
                return ''
            }
            default { return '' }
        }
    }
    if ($BastionOnly -or $ShutdownOnly) {
        $stage = if ($BastionOnly) { 'bastion' } else { 'auto-shutdown' }
        & (Join-Path $PSScriptRoot 'deploy.ps1') -Stage $stage
        if ($BastionFailure) { throw 'Failed Bastion submission unexpectedly succeeded.' }
        $expectedOnly = if ($BastionOnly) { 'arc-jumpstart-bastion' } else { 'arc-jumpstart-auto-shutdown' }
        if (@($global:LabTestDeployed).Count -ne 1 -or $global:LabTestDeployed[0] -ne $expectedOnly) {
            throw 'Independent action replayed numbered infrastructure stages.'
        }
        return
    }
    & (Join-Path $PSScriptRoot 'deploy.ps1') -Stage all
    if ($NetworkFailure -or $ImageFailure) { throw 'Failed stage unexpectedly returned success.' }
    $names = @($global:LabTestDeployed)
    $expected = @('arc-jumpstart-00-foundation', 'arc-jumpstart-bastion',
        'arc-jumpstart-10-hyperv-host', 'arc-jumpstart-auto-shutdown',
        'arc-jumpstart-30-images', 'arc-jumpstart-20-host-network',
        'arc-jumpstart-40-nested-vms', 'arc-jumpstart-45-sql-install',
        'arc-jumpstart-50-domain', 'arc-jumpstart-60-sql-ag',
        'arc-jumpstart-arc-launchers')
    if ($DisableBastion) { $expected = @($expected | Where-Object { $_ -ne 'arc-jumpstart-bastion' }) }
    if ($DisableLaunchers) { $expected = @($expected | Where-Object { $_ -ne 'arc-jumpstart-arc-launchers' }) }
    if ($names.Count -ne $expected.Count) {
        throw "Expected $($expected.Count) deployments, got $($names.Count)."
    }
    if (($names -join '|') -ne ($expected -join '|')) {
        throw "Stage order was incorrect: $($names -join ', ')."
    }
    $bastionCall = @($global:LabTestCalls | Where-Object {
        ($_ -join ' ') -match 'arc-jumpstart-bastion'
    })
    if (($DisableBastion -and $bastionCall.Count -ne 0) -or
        (-not $DisableBastion -and ($bastionCall.Count -ne 1 -or
            $bastionCall[0] -notcontains '--no-wait'))) {
        throw 'Bastion must be submitted once without waiting.'
    }
    if ($BastionFailure -and $DisableBastion) { throw 'Invalid test combination.' }
    if ($BastionFailure -and $global:LabTestDeployed -notcontains 'arc-jumpstart-60-sql-ag') {
        throw 'Optional Bastion failure blocked the core build.'
    }
    if (@($global:LabTestCalls | Where-Object { ($_ -join ' ') -match 'FakeOnly-123!' }).Count) {
        throw 'A password appeared on the Azure CLI command line.'
    }
    if ($BastionFailure -or $DisableBastion -or $DisableLaunchers) { return }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -NetworkFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -match '==> Stage 40:' -or
        $failed -notmatch 'Stage 30 may outlive this wrapper') {
        throw 'Network failure did not prevent stage 40.'
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ImageFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -match '==> Stage 40:' -or
        $failed -notmatch 'Stage 30 may outlive this wrapper') {
        throw 'Image failure did not prevent stage 40.'
    }
    foreach ($mode in @('-BastionFailure', '-DisableBastion', '-DisableLaunchers',
        '-BastionOnly', '-ShutdownOnly')) {
        $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath $mode 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "$mode regression failed: $result" }
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -BastionOnly -BastionFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'Bastion submission failed') {
        throw 'On-demand Bastion failure did not propagate.'
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -MissingShutdown 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'AUTO_SHUTDOWN_ENABLED must be set') {
        throw 'Full deployment accepted an unspecified auto-shutdown decision.'
    }
    Add-Content -LiteralPath $env:ENV_FILE -Value @(
        'HOST_VM_SIZE=Standard_E16s_v7'
        'IMAGE_SOURCE_URL=https://example.invalid/images')
    function Invoke-WebRequest {
        param([string]$Uri, [string]$Method, [int]$TimeoutSec)
        if ($Method -ne 'Head') { throw 'Preflight must use HEAD requests.' }
        return @{ Headers = @{ 'Content-Length' = @('1024') } }
    }
    $previousCount = $global:LabTestDeployed.Count
    & (Join-Path $PSScriptRoot 'preflight.ps1') -Profile infra
    if ($global:LabTestDeployed.Count -ne $previousCount) {
        throw 'Infrastructure preflight created an Azure deployment.'
    }
    Write-Host 'PowerShell runtime regression checks passed.'
}
finally {
    $env:ENV_FILE = $originalEnv
    Remove-Item -LiteralPath $directory -Recurse -Force
    Remove-Variable LabTestCalls, LabTestDeployed -Scope Global -ErrorAction SilentlyContinue
}
