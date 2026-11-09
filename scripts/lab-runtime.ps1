function Get-LabEnvironmentFile {
    param([string]$RepositoryRoot)
    if ($env:ENV_FILE) { return $env:ENV_FILE }
    return Join-Path $RepositoryRoot 'deploy.env'
}

function Read-LabSettings {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing configuration file at $Path. Set ENV_FILE to the private environment file path."
    }
    $settings = @{}
    $allowed = @(
        'AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'RESOURCE_GROUP_ROOT', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX',
        'HOST_ADMIN_USERNAME', 'HOST_ADMIN_PASSWORD', 'NESTED_WINDOWS_PASSWORD',
        'SAFE_MODE_PASSWORD', 'SQL_SERVICE_ACCOUNT_PASSWORD', 'SQL_SA_PASSWORD', 'DEPLOY_BASTION',
        'AUTO_SHUTDOWN_ENABLED', 'AUTO_SHUTDOWN_TIME', 'AUTO_SHUTDOWN_TIME_ZONE',
        'PREPARE_ARC_LAUNCHERS', 'INSTALL_HOST_SSMS', 'ARC_RESOURCE_GROUP', 'ARC_LOCATION',
        'HOST_VM_SIZE', 'HOST_DATA_DISK_SIZE_GB', 'IMAGE_SOURCE_URL',
        'IMAGE_SOURCE_SAS_TOKEN', 'WINDOWS_IMAGE_FILE_NAME', 'LINUX_IMAGE_FILE_NAME',
        'IMAGE_MODE', 'INCLUDE_LINUX', 'INCLUDE_APPLIANCE_VM', 'WINDOWS_SERVER_VERSION',
        'SQL_MEDIA_ACCOUNT_NAME',
        'WINDOWS_ISO_URL', 'WINDOWS_ISO_SHA256',
        'UBUNTU_ISO_URL', 'UBUNTU_ISO_SHA256', 'LINUX_SSH_PUBLIC_KEY',
        'SQL_EDITION_MODE', 'SQL_MEDIA_RESOURCE_GROUP',
        'SQL_DOWNLOAD_URL')
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if (-not $line.Trim() -or $line.StartsWith('#')) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw "Invalid configuration line: expected KEY=value." }
        $key = $line.Substring(0, $separator)
        if ($key -notmatch '^[A-Z][A-Z0-9_]*$') { throw "Invalid configuration key in $Path." }
        if ($key -cnotin $allowed) { throw "Unknown configuration key: $key." }
        if ($settings.ContainsKey($key)) { throw "Duplicate configuration key: $key." }
        $settings[$key] = $line.Substring($separator + 1)
    }
    if ($settings.ContainsKey('RESOURCE_GROUP_ROOT')) {
        $root = $settings.RESOURCE_GROUP_ROOT
        if (-not $root -or $root -eq 'CHANGEME' -or $root.Length -gt 84 -or
            $root -notmatch '^[\p{L}\p{Nd}_().-]+(?<!\.)$' -or
            $root -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
            throw 'RESOURCE_GROUP_ROOT must be a valid cross-platform name of 1-84 characters, not ending in a period.'
        }
        foreach ($entry in @{ AZURE_RESOURCE_GROUP = "$root-infra"; ARC_RESOURCE_GROUP = "$root-arc" }.GetEnumerator()) {
            if ($settings[$entry.Key] -and $settings[$entry.Key] -ne $entry.Value) {
                throw "$($entry.Key) conflicts with RESOURCE_GROUP_ROOT. Expected $($entry.Value)."
            }
            $settings[$entry.Key] = $entry.Value
        }
    }
    return $settings
}

function Assert-NewLabResourceGroups {
    param([Parameter(Mandatory)][hashtable]$Settings)
    $arcGroup = if ($Settings.ARC_RESOURCE_GROUP) {
        $Settings.ARC_RESOURCE_GROUP
    } else { "$($Settings.AZURE_RESOURCE_GROUP)-arc" }
    $existing = @()
    foreach ($group in @($Settings.AZURE_RESOURCE_GROUP, $arcGroup) | Select-Object -Unique) {
        $result = Invoke-LabAz @('group', 'exists', '--name', $group,
            '--subscription', $Settings.AZURE_SUBSCRIPTION_ID, '--output', 'tsv')
        switch ($result.Output.Trim()) {
            'true' { $existing += $group }
            'false' {}
            default { throw "Could not determine whether resource group $group exists." }
        }
    }
    if ($existing.Count) {
        throw "Resource groups already exist: $($existing -join ', '). Refusing a fresh deployment. Choose another root or use documented stage-specific recovery; do not rerun all."
    }
}

function Assert-LabSettings {
    param([hashtable]$Settings, [string[]]$Keys)
    foreach ($key in $Keys) {
        if (-not $Settings[$key] -or $Settings[$key] -eq 'CHANGEME') {
            throw "$key must be set in the private configuration file."
        }
    }
}

function New-LabSqlSaPassword {
    $bytes = [byte[]]::new(24)
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) }
    finally { $random.Dispose() }
    'Sa9!' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Assert-LabSqlSaPassword {
    param([Parameter(Mandatory)][hashtable]$Settings)
    Assert-LabSettings $Settings @('SQL_SA_PASSWORD')
    $password = $Settings.SQL_SA_PASSWORD
    if ($password -cnotmatch '^[A-Za-z0-9!@#$%&*+=?:.,_-]{32,128}$' -or
        $password -cnotmatch '[a-z]' -or $password -cnotmatch '[A-Z]' -or
        $password -notmatch '[0-9]' -or $password -notmatch '[!@#$%&*+=?:.,_-]') {
        throw 'SQL_SA_PASSWORD must be 32-128 characters with uppercase, lowercase, digits and punctuation from !@#$%&*+=?:.,_- (no spaces or quotes).'
    }
    foreach ($key in @('HOST_ADMIN_PASSWORD', 'NESTED_WINDOWS_PASSWORD', 'SAFE_MODE_PASSWORD', 'SQL_SERVICE_ACCOUNT_PASSWORD')) {
        if ($password -ceq $Settings[$key]) { throw "SQL_SA_PASSWORD must not reuse $key." }
    }
}

function Get-LabWindowsServerVersion {
    param([Parameter(Mandatory)][hashtable]$Settings)
    $version = if ($Settings.ContainsKey('WINDOWS_SERVER_VERSION')) { $Settings.WINDOWS_SERVER_VERSION } else { '2022' }
    if ($version -cnotin @('2022', '2025')) { throw 'WINDOWS_SERVER_VERSION must be 2022 or 2025.' }
    return $version
}

function Get-LabImageSettings {
    param([Parameter(Mandatory)][hashtable]$Settings)
    $mode = if ($Settings.IMAGE_MODE) { $Settings.IMAGE_MODE } else { 'jumpstart' }
    if ($mode -cnotin @('jumpstart', 'installation-media')) {
        throw 'IMAGE_MODE must be jumpstart or installation-media.'
    }
    $linux = if ($Settings.ContainsKey('INCLUDE_LINUX')) { $Settings.INCLUDE_LINUX } else { 'true' }
    if ($linux -cnotin @('true', 'false')) { throw 'INCLUDE_LINUX must be true or false.' }
    $includeLinux = $linux -ceq 'true'
    $appliance = if ($Settings.ContainsKey('INCLUDE_APPLIANCE_VM')) { $Settings.INCLUDE_APPLIANCE_VM } else { 'false' }
    if ($appliance -cnotin @('true', 'false')) { throw 'INCLUDE_APPLIANCE_VM must be true or false.' }
    $windowsVersion = Get-LabWindowsServerVersion $Settings
    if ($mode -eq 'jumpstart') {
        if ($windowsVersion -ne '2022') { throw 'Windows Server 2025 guests require IMAGE_MODE=installation-media; the Jumpstart source is Server 2022.' }
        return @{
            Mode = $mode
            IncludeLinux = $includeLinux
            IncludeAppliance = ($appliance -ceq 'true')
            WindowsServerVersion = $windowsVersion
            WindowsFileName = $(if ($Settings.WINDOWS_IMAGE_FILE_NAME) { $Settings.WINDOWS_IMAGE_FILE_NAME } else { 'ArcBox-Win2K22.vhdx' })
            LinuxFileName = $(if ($Settings.LINUX_IMAGE_FILE_NAME) { $Settings.LINUX_IMAGE_FILE_NAME } else { 'ArcBox-Ubuntu-01.vhdx' })
            LicenseMode = 'azure-kms'
        }
    }
    $urlKeys = @('WINDOWS_ISO_URL')
    $hashKeys = @('WINDOWS_ISO_SHA256')
    if ($includeLinux) {
        $urlKeys += 'UBUNTU_ISO_URL'
        $hashKeys += 'UBUNTU_ISO_SHA256'
        Assert-LabSettings $Settings @('LINUX_SSH_PUBLIC_KEY')
    }
    Assert-LabSettings $Settings ($urlKeys + $hashKeys)
    foreach ($key in $urlKeys) {
        $uri = $null
        if (-not [uri]::TryCreate($Settings[$key], [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) {
            throw "$key must be an absolute HTTPS download URL without embedded credentials or a fragment."
        }
    }
    foreach ($key in $hashKeys) {
        if ($key -eq 'WINDOWS_ISO_SHA256' -and $Settings[$key] -ceq 'auto') {
            $official = if ($windowsVersion -eq '2025') {
                'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us'
            } else { 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US' }
            if ($Settings.WINDOWS_ISO_URL -cne $official) {
                throw "Automatic Windows media verification is restricted to the official Windows Server $windowsVersion Evaluation source."
            }
            continue
        }
        if ($Settings[$key] -notmatch '^[a-fA-F0-9]{64}$') {
            throw "$key must be the approved media's 64-character SHA-256 checksum."
        }
    }
    if ($includeLinux -and $Settings.LINUX_SSH_PUBLIC_KEY -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( [^\r\n]*)?$') {
        throw 'LINUX_SSH_PUBLIC_KEY must contain one OpenSSH public key, never a private key.'
    }
    return @{
        Mode = $mode
        IncludeLinux = $includeLinux
        IncludeAppliance = ($appliance -ceq 'true')
        WindowsServerVersion = $windowsVersion
        WindowsFileName = "InstallationMedia/Windows-Server-$windowsVersion-Eval.vhdx"
        LinuxFileName = 'InstallationMedia/Ubuntu-22.04.vhdx'
        LicenseMode = 'evaluation'
    }
}

function Get-LabSqlSettings {
    param([hashtable]$Settings)
    $mode = if ($Settings.SQL_EDITION_MODE) { $Settings.SQL_EDITION_MODE } else { 'developer' }
    if ($mode -cnotin @('developer', 'licensed')) { throw 'SQL_EDITION_MODE must be developer or licensed.' }
    $group = if ($Settings.SQL_MEDIA_RESOURCE_GROUP) { $Settings.SQL_MEDIA_RESOURCE_GROUP }
        elseif ($Settings.RESOURCE_GROUP_ROOT) { "$($Settings.RESOURCE_GROUP_ROOT)-media" }
        else { "$($Settings.AZURE_RESOURCE_GROUP)-media" }
    if ($group.Length -gt 90 -or $group -notmatch '^[\p{L}\p{Nd}_().-]+(?<!\.)$') { throw 'Invalid SQL_MEDIA_RESOURCE_GROUP.' }
    if ($group -in @($Settings.AZURE_RESOURCE_GROUP, $Settings.ARC_RESOURCE_GROUP)) {
        throw 'SQL_MEDIA_RESOURCE_GROUP must be separate from the disposable infrastructure and Arc groups.'
    }
    $account = $Settings.SQL_MEDIA_ACCOUNT_NAME
    if ($account -and ($account -cnotmatch '^[a-z0-9]{3,24}$' -or
        -not $Settings.SQL_MEDIA_RESOURCE_GROUP)) {
        throw 'SQL_MEDIA_ACCOUNT_NAME requires an explicit SQL_MEDIA_RESOURCE_GROUP and a valid existing storage account name.'
    }
    @{ Mode = $mode; ResourceGroup = $group; AccountName = $account }
}

function Invoke-LabAz {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required on PATH.'
    }
    $global:LASTEXITCODE = 0
    $output = & az @Arguments 2>&1 | Out-String
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Azure CLI command failed (exit $exitCode): $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ')."
    }
    return @{ Success = ($exitCode -eq 0); ExitCode = $exitCode; Output = $output.TrimEnd() }
}

function Protect-LabPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory)
    if ($IsWindows) {
        $item = Get-Item -LiteralPath $Path
        $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl(
            $item, [System.Security.AccessControl.AccessControlSections]::Access)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existing in $acl.Access) {
            [void]$acl.RemoveAccessRuleSpecific($existing)
        }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $inheritance = if ($Directory) {
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        } else { [System.Security.AccessControl.InheritanceFlags]::None }
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        [System.IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
    }
    else {
        $mode = if ($Directory) { '700' } else { '600' }
        & chmod $mode $Path
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions on $Path." }
    }
}

function New-LabParameterFile {
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-jumpstart-{0}.json" -f [guid]::NewGuid())
    try {
        [void][System.IO.File]::Create($path).Dispose()
        Protect-LabPath $path
        $wrapped = @{}
        foreach ($key in $Parameters.Keys) { $wrapped[$key] = @{ value = $Parameters[$key] } }
        $document = @{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = $wrapped
        }
        [System.IO.File]::WriteAllText(
            $path, ($document | ConvertTo-Json -Depth 10),
            [System.Text.UTF8Encoding]::new($false))
        return $path
    }
    catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}
