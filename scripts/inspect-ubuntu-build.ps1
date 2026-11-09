param([Parameter(Mandatory)][string]$OutputPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
$settings = Read-LabSettings (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot))
Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
[void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))

function Invoke-ConsoleProbe {
    param([string]$Script)
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("arc-console-{0}.ps1" -f [guid]::NewGuid())
    try {
        [void][IO.File]::Create($temporary).Dispose()
        Protect-LabPath $temporary
        [IO.File]::WriteAllText($temporary, $Script, [Text.UTF8Encoding]::new($false))
        $response = Invoke-LabAz @('vm', 'run-command', 'invoke', '--resource-group',
            $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host",
            '--command-id', 'RunPowerShellScript', '--scripts', "@$temporary",
            '--query', 'value[].message', '--output', 'tsv', '--only-show-errors')
        return $response.Output
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

$capture = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$cache = 'F:\ArcJumpstart\Images\InstallationMedia'
$lock = [IO.File]::Open((Join-Path $cache 'build.lock'), 'Open', 'ReadWrite', 'None')
try {
    $vm = Get-VM -Name 'TEMPLATE-Ubuntu-22.04' -ErrorAction Stop
    $parent = 'F:\ArcJumpstart\Images\Generalized\Windows-Server-2022-Eval.vhdx.ready'
    Write-Output "VMState=$($vm.State); Uptime=$($vm.Uptime); CPU=$($vm.CPUUsage); WindowsGeneralizedReady=$(Test-Path -LiteralPath $parent)"
    $namespace = 'root/virtualization/v2'
    $system = Get-CimInstance -Namespace $namespace -ClassName Msvm_ComputerSystem -Filter "Name='$($vm.Id)'"
    $configuration = @($system | Get-CimAssociatedInstance -Association Msvm_SettingsDefineState `
        -ResultClassName Msvm_VirtualSystemSettingData)
    if ($configuration.Count -ne 1) { throw 'Expected one current Ubuntu VM configuration.' }
    $service = Get-CimInstance -Namespace $namespace -ClassName Msvm_VirtualSystemManagementService
    $frame = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage `
        -Arguments @{ TargetSystem = $configuration[0]; WidthPixels = [uint16]800; HeightPixels = [uint16]600 }
    $pixelBytes = 800 * 600 * 2
    if ($frame.ReturnValue -ne 0 -or $frame.ImageData.Length -lt $pixelBytes -or
        $frame.ImageData.Length -gt ($pixelBytes + 4)) {
        throw "Console capture failed (Hyper-V result $($frame.ReturnValue), bytes=$($frame.ImageData.Length), VM=$($vm.State)). No VM state was changed."
    }
    $bitmap = [Drawing.Bitmap]::new(800, 600, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        $region = [Drawing.Rectangle]::new(0, 0, 800, 600)
        $pixels = $bitmap.LockBits($region, [Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
        try {
            # The provider can allocate four extra bytes; copy only bitmap pixels.
            [Runtime.InteropServices.Marshal]::Copy([byte[]]$frame.ImageData, 0, $pixels.Scan0, $pixels.Stride * $pixels.Height)
        }
        finally { $bitmap.UnlockBits($pixels) }
        $token = [guid]::NewGuid().ToString('N')
        $directory = 'C:\ArcJumpstart\Diagnostics'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $path = Join-Path $directory "ubuntu-$token.png"
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    $bytes = [IO.File]::ReadAllBytes($path)
    $parent = 'F:\ArcJumpstart\Images\Generalized\Windows-Server-2022-Eval.vhdx.ready'
    $info = @{
        Token = $token; Length = $bytes.Length; Base64Length = [Convert]::ToBase64String($bytes).Length
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        State = [string]$vm.State; Uptime = [string]$vm.Uptime; CpuUsage = $vm.CPUUsage
        WindowsGeneralizedReady = (Test-Path -LiteralPath $parent)
    }
    Write-Output ('SNAPSHOT:' + ($info | ConvertTo-Json -Compress))
}
finally { $lock.Dispose() }
'@
$response = Invoke-ConsoleProbe $capture
$match = [regex]::Match($response, '(?m)^SNAPSHOT:(.+)$')
if (-not $match.Success) { throw "Console capture did not return a snapshot: $response" }
$snapshot = $match.Groups[1].Value.Trim() | ConvertFrom-Json -ErrorAction Stop
if ($snapshot.Token -notmatch '^[a-f0-9]{32}$' -or $snapshot.Length -gt 262144 -or
    $snapshot.Base64Length -ne 4 * [Math]::Ceiling($snapshot.Length / 3)) {
    throw 'Invalid console snapshot metadata.'
}
$parts = [Collections.Generic.List[string]]::new()
for ($offset = 0; $offset -lt $snapshot.Base64Length; $offset += 3000) {
    $count = [Math]::Min(3000, $snapshot.Base64Length - $offset)
    $chunk = Invoke-ConsoleProbe @"
`$ErrorActionPreference = 'Stop'
`$bytes = [IO.File]::ReadAllBytes('C:\ArcJumpstart\Diagnostics\ubuntu-$($snapshot.Token).png')
Write-Output ('DATA:' + [Convert]::ToBase64String(`$bytes).Substring($offset, $count))
"@
    $data = [regex]::Match($chunk, '(?m)^DATA:([A-Za-z0-9+/=]+)\r?$')
    if (-not $data.Success -or $data.Groups[1].Value.Length -ne $count) { throw 'Incomplete console snapshot transfer.' }
    $parts.Add($data.Groups[1].Value)
}
$image = [Convert]::FromBase64String([string]::Concat($parts))
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = ([BitConverter]::ToString($sha.ComputeHash($image))).Replace('-', '') }
finally { $sha.Dispose() }
if ($image.Length -ne $snapshot.Length -or $hash -ine $snapshot.Sha256) { throw 'Console snapshot fingerprint mismatch.' }
[IO.File]::WriteAllBytes($OutputPath, $image)
Write-Host "UbuntuState=$($snapshot.State); Uptime=$($snapshot.Uptime); CPU=$($snapshot.CpuUsage); WindowsGeneralizedReady=$($snapshot.WindowsGeneralizedReady)"
Write-Host "Console snapshot saved at $OutputPath. No VM was stopped, restarted, or sent input."
