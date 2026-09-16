[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ImageSourceUrl,

    [Parameter(Mandatory)]
    [string]$ImageFileNames,

    [string]$ImageSourceSasToken = '',

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

try {
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
    Stop-Transcript
}
