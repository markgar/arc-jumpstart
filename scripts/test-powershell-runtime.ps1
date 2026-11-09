param([switch]$NetworkFailure, [switch]$ImageFailure,
    [switch]$BastionFailure, [switch]$BastionOnly,
    [switch]$DisableBastion, [switch]$DisableLaunchers,
    [switch]$ShutdownOnly, [switch]$MissingShutdown,
    [switch]$SsmsOnly, [switch]$DisableSsms, [switch]$SsmsFailure,
    [switch]$MigrationRegistrationFailure,
    [switch]$InstallationMedia,
    [ValidateSet('2022', '2025')][string]$WindowsVersion = '2025',
    [switch]$LicensedMedia, [switch]$ContinueMedia, [switch]$AlreadyContinued,
    [switch]$ReuseMedia, [switch]$MediaCheckFailure,
    [switch]$OsOnly, [switch]$PreparedOs,
    [ValidateSet('', 'infra', 'arc', 'media', 'error', 'invalid')][string]$ExistingTarget = '')

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
        'RESOURCE_GROUP_ROOT=mock'
        'NAME_PREFIX=mock'
        'HOST_ADMIN_USERNAME=mockadmin'
        'HOST_ADMIN_PASSWORD=FakeOnly-123!'
        'NESTED_WINDOWS_PASSWORD=JS123!!'
        'SAFE_MODE_PASSWORD=FakeOnly-123!'
        'SQL_SERVICE_ACCOUNT_PASSWORD=FakeOnly-123!'
        'SQL_SA_PASSWORD=TestsOnly!Aa123456789012345678901234'
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
    if ($DisableSsms) { $config += 'INSTALL_HOST_SSMS=false' }
    if ($MissingShutdown) {
        $config = @($config | Where-Object { $_ -notmatch '^AUTO_SHUTDOWN_ENABLED=' })
    }
    if ($InstallationMedia) {
        $config += @('IMAGE_MODE=installation-media', 'HOST_VM_SIZE=Standard_E16s_v7',
            "WINDOWS_SERVER_VERSION=$WindowsVersion", 'INCLUDE_APPLIANCE_VM=true',
            'WINDOWS_ISO_URL=https://example.invalid/windows.iso',
            "WINDOWS_ISO_SHA256=$('a' * 64)",
            'UBUNTU_ISO_URL=https://example.invalid/ubuntu.iso',
            "UBUNTU_ISO_SHA256=$('b' * 64)",
            'LINUX_SSH_PUBLIC_KEY=ssh-ed25519 YWJj test-key')
    }
    if ($LicensedMedia -or $ContinueMedia -or $OsOnly) { $config += 'SQL_EDITION_MODE=licensed' }
    if ($ReuseMedia) {
        $config += @('SQL_EDITION_MODE=licensed', 'SQL_MEDIA_RESOURCE_GROUP=mock-media',
            'SQL_MEDIA_ACCOUNT_NAME=sqlmediamock')
    }
    [System.IO.File]::WriteAllLines($env:ENV_FILE, $config)
    $settings = Read-LabSettings $env:ENV_FILE
    Assert-LabSqlSaPassword $settings
    foreach ($invalid in @('', 'CHANGEME', 'Short1!', ('a' * 52), ('A' * 52),
        ($settings.SQL_SA_PASSWORD + '"'), ($settings.SQL_SA_PASSWORD + ';'), ('Aa1!' + ('x' * 125)))) {
        $bad = $settings.Clone()
        $bad.SQL_SA_PASSWORD = $invalid
        $rejected = $false
        try { Assert-LabSqlSaPassword $bad } catch { $rejected = $true }
        if (-not $rejected) { throw 'An invalid shared sa password was accepted.' }
    }
    foreach ($key in @('HOST_ADMIN_PASSWORD','NESTED_WINDOWS_PASSWORD','SAFE_MODE_PASSWORD','SQL_SERVICE_ACCOUNT_PASSWORD')) {
        $bad = $settings.Clone()
        $bad[$key] = $bad.SQL_SA_PASSWORD
        $rejected = $false
        try { Assert-LabSqlSaPassword $bad } catch { $rejected = $true }
        if (-not $rejected) { throw 'Reusing another lab password for sa was accepted.' }
    }
    if ($settings.AUTO_SHUTDOWN_TIME_ZONE -ne 'Central Standard Time') {
        throw 'Literal configuration values were not preserved.'
    }
    $settingsFixture = Join-Path $directory 'settings.env'
    foreach ($root in @('custom-lab', ('a' * 84))) {
        [System.IO.File]::WriteAllLines($settingsFixture, @("RESOURCE_GROUP_ROOT=$root"))
        $derived = Read-LabSettings $settingsFixture
        if ($derived.AZURE_RESOURCE_GROUP -ne "$root-infra" -or
            $derived.ARC_RESOURCE_GROUP -ne "$root-arc") {
            throw 'Root-based settings did not derive fixed resource group suffixes.'
        }
    }
    foreach ($invalid in @('RESOURCE_GROUP_ROOT=', 'RESOURCE_GROUP_ROOT=CHANGEME',
        'RESOURCE_GROUP_ROOT=../escape', 'RESOURCE_GROUP_ROOT=CON',
        "RESOURCE_GROUP_ROOT=$('a' * 85)",
        "RESOURCE_GROUP_ROOT=custom`nAZURE_RESOURCE_GROUP=wrong",
        "RESOURCE_GROUP_ROOT=custom`nARC_RESOURCE_GROUP=wrong")) {
        [System.IO.File]::WriteAllText($settingsFixture, $invalid)
        $rejected = $false
        try { [void](Read-LabSettings $settingsFixture) }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'Invalid or conflicting root-based settings were accepted.' }
    }
    [System.IO.File]::WriteAllLines($settingsFixture, @(
        'AZURE_RESOURCE_GROUP=legacy-rg', 'ARC_RESOURCE_GROUP=legacy-arc'))
    $legacy = Read-LabSettings $settingsFixture
    if ($legacy.AZURE_RESOURCE_GROUP -ne 'legacy-rg' -or $legacy.ARC_RESOURCE_GROUP -ne 'legacy-arc') {
        throw 'Existing configurations must retain their original resource group names.'
    }
    $savedPath = $env:ENV_FILE
    & {
        New-Variable -Name HOME -Value (Join-Path $directory 'home') -Scope Local -Force
        $env:ENV_FILE = ''
        & (Join-Path $PSScriptRoot 'init-config.ps1') | Out-Null
        $defaultPath = Join-Path $HOME 'ArcJumpstart/rg-arc-jumpstart-v2.env'
        $defaultSettings = Read-LabSettings $defaultPath
        Assert-LabSqlSaPassword $defaultSettings
        if ($defaultSettings.SQL_SA_PASSWORD.Length -ne 52) { throw 'Generate a long private sa password for each new lab.' }
        if ($defaultSettings.AZURE_RESOURCE_GROUP -ne 'rg-arc-jumpstart-v2-infra' -or
            $defaultSettings.ARC_RESOURCE_GROUP -ne 'rg-arc-jumpstart-v2-arc' -or
            $defaultSettings.WINDOWS_SERVER_VERSION -cne '2025' -or
            $defaultSettings.IMAGE_MODE -cne 'installation-media' -or
            $defaultSettings.INCLUDE_APPLIANCE_VM -cne 'true' -or
            $defaultSettings.NESTED_WINDOWS_PASSWORD -cne 'JS123!!') {
            throw 'Default configuration must use the root for its filename and paired resource groups.'
        }
        $original = [System.IO.File]::ReadAllText($defaultPath)
        & (Join-Path $PSScriptRoot 'init-config.ps1') -ResourceGroupRoot 'second-lab' | Out-Null
        $secondPath = Join-Path $HOME 'ArcJumpstart/second-lab.env'
        $secondSettings = Read-LabSettings $secondPath
        Assert-LabSqlSaPassword $secondSettings
        if ($secondSettings.SQL_SA_PASSWORD -ceq $defaultSettings.SQL_SA_PASSWORD) {
            throw 'Separate labs must not share a generated sa password.'
        }
        if ($secondSettings.AZURE_RESOURCE_GROUP -ne 'second-lab-infra' -or
            $secondSettings.ARC_RESOURCE_GROUP -ne 'second-lab-arc' -or
            [System.IO.File]::ReadAllText($defaultPath) -ne $original) {
            throw 'A second root must create isolated targets without changing the first configuration.'
        }
        Add-Content -LiteralPath $secondPath -Value '# Preserve existing configuration'
        $second = [System.IO.File]::ReadAllText($secondPath)
        & (Join-Path $PSScriptRoot 'init-config.ps1') -ResourceGroupRoot 'second-lab' | Out-Null
        if ([System.IO.File]::ReadAllText($secondPath) -ne $second) {
            throw 'Root-based initialization overwrote an existing configuration.'
        }
        if (-not $IsWindows) {
            Assert-PrivateUnixMode $defaultPath
            Assert-PrivateUnixMode $secondPath
        }
        foreach ($invalidRoot in @('../escape', 'bad/name', 'bad\name', 'trailing.', '', ('a' * 85))) {
            $rejected = $false
            try {
                & (Join-Path $PSScriptRoot 'init-config.ps1') -ResourceGroupRoot $invalidRoot | Out-Null
            }
            catch { $rejected = $true }
            if (-not $rejected) { throw 'An invalid resource group root was accepted.' }
        }
    }
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
    $firstPath = $env:ENV_FILE
    $env:ENV_FILE = Join-Path (Split-Path -Parent $firstPath) 'second-lab.env'
    & (Join-Path $PSScriptRoot 'init-config.ps1') | Out-Null
    $secondText = [System.IO.File]::ReadAllText($env:ENV_FILE)
    if ([System.IO.File]::ReadAllText($firstPath) -ne $first -or
        [regex]::Replace($secondText, '(?m)^SQL_SA_PASSWORD=[^\r\n]*', '') -ne
        [regex]::Replace($first, '(?m)^SQL_SA_PASSWORD=[^\r\n]*', '') -or
        (Read-LabSettings $env:ENV_FILE).SQL_SA_PASSWORD -ceq (Read-LabSettings $firstPath).SQL_SA_PASSWORD) {
        throw 'Creating a second lab must preserve the first and change only its generated sa password.'
    }
    if ($IsWindows) {
        foreach ($path in @((Split-Path -Parent $env:ENV_FILE), $env:ENV_FILE)) {
            $acl = Get-Acl -LiteralPath $path
            if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object {
                $_.IdentityReference.Value -ne $owner
            }).Count) { throw "Second lab folder or file is not owner-only: $path" }
        }
    }
    else {
        Assert-PrivateUnixMode $env:ENV_FILE
    }
    $env:ENV_FILE = Join-Path (Split-Path -Parent $firstPath) 'custom-path.env'
    & (Join-Path $PSScriptRoot 'init-config.ps1') -ResourceGroupRoot 'custom-root' | Out-Null
    $customSettings = Read-LabSettings $env:ENV_FILE
    if ($customSettings.AZURE_RESOURCE_GROUP -ne 'custom-root-infra' -or
        $customSettings.ARC_RESOURCE_GROUP -ne 'custom-root-arc') {
        throw 'An explicit ENV_FILE must preserve the selected resource group root.'
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
            'account get-access-token --resource' { return 'FakeStorageToken' }
            'ad signed-in-user show' { return '11111111-1111-1111-1111-111111111111' }
            'group exists --name' {
                if ($ExistingTarget -eq 'error') {
                    $global:LASTEXITCODE = 1
                    return 'Mock resource group lookup failed.'
                }
                if ($ExistingTarget -eq 'invalid') { return 'unknown' }
                if ($name -eq "mock-$ExistingTarget") { return 'true' }
                return 'false'
            }
            'group create --name' {
                if ($ExistingTarget) { throw 'Collision gate allowed a resource group mutation.' }
                if ($ReuseMedia -and $name -eq 'mock-media') { throw 'Existing media resource group must not be redeployed.' }
                return ''
            }
            'storage container-rm show' {
                if (-not $ReuseMedia -or $call -notcontains 'sqlmediamock') {
                    throw 'Validate the explicitly approved existing container before referencing it.'
                }
                return ''
            }
            'deployment group create' {
                $global:LabTestDeployed.Add($name)
                $file = $call[([array]::IndexOf($call, '--parameters') + 1)].TrimStart('@')
                if (-not (Test-Path -LiteralPath $file)) { throw 'Parameter file was not available to Azure CLI.' }
                if ($name -eq 'arc-jumpstart-45-sql-install') {
                    $p = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
                    if ($p.sqlSaPassword.value -cne $settings.SQL_SA_PASSWORD) {
                        throw 'The single configured sa password must reach stage 45 for Developer and licensed media.'
                    }
                }
                if ($InstallationMedia) {
                    $parameters = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
                    if ($name -in @('arc-jumpstart-10-hyperv-host', 'arc-jumpstart-30-images', 'arc-jumpstart-40-nested-vms') -and
                        $parameters.windowsServerVersion.value -cne $WindowsVersion) {
                        throw 'The selected Windows version must reach the Marketplace host and both guest-image stages.'
                    }
                    if ($name -eq 'arc-jumpstart-30-images' -and
                        ($parameters.imageMode.value -ne 'installation-media' -or
                        $parameters.windowsIsoSha256.value -ne ('a' * 64) -or
                        $parameters.nestedWindowsPassword.value -cne 'JS123!!')) {
                        throw 'Installation media and protected credentials did not reach stage 30.'
                    }
                    if ($name -eq 'arc-jumpstart-40-nested-vms' -and
                        ($parameters.imageMode.value -ne 'installation-media' -or
                        $parameters.windowsLicenseMode.value -ne 'evaluation' -or
                        $parameters.windowsImageFileName.value -ne "InstallationMedia/Windows-Server-$WindowsVersion-Eval.vhdx" -or
                        $parameters.includeAppliance.value -ne $true -or
                        $parameters.linuxImageFileName.value -ne 'InstallationMedia/Ubuntu-22.04.vhdx')) {
                        throw 'Stage 40 did not consume the newly built media disks and evaluation licensing.'
                    }
                }
                if ($name -eq 'arc-jumpstart-auto-shutdown') {
                    $enabled = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters.enabled.value
                    if ($enabled -ne $false) { throw 'Shutdown decision did not reach Bicep.' }
                }
                if ($name -eq 'arc-jumpstart-00-foundation') {
                    $p = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
                    if ($p.sqlMediaResourceGroup.value -ne 'mock-media') { throw 'Private media must have a separate durable group.' }
                    if ($p.existingSqlMediaAccountName.value -cne $(if ($ReuseMedia) { 'sqlmediamock' } else { '' })) {
                        throw 'An existing media account must only be referenced with explicit approval.'
                    }
                }
                if ($name -eq 'arc-jumpstart-45-sql-install' -and $ContinueMedia) {
                    $p = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
                    if ($p.sqlEditionMode.value -ne 'licensed' -or
                        $p.sqlMediaAccountName.value -ne 'sqlmediamock' -or $p.sqlDownloadUrl.value) {
                        throw 'Licensed SQL mode must use the private account, not Developer downloads.'
                    }
                }
                if ($name -eq 'arc-jumpstart-sql-media') {
                    $p = (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).parameters
                    if (($ContinueMedia -or $ReuseMedia) -and $p.manifestWriteToken.value -ne 'FakeStorageToken') {
                        throw 'Root-upload registration requires an operator token in the protected parameter file.'
                    }
                    if (-not $ContinueMedia -and -not $ReuseMedia -and $p.PSObject.Properties.Name -contains 'manifestWriteToken') {
                        throw 'Staging the desktop uploader must not request a storage write token.'
                    }
                    if ($ReuseMedia -and $p.action.value -cne 'check') {
                        throw 'Reuse must verify existing media automatically, not request another upload.'
                    }
                    if ($MediaCheckFailure) {
                        $global:LASTEXITCODE = 9
                        return 'Mock shared-media validation failed.'
                    }
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
                if ($query -eq 'properties.outputs.sqlMedia.value') {
                    return '{"accountName":"sqlmediamock","accountId":"/mock/storage","containerId":"/mock/storage/container"}'
                }
                return 'Succeeded'
            }
            'deployment group list' {
                if ($AlreadyContinued) { return '[{"name":"arc-jumpstart-50-domain","state":"Succeeded"}]' }
                if ($PreparedOs) {
                    return '[{"name":"arc-jumpstart-20-host-network","state":"Succeeded"},{"name":"arc-jumpstart-30-images","state":"Succeeded"},{"name":"arc-jumpstart-40-nested-vms","state":"Succeeded"}]'
                }
                return '[]'
            }
            'network vnet show' { return 'Succeeded' }
            'vm show --resource-group' { $global:LASTEXITCODE = 1; return '' }
            'vm get-instance-view --resource-group' {
                if ($call -join ' ' -match 'PowerState/') { return 'PowerState/running' }
                return 'ProvisioningState/succeeded'
            }
            'vm run-command show' {
                $generation = @($global:LabTestDeployed | Where-Object {
                    $_ -in @('arc-jumpstart-30-images', 'arc-jumpstart-45-sql-install',
                        'arc-jumpstart-ssms')
                }).Count
                if ($SsmsFailure -and $name -eq 'stage-ssms' -and
                    $global:LabTestDeployed -contains 'arc-jumpstart-ssms') {
                    return "Failed|1|$generation"
                }
                if ($ImageFailure -and $name -eq 'stage30-images' -and $generation -gt 0) {
                    return "Failed|1|$generation"
                }
                return "Succeeded|0|$generation"
            }
            'provider show --namespace' { return 'Registered' }
            'provider register --namespace' {
                if ($ExistingTarget) { throw 'Collision gate allowed provider registration.' }
                if ($call -notcontains 'Microsoft.DataMigration' -or $call -notcontains '--wait' -or
                    $call -notcontains '--subscription' -or $call -notcontains 'mock-sub') {
                    throw 'Migration registration must wait and target the configured subscription.'
                }
                if ($MigrationRegistrationFailure) {
                    $global:LASTEXITCODE = 1
                    return 'Mock provider registration denied.'
                }
                return ''
            }
            'feature show --namespace' { return 'Registered' }
            'vm list-skus --location' {
                $query = $call[([array]::IndexOf($call, '--query') + 1)]
                if ($query -eq '[0].name') { return 'Standard_E16s_v7' }
                return ''
            }
            default { return '' }
        }
    }
    if ($BastionOnly -or $ShutdownOnly -or $SsmsOnly) {
        $stage = if ($BastionOnly) { 'bastion' } elseif ($SsmsOnly) { 'ssms' } else { 'auto-shutdown' }
        & (Join-Path $PSScriptRoot 'deploy.ps1') -Stage $stage
        if ($BastionFailure) { throw 'Failed Bastion submission unexpectedly succeeded.' }
        $expectedOnly = if ($BastionOnly) { 'arc-jumpstart-bastion' }
            elseif ($SsmsOnly) { 'arc-jumpstart-ssms' } else { 'arc-jumpstart-auto-shutdown' }
        if (@($global:LabTestDeployed).Count -ne 1 -or $global:LabTestDeployed[0] -ne $expectedOnly) {
            throw 'Independent action replayed numbered infrastructure stages.'
        }
        if (@($global:LabTestCalls | Where-Object { ($_ -join ' ') -match 'provider register' }).Count) {
            throw 'Independent action unexpectedly registered a provider.'
        }
        return
    }
    & (Join-Path $PSScriptRoot 'deploy.ps1') -Stage $(if ($ContinueMedia) { 'continue' } elseif ($OsOnly) { 'os-only' } else { 'all' })
    if ($OsOnly) {
        $expectedOs = 'arc-jumpstart-00-foundation|arc-jumpstart-bastion|arc-jumpstart-10-hyperv-host|arc-jumpstart-auto-shutdown|arc-jumpstart-sql-media|arc-jumpstart-30-images|arc-jumpstart-20-host-network|arc-jumpstart-40-nested-vms'
        if (($global:LabTestDeployed -join '|') -ne $expectedOs) { throw 'OS-only trial must run through stage 40 without SQL, domain or Arc setup.' }
        return
    }
    if ($LicensedMedia) {
        if ($LASTEXITCODE -ne 2 -or ($global:LabTestDeployed -join '|') -ne
            'arc-jumpstart-00-foundation|arc-jumpstart-bastion|arc-jumpstart-10-hyperv-host|arc-jumpstart-auto-shutdown|arc-jumpstart-sql-media') {
            throw 'Licensed mode must pause with exit 2 after host/media preparation, before all guest stages.'
        }
        $global:LASTEXITCODE = 0
        return
    }
    $registrationCalls = @($global:LabTestCalls | Where-Object { ($_ -join ' ') -match 'provider register' })
    if ($registrationCalls.Count -ne $(if ($ContinueMedia) { 0 } else { 1 })) {
        throw 'Full deployment must register DataMigration once.'
    }
    if ($NetworkFailure -or $ImageFailure) { throw 'Failed stage unexpectedly returned success.' }
    $names = @($global:LabTestDeployed)
    $expected = @('arc-jumpstart-00-foundation', 'arc-jumpstart-bastion',
        'arc-jumpstart-10-hyperv-host', 'arc-jumpstart-auto-shutdown',
        'arc-jumpstart-30-images', 'arc-jumpstart-20-host-network',
        'arc-jumpstart-40-nested-vms', 'arc-jumpstart-45-sql-install',
        'arc-jumpstart-50-domain', 'arc-jumpstart-60-sql-ag',
        'arc-jumpstart-ssms',
        'arc-jumpstart-arc-launchers')
    if ($ContinueMedia) {
        $expected = @('arc-jumpstart-sql-media') + @($expected | Where-Object {
            $_ -notin @('arc-jumpstart-00-foundation', 'arc-jumpstart-bastion',
                'arc-jumpstart-10-hyperv-host', 'arc-jumpstart-auto-shutdown')
        })
        if ($PreparedOs) {
            $expected = @($expected | Where-Object {
                $_ -notin @('arc-jumpstart-20-host-network', 'arc-jumpstart-30-images', 'arc-jumpstart-40-nested-vms')
            })
        }
    }
    if ($ReuseMedia) {
        $expected = $expected[0..3] + @('arc-jumpstart-sql-media') + $expected[4..($expected.Count - 1)]
    }
    if ($DisableBastion) { $expected = @($expected | Where-Object { $_ -ne 'arc-jumpstart-bastion' }) }
    if ($DisableLaunchers) { $expected = @($expected | Where-Object { $_ -ne 'arc-jumpstart-arc-launchers' }) }
    if ($DisableSsms) { $expected = @($expected | Where-Object { $_ -ne 'arc-jumpstart-ssms' }) }
    if ($names.Count -ne $expected.Count) {
        throw "Expected $($expected.Count) deployments, got $($names.Count)."
    }
    if (($names -join '|') -ne ($expected -join '|')) {
        throw "Stage order was incorrect: $($names -join ', ')."
    }
    $bastionCall = @($global:LabTestCalls | Where-Object {
        ($_ -join ' ') -match 'arc-jumpstart-bastion'
    })
    if ((($DisableBastion -or $ContinueMedia) -and $bastionCall.Count -ne 0) -or
        (-not $DisableBastion -and -not $ContinueMedia -and ($bastionCall.Count -ne 1 -or
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
    if (@($global:LabTestCalls | Where-Object { ($_ -join ' ') -match 'FakeStorageToken' }).Count) {
        throw 'A storage token appeared on the Azure CLI command line.'
    }
    if ($ContinueMedia -or $ReuseMedia) { return }
    if ($InstallationMedia) {
        $global:MediaDownloadChecks = [Collections.Generic.List[string]]::new()
        function Invoke-WebRequest {
            param($Uri, $Method, $TimeoutSec)
            $global:MediaDownloadChecks.Add([string]$Uri)
            @{ Headers = @{ 'Content-Length' = '1024' } }
        }
        & (Join-Path $PSScriptRoot 'preflight.ps1') -Profile infra
        if ($global:MediaDownloadChecks.Count -ne 3 -or
            @($global:MediaDownloadChecks | Where-Object { $_ -match 'jumpstartprodsg|arcbox' }).Count -or
            $global:MediaDownloadChecks -notcontains 'https://example.invalid/windows.iso' -or
            $global:MediaDownloadChecks -notcontains 'https://example.invalid/ubuntu.iso') {
            throw 'Media preflight must check only direct OS/SQL downloads, never Jumpstart storage.'
        }
        return
    }
    if ($BastionFailure -or $DisableBastion -or $DisableLaunchers -or $DisableSsms -or $SsmsFailure) { return }
    foreach ($case in @('LicensedMedia', 'ContinueMedia', 'OsOnly')) {
        $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath "-$case" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Licensed orchestration failed ($case): $result" }
        if ($case -eq 'OsOnly' -and ($result.IndexOf('OS_IMAGE_TEST_READY:') -lt $result.IndexOf('==> Stage 40:'))) {
            throw 'Never declare OS trial readiness before the stage-40 gates.'
        }
        $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ReuseMedia 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Reusing existing licensed SQL media failed: $result" }
        $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ReuseMedia -MediaCheckFailure 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or $failed -match '==> Stage (20|30|40|45):') {
            throw 'Invalid or unavailable shared media must stop the build before guest preparation.'
        }
    }
    $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ContinueMedia -PreparedOs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "OS-only trial continuation failed: $result" }
    $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ContinueMedia -AlreadyContinued 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $result -notmatch 'continuation has already been used' -or $result -match '==> Stage (00|10|40):') {
        throw 'A second media continuation must not replay preparation or promoted guests.'
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -MigrationRegistrationFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'Azure CLI command failed' -or $failed -match '==> Stage 00:') {
        throw 'Provider registration failure did not stop deployment before foundation.'
    }
    foreach ($target in @('infra', 'arc', 'media', 'error', 'invalid')) {
        $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -ExistingTarget $target 2>&1 | Out-String
        $expectedError = if ($target -in @('infra', 'arc')) { "Resource groups already exist: mock-$target" }
            elseif ($target -eq 'media') { 'Private media group already exists' }
            elseif ($target -eq 'error') { 'Azure CLI command failed (exit 1): group exists --name' }
            else { 'Could not determine whether resource group' }
        if ($LASTEXITCODE -eq 0 -or $failed -notmatch [regex]::Escape($expectedError) -or
            $failed -match '==> Stage 00:' -or $failed -match 'Collision gate allowed') {
            throw "Fresh-deployment resource group gate failed for $target."
        }
    }
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
        '-DisableSsms', '-BastionOnly', '-ShutdownOnly', '-SsmsOnly', '-InstallationMedia')) {
        $result = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath $mode 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "$mode regression failed: $result" }
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -BastionOnly -BastionFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'Bastion submission failed') {
        throw 'On-demand Bastion failure did not propagate.'
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -SsmsOnly -SsmsFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'stage-ssms ended in state Failed') {
        throw 'On-demand SSMS installation failure did not propagate.'
    }
    $failed = & (Get-Command pwsh).Source -NoProfile -File $PSCommandPath -SsmsFailure 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $failed -notmatch 'Numbered stages finished' -or
        $failed -notmatch '==> Arc launchers:') {
        throw 'Optional SSMS failure was hidden or prevented independent Arc launcher staging.'
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
    $global:LabTestCalls.Clear()
    & (Join-Path $PSScriptRoot 'preflight.ps1') -Profile infra
    if (@($global:LabTestCalls | Where-Object { $_ -contains 'Microsoft.DataMigration' }).Count) {
        throw 'Infrastructure preflight must allow deployment to register DataMigration.'
    }
    $global:LabTestCalls.Clear()
    & (Join-Path $PSScriptRoot 'preflight.ps1') -Profile full
    if (-not @($global:LabTestCalls | Where-Object {
        ($_ -join ' ') -match 'provider show --namespace Microsoft.DataMigration'
    }).Count -or @($global:LabTestCalls | Where-Object {
        ($_ -join ' ') -match 'provider register'
    }).Count) {
        throw 'Full preflight must check DataMigration without registering it.'
    }
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
