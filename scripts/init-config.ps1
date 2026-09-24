param(
    [ValidateLength(1, 84)]
    [ValidatePattern('^[\p{L}\p{Nd}_().-]+(?<!\.)$')]
    [string]$ResourceGroupRoot = 'rg-arc-jumpstart-v2'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ($ResourceGroupRoot -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
        throw 'ResourceGroupRoot must also be a valid cross-platform file name.'
    }
    $path = if ($env:ENV_FILE) { $env:ENV_FILE } else {
        Join-Path (Join-Path $HOME 'ArcJumpstart') "$ResourceGroupRoot.env"
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($path)) {
        throw 'ENV_FILE must be an absolute path outside the repository.'
    }
    if ([System.IO.Path]::GetFullPath($path).StartsWith(
        [System.IO.Path]::GetFullPath($repoRoot) + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Keep the private configuration outside the repository.'
    }
    if (Test-Path -LiteralPath $path) {
        Write-Host "Configuration already exists at $path; left unchanged."
        exit 0
    }
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) {
        [void](New-Item -ItemType Directory -Path $folder -Force)
    }
    Protect-LabPath $folder -Directory
    Copy-Item -LiteralPath (Join-Path $repoRoot 'deploy.env.example') -Destination $path -ErrorAction Stop
    Protect-LabPath $path
    $content = [System.IO.File]::ReadAllText($path)
    $content = [regex]::Replace($content, '(?m)^RESOURCE_GROUP_ROOT=[^\r\n]*',
        "RESOURCE_GROUP_ROOT=$ResourceGroupRoot")
    [System.IO.File]::WriteAllText($path, $content)
    Write-Host "Private configuration template created at $path; replace each CHANGEME without sharing the contents."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
