[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$DcMemoryGB,

    [Parameter(Mandatory)]
    [int]$SqlMemoryGB,

    [Parameter(Mandatory)]
    [int]$LinuxMemoryGB,

    [Parameter(Mandatory)]
    [string]$DcStaticIp,

    [Parameter(Mandatory)]
    [string]$NestedGatewayIp,

    [Parameter(Mandatory)]
    [string]$WindowsImageFileName,

    [Parameter(Mandatory)]
    [string]$LinuxImageFileName,

    [Parameter(Mandatory)]
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
$imageRoot = 'F:\ArcJumpstart\Images'
$generalizedImageRoot = Join-Path $imageRoot 'Generalized'
$vmRoot = 'F:\ArcJumpstart\Virtual Machines'
$switchName = 'ArcJumpstartInternal'
$retiredVmFile = Join-Path $root 'RetiredVMs.txt'
$retiredVmNames = if (Test-Path $retiredVmFile) {
    @(Get-Content $retiredVmFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
else {
    @()
}
New-Item -ItemType Directory -Path $logRoot, $generalizedImageRoot, $vmRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "40-create-nested-vms-$RunId.log") -Force

function Wait-VMHeartbeat {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $heartbeat = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if ($heartbeat.PrimaryStatusDescription -eq 'OK') {
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for heartbeat from $VMName."
}

function Invoke-WindowsGuest {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 900
    )

    $securePassword = ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force
    $credential = [pscredential]::new('Administrator', $securePassword)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage40] Preparing or reusing the generalized Windows parent."
            return Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        }
        catch {
            $transportFailure =
                $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -or
                $_.FullyQualifiedErrorId -like '*PSSessionStateBroken*'
            if (-not $transportFailure) {
                throw
            }
            if ((Get-Date) -ge $deadline) {
                throw
            }
            Start-Sleep -Seconds 15
        }
    } while ($true)
}

function Wait-WindowsGuestOobe {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $remaining = [Math]::Max(0, [int]($deadline - (Get-Date)).TotalSeconds)
        $state = Invoke-WindowsGuest -VMName $VMName -TimeoutSeconds $remaining -ScriptBlock {
            if (-not ('ArcJumpstart.WindowsSetup' -as [type])) {
                Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace ArcJumpstart {
    public static class WindowsSetup {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
'@ -ErrorAction Stop
            }
            $complete = $false
            if (-not [ArcJumpstart.WindowsSetup]::OOBEComplete([ref]$complete)) {
                throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
            }
            [pscustomobject]@{
                Complete = $complete
                ImageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction Stop).ImageState
            }
        }
        if ($state.Complete -eq $true -and $state.ImageState -eq 'IMAGE_STATE_COMPLETE') {
            Write-Host "Windows first-boot setup completed on $VMName."
            return
        }
        if ((Get-Date) -ge $deadline) { break }
        Write-Host "Waiting for Windows OOBE on $VMName (complete=$($state.Complete), image=$($state.ImageState)); no rename or reboot yet."
        Start-Sleep -Seconds 10
    } while ($true)
    throw "Windows first-boot setup did not complete on $VMName within $TimeoutSeconds seconds (OOBE=$($state.Complete), image=$($state.ImageState)). Inspect its console and C:\Windows\Panther\UnattendGC. Do not force setup registry flags or continue to SQL/domain installation."
}

function Read-TemplateGeneralizationResult {
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath
    )

    $mountRoot = Join-Path 'C:\ArcJumpstart\Mounts' ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $mountRoot -Force | Out-Null
    $mounted = $null
    try {
        $mounted = Mount-VHD -Path $VhdPath -ReadOnly -NoDriveLetter -Passthru
        $partitions = @(Get-Partition -DiskNumber $mounted.DiskNumber | Where-Object Type -eq 'Basic')
        foreach ($partition in $partitions) {
            Add-PartitionAccessPath -DiskNumber $mounted.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $mountRoot
            try {
                $sysprepRoot = Join-Path $mountRoot 'Windows\System32\Sysprep'
                if (Test-Path $sysprepRoot) {
                    $resultPath = Join-Path $sysprepRoot 'ArcJumpstart-Result.json'
                    if (-not (Test-Path $resultPath)) {
                        throw 'Template shut down without a recorded Sysprep result. No ready marker will be written.'
                    }
                    $result = Get-Content $resultPath -Raw | ConvertFrom-Json
                    $result | Add-Member -NotePropertyName SuccessTag -NotePropertyValue (Test-Path (Join-Path $sysprepRoot 'Sysprep_succeeded.tag'))
                    return $result
                }
            }
            finally {
                Remove-PartitionAccessPath -DiskNumber $mounted.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $mountRoot
            }
        }
        throw "No Windows Sysprep directory found in $VhdPath."
    }
    finally {
        if ($mounted) {
            Dismount-VHD -Path $VhdPath
        }
        Remove-Item -LiteralPath $mountRoot
    }
}

function Wait-TemplateGeneralization {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$VhdPath,

        [int]$TimeoutSeconds = 1800
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -eq 'Off') {
            $result = Read-TemplateGeneralizationResult -VhdPath $VhdPath
            if (-not $result -or $null -eq $result.ExitCode -or $result.ExitCode -ne 0 -or
                $result.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -or
                $result.Error -or $result.SuccessTag -ne $true) {
                throw "Sysprep failed on $VMName. ExitCode=$($result.ExitCode); ImageState=$($result.ImageState); Error=$($result.Error)`n$($result.Panther)"
            }
            Write-Host "Verified Sysprep generalization on $VMName from its offline disk."
            return
        }
        if ($vm.State -notin @('Running', 'Stopping')) {
            throw "$VMName entered state $($vm.State) ($($vm.Status)) before verified generalization. No ready marker will be written."
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for Sysprep on $VMName. Inspect C:\Windows\System32\Sysprep\Panther in the guest. No ready marker will be written."
}

function Get-WindowsServer2022KmsConfiguration {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $edition = (Get-WindowsEdition -Online -ErrorAction Stop).Edition
    if ($os.BuildNumber -ne '20348' -or $os.ProductType -notin @(2, 3)) {
        throw "Unsupported Windows image: edition=$edition, build=$($os.BuildNumber), productType=$($os.ProductType). Only Windows Server 2022 Standard/Datacenter build 20348 is supported."
    }
    # Published client keys select the edition; they are not licenses or secrets.
    # https://learn.microsoft.com/windows-server/get-started/kms-client-activation-keys
    $key = switch ($edition) {
        'ServerStandard' { 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H' }
        'ServerDatacenter' { 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33' }
        default { throw "Unsupported Windows image edition '$edition' (build 20348). No default product key will be used." }
    }
    [pscustomobject]@{
        Edition = $edition
        Build = [string]$os.BuildNumber
        ProductKey = $key
        PartialProductKey = $key.Substring($key.Length - 5)
        Channel = 'VOLUME_KMSCLIENT'
        KmsEndpoint = 'azkms.core.windows.net:1688'
    }
}

function New-WindowsServer2022Unattend {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdministratorPassword)
    $configuration = Get-WindowsServer2022KmsConfiguration
    $escapedPassword = [Security.SecurityElement]::Escape($AdministratorPassword)
    # Specialize ProductKey prevents the interactive product-key OOBE page.
    # https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-productkey
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>*</ComputerName>
      <ProductKey>$($configuration.ProductKey)</ProductKey>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$escapedPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function Invoke-WindowsLicenseCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $cscript = (Get-Command cscript.exe -CommandType Application -ErrorAction Stop).Source
    $output = & $cscript //NoLogo "$env:SystemRoot\System32\slmgr.vbs" @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    if ($exitCode -ne 0 -or $text -match '(?i)\b0x[89a-f][0-9a-f]{7}\b') {
        throw "Windows licensing command $($Arguments[0]) failed (exit $exitCode): $text"
    }
    Write-Host $text
}

function Enable-WindowsServer2022AzureKms {
    $configuration = Get-WindowsServer2022KmsConfiguration
    function Get-InstalledWindowsProduct {
        @(Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
            Where-Object { $_.LicenseStatus -eq 1 -or -not [string]::IsNullOrWhiteSpace($_.PartialProductKey) })
    }
    function Test-ExpectedKmsProduct($Product) {
        $Product -and $Product.PartialProductKey -eq $configuration.PartialProductKey -and
            $Product.Description -match '\bVOLUME_KMSCLIENT channel\b'
    }
    $products = @(Get-InstalledWindowsProduct)
    if ($products.Count -gt 1) { throw 'Multiple installed Windows licensing products; refusing ambiguous activation.' }
    if ($products.Count -eq 1 -and (Test-ExpectedKmsProduct $products[0]) -and $products[0].LicenseStatus -eq 1) {
        Write-Host "Windows $($configuration.Edition) is already licensed with the expected KMS client key."
        return
    }
    # AVMA is unsupported in Azure; use the documented Azure KMS endpoint.
    # https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/windows-vm-activation-error-0xc004fd01-0xc004fd02
    if ($products.Count -ne 1 -or -not (Test-ExpectedKmsProduct $products[0])) {
        Invoke-WindowsLicenseCommand -Arguments @('/ipk', $configuration.ProductKey)
    }
    Invoke-WindowsLicenseCommand -Arguments @('/skms', $configuration.KmsEndpoint)
    Invoke-WindowsLicenseCommand -Arguments @('/ato')
    $products = @(Get-InstalledWindowsProduct)
    if ($products.Count -ne 1 -or $products[0].LicenseStatus -ne 1 -or -not (Test-ExpectedKmsProduct $products[0])) {
        throw "Windows activation postcondition failed: require exactly one licensed $($configuration.Edition) product with the expected GVLK and VOLUME_KMSCLIENT channel. slmgr exit 0 alone is not success."
    }
    Write-Host "Windows $($configuration.Edition) activation verified via CIM (LicenseStatus=1, VOLUME_KMSCLIENT)."
}

function Get-WindowsProvisioningHelperScript {
    @"
function Get-WindowsServer2022KmsConfiguration {
${function:Get-WindowsServer2022KmsConfiguration}
}
function New-WindowsServer2022Unattend {
${function:New-WindowsServer2022Unattend}
}
function Invoke-WindowsLicenseCommand {
${function:Invoke-WindowsLicenseCommand}
}
function Enable-WindowsServer2022AzureKms {
${function:Enable-WindowsServer2022AzureKms}
}
"@
}

function Get-VhdChainPaths {
    param([Parameter(Mandatory)][string]$Path)
    $seen = @{}
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ($seen.ContainsKey($current)) { throw "Cyclic VHD dependency at $current; preserve the disks and investigate." }
        $seen[$current] = $true
        $current
        try { $disk = Get-VHD -Path $current -ErrorAction Stop }
        catch { throw "Cannot inspect VHD dependency $current. Preserve existing disks and investigate: $($_.Exception.Message)" }
        if (-not $disk.ParentPath) { break }
        $parent = $disk.ParentPath
        if (-not [IO.Path]::IsPathRooted($parent)) { $parent = Join-Path ([IO.Path]::GetDirectoryName($current)) $parent }
        $current = [IO.Path]::GetFullPath($parent)
    }
}

function Get-GeneralizedParentDependents {
    param(
        [Parameter(Mandatory)][string]$ParentVhd,
        [string]$LabRoot = 'F:\ArcJumpstart'
    )
    $target = [IO.Path]::GetFullPath($ParentVhd)
    $attachedPaths = @(
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Where-Object Path | ForEach-Object Path
            foreach ($snapshot in @(Get-VMSnapshot -VM $vm -ErrorAction Stop)) {
                Get-VMHardDiskDrive -VMSnapshot $snapshot -ErrorAction Stop | Where-Object Path | ForEach-Object Path
            }
        }
    )
    foreach ($attached in $attachedPaths) {
        if ([IO.Path]::GetFullPath($attached) -eq $target) { "Attached disk: $attached" }
    }
    $candidates = @(
        Get-ChildItem -LiteralPath $LabRoot -Recurse -File -ErrorAction Stop |
            Where-Object Extension -in @('.vhdx', '.avhdx') | ForEach-Object FullName
        $attachedPaths
    ) | Sort-Object -Unique
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFullPath($candidate) -eq $target) { continue }
        if ($target -in @(Get-VhdChainPaths -Path $candidate)) { "Dependent disk: $candidate" }
    }
}

function Get-GeneralizedParentCacheState {
    param(
        [Parameter(Mandatory)][string]$ParentVhd,
        [Parameter(Mandatory)][string]$SourceVhd,
        [string]$LabRoot = 'F:\ArcJumpstart'
    )
    $recovery = 'Preserve existing guests and disks; use deliberate supported recovery or a fresh lab. Never relabel an old marker.'
    if (-not (Test-Path -LiteralPath $SourceVhd)) { throw "Required base image is missing: $SourceVhd. Run stage 30 first." }
    $markerPath = "$ParentVhd.ready"
    if (Test-Path -LiteralPath $markerPath) {
        try { $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Legacy or unreadable generalized-parent marker $markerPath. $recovery" }
        if ($marker.Version -ne 'windows-server-2022-gvlk-v1' -or $marker.Build -ne '20348' -or
            $marker.Edition -notin @('ServerStandard', 'ServerDatacenter') -or -not $marker.CompletedUtc -or
            $marker.SourceVhd -ne [IO.Path]::GetFullPath($SourceVhd) -or -not (Test-Path -LiteralPath $ParentVhd)) {
            throw "Stale or incompatible generalized-parent cache $ParentVhd. $recovery"
        }
        return 'Ready'
    }
    $dependents = @(Get-GeneralizedParentDependents -ParentVhd $ParentVhd -LabRoot $LabRoot)
    if ($dependents.Count) { throw "Generalized-parent marker is missing and its disk is in use: $($dependents -join '; '). $recovery" }
    return 'Build'
}

function New-GeneralizedParent {
    param(
        [Parameter(Mandatory)]
        [string]$TemplateName,

        [Parameter(Mandatory)]
        [string]$SourceVhd,

        [Parameter(Mandatory)]
        [int]$MemoryGB
    )

    if (-not (Test-Path $SourceVhd)) {
        throw "Required base image is missing: $SourceVhd. Run stage 30 first."
    }

    $generalizedVhd = Join-Path $generalizedImageRoot "$TemplateName.vhdx"
    $readyMarker = "$generalizedVhd.ready"
    $stagingVmName = "TEMPLATE-$TemplateName"
    $stagingPath = Join-Path $vmRoot $stagingVmName

    if ((Get-GeneralizedParentCacheState -ParentVhd $generalizedVhd -SourceVhd $SourceVhd) -eq 'Ready') {
        return $generalizedVhd
    }

    $existingStagingVm = Get-VM -Name $stagingVmName -ErrorAction SilentlyContinue
    if ($existingStagingVm) {
        throw "Existing template VM $stagingVmName must be investigated before rebuilding. Preserve its VM and disks; no automatic replacement is permitted."
    }
    if (Test-Path -LiteralPath $generalizedVhd) { Remove-Item -LiteralPath $generalizedVhd -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null

    New-VHD -Path $generalizedVhd -ParentPath $SourceVhd -Differencing | Out-Null
    New-VM `
        -Name $stagingVmName `
        -Generation 2 `
        -MemoryStartupBytes ($MemoryGB * 1GB) `
        -VHDPath $generalizedVhd `
        -Path $stagingPath `
        -SwitchName $switchName | Out-Null
    Set-VM -Name $stagingVmName -ProcessorCount 2 -AutomaticStartAction Nothing
    Enable-VMIntegrationService -VMName $stagingVmName -Name 'Guest Service Interface'
    Set-VMFirmware -VMName $stagingVmName -EnableSecureBoot Off
    Start-VM -Name $stagingVmName
    Wait-VMHeartbeat -VMName $stagingVmName

    Write-Host "Generalizing $TemplateName with Windows Sysprep."
    $templateConfiguration = Invoke-WindowsGuest `
        -VMName $stagingVmName `
        -ArgumentList $NestedWindowsPassword, (Get-WindowsProvisioningHelperScript) `
        -ScriptBlock {
            param($AdministratorPassword, $HelperScript)
            $ErrorActionPreference = 'Stop'
            . ([scriptblock]::Create($HelperScript))
            $configuration = Get-WindowsServer2022KmsConfiguration

            function Repair-TemplateEdgeRegistration {
                $provisioned = @(Get-AppxProvisionedPackage -Online |
                    Where-Object DisplayName -eq 'Microsoft.MicrosoftEdge.Stable')
                $installed = @(Get-AppxPackage -Name Microsoft.MicrosoftEdge.Stable)
                foreach ($package in $installed) {
                    if ($provisioned.PackageName -contains $package.PackageFullName) {
                        continue
                    }
                    $newer = @($provisioned | Where-Object { [version]$_.Version -gt [version]$package.Version })
                    # The original ArcBox image has this orphaned registration before Edge updates provision a replacement.
                    $knownSourceRegistration = [version]$package.Version -eq [version]'120.0.2210.61'
                    if ($package.NonRemovable -or ($newer.Count -eq 0 -and -not $knownSourceRegistration)) {
                        throw "Edge package $($package.PackageFullName) is not provisioned and cannot be safely cleaned up: it is non-removable, or has neither a newer provisioned version nor the known source-image version."
                    }
                    Write-Host "Removing stale Administrator Edge registration $($package.PackageFullName); preserving any provisioned Edge."
                    Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                }
                $remaining = @(Get-AppxPackage -AllUsers -Name Microsoft.MicrosoftEdge.Stable |
                    Where-Object {
                        $_.PackageFullName -notin $provisioned.PackageName -and
                        @($_.PackageUserInformation | Where-Object InstallState -eq 'Installed').Count -gt 0
                    })
                if ($remaining.Count -gt 0) {
                    throw "Unprovisioned Edge registrations remain: $($remaining.PackageFullName -join ', '). Inspect the affected user profiles before retrying."
                }
            }

            Repair-TemplateEdgeRegistration
            $unattendPath = 'C:\Windows\System32\Sysprep\ArcJumpstart-Unattend.xml'
            $unattend = New-WindowsServer2022Unattend -AdministratorPassword $AdministratorPassword
            Set-Content -Path $unattendPath -Value $unattend -Encoding UTF8
            & net.exe user Administrator /active:yes | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to enable Administrator (net.exe exit code $LASTEXITCODE)."
            }
            $resultPath = 'C:\Windows\System32\Sysprep\ArcJumpstart-Result.json'
            if (Test-Path $resultPath) {
                Remove-Item $resultPath -Force
            }
            $successTag = 'C:\Windows\System32\Sysprep\Sysprep_succeeded.tag'
            if (Test-Path $successTag) {
                Remove-Item $successTag -Force
            }
            $runnerPath = 'C:\Windows\System32\Sysprep\ArcJumpstart-RunSysprep.ps1'
            $runner = @'
$ErrorActionPreference = 'Stop'
$resultPath = 'C:\Windows\System32\Sysprep\ArcJumpstart-Result.json'
$result = [ordered]@{ ExitCode = -1; ImageState = ''; Error = ''; Panther = '' }
try {
    # Generalization can break PowerShell Direct; persist the result for offline verification.
    $process = Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
        -ArgumentList '/generalize /oobe /quit /quiet /unattend:C:\Windows\System32\Sysprep\ArcJumpstart-Unattend.xml' `
        -Wait -PassThru
    $result.ExitCode = $process.ExitCode
    $result.ImageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    try {
        $errorLog = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'
        if (Test-Path $errorLog) {
            $result.Panther = (Get-Content $errorLog -Tail 40) -join "`n"
        }
    }
    catch {
        $result.Error += " Could not read Panther errors: $($_.Exception.Message)"
    }
    $result | ConvertTo-Json | Set-Content "$resultPath.tmp" -Encoding UTF8
    Move-Item "$resultPath.tmp" $resultPath -Force
    & "$env:SystemRoot\System32\shutdown.exe" /s /t 5 /f
    if ($LASTEXITCODE -ne 0) {
        throw "Could not request template shutdown (exit code $LASTEXITCODE)."
    }
}
if ($result.ExitCode -ne 0 -or $result.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -or $result.Error) {
    exit 1
}
'@
            Set-Content -Path $runnerPath -Value $runner -Encoding UTF8
            $taskName = 'ArcJumpstart-Sysprep'
            $action = New-ScheduledTaskAction `
                -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`""
            Register-ScheduledTask `
                -TaskName $taskName `
                -Action $action `
                -User SYSTEM `
                -RunLevel Highest `
                -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            $configuration
        }

    Wait-TemplateGeneralization -VMName $stagingVmName -VhdPath $generalizedVhd
    if (-not $templateConfiguration -or @($templateConfiguration).Count -ne 1 -or
        $templateConfiguration.Build -ne '20348' -or
        $templateConfiguration.Edition -notin @('ServerStandard', 'ServerDatacenter')) {
        throw 'Template edition/build evidence is missing or invalid. Preserve the template; no versioned ready marker will be written.'
    }
    Remove-VM -Name $stagingVmName -Force
    Set-ItemProperty -Path $generalizedVhd -Name IsReadOnly -Value $true
    @{
        Version = 'windows-server-2022-gvlk-v1'
        SourceVhd = [IO.Path]::GetFullPath($SourceVhd)
        Edition = $templateConfiguration.Edition
        Build = $templateConfiguration.Build
        CompletedUtc = (Get-Date).ToUniversalTime().ToString('O')
    } | ConvertTo-Json | Set-Content -LiteralPath $readyMarker -Encoding UTF8 -ErrorAction Stop
    return $generalizedVhd
}

function New-NestedVM {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ParentVhd,

        [Parameter(Mandatory)]
        [int]$MemoryGB,

        [switch]$Linux
    )

    if (-not (Test-Path $ParentVhd)) {
        throw "Required base image is missing: $ParentVhd. Run stage 30 first."
    }

    $vmPath = Join-Path $vmRoot $Name
    $childVhd = Join-Path $vmPath "$Name.vhdx"
    $existingVm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    $parentMismatch = (Test-Path $childVhd) -and
        ((Get-VHD -Path $childVhd -ErrorAction Stop).ParentPath -ne $ParentVhd)
    if ($parentMismatch) {
        throw "Parent mismatch for $Name at $childVhd. Preserve the existing VM and disk; use deliberate recovery or a fresh lab. No automatic replacement is permitted."
    }
    if ($existingVm) {
        if (-not (Test-Path -LiteralPath $childVhd)) {
            throw "Existing VM $Name has no expected child disk at $childVhd. Preserve it and investigate; no replacement disk will be created."
        }
        $attachedChains = @(Get-VMHardDiskDrive -VM $existingVm -ErrorAction Stop | Where-Object Path |
            ForEach-Object { Get-VhdChainPaths -Path $_.Path })
        if ([IO.Path]::GetFullPath($childVhd) -notin $attachedChains) {
            throw "Existing VM $Name is not attached to its expected child disk. Preserve the VM/disks and investigate."
        }
    }
    elseif ((Test-Path -LiteralPath $childVhd) -and @(Get-GeneralizedParentDependents -ParentVhd $childVhd).Count) {
        throw "Disconnected child disk $childVhd still has dependents. Preserve its chain; do not attach an earlier disk state automatically."
    }
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

    if (-not (Test-Path $childVhd)) {
        New-VHD -Path $childVhd -ParentPath $ParentVhd -Differencing | Out-Null
    }

    if (-not $existingVm) {
        New-VM `
            -Name $Name `
            -Generation 2 `
            -MemoryStartupBytes ($MemoryGB * 1GB) `
            -VHDPath $childVhd `
            -Path $vmPath `
            -SwitchName $switchName | Out-Null
        Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    }

    $isRetired = $retiredVmNames -contains $Name
    Set-VM `
        -Name $Name `
        -ProcessorCount 2 `
        -AutomaticStartAction $(if ($isRetired) { 'Nothing' } else { 'Start' }) `
        -AutomaticStopAction ShutDown
    if ($isRetired) {
        if ((Get-VM -Name $Name).State -ne 'Off') {
            Stop-VM -Name $Name -Force
        }
        Write-Host "$Name is marked retired and will not be started by stage 40."
        return
    }

    if ((Get-VM -Name $Name).State -ne 'Running') {
        Start-VM -Name $Name
    }
}

try {
    $generalizedWindowsImage = New-GeneralizedParent `
        -TemplateName 'Windows-Server-2022' `
        -SourceVhd (Join-Path $imageRoot $WindowsImageFileName) `
        -MemoryGB $DcMemoryGB
    $definitions = @(
        @{
            Name = 'JS-DC-01'
            Parent = $generalizedWindowsImage
            Memory = $DcMemoryGB
            Linux = $false
        },
        @{
            Name = 'JS-SQL-01'
            Parent = $generalizedWindowsImage
            Memory = $SqlMemoryGB
            Linux = $false
        },
        @{
            Name = 'JS-SQL-AG-01'
            Parent = $generalizedWindowsImage
            Memory = $SqlMemoryGB
            Linux = $false
        },
        @{
            Name = 'JS-SQL-AG-02'
            Parent = $generalizedWindowsImage
            Memory = $SqlMemoryGB
            Linux = $false
        },
        @{
            Name = 'JS-UBUNTU-01'
            Parent = Join-Path $imageRoot $LinuxImageFileName
            Memory = $LinuxMemoryGB
            Linux = $true
        }
    )

    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage40] Creating and starting all nested guests before per-guest readiness checks."
    foreach ($definition in $definitions) {
        New-NestedVM `
            -Name $definition.Name `
            -ParentVhd $definition.Parent `
            -MemoryGB $definition.Memory `
            -Linux:$definition.Linux
    }

    foreach ($definition in $definitions) {
        if (-not $definition.Linux) {
            Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage40] Verifying heartbeat, OOBE, activation, and final name on $($definition.Name)."
            Wait-VMHeartbeat -VMName $definition.Name
            Wait-WindowsGuestOobe -VMName $definition.Name
            Invoke-WindowsGuest -VMName $definition.Name -ArgumentList (Get-WindowsProvisioningHelperScript) -ScriptBlock {
                param($HelperScript)
                . ([scriptblock]::Create($HelperScript))
                Enable-WindowsServer2022AzureKms
            }
            $restartNeeded = Invoke-WindowsGuest -VMName $definition.Name -ArgumentList $definition.Name -ScriptBlock {
                param($DesiredName)
                if ($env:COMPUTERNAME -ne $DesiredName) {
                    Rename-Computer -NewName $DesiredName -Force
                    return $true
                }
                return $false
            }

            if ($restartNeeded) {
                Restart-VM -Name $definition.Name -Force
            }
        }
    }

    $machineSids = foreach ($name in @('JS-DC-01', 'JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')) {
        Wait-VMHeartbeat -VMName $name
        $machineSid = Invoke-WindowsGuest -VMName $name -ScriptBlock {
            ((Get-LocalUser -Name Administrator).SID.Value -replace '-500$', '')
        }
        [pscustomobject]@{
            VMName = $name
            MachineSid = $machineSid
        }
    }
    $duplicateSids = $machineSids | Group-Object MachineSid | Where-Object Count -gt 1
    if ($duplicateSids) {
        $details = ($duplicateSids.Group | ForEach-Object { "$($_.VMName)=$($_.MachineSid)" }) -join ', '
        throw "The source VHDX produced duplicate Windows machine SIDs ($details). The image cannot be safely cloned for this lab; use generalized replacement images."
    }

    Disable-VMIntegrationService -VMName 'JS-DC-01' -Name 'Time Synchronization'
    Invoke-WindowsGuest -VMName 'JS-DC-01' -ArgumentList $DcStaticIp, $NestedGatewayIp -ScriptBlock {
        param($Address, $Gateway)
        $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        $current = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object IPAddress -eq $Address
        if (-not $current) {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Address -PrefixLength 24 -DefaultGateway $Gateway | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '1.1.1.1'
        }
        Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage40] Nested guests passed setup, activation, identity, and DC network preparation gates."
    }

    Get-VM | Where-Object Name -like 'JS-*' |
        Select-Object Name, State, ProcessorCount, MemoryAssigned, Uptime |
        Format-Table -AutoSize
}
finally {
    Stop-Transcript
}
