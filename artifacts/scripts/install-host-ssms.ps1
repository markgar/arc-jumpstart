[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunId)

$ErrorActionPreference = 'Stop'
$bootstrapperUrl = 'https://aka.ms/ssms/22/release/vs_SSMS.exe'
$desktop = Join-Path $env:PUBLIC 'Desktop'
$bootstrapper = Join-Path $desktop 'vs_SSMS.exe'
$protectedBootstrapper = Join-Path $env:ProgramFiles 'ArcJumpstart\SSMS22\vs_SSMS.exe'
$installPath = 'F:\ArcJumpstart\SSMS22'
$logRoot = 'C:\ArcJumpstart\Logs'
$rebootMarker = 'C:\ArcJumpstart\ssms-reboot-required.json'

function Assert-MicrosoftSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch '(^|, )O=Microsoft Corporation(,|$)') {
        throw "Invalid Microsoft Authenticode signature: $Path"
    }
}

function Assert-SsmsBootstrapper {
    param([string]$Path)
    Assert-MicrosoftSignature $Path
    $version = (Get-Item -LiteralPath $Path).VersionInfo
    # The SSMS 22 bootstrapper reports Visual Studio Installer major 18, not SSMS major 22.
    if ($version.OriginalFilename -ine 'vs_ssms.exe' -or
        $version.ProductName -ne 'Microsoft SQL Server Management Studio') {
        throw "Unexpected SSMS 22 bootstrapper identity: $Path"
    }
}

function Assert-DownloadUri {
    param([uri]$Uri)
    if ($Uri.Scheme -ne 'https' -or $Uri.UserInfo -or -not $Uri.IsDefaultPort -or
        $Uri.Host -notin @('aka.ms', 'download.microsoft.com', 'download.visualstudio.microsoft.com')) {
        throw 'SSMS bootstrapper redirect is not an approved Microsoft HTTPS endpoint.'
    }
}

function Save-SsmsBootstrapper {
    param([string]$Path)
    $current = [uri]$bootstrapperUrl
    $partial = "$Path.partial"
    try {
        for ($redirects = 0; $redirects -le 10; $redirects++) {
            Assert-DownloadUri $current
            $request = [Net.HttpWebRequest]::Create($current)
            $request.AllowAutoRedirect = $false
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            $response = $null
            try {
                $response = $request.GetResponse()
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    if (-not $response.Headers['Location']) { throw 'SSMS download redirect has no Location.' }
                    $current = [uri]::new($current, $response.Headers['Location'])
                    continue
                }
                Assert-DownloadUri $response.ResponseUri
                if ([int]$response.StatusCode -ne 200 -or
                    $response.ResponseUri.Host -notin @('download.microsoft.com', 'download.visualstudio.microsoft.com') -or
                    [uri]::UnescapeDataString($response.ResponseUri.Segments[-1]) -ine 'vs_SSMS.exe' -or
                    $response.ContentLength -gt 100MB) {
                    throw 'Unexpected SSMS bootstrapper download destination, status or length.'
                }
                $inputStream = $response.GetResponseStream()
                $outputStream = [IO.File]::Open($partial, 'Create', 'Write', 'None')
                try {
                    $buffer = [byte[]]::new(65536)
                    $received = [long]0
                    while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $received += $count
                        if ($received -gt 100MB) { throw 'SSMS bootstrapper exceeds the size limit.' }
                        $outputStream.Write($buffer, 0, $count)
                    }
                }
                finally {
                    $outputStream.Dispose()
                    $inputStream.Dispose()
                }
                if ($received -eq 0 -or ($response.ContentLength -ge 0 -and
                    $received -ne $response.ContentLength)) {
                    throw 'SSMS bootstrapper download is incomplete.'
                }
                Assert-SsmsBootstrapper $partial
                Move-Item -LiteralPath $partial -Destination $Path -Force
                return
            }
            finally {
                if ($response) { $response.Dispose() }
            }
        }
        throw 'SSMS bootstrapper exceeded the redirect limit.'
    }
    finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Get-InstalledSsms {
    $paths = @(
        (Join-Path $installPath 'Common7\IDE\Ssms.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft SQL Server Management Studio 22\Common7\IDE\Ssms.exe')
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Assert-MicrosoftSignature $path
            $version = (Get-Item -LiteralPath $path).VersionInfo
            if ($version.ProductMajorPart -ne 22 -or
                $version.ProductName -notmatch 'SQL Server Management Studio') {
                throw "Unexpected SSMS executable product/version at $path."
            }
            return $path
        }
    }
    return $null
}

New-Item -ItemType Directory -Path $logRoot, $desktop -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "install-host-ssms-$RunId.log") -Force
try {
    if (-not (Test-Path -LiteralPath 'F:\ArcJumpstart' -PathType Container)) {
        throw 'Persistent host data volume F:\ArcJumpstart is unavailable; run stage 10 first.'
    }
    if (Test-Path -LiteralPath $protectedBootstrapper) {
        Assert-SsmsBootstrapper $protectedBootstrapper
        Write-Host 'Verified cached SSMS 22 bootstrapper in protected Program Files.'
    }
    else {
        Write-Host 'Downloading SSMS 22 bootstrapper to protected Program Files.'
        New-Item -ItemType Directory -Path (Split-Path -Parent $protectedBootstrapper) -Force | Out-Null
        try { Save-SsmsBootstrapper $protectedBootstrapper }
        catch { throw "Official SSMS 22 bootstrapper download failed; no installer was executed: $($_.Exception.Message)" }
    }
    Copy-Item -LiteralPath $protectedBootstrapper -Destination $bootstrapper -Force
    Assert-SsmsBootstrapper $bootstrapper
    if ((Get-FileHash -LiteralPath $bootstrapper -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $protectedBootstrapper -Algorithm SHA256).Hash) {
        throw 'Public Desktop SSMS bootstrapper differs from the verified protected copy.'
    }
    Write-Host 'Verified SSMS 22 bootstrapper staged on host Public Desktop.'

    if (Test-Path -LiteralPath $rebootMarker) {
        $previousBoot = (Get-Content -LiteralPath $rebootMarker -Raw | ConvertFrom-Json).LastBootTicks
        $currentBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
        if (-not $previousBoot -or $previousBoot -eq $currentBoot) {
            throw 'SSMS setup requires a host reboot before use (exit 3010). Do not reboot while lab operations are active.'
        }
        Remove-Item -LiteralPath $rebootMarker -Force
    }
    $existing = Get-InstalledSsms
    if ($existing) {
        Write-Host "Verified existing SSMS 22: $existing"
        return
    }
    if (Test-Path -LiteralPath $installPath) {
        throw "SSMS install directory exists without a verified SSMS 22 executable: $installPath. Inspect the Visual Studio Installer logs before retrying."
    }
    if (@(Get-Process -Name 'vs_SSMS', 'setup', 'ssms' -ErrorAction SilentlyContinue).Count) {
        throw 'An SSMS/Visual Studio installer or SSMS process is active; do not start a competing install.'
    }
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $dataDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='F:'"
    if (-not $systemDrive -or $systemDrive.FreeSpace -lt 20GB -or
        -not $dataDrive -or $dataDrive.FreeSpace -lt 20GB) {
        throw 'SSMS installation needs at least 20 GiB free on both the system drive (shared components/cache) and F: (product). Bootstrapper remains on Public Desktop.'
    }
    Write-Host "Installing minimal SSMS 22 for all host users at $installPath. No host restart will be initiated."
    $process = Start-Process -FilePath $protectedBootstrapper -ArgumentList @(
        '--installPath', $installPath, '--quiet', '--wait', '--norestart'
    ) -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        @{ LastBootTicks = [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks } |
            ConvertTo-Json | Set-Content -LiteralPath $rebootMarker -Encoding utf8
        throw 'SSMS setup returned 3010: host reboot required before use. Do not reboot during active lab operations; arrange a scoped host restart and rerun deploy.ps1 ssms to verify.'
    }
    if ($process.ExitCode -ne 0) {
        throw "SSMS setup failed (exit $($process.ExitCode)). Bootstrapper remains on Public Desktop; inspect Visual Studio Installer logs before retrying."
    }
    $installed = Get-InstalledSsms
    if (-not $installed) { throw 'SSMS setup returned success but no signed SSMS 22 executable was found.' }
    Write-Host "Verified SSMS 22 for host users: $installed"
}
finally {
    Stop-Transcript
}
