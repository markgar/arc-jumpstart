[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ImageSourceUrl,

    [Parameter(Mandatory)]
    [string]$ImageFileNames,

    [string]$ImageSourceSasToken = '',

    [ValidateSet('jumpstart', 'installation-media')]
    [string]$ImageMode = 'jumpstart',
    [ValidateSet('true', 'false')][string]$IncludeLinux = 'true',
    [ValidateSet('2022', '2025')][string]$WindowsServerVersion = '2022',
    [string]$WindowsIsoUrl,
    [string]$WindowsIsoSha256,
    [string]$UbuntuIsoUrl,
    [string]$UbuntuIsoSha256,
    [string]$LinuxSshPublicKey,
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
$imageRoot = 'F:\ArcJumpstart\Images'
New-Item -ItemType Directory -Path $logRoot, $imageRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "30-download-images-$RunId.log") -Force

# IMAGE_MEDIA_HELPERS

$imageLock = $null
try {
    if ($ImageMode -eq 'installation-media') {
        $ImageStage = '30'
        Protect-ImageBuildDirectory 'F:\ArcJumpstart\Images\InstallationMedia'
        $imageLock = [IO.File]::Open('F:\ArcJumpstart\Images\InstallationMedia\build.lock', 'OpenOrCreate', 'ReadWrite', 'None')
        Initialize-InstallationMedia -WindowsUrl $WindowsIsoUrl -WindowsHash $WindowsIsoSha256 `
            -WindowsServerVersion $WindowsServerVersion `
            -IncludeLinux:($IncludeLinux -eq 'true') -UbuntuUrl $UbuntuIsoUrl -UbuntuHash $UbuntuIsoSha256 `
            -Password $NestedWindowsPassword -PublicKey $LinuxSshPublicKey
        Write-ImagePhase "Selected installation media prepared (IncludeLinux=$IncludeLinux); guest readiness checks run in stage 40."
        return
    }
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage30] Preparing the image cache and AzCopy."
    $azCopy = Join-Path $root 'Tools\azcopy.exe'
    if (-not (Test-Path $azCopy)) {
        $toolsRoot = Split-Path $azCopy
        New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
        $zipPath = Join-Path $env:TEMP 'azcopy.zip'
        $extractPath = Join-Path $env:TEMP 'azcopy'
        Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $zipPath
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        $downloadedExe = Get-ChildItem $extractPath -Filter azcopy.exe -Recurse | Select-Object -First 1
        if (-not $downloadedExe) {
            throw 'AzCopy was not present in the downloaded archive.'
        }
        Copy-Item $downloadedExe.FullName $azCopy -Force
    }

    $env:AZCOPY_BUFFER_GB = '4'
    foreach ($fileName in ($ImageFileNames -split ';' | Where-Object { $_ })) {
        $destination = Join-Path $imageRoot $fileName
        if (Test-Path $destination) {
            Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage30] Already present: $destination"
            continue
        }

        $source = "$($ImageSourceUrl.TrimEnd('/'))/$fileName"
        if (-not [string]::IsNullOrWhiteSpace($ImageSourceSasToken)) {
            $source = "${source}?$($ImageSourceSasToken.TrimStart('?'))"
        }
        $partialDestination = "$destination.partial"
        Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage30] Downloading $fileName"
        Remove-Item $partialDestination -Force -ErrorAction SilentlyContinue
        & $azCopy copy $source $partialDestination --check-length=true --overwrite=true --log-level=INFO
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $partialDestination)) {
            Remove-Item $partialDestination -Force -ErrorAction SilentlyContinue
            throw "AzCopy failed for $fileName with exit code $LASTEXITCODE."
        }
        Move-Item $partialDestination $destination -Force
        Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage30] Completed $fileName ($((Get-Item $destination).Length) bytes)."
    }

    Get-ChildItem $imageRoot -Filter *.vhdx |
        Select-Object Name, Length, LastWriteTime |
        Format-Table -AutoSize
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage30] Required image cache is ready."
}
finally {
    if ($imageLock) { $imageLock.Dispose() }
    Stop-Transcript
}
