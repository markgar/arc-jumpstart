$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'configure-installation-media.ps1')
function Assert-Fails {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected error: $Message"
}
function Assert-NewLabResourceGroups {
    param($Settings)
    if ($script:occupied) { throw 'Existing lab cannot be reconfigured.' }
}
function Get-LabOperatorPublicKey {
    param($Path)
    $script:keyCalls++
    'ssh-ed25519 YWJj test-key'
}
$directory = Join-Path ([IO.Path]::GetTempPath()) "arc-config-media-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $path = Join-Path $directory 'lab.env'
    $original = @(
        'RESOURCE_GROUP_ROOT=test'
        'AZURE_SUBSCRIPTION_ID=test-sub'
        'HOST_ADMIN_USERNAME=testadmin'
        'HOST_ADMIN_PASSWORD=FakeHost$123!'
        'SAFE_MODE_PASSWORD=FakeDsrm$123!'
        'SQL_SERVICE_ACCOUNT_PASSWORD=FakeSql$123!'
        'NESTED_WINDOWS_PASSWORD=old'
        '# preserve this comment'
    ) -join "`n"
    [IO.File]::WriteAllText($path, $original)
    $script:keyCalls = 0; $script:occupied = $false
    Set-LabMediaConfiguration $path 'https://example.invalid/windows.iso' ('a' * 64) licensed
    $settings = Read-LabSettings $path
    if ($settings.NESTED_WINDOWS_PASSWORD -cne 'JS123!!' -or
        $settings.HOST_ADMIN_PASSWORD -cne 'FakeHost$123!' -or
        $settings.SQL_SERVICE_ACCOUNT_PASSWORD -cne 'FakeSql$123!' -or
        $settings.AZURE_RESOURCE_GROUP -ne 'test-infra' -or
        $settings.WINDOWS_SERVER_VERSION -cne '2025' -or
        $settings.INCLUDE_APPLIANCE_VM -cne 'true' -or
        $settings.IMAGE_MODE -ne 'installation-media' -or $settings.SQL_EDITION_MODE -ne 'licensed' -or
        [IO.File]::ReadAllText("$path.before-installation-media") -cne $original) {
        throw 'Fresh-media setup did not preserve targets/credentials and the original configuration.'
    }
    $prepared = [IO.File]::ReadAllText($path)
    Set-LabMediaConfiguration $path '' '' licensed
    if ([IO.File]::ReadAllText($path) -cne $prepared -or $script:keyCalls -ne 1) {
        throw 'Repeated preparation must preserve the password and operator key.'
    }
    $freshPath = Join-Path $directory 'new-defaults.env'
    [IO.File]::WriteAllText($freshPath, $original)
    Set-LabMediaConfiguration $freshPath '' '' developer
    $fresh = Read-LabSettings $freshPath
    if ($fresh.WINDOWS_SERVER_VERSION -cne '2025' -or
        $fresh.WINDOWS_ISO_URL -cne 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us' -or
        $fresh.NESTED_WINDOWS_PASSWORD -cne 'JS123!!') {
        throw 'Fresh default configuration must persist Server 2025 and matching official media.'
    }
    $legacyPath = Join-Path $directory 'legacy.env'
    [IO.File]::WriteAllText($legacyPath, "$original`nWINDOWS_SERVER_VERSION=2022`n")
    Set-LabMediaConfiguration $legacyPath '' '' developer
    $legacy = Read-LabSettings $legacyPath
    if ($legacy.WINDOWS_SERVER_VERSION -cne '2022' -or
        $legacy.WINDOWS_ISO_URL -cne 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US') {
        throw 'An explicit legacy version must select matching media, not the new Server 2025 source.'
    }
    $script:occupied = $true
    Assert-Fails { Set-LabMediaConfiguration $path '' '' licensed } 'Existing lab cannot'
    if ([IO.File]::ReadAllText($path) -cne $prepared) { throw 'Existing-lab refusal changed configuration.' }
    Write-Host 'Fresh installation-media configuration regressions passed.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
