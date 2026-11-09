[CmdletBinding(DefaultParameterSetName = 'Inspect')]
param(
    [Parameter(ParameterSetName = 'Initialize')][switch]$InitializeBoot,
    [Parameter(ParameterSetName = 'Preserve')][switch]$PreserveUnpublishedWindows,
    [Parameter(ParameterSetName = 'Ubuntu')][switch]$UbuntuInstaller
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')

$settings = Read-LabSettings (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot))
Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
$probe = @'
$ErrorActionPreference = 'Stop'
$cache = 'F:\ArcJumpstart\Images\InstallationMedia'
$path = Join-Path $cache 'Windows-Server-__WINDOWS_VERSION__-Eval.vhdx'
$lock = [IO.File]::Open((Join-Path $cache 'build.lock'), 'Open', 'ReadWrite', 'None')
$mounted = $false
try {
    $image = Get-VHD -Path $path
    if ($image.Attached) { throw 'Image is already attached. Do not disturb its owner.' }
    # INITIALIZATION_GUARD
    $disk = Mount-VHD -Path $path -ReadOnly:__READ_ONLY__ -NoDriveLetter -Passthru
    $mounted = $true
    # INITIALIZE_BOOT
    $partitions = @(Get-Partition -DiskNumber $disk.DiskNumber | ForEach-Object {
        $partition = $_
        $entry = [ordered]@{
            Number = $partition.PartitionNumber; Type = $partition.GptType
            Size = $partition.Size; DriveLetter = [string]$partition.DriveLetter
        }
        if ($partition.GptType -ne '{e3c9e316-0b5c-4db8-817d-f92df00215ae}') {
            $volume = $partition | Get-Volume -ErrorAction Stop
            $entry.FileSystem = $volume.FileSystem
            $entry.Label = $volume.FileSystemLabel
            $entry.VolumePath = $volume.Path
            $entry.Files = @('Windows\System32\Config\BCD-Template',
                'Windows\Boot\EFI\bootmgfw.efi', 'Windows\System32\bcdboot.exe',
                'EFI\Microsoft\Boot\BCD', 'EFI\Microsoft\Boot\bootmgfw.efi',
                'EFI\Boot\bootx64.efi') | ForEach-Object {
                $file = [IO.Path]::Combine($volume.Path, $_)
                [pscustomobject]@{ Name = $_; Exists = (Test-Path -LiteralPath $file) }
            }
        }
        [pscustomobject]$entry
    })
    [ordered]@{
        Image = $path; Ready = (Test-Path -LiteralPath "$path.ready")
        HostBcdboot = (Get-Command bcdboot.exe -CommandType Application).Source
        HostBcdbootVersion = (Get-Item "$env:windir\System32\bcdboot.exe").VersionInfo.FileVersion
        Partitions = $partitions
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($mounted) { Dismount-VHD -Path $path | Out-Null }
    $lock.Dispose()
}
'@
if ($UbuntuInstaller) {
    $probe = $probe.Replace('Windows-Server-__WINDOWS_VERSION__-Eval.vhdx', 'Ubuntu-Installer.vhdx').
        Replace('__READ_ONLY__', '$true').Replace('# INITIALIZE_BOOT', @'
    $partition = @(Get-Partition -DiskNumber $disk.DiskNumber |
        Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}')
    if ($partition.Count -ne 1) { throw 'Expected one Ubuntu installer EFI volume.' }
    $volume = $partition[0] | Get-Volume -ErrorAction Stop
    $seed = [IO.File]::ReadAllBytes([IO.Path]::Combine($volume.Path, 'user-data'))
    Write-Output ('SeedHeader=' + [BitConverter]::ToString($seed[0..15]))
    Write-Output ('SeedBytes=' + $seed.Length)
    $grub = [IO.File]::ReadAllText([IO.Path]::Combine($volume.Path, 'boot\grub\grub.cfg'))
    [regex]::Matches($grub, '(?m)^\s*linux\s+/casper/vmlinuz[^\r\n]*') |
        ForEach-Object { Write-Output ('InstallerKernel=' + $_.Value.Trim()) }
'@)
}
elseif ($PreserveUnpublishedWindows) {
    $probe = $probe.Replace('# INITIALIZATION_GUARD', @'
    if (Test-Path -LiteralPath "$path.ready") { throw 'Do not move a published base image.' }
    if (@(Get-VM).Count) { throw 'Preserving a failed image is restricted to the pre-guest build.' }
    if ($image.ParentPath) { throw 'Expected an independent base disk, not a differencing disk.' }
    $backup = Join-Path $cache ("Windows-Server-__WINDOWS_VERSION__-Eval.failed-{0}-{1}.vhdx" -f
        [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), [guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
    Write-Output "Preserved unpublished Windows disk at $backup. No disk or guest was deleted."
    Write-Output 'IMAGE_MEDIA_DIAGNOSTICS_COMPLETED'
    return
'@).Replace('__READ_ONLY__', '$true')
}
elseif ($InitializeBoot) {
    $probe = $probe.Replace('# INITIALIZATION_GUARD', @'
    if (Test-Path -LiteralPath "$path.ready") { throw 'Do not repair a published base image.' }
    if (@(Get-VM).Count) { throw 'Boot initialization recovery is restricted to the pre-guest image build.' }
'@).Replace('__READ_ONLY__', '$false').Replace('# INITIALIZE_BOOT', @'
    $efi = @(Get-Partition -DiskNumber $disk.DiskNumber | Where-Object GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}')
    $windows = @(Get-Partition -DiskNumber $disk.DiskNumber | Where-Object {
        $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    })
    if ($efi.Count -ne 1 -or $windows.Count -ne 1) { throw 'Unexpected Windows image partition layout.' }
    foreach ($partition in @($efi[0], $windows[0])) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
    }
    $efi = Get-Partition -DiskNumber $disk.DiskNumber -PartitionNumber $efi[0].PartitionNumber
    $windows = Get-Partition -DiskNumber $disk.DiskNumber -PartitionNumber $windows[0].PartitionNumber
    $source = "$($windows.DriveLetter):\Windows"
    $destination = "$($efi.DriveLetter):"
    if ($source -notmatch '^[A-Z]:\\Windows$' -or $destination -notmatch '^[A-Z]:$') { throw 'Missing image-only drive letters.' }
    $offlineBoot = '__WINDOWS_VERSION__' -eq '2025'
    $bcdboot = if ($offlineBoot) { Join-Path $env:windir 'System32\bcdboot.exe' }
        else { Join-Path $source 'System32\bcdboot.exe' }
    if (-not (Test-Path -LiteralPath $bcdboot)) { throw "Required BCDBoot executable is missing: $bcdboot" }
    $arguments = @($source, '/s', $destination, '/f', 'UEFI', '/v')
    if ($offlineBoot) { $arguments += '/offline' }
    New-Item -ItemType Directory -Path "$destination\EFI\Microsoft\Boot", "$destination\EFI\Boot" -Force | Out-Null
    Write-Output "Initializing unpublished image boot files: $bcdboot $($arguments -join ' ')"
    & $bcdboot @arguments
    if ($LASTEXITCODE -ne 0) { throw "BCDBoot diagnostic failed with exit $LASTEXITCODE." }
    foreach ($bootFile in @('EFI\Microsoft\Boot\BCD', 'EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Boot\bootx64.efi')) {
        if (-not (Test-Path -LiteralPath (Join-Path "$destination\" $bootFile) -PathType Leaf)) {
            throw "Windows UEFI boot file is missing after BCDBoot: $bootFile"
        }
    }
    Write-Output 'Boot files initialized. The image remains unpublished; no readiness receipt was created.'
'@)
}
else { $probe = $probe.Replace('__READ_ONLY__', '$true') }
$probe = $probe.Replace('__WINDOWS_VERSION__', (Get-LabWindowsServerVersion $settings))
$probe += "`nWrite-Output 'IMAGE_MEDIA_DIAGNOSTICS_COMPLETED'"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("arc-image-inspect-{0}.ps1" -f [guid]::NewGuid())
try {
    [void][IO.File]::Create($temporary).Dispose()
    Protect-LabPath $temporary
    [IO.File]::WriteAllText($temporary, $probe, [Text.UTF8Encoding]::new($false))
    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    $result = Invoke-LabAz @('vm', 'run-command', 'invoke', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host",
        '--command-id', 'RunPowerShellScript', '--scripts', "@$temporary",
        '--query', 'value[].message', '--output', 'tsv', '--only-show-errors')
    Write-Host (Protect-LabOutput $result.Output $settings)
    if (-not $result.Output.Contains('IMAGE_MEDIA_DIAGNOSTICS_COMPLETED')) {
        throw 'Image diagnostics/recovery did not complete. Inspect the redacted host error above.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
