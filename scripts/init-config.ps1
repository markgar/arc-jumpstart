$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $path = if ($env:ENV_FILE) { $env:ENV_FILE } else {
        Join-Path (Join-Path $HOME 'ArcJumpstart') 'lab.env'
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
    Write-Host "Private configuration template created at $path; replace each CHANGEME without sharing the contents."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
