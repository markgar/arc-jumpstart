[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# SQL_MEDIA_VALIDATION
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    return
}
$settings = Get-Content (Join-Path $PSScriptRoot 'SQL media target.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.Windows.Forms

function Select-LicensedIso {
    param([string]$Edition)
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = "Select licensed SQL Server 2025 $Edition ISO (pre-keyed media)"
        $dialog.Filter = 'SQL installation ISO (*.iso)|*.iso'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
            throw 'Media selection cancelled. Nothing is declared ready; run the launcher again when media is available.'
        }
        return $dialog.FileName
    }
    finally { $dialog.Dispose() }
}

$work = Join-Path $env:LOCALAPPDATA 'ArcJumpstartSqlMedia'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$entries = @()
foreach ($edition in @('Standard', 'Enterprise')) {
    $path = Select-LicensedIso $edition
    Test-LicensedSqlIso -Path $path
    $size = (Get-Item -LiteralPath $path).Length
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $entries += [pscustomobject]@{
        Edition = $edition; Path = $path; Name = "SQL2025-$edition-$hash.iso"
        Size = $size; Sha256 = $hash
    }
}
$azcopy = $settings.AzCopy
& $azcopy login --tenant-id $settings.TenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure user authentication failed; no upload readiness marker was published.' }
foreach ($entry in $entries) {
    & $azcopy copy $entry.Path "$($settings.ContainerUrl)/$($entry.Name)" --overwrite=false
    if ($LASTEXITCODE -ne 0) { throw "Upload failed for $($entry.Edition); no readiness manifest was published." }
}
$manifest = Join-Path $work 'manifest.json'
@{
    Version = 1
    Media = @($entries | Select-Object Edition, Name, Size, Sha256)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding UTF8
& $azcopy copy $manifest "$($settings.ContainerUrl)/manifest.json" --overwrite=true
if ($LASTEXITCODE -ne 0) { throw 'Could not publish the upload manifest. Do not start SQL installation.' }
Write-Host 'Licensed SQL media uploaded. Continue using the repository deployment command; installed editions will be verified, not assumed from filenames.'
