$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
$environmentPath = Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot)
$original = [IO.File]::ReadAllText($environmentPath)
$settings = Read-LabSettings $environmentPath
Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
if ((Get-LabImageSettings $settings).Mode -ne 'installation-media') {
    throw 'This recovery is only for the installation-media trial.'
}
[void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
$state = (Invoke-LabAz @('vm', 'run-command', 'show', '--resource-group',
    $settings.AZURE_RESOURCE_GROUP, '--vm-name', "$($settings.NAME_PREFIX)-host",
    '--name', 'stage40-nested-vms', '--expand', 'instanceView',
    '--query', 'instanceView.executionState', '--output', 'tsv', '--only-show-errors')).Output.Trim()
if ($state -notin @('Failed', 'Succeeded', 'TimedOut', 'Canceled')) {
    throw "Stage 40 is not terminal ($state). Do not disturb an active build."
}
$probe = @'
$ErrorActionPreference = 'Stop'
$cache = 'F:\ArcJumpstart\Images\InstallationMedia'
$lock = [IO.File]::Open((Join-Path $cache 'build.lock'), 'Open', 'ReadWrite', 'None')
try {
    if (Get-VM -Name 'JS-UBUNTU-01' -ErrorAction SilentlyContinue) { throw 'Refusing to remove an existing lab guest.' }
    if (Test-Path -LiteralPath (Join-Path $cache 'Ubuntu-22.04.vhdx.ready')) {
        throw 'Refusing to remove a completed Ubuntu base image.'
    }
    $name = 'TEMPLATE-Ubuntu-22.04'
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    $target = Join-Path $cache 'Ubuntu-22.04.vhdx'
    $builder = Join-Path $cache $name
    if ($vm) {
        $paths = @($vm | Get-VMHardDiskDrive | Select-Object -ExpandProperty Path)
        if ($paths.Count -ne 2 -or @($paths | Where-Object {
            $_ -notin @($target, (Join-Path $builder 'installer.vhdx'))
        }).Count) { throw 'Unexpected Ubuntu template disks; no cleanup performed.' }
        if ($vm.State -notin @('Off', 'Running')) { throw "Unexpected Ubuntu template state: $($vm.State)." }
        if ($vm.State -eq 'Running') { Stop-VM -Name $name -TurnOff -Confirm:$false -ErrorAction Stop }
        Remove-VM -Name $name -Force -ErrorAction Stop
    }
    Write-Output 'Disabled Ubuntu template; unused VHDs, installer media, and diagnostic files remain on the host. No disk cleanup or export is required.'
    Write-Output 'LINUX_DISABLED_CLEANUP_COMPLETED'
}
finally { $lock.Dispose() }
'@
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("arc-disable-linux-{0}.ps1" -f [guid]::NewGuid())
try {
    [void][IO.File]::Create($temporary).Dispose()
    Protect-LabPath $temporary
    [IO.File]::WriteAllText($temporary, $probe, [Text.UTF8Encoding]::new($false))
    $result = Invoke-LabAz @('vm', 'run-command', 'invoke', '--resource-group',
        $settings.AZURE_RESOURCE_GROUP, '--name', "$($settings.NAME_PREFIX)-host",
        '--command-id', 'RunPowerShellScript', '--scripts', "@$temporary",
        '--query', 'value[].message', '--output', 'tsv', '--only-show-errors')
    Write-Host (Protect-LabOutput $result.Output $settings)
    if (-not $result.Output.Contains('LINUX_DISABLED_CLEANUP_COMPLETED')) {
        throw 'Ubuntu cleanup did not complete; configuration is unchanged.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
if ([IO.File]::ReadAllText($environmentPath) -cne $original) {
    throw 'Environment file changed concurrently; cleanup completed but configuration was not overwritten.'
}
$candidate = $settings.Clone()
$candidate.INCLUDE_LINUX = 'false'
[void](Get-LabImageSettings $candidate)
$content = if ($original -match '(?m)^INCLUDE_LINUX=') {
    [regex]::Replace($original, '(?m)^INCLUDE_LINUX=[^\r\n]*', 'INCLUDE_LINUX=false')
}
else { $original.TrimEnd() + "`nINCLUDE_LINUX=false`n" }
$backupPath = "$environmentPath.before-disable-linux"
if (-not (Test-Path -LiteralPath $backupPath)) {
    Copy-Item -LiteralPath $environmentPath -Destination $backupPath -ErrorAction Stop
    Protect-LabPath $backupPath
}
$temporary = "$environmentPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [void][IO.File]::Create($temporary).Dispose()
    Protect-LabPath $temporary
    [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $environmentPath -Force
    Protect-LabPath $environmentPath
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
Write-Host "INCLUDE_LINUX=false saved in $environmentPath. Windows images, guests, Azure infrastructure, and credentials were preserved."
