$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../artifacts/scripts/install-host-ssms.ps1'
$source = Get-Content -LiteralPath $path -Raw
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Host SSMS script parse failed: $($errors.Message -join ', ')" }

function Get-SsmsFunction {
    param([string]$Name)
    $node = $ast.Find({
        param($item)
        $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing host SSMS function $Name" }
    return $node.Extent.Text
}
foreach ($name in @('Assert-MicrosoftSignature', 'Assert-SsmsBootstrapper', 'Assert-DownloadUri',
    'Save-SsmsBootstrapper', 'Get-InstalledSsms')) {
    . ([scriptblock]::Create((Get-SsmsFunction $name)))
}
function Assert-Fails {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing $Message"
}

foreach ($url in @('http://aka.ms/ssms/22/release/vs_SSMS.exe',
    'https://example.org/vs_SSMS.exe',
    'https://aka.ms:444/vs_SSMS.exe',
    'https://user:pass@aka.ms/vs_SSMS.exe',
    'https://download.visualstudio.microsoft.com.evil.org/vs_SSMS.exe')) {
    Assert-Fails { Assert-DownloadUri ([uri]$url) } 'approved Microsoft HTTPS'
}
Assert-DownloadUri ([uri]'https://aka.ms/ssms/22/release/vs_SSMS.exe')
Assert-DownloadUri ([uri]'https://download.visualstudio.microsoft.com/download/pr/vs_SSMS.exe')

if (-not (Get-SsmsFunction Save-SsmsBootstrapper).Contains('AllowAutoRedirect = $false') -or
    -not (Get-SsmsFunction Save-SsmsBootstrapper).Contains('Assert-SsmsBootstrapper $partial') -or
    -not (Get-SsmsFunction Save-SsmsBootstrapper).Contains('Move-Item -LiteralPath $partial') -or
    $source -notmatch 'Start-Process -FilePath \$protectedBootstrapper' -or
    $source -notmatch "'--quiet', '--wait', '--norestart'" -or
    $source -notmatch 'ExitCode -eq 3010' -or
    $source -notmatch 'LastBootTicks' -or
    $source -match 'Restart-Computer|Restart-VM|vm restart') {
    throw 'Host SSMS signature, redirect, synchronous install, or no-restart contract regressed.'
}

& {
    function Get-Item {
        param([string]$LiteralPath)
        return @{ VersionInfo = @{
            OriginalFilename = 'vs_ssms.exe'
            ProductName = 'Microsoft SQL Server Management Studio'
            ProductMajorPart = 18
        } }
    }
    function Get-AuthenticodeSignature {
        param([string]$FilePath)
        return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Microsoft, O=Microsoft Corporation, C=US' } }
    }
    Assert-SsmsBootstrapper 'C:\trusted\vs_SSMS.exe'
    function Get-Item {
        param([string]$LiteralPath)
        return @{ VersionInfo = @{
            OriginalFilename = 'vs_another.exe'
            ProductName = 'Microsoft SQL Server Management Studio'
            ProductMajorPart = 18
        } }
    }
    Assert-Fails { Assert-SsmsBootstrapper 'C:\unrelated\vs_SSMS.exe' } 'Unexpected SSMS 22 bootstrapper identity'
    function Get-Item {
        param([string]$LiteralPath)
        return @{ VersionInfo = @{
            OriginalFilename = 'vs_ssms.exe'
            ProductName = 'Unrelated Microsoft installer'
            ProductMajorPart = 18
        } }
    }
    Assert-Fails { Assert-SsmsBootstrapper 'C:\unrelated\vs_SSMS.exe' } 'Unexpected SSMS 22 bootstrapper identity'
    function Get-AuthenticodeSignature {
        param([string]$FilePath)
        return @{ Status = 'NotSigned'; SignerCertificate = @{ Subject = 'CN=Unknown' } }
    }
    Assert-Fails { Assert-SsmsBootstrapper 'C:\unsigned\vs_SSMS.exe' } 'Invalid Microsoft Authenticode signature'
}

& {
    $installPath = 'F:\ArcJumpstart\SSMS22'
    $env:ProgramFiles = 'C:\Program Files'
    function Join-Path {
        param([string]$Path, [string]$ChildPath)
        return "$($Path.TrimEnd('\'))\$ChildPath"
    }
    function Test-Path {
        param([string]$LiteralPath)
        return $LiteralPath -eq 'F:\ArcJumpstart\SSMS22\Common7\IDE\Ssms.exe'
    }
    function Get-AuthenticodeSignature {
        param([string]$FilePath)
        return @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'CN=Microsoft, O=Microsoft Corporation, C=US' } }
    }
    function Get-Item {
        param([string]$LiteralPath)
        return @{ VersionInfo = @{ ProductMajorPart = 22; ProductName = 'Microsoft SQL Server Management Studio' } }
    }
    $installed = Get-InstalledSsms
    if ($installed -ne 'F:\ArcJumpstart\SSMS22\Common7\IDE\Ssms.exe') {
        throw 'Verified machine-wide SSMS 22 was not detected.'
    }
    function Get-Item {
        param([string]$LiteralPath)
        return @{ VersionInfo = @{ ProductMajorPart = 21; ProductName = 'Microsoft SQL Server Management Studio' } }
    }
    Assert-Fails { Get-InstalledSsms } 'Unexpected SSMS executable product/version'
    function Get-AuthenticodeSignature {
        param([string]$FilePath)
        return @{ Status = 'NotSigned'; SignerCertificate = @{ Subject = 'CN=Unknown' } }
    }
    Assert-Fails { Get-InstalledSsms } 'Invalid Microsoft Authenticode signature'
}

$entry = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.TryStatementAst]
})
if ($entry.Count -ne 1) { throw 'Expected one host SSMS installation entry point.' }
$install = [scriptblock]::Create($entry[0].Extent.Text)
& {
    $bootstrapper = 'C:\Users\Public\Desktop\vs_SSMS.exe'
    $protectedBootstrapper = 'C:\Program Files\ArcJumpstart\SSMS22\vs_SSMS.exe'
    $installPath = 'F:\ArcJumpstart\SSMS22'
    $rebootMarker = 'C:\ArcJumpstart\ssms-reboot-required.json'
    $script:bootstrapper = $bootstrapper
    $script:protectedBootstrapper = $protectedBootstrapper
    $script:installPath = $installPath
    $script:rebootMarker = $rebootMarker
    $env:SystemDrive = 'C:'
    function Test-Path {
        param([string]$LiteralPath, [string]$PathType)
        if ($LiteralPath -eq 'F:\ArcJumpstart') { return $true }
        if ($LiteralPath -eq $protectedBootstrapper) { return $script:protectedPresent }
        if ($LiteralPath -eq $bootstrapper) { return $true }
        if ($LiteralPath -eq $rebootMarker) { return $script:rebootPending }
        if ($LiteralPath -eq $installPath) { return $false }
        return $false
    }
    function Assert-SsmsBootstrapper {
        param([string]$Path)
        if ($Path -notin @($protectedBootstrapper, $bootstrapper)) {
            throw "Unexpected bootstrapper validation path $Path"
        }
    }
    function Save-SsmsBootstrapper { param([string]$Path) throw 'mock network blocked' }
    function New-Item { param([string]$ItemType, [string]$Path, [switch]$Force) }
    function Copy-Item { param([string]$LiteralPath, [string]$Destination, [switch]$Force) }
    function Get-FileHash {
        param([string]$LiteralPath, [string]$Algorithm)
        return @{ Hash = 'verified-copy' }
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter)
        if ($ClassName -eq 'Win32_OperatingSystem') {
            return @{ LastBootUpTime = [datetime]'2026-09-24T10:00:00Z' }
        }
        return @{ FreeSpace = 25GB }
    }
    function Get-Content {
        param([string]$LiteralPath, [switch]$Raw)
        return (@{ LastBootTicks = [string](Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks } |
            ConvertTo-Json)
    }
    function Get-InstalledSsms { return $script:verifiedSsms }
    function Get-Process { param([string[]]$Name, $ErrorAction) }
    function Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [switch]$Wait, [switch]$PassThru)
        if ($FilePath -ne $protectedBootstrapper -or -not $Wait -or -not $PassThru -or
            ($ArgumentList -join ' ') -ne '--installPath F:\ArcJumpstart\SSMS22 --quiet --wait --norestart') {
            throw 'SSMS installation did not use the supported synchronous arguments.'
        }
        return @{ ExitCode = $script:setupExitCode }
    }
    function Stop-Transcript {}
    function Set-Content { param([string]$LiteralPath, [string]$Encoding, [Parameter(ValueFromPipeline)]$Value) process {} }
    function Remove-Item { param([string]$LiteralPath, [switch]$Force) }
    $script:protectedPresent = $false
    try { & $install; throw 'Untrusted Public Desktop bootstrapper was executed.' }
    catch { if ($_.Exception.Message -notlike '*download failed; no installer was executed*mock network blocked*') { throw } }
    $script:protectedPresent = $true
    $script:rebootPending = $true
    $script:verifiedSsms = 'F:\ArcJumpstart\SSMS22\Common7\IDE\Ssms.exe'
    if (-not (Test-Path -LiteralPath $rebootMarker)) { throw 'Mock reboot marker was not visible.' }
    $expectedBoot = (Get-Content -LiteralPath $rebootMarker -Raw | ConvertFrom-Json).LastBootTicks
    $actualBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
    if ($expectedBoot -ne $actualBoot) { throw "Mock boot mismatch: $expectedBoot vs $actualBoot" }
    try { & $install; throw 'Reboot marker was ignored.' }
    catch { if ($_.Exception.Message -notlike '*requires a host reboot before use*') { throw } }
    $script:rebootPending = $false
    & $install
    $script:verifiedSsms = $null
    $script:setupExitCode = 3010
    try { & $install; throw 'Reboot-needed exit was ignored.' }
    catch { if ($_.Exception.Message -notlike '*host reboot required before use*') { throw } }
    $script:setupExitCode = 5003
    try { & $install; throw 'Installer failure was ignored.' }
    catch { if ($_.Exception.Message -notlike '*SSMS setup failed (exit 5003)*') { throw } }
    Remove-Variable protectedPresent, rebootPending, verifiedSsms, setupExitCode, bootstrapper, protectedBootstrapper, installPath, rebootMarker -Scope Script
}

$bicep = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../infra/stages/ssms/main.bicep') -Raw
foreach ($expected in @('loadTextContent', 'install-host-ssms.ps1', 'asyncExecution: true',
    "stageName: 'stage-ssms'", 'timeoutInSeconds: 14400')) {
    if (-not $bicep.Contains($expected)) { throw "Missing SSMS Bicep wiring: $expected" }
}
Write-Host 'Host SSMS download, signature, version and stage wiring regressions passed.'
