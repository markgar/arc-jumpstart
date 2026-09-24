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
        'SAFE_MODE_PASSWORD', 'SQL_SERVICE_ACCOUNT_PASSWORD', 'DEPLOY_BASTION',
        'AUTO_SHUTDOWN_ENABLED', 'AUTO_SHUTDOWN_TIME', 'AUTO_SHUTDOWN_TIME_ZONE',
        'PREPARE_ARC_LAUNCHERS', 'INSTALL_HOST_SSMS', 'ARC_RESOURCE_GROUP', 'ARC_LOCATION',
        'HOST_VM_SIZE', 'HOST_DATA_DISK_SIZE_GB', 'IMAGE_SOURCE_URL',
        'IMAGE_SOURCE_SAS_TOKEN', 'WINDOWS_IMAGE_FILE_NAME', 'LINUX_IMAGE_FILE_NAME',
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
