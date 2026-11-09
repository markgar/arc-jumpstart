[CmdletBinding()]
param(
    [string]$AccountName,
    [string]$TenantId,
    [string]$UploadScriptBase64,
    [ValidateSet('prepare', 'check')][string]$Action = 'prepare',
    [string]$ManifestWriteToken,
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# PRIVATE_SQL_MEDIA_HELPERS
# SQL_MEDIA_VALIDATION
$work = 'C:\ArcJumpstart\SqlMedia'
New-Item -ItemType Directory -Path $work -Force | Out-Null
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict SQL media preparation directory.' }
if ($Action -eq 'check') {
    $manifest = Initialize-PrivateSqlManifest -AccountName $AccountName -WorkDirectory $work -RunId $RunId -WriteToken $ManifestWriteToken
    Write-Host 'Licensed SQL upload manifest is readable using the host managed identity. Stage 45 will verify the downloaded ISO bytes and installed editions.'
    return
}
$azcopy = Join-Path $work 'Tools\azcopy.exe'
if (-not (Test-Path -LiteralPath $azcopy)) {
    $tools = Split-Path -Parent $azcopy
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $zip = Join-Path $tools 'azcopy.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $zip
    $extract = Join-Path $tools "azcopy-$RunId"
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    $binaries = @(Get-ChildItem -LiteralPath $extract -Filter azcopy.exe -Recurse)
    if ($binaries.Count -ne 1) { throw 'AzCopy archive did not contain exactly one executable.' }
    $signature = Get-AuthenticodeSignature $binaries[0].FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw 'AzCopy must have a valid Microsoft signature.'
    }
    Copy-Item -LiteralPath $binaries[0].FullName -Destination $azcopy
}
$desktop = Join-Path $env:PUBLIC 'Desktop'
@{
    ContainerUrl = "https://$AccountName.blob.core.windows.net/sql-media"
    TenantId = $TenantId; AzCopy = $azcopy
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $desktop 'SQL media target.json') -Encoding UTF8
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($UploadScriptBase64)) |
    Set-Content -LiteralPath (Join-Path $desktop 'Upload licensed SQL media.ps1') -Encoding UTF8
'@echo off', 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upload licensed SQL media.ps1"', 'pause' |
    Set-Content -LiteralPath (Join-Path $desktop 'Upload licensed SQL media.cmd') -Encoding ASCII
Write-Host "SQL media preparation ready. Use the Public Desktop upload launcher with authorized pre-keyed SQL Server 2025 Standard and Enterprise ISOs, or upload them directly to https://$AccountName.blob.core.windows.net/sql-media in the container root. Keep original Microsoft filenames or use SQL2025-Standard.iso and SQL2025-Enterprise.iso. The agent runs deploy.ps1 continue to verify or create the manifest."
