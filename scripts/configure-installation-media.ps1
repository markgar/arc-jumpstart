[CmdletBinding()]
param(
    [string]$WindowsIsoUrl = '',
    [string]$WindowsIsoSha256 = '',
    [ValidateSet('developer', 'licensed')][string]$SqlEditionMode = 'developer'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

function Get-LabOperatorPublicKey {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -xor (Test-Path -LiteralPath "$Path.pub")) {
        throw 'An incomplete operator SSH key pair exists. Preserve it and diagnose before configuration.'
    }
    $keygen = Get-Command ssh-keygen -CommandType Application -ErrorAction Stop
    $start = [Diagnostics.ProcessStartInfo]::new($keygen.Source)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $true
    $existing = Test-Path -LiteralPath $Path
    $arguments = if ($existing) { @('-y', '-P', '', '-f', $Path) }
        else { @('-q', '-t', 'ed25519', '-N', '', '-C', 'arc-jumpstart-operator', '-f', $Path) }
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Operator SSH key creation/verification failed. Existing key files are preserved.' }
        if ($existing -and (($output.Trim() -split ' ')[0..1] -join ' ') -cne
            (((Get-Content -LiteralPath "$Path.pub" -Raw).Trim() -split ' ')[0..1] -join ' ')) {
            throw 'The existing operator SSH public/private key pair does not match.'
        }
    }
    finally { $process.Dispose() }
    Protect-LabPath $Path
    Protect-LabPath "$Path.pub"
    return (Get-Content -LiteralPath "$Path.pub" -Raw).Trim()
}

function Set-LabMediaConfiguration {
    param([string]$Path, [string]$IsoUrl, [string]$IsoSha256,
        [string]$SqlMode)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Use an absolute external ENV_FILE path.' }
    $repo = Split-Path -Parent $PSScriptRoot
    if ([IO.Path]::GetFullPath($Path).StartsWith(
            [IO.Path]::GetFullPath($repo) + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep ENV_FILE outside the repository.' }
    $original = [IO.File]::ReadAllText($Path)
    $settings = Read-LabSettings $Path
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP',
        'HOST_ADMIN_USERNAME', 'HOST_ADMIN_PASSWORD', 'SAFE_MODE_PASSWORD',
        'SQL_SERVICE_ACCOUNT_PASSWORD')
    Assert-NewLabResourceGroups $settings
    $defaults = Read-LabSettings (Join-Path $repo 'deploy.env.example')
    $windowsVersion = if ($settings.ContainsKey('WINDOWS_SERVER_VERSION')) {
        Get-LabWindowsServerVersion $settings
    }
    elseif ($settings.WINDOWS_ISO_URL -and $settings.WINDOWS_ISO_URL -ne 'CHANGEME' -and
        $settings.WINDOWS_ISO_URL -cne $defaults.WINDOWS_ISO_URL) { '2022' }
    else { $defaults.WINDOWS_SERVER_VERSION }
    if ($IsoUrl -or $IsoSha256) {
        if (-not $IsoUrl -or -not $IsoSha256) { throw 'Supply both Windows ISO URL and SHA256 overrides.' }
    }
    elseif ($settings.WINDOWS_ISO_URL -and $settings.WINDOWS_ISO_URL -ne 'CHANGEME') {
        $IsoUrl = $settings.WINDOWS_ISO_URL
        $IsoSha256 = $settings.WINDOWS_ISO_SHA256
    }
    else {
        $IsoUrl = if ($windowsVersion -eq '2022') {
            'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
        } else { $defaults.WINDOWS_ISO_URL }
        $IsoSha256 = $defaults.WINDOWS_ISO_SHA256
    }
    $candidate = $settings.Clone()
    $candidate.IMAGE_MODE = 'installation-media'
    $candidate.SQL_EDITION_MODE = $SqlMode
    $candidate.WINDOWS_SERVER_VERSION = $windowsVersion
    if (-not $candidate.ContainsKey('INCLUDE_APPLIANCE_VM')) {
        $candidate.INCLUDE_APPLIANCE_VM = $defaults.INCLUDE_APPLIANCE_VM
    }
    $candidate.WINDOWS_ISO_URL = $IsoUrl
    $candidate.WINDOWS_ISO_SHA256 = $IsoSha256
    foreach ($key in @('UBUNTU_ISO_URL', 'UBUNTU_ISO_SHA256')) {
        if (-not $candidate[$key] -or $candidate[$key] -eq 'CHANGEME') { $candidate[$key] = $defaults[$key] }
    }
    $candidate.LINUX_SSH_PUBLIC_KEY = 'ssh-ed25519 YWJj validation-placeholder'
    [void](Get-LabImageSettings $candidate)
    [void](Get-LabSqlSettings $candidate)
    $candidate.NESTED_WINDOWS_PASSWORD = 'JS123!!'
    $folder = Split-Path -Parent $Path
    Protect-LabPath $folder -Directory
    Protect-LabPath $Path
    if ($settings.LINUX_SSH_PUBLIC_KEY -and $settings.LINUX_SSH_PUBLIC_KEY -ne 'CHANGEME') {
        $candidate.LINUX_SSH_PUBLIC_KEY = $settings.LINUX_SSH_PUBLIC_KEY
    }
    else {
        $keyPath = Join-Path $folder "$([IO.Path]::GetFileNameWithoutExtension($Path))-ubuntu-ed25519"
        $candidate.LINUX_SSH_PUBLIC_KEY = Get-LabOperatorPublicKey $keyPath
    }
    [void](Get-LabImageSettings $candidate)
    $content = $original
    foreach ($key in @('IMAGE_MODE', 'SQL_EDITION_MODE', 'WINDOWS_SERVER_VERSION', 'INCLUDE_APPLIANCE_VM',
        'WINDOWS_ISO_URL', 'WINDOWS_ISO_SHA256',
        'UBUNTU_ISO_URL', 'UBUNTU_ISO_SHA256', 'LINUX_SSH_PUBLIC_KEY', 'NESTED_WINDOWS_PASSWORD')) {
        $line = "$key=$($candidate[$key])"
        $pattern = "(?m)^$key=[^\r\n]*"
        if ([regex]::IsMatch($content, $pattern)) {
            $content = [regex]::Replace($content, $pattern,
                [Text.RegularExpressions.MatchEvaluator]{ param($match) $line })
        }
        else { $content = $content.TrimEnd("`r", "`n") + [Environment]::NewLine + $line + [Environment]::NewLine }
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.before-installation-media"
    try {
        [void][IO.File]::Open($temporary, 'CreateNew', 'Write', 'None').Dispose()
        Protect-LabPath $temporary
        [IO.File]::WriteAllText($temporary, $content)
        if ([IO.File]::ReadAllText($Path) -cne $original) { throw 'ENV_FILE changed during preparation; it has not been overwritten.' }
        if (-not (Test-Path -LiteralPath $backup)) {
            [void][IO.File]::Open($backup, 'CreateNew', 'Write', 'None').Dispose()
            Protect-LabPath $backup
            [IO.File]::WriteAllText($backup, $original)
        }
        [IO.File]::Move($temporary, $Path, $true)
        Write-Host "Installation-media configuration prepared at $Path. Original configuration retained at $backup. Secret values are not displayed."
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Set-LabMediaConfiguration -Path (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot)) `
            -IsoUrl $WindowsIsoUrl -IsoSha256 $WindowsIsoSha256 -SqlMode $SqlEditionMode
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
