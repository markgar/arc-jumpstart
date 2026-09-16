[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$DataDiskSizeGB,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "10-init-host-$RunId.log") -Force

try {
    $expectedSize = $DataDiskSizeGB * 1GB
    $candidateDisks = @(
        Get-Disk | Where-Object {
            -not $_.IsBoot -and
            -not $_.IsSystem -and
            [math]::Abs($_.Size - $expectedSize) -lt 1GB
        }
    )
    if ($candidateDisks.Count -ne 1) {
        throw "Expected exactly one non-OS disk near $DataDiskSizeGB GiB, but found $($candidateDisks.Count)."
    }
    $disk = $candidateDisks[0]

    $driveFPartition = Get-Partition -DriveLetter F -ErrorAction SilentlyContinue
    if ($driveFPartition -and $driveFPartition.DiskNumber -ne $disk.Number) {
        Write-Warning "Drive F is assigned to disk $($driveFPartition.DiskNumber), not the $DataDiskSizeGB GiB managed disk $($disk.Number). Removing only the incorrect drive-letter assignment."
        Remove-PartitionAccessPath `
            -DiskNumber $driveFPartition.DiskNumber `
            -PartitionNumber $driveFPartition.PartitionNumber `
            -AccessPath 'F:\'
    }

    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    }

    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Where-Object Type -eq 'Basic' |
        Sort-Object Size -Descending |
        Select-Object -First 1
    if (-not $partition) {
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter F
    }
    elseif (-not $partition.DriveLetter) {
        $partition | Set-Partition -NewDriveLetter F
    }
    elseif ($partition.DriveLetter -ne 'F') {
        if (Get-Volume -DriveLetter F -ErrorAction SilentlyContinue) {
            throw "Drive F is already assigned to another volume; data disk $($disk.Number) is mounted as $($partition.DriveLetter)."
        }
        $partition | Set-Partition -NewDriveLetter F
    }

    $volume = Get-Volume -DriveLetter F -ErrorAction SilentlyContinue
    if (-not $volume -or -not $volume.FileSystem) {
        Format-Volume -DriveLetter F -FileSystem NTFS -NewFileSystemLabel 'NestedVMs' -Confirm:$false
    }
    elseif ($volume.FileSystem -ne 'NTFS') {
        throw "Drive F uses $($volume.FileSystem); this lab requires NTFS."
    }

    foreach ($path in @(
        $root,
        $logRoot,
        'F:\ArcJumpstart',
        'F:\ArcJumpstart\Images',
        'F:\ArcJumpstart\Virtual Machines'
    )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $features = @('Hyper-V', 'DHCP', 'RSAT-DHCP')
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    if (-not $result.Success) {
        throw "Windows feature installation failed: $($result.ExitCode)"
    }

    if ($result.RestartNeeded -eq 'Yes') {
        Write-Host 'A restart is required. The deployment wrapper will restart the host after this run command completes.'
    }
}
finally {
    Stop-Transcript
}
