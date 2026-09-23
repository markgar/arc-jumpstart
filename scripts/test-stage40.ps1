$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../artifacts/scripts/40-create-nested-vms.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }

foreach ($name in @('Repair-TemplateEdgeRegistration', 'Wait-TemplateGeneralization', 'Wait-WindowsGuestOobe',
    'Enable-WindowsGuestEnhancedSession', 'Get-WindowsServer2022KmsConfiguration', 'New-WindowsServer2022Unattend', 'Invoke-WindowsLicenseCommand',
    'Enable-WindowsServer2022AzureKms', 'Get-WindowsProvisioningHelperScript', 'Get-VhdChainPaths',
    'Get-GeneralizedParentDependents', 'Get-GeneralizedParentCacheState', 'New-GeneralizedParent', 'New-NestedVM')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

& {
    $script:denyConnections = 1
    $script:serviceStatus = 'Stopped'
    $script:startupType = $null
    function Set-ItemProperty {
        param($Path, $Name, $Value)
        if ($Path -ne 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -or
            $Name -ne 'fDenyTSConnections' -or $Value -ne 0) {
            throw 'Enhanced Session Mode must enable the supported Remote Desktop policy.'
        }
        $script:denyConnections = $Value
    }
    function Get-ItemProperty {
        param($Path, $Name)
        [pscustomobject]@{ fDenyTSConnections = $script:denyConnections }
    }
    function Set-Service {
        param($Name, $StartupType)
        if ($Name -ne 'TermService') { throw 'Only TermService should be changed.' }
        $script:startupType = $StartupType
    }
    function Start-Service {
        param($Name)
        if ($Name -ne 'TermService') { throw 'Only TermService should be started.' }
        $script:serviceStatus = 'Running'
    }
    function Get-Service {
        param($Name)
        [pscustomobject]@{ Status = $script:serviceStatus }
    }

    Enable-WindowsGuestEnhancedSession
    if ($script:denyConnections -ne 0 -or
        $script:startupType -ne 'Automatic' -or
        $script:serviceStatus -ne 'Running') {
        throw 'Enhanced Session Mode guest prerequisites were not configured.'
    }
}
$runner = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$runner'
}, $true)
[void][System.Management.Automation.Language.Parser]::ParseInput($runner.Right.Expression.Value, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}

& {
    function Get-WindowsEdition { param([switch]$Online, $ErrorAction) @{ Edition = $script:edition } }
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_OperatingSystem') { return @{ BuildNumber = $script:build; ProductType = $script:productType } }
        if ($ClassName -ne 'SoftwareLicensingProduct' -or
            $Filter -ne "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'") {
            throw 'Activation must inspect installed Windows products only.'
        }
        $script:products
    }
    function Get-Command {
        param($Name, $CommandType, $ErrorAction)
        if ($Name -ne 'cscript.exe' -or $CommandType -ne 'Application') { throw 'Use the supported native script host.' }
        @{ Source = 'Invoke-FakeCscript' }
    }
    function Invoke-FakeCscript {
        $script:licenseCalls += ,@($args)
        if ($args[0] -ne '//NoLogo' -or $args[1] -notlike '*\System32\slmgr.vbs') { throw 'Invoke the Windows slmgr script, not a guessed installer.' }
        $verb = $args[2]
        $global:LASTEXITCODE = if ($verb -eq $script:failVerb) { 5 } else { 0 }
        if ($verb -eq '/ipk' -and $args[3] -ne (Get-WindowsServer2022KmsConfiguration).ProductKey) { throw 'Use the edition-specific public GVLK.' }
        if ($verb -eq '/skms' -and $args[3] -ne 'azkms.core.windows.net:1688') { throw 'Use the documented Azure KMS endpoint.' }
        if ($verb -eq '/ato' -and $script:applyActivation) { $script:products = $script:activationProducts }
        if ($verb -eq $script:errorTextVerb) { 'Error: 0xC004FD02' } else { 'Command completed.' }
    }
    function Write-Host { param($Object) }
    function New-LicensedProduct {
        param($Status = 1, $Channel = 'VOLUME_KMSCLIENT', $PartialKey = 'VMK7H')
        [pscustomobject]@{ LicenseStatus = $Status; Description = "Windows(R) Operating System, $Channel channel"; PartialProductKey = $PartialKey }
    }
    function Reset-Activation {
        $script:edition = 'ServerStandard'; $script:build = '20348'; $script:productType = 3
        $script:products = @((New-LicensedProduct 0))
        $script:activationProducts = @((New-LicensedProduct))
        $script:licenseCalls = @(); $script:failVerb = ''; $script:errorTextVerb = ''; $script:applyActivation = $true
    }
    Reset-Activation
    $password = 'A<&>"''special-password'
    foreach ($entry in @(
        @{ Edition = 'ServerStandard'; Key = 'VDYBN-27WPP-V4HQT-9VMD4-VMK7H' },
        @{ Edition = 'ServerDatacenter'; Key = 'WX4NM-KYWYW-QJJR4-XV3QB-6VM33' })) {
        $script:edition = $entry.Edition
        $configuration = Get-WindowsServer2022KmsConfiguration
        if ($configuration.ProductKey -cne $entry.Key) { throw 'Wrong published GVLK mapping.' }
        [xml]$xml = New-WindowsServer2022Unattend -AdministratorPassword $password
        $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $keyNodes = $xml.SelectNodes('//u:ProductKey', $ns)
        $key = $xml.SelectSingleNode('/u:unattend/u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:ProductKey', $ns)
        $passwordNode = $xml.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns)
        if ($keyNodes.Count -ne 1 -or $key.InnerText -cne $entry.Key -or $passwordNode.InnerText -cne $password) {
            throw 'Generated XML must put the correct key in specialize and preserve XML-escaped passwords.'
        }
        foreach ($setting in @('HideEULAPage', 'HideLocalAccountScreen', 'HideOnlineAccountScreens', 'HideWirelessSetupInOOBE')) {
            if ($xml.SelectSingleNode("//u:OOBE/u:$setting", $ns).InnerText -ne 'true') { throw 'Preserve existing OOBE settings.' }
        }
        if ($xml.SelectSingleNode('//u:ComputerName', $ns).InnerText -ne '*' -or
            $xml.SelectSingleNode('//u:OOBE/u:ProtectYourPC', $ns).InnerText -ne '3') { throw 'Preserve generalized-name and setup policy settings.' }
    }
    foreach ($unsupported in @('ServerStandardEval', 'ServerDatacenterEval', 'Professional', 'Unknown')) {
        $script:edition = $unsupported
        Assert-Throws { New-WindowsServer2022Unattend -AdministratorPassword $password } 'Unsupported Windows image'
        Assert-Throws { Enable-WindowsServer2022AzureKms } 'Unsupported Windows image'
    }
    Reset-Activation
    $script:build = '26100'
    Assert-Throws { Enable-WindowsServer2022AzureKms } 'Unsupported Windows image'
    if ($script:licenseCalls.Count) { throw 'Unsupported images must not invoke licensing commands.' }
    $script:build = '20348'; $script:productType = 1
    Assert-Throws { Get-WindowsServer2022KmsConfiguration } 'Unsupported Windows image'
    Reset-Activation
    Enable-WindowsServer2022AzureKms
    if (($script:licenseCalls | ForEach-Object { $_[2] }) -join ',' -ne '/skms,/ato') { throw 'An installed GVLK should not be reinstalled.' }
    $script:licenseCalls = @()
    Enable-WindowsServer2022AzureKms
    if ($script:licenseCalls.Count) { throw 'Already licensed expected KMS clients must skip activation.' }
    Reset-Activation
    $script:products = @((New-LicensedProduct 0 'VIRTUAL_MACHINE_ACTIVATION' 'OLDAV'))
    Enable-WindowsServer2022AzureKms
    if (($script:licenseCalls | ForEach-Object { $_[2] }) -join ',' -ne '/ipk,/skms,/ato') { throw 'Replace an unexpected channel with the supported GVLK before Azure KMS activation.' }
    foreach ($verb in @('/ipk', '/skms', '/ato')) {
        Reset-Activation
        $script:products = @((New-LicensedProduct 0 'VIRTUAL_MACHINE_ACTIVATION' 'OLDAV'))
        $script:failVerb = $verb
        Assert-Throws { Enable-WindowsServer2022AzureKms } 'failed (exit 5)'
        if ($script:licenseCalls[-1][2] -ne $verb) { throw 'Native licensing errors must halt the command sequence.' }
    }
    Reset-Activation
    $script:errorTextVerb = '/skms'
    Assert-Throws { Enable-WindowsServer2022AzureKms } '0xC004FD02'
    foreach ($invalidProducts in @(
        @(), @((New-LicensedProduct 0)), @((New-LicensedProduct 1 'VIRTUAL_MACHINE_ACTIVATION')),
        @((New-LicensedProduct 1 'VOLUME_KMSCLIENT' 'WRONG')), @((New-LicensedProduct), (New-LicensedProduct)),
        @((New-LicensedProduct), (New-LicensedProduct 1 'VOLUME_KMSCLIENT' '')))) {
        Reset-Activation
        $script:activationProducts = $invalidProducts
        Assert-Throws { Enable-WindowsServer2022AzureKms } 'activation postcondition failed'
    }
    Reset-Activation
    $script:products = @((New-LicensedProduct), (New-LicensedProduct))
    Assert-Throws { Enable-WindowsServer2022AzureKms } 'Multiple installed Windows'
    if ($script:licenseCalls.Count) { throw 'Ambiguous installations must not be modified.' }
    $script:products = @((New-LicensedProduct), (New-LicensedProduct 1 'VOLUME_KMSCLIENT' ''))
    Assert-Throws { Enable-WindowsServer2022AzureKms } 'Multiple installed Windows'
    if ($script:licenseCalls.Count) { throw 'Do not hide a second active Windows product merely because its partial key is absent.' }
    Reset-Activation
    $script:edition = 'ServerDatacenter'
    $script:products = @((New-LicensedProduct 0 'VOLUME_KMSCLIENT' '6VM33'))
    $script:activationProducts = @((New-LicensedProduct 1 'VOLUME_KMSCLIENT' '6VM33'))
    # Execute the actual serialized helper package used in the guest.
    & {
        . ([scriptblock]::Create((Get-WindowsProvisioningHelperScript)))
        Enable-WindowsServer2022AzureKms
        if ((Get-WindowsServer2022KmsConfiguration).Edition -ne 'ServerDatacenter') { throw 'Guest helper transport must preserve image detection.' }
    }
}

& {
    $labRoot = Join-Path (Get-Location) '.stage40-cache-fixture'
    $generalizedImageRoot = Join-Path $labRoot 'Generalized'
    $vmRoot = Join-Path $labRoot 'VMs'
    $parent = Join-Path $generalizedImageRoot 'Windows-Server-2022.vhdx'
    $sourceDisk = Join-Path $labRoot 'source.vhdx'
    $child = Join-Path $labRoot 'detached.vhdx'
    $snapshotDisk = Join-Path $labRoot 'detached.avhdx'
    function Test-Path {
        param($Path, $LiteralPath)
        if ($LiteralPath) { $Path = $LiteralPath }
        $script:cacheFiles.ContainsKey($Path)
    }
    function Get-Content { param($LiteralPath, [switch]$Raw, $ErrorAction) $script:cacheFiles[$LiteralPath] }
    function Get-ChildItem {
        param($LiteralPath, [switch]$Recurse, [switch]$File, $ErrorAction)
        if (-not $Recurse -or -not $File -or $ErrorAction -ne 'Stop') { throw 'Detached disk discovery must be recursive and fail closed.' }
        foreach ($entry in $script:cacheFiles.Keys) {
            [pscustomobject]@{ FullName = $entry; Extension = [IO.Path]::GetExtension($entry) }
        }
    }
    function Get-VM {
        param($Name, $ErrorAction)
        if ($Name) { return $script:stagingVm }
        $script:cacheVms
    }
    function Get-VMSnapshot { param($VM, $ErrorAction) $VM.Snapshots }
    function Get-VMHardDiskDrive {
        param($VM, $VMSnapshot, $ErrorAction)
        $owner = if ($VMSnapshot) { $VMSnapshot } else { $VM }
        foreach ($diskPath in $owner.Paths) { [pscustomobject]@{ Path = $diskPath } }
    }
    function Get-VHD {
        param($Path, $ErrorAction)
        if ($script:unreadableDisk -eq $Path -or -not $script:diskParents.ContainsKey($Path)) { throw 'Disk metadata unavailable' }
        [pscustomobject]@{ ParentPath = $script:diskParents[$Path] }
    }
    function Stop-VM { $script:cacheMutations++; throw 'Unsafe Stop-VM' }
    function Remove-VM { $script:cacheMutations++; throw 'Unsafe Remove-VM' }
    function Remove-Item { $script:cacheMutations++; throw 'Unsafe disk deletion' }
    function New-Item { $script:cacheMutations++; throw 'Unexpected creation before preflight' }
    function New-VHD { $script:cacheMutations++; throw 'Unsafe disk creation' }
    function Set-ItemProperty { $script:cacheMutations++; throw 'Unsafe parent attribute modification' }
    function Reset-Cache {
        $script:cacheFiles = @{ $sourceDisk = 'disk'; $parent = 'disk' }
        $script:diskParents = @{ $sourceDisk = $null; $parent = $sourceDisk }
        $script:cacheVms = @(); $script:cacheMutations = 0; $script:stagingVm = $null; $script:unreadableDisk = ''
    }
    function New-ReadyMarker {
        @{ Version = 'windows-server-2022-gvlk-v1'; SourceVhd = $sourceDisk; Build = '20348';
            Edition = 'ServerStandard'; CompletedUtc = '2026-09-16T08:00:00Z' } | ConvertTo-Json
    }
    $check = { Get-GeneralizedParentCacheState -ParentVhd $parent -SourceVhd $sourceDisk -LabRoot $labRoot }
    $build = { New-GeneralizedParent -TemplateName Windows-Server-2022 -SourceVhd $sourceDisk -MemoryGB 4 }
    Reset-Cache
    $script:cacheFiles["$parent.ready"] = New-ReadyMarker
    if ((& $check) -ne 'Ready' -or (& $build) -ne $parent -or $script:cacheMutations) { throw 'Valid versioned parents must be reused without modifying them.' }
    foreach ($marker in @('2026-09-16T08:00:00Z', (New-ReadyMarker).Replace('gvlk-v1', 'old-v0'),
        (New-ReadyMarker).Replace('20348', '26100'), (New-ReadyMarker).Replace('ServerStandard', 'ServerStandardEval'))) {
        Reset-Cache
        $script:cacheFiles["$parent.ready"] = $marker
        Assert-Throws $build 'Preserve existing guests and disks'
        if ($script:cacheMutations) { throw 'Stale markers must halt before stopping guests or touching disks.' }
    }
    Reset-Cache
    $script:cacheFiles["$parent.ready"] = New-ReadyMarker
    $script:cacheFiles.Remove($parent)
    Assert-Throws $build 'Stale or incompatible'
    Reset-Cache
    if ((& $check) -ne 'Build') { throw 'An unreferenced orphan can only be rebuilt after dependency preflight.' }
    $script:cacheFiles[$child] = 'disk'; $script:diskParents[$child] = $parent
    Assert-Throws $build 'marker is missing and its disk is in use'
    if ($script:cacheMutations) { throw 'Detached VHDX children must protect their parent.' }
    Reset-Cache
    $script:cacheFiles[$child] = 'disk'; $script:diskParents[$child] = $sourceDisk
    $script:cacheFiles[$snapshotDisk] = 'disk'; $script:diskParents[$snapshotDisk] = $parent
    Assert-Throws $build 'marker is missing and its disk is in use'
    if ($script:cacheMutations) { throw 'Detached AVHDX files must protect their parent.' }
    Reset-Cache
    $outsideChild = Join-Path (Get-Location) 'outside-child.vhdx'
    $script:diskParents[$outsideChild] = $parent
    $script:cacheVms = @(@{ Paths = @($outsideChild); Snapshots = @() })
    Assert-Throws $build 'marker is missing and its disk is in use'
    Reset-Cache
    $script:diskParents[$outsideChild] = $parent
    $script:cacheVms = @(@{ Paths = @($sourceDisk); Snapshots = @(@{ Paths = @($outsideChild) }) })
    Assert-Throws $build 'marker is missing and its disk is in use'
    Reset-Cache
    $script:cacheVms = @(@{ Paths = @($parent); Snapshots = @() })
    Assert-Throws $build 'Attached disk'
    Reset-Cache
    $script:cacheFiles[$snapshotDisk] = 'disk'; $script:diskParents[$snapshotDisk] = $child
    $script:diskParents[$child] = $parent
    Assert-Throws $build 'marker is missing and its disk is in use'
    Reset-Cache
    $script:cacheFiles[$child] = 'disk'; $script:diskParents[$child] = $parent; $script:unreadableDisk = $child
    Assert-Throws $build 'Cannot inspect VHD dependency'
    if ($script:cacheMutations) { throw 'Uninspectable dependency chains must not authorize replacement.' }
    Reset-Cache
    $script:cacheFiles[$child] = 'disk'; $script:diskParents[$child] = $child
    Assert-Throws $check 'Cyclic VHD dependency'
    Reset-Cache
    $script:stagingVm = @{ State = 'Running' }
    Assert-Throws $build 'Existing template VM'
    if ($script:cacheMutations) { throw 'Do not stop or replace a previous template operation.' }

    # Exercise successful creation and marker publication with platform work mocked.
    function New-Item { param($ItemType, $Path, [switch]$Force) }
    function New-VHD {
        param($Path, $ParentPath, [switch]$Differencing)
        if (-not $Differencing) { throw 'Never modify the source image directly.' }
        $script:cacheFiles[$Path] = 'disk'; $script:diskParents[$Path] = $ParentPath
    }
    function New-VM { param($Name, $Generation, $MemoryStartupBytes, $VHDPath, $Path, $SwitchName) }
    function Set-VM { param($Name, $ProcessorCount, $AutomaticStartAction) }
    function Enable-VMIntegrationService { param($VMName, $Name) }
    function Set-VMFirmware { param($VMName, $EnableSecureBoot) }
    function Start-VM { param($Name) }
    function Wait-VMHeartbeat { param($VMName) }
    function Invoke-WindowsGuest {
        param($VMName, $ArgumentList, $ScriptBlock)
        if ($ArgumentList.Count -ne 2 -or -not $ArgumentList[1].Contains('function New-WindowsServer2022Unattend') -or
            -not $ScriptBlock.ToString().Contains('New-WindowsServer2022Unattend -AdministratorPassword $AdministratorPassword')) {
            throw 'Template must receive and invoke the canonical answer-file helper.'
        }
        @{ Edition = 'ServerStandard'; Build = '20348' }
    }
    function Wait-TemplateGeneralization {
        param($VMName, $VhdPath)
        if ($script:sysprepFails) { throw 'Sysprep proof failed' }
        $script:generalizationVerified = $true
    }
    function Remove-VM {
        param($Name, [switch]$Force)
        if (-not $script:generalizationVerified) { throw 'Do not remove the staging VM before verified shutdown/generalization.' }
    }
    function Set-ItemProperty {
        param($Path, $Name, $Value)
        if ($Path -ne $parent -or -not $script:generalizationVerified) { throw 'Only seal the newly verified parent, never modify the source.' }
    }
    function Set-Content {
        [CmdletBinding()]
        param($LiteralPath, $Encoding, [Parameter(ValueFromPipeline)]$Value)
        process {
            if (-not $script:generalizationVerified) { throw 'No marker before verified generalization.' }
            $script:cacheFiles[$LiteralPath] = $Value
        }
    }
    Reset-Cache
    $script:cacheFiles.Remove($parent); $script:diskParents.Remove($parent)
    $script:generalizationVerified = $false; $script:sysprepFails = $false
    if ((& $build) -ne $parent -or (& $check) -ne 'Ready') { throw 'New parents must publish a reusable versioned marker only after verified Sysprep.' }
    Reset-Cache
    $script:cacheFiles.Remove($parent); $script:diskParents.Remove($parent)
    $script:generalizationVerified = $false; $script:sysprepFails = $true
    Assert-Throws $build 'Sysprep proof failed'
    if ($script:cacheFiles.ContainsKey("$parent.ready")) { throw 'Failed Sysprep must never publish a ready marker.' }
}

& {
    $vmRoot = Join-Path (Get-Location) '.stage40-vm-fixture'
    $parent = Join-Path $vmRoot 'parent.vhdx'
    $child = Join-Path (Join-Path $vmRoot 'test') 'test.vhdx'
    $otherDisk = Join-Path $vmRoot 'other.vhdx'
    function Test-Path {
        param($Path, $LiteralPath)
        if ($LiteralPath) { $Path = $LiteralPath }
        $Path -eq $parent -or ($Path -eq $child -and $script:childExists)
    }
    function Get-VM { param($Name, $ErrorAction) if ($script:vmExists) { @{ State = 'Running' } } }
    function Get-VHD { param($Path, $ErrorAction) @{ ParentPath = $(if ($Path -eq $child) { $script:childParent } else { $null }) } }
    function Get-VMHardDiskDrive { param($VM, $ErrorAction) @{ Path = $script:attachedDisk } }
    function Get-GeneralizedParentDependents { param($ParentVhd) if ($script:detachedDependents) { 'detached.avhdx' } }
    function New-Item { $script:vmMutations++ }
    function New-VHD { $script:vmMutations++; throw 'Must not replace an existing disk.' }
    function Set-ItemProperty { $script:vmMutations++; throw 'Must not modify parent attributes.' }
    function Stop-VM { $script:vmMutations++; throw 'Must preserve VM running state.' }
    function Remove-VM { $script:vmMutations++; throw 'Must not delete VM.' }
    function Remove-Item { $script:vmMutations++; throw 'Must not delete disk.' }
    $script:childExists = $true; $script:detachedDependents = $false
    foreach ($registered in @($true, $false)) {
        $script:vmExists = $registered; $script:childParent = $otherDisk; $script:vmMutations = 0
        Assert-Throws { New-NestedVM -Name test -ParentVhd $parent -MemoryGB 4 } 'Parent mismatch'
        if ($script:vmMutations) { throw 'Parent mismatches must preserve both registered and disconnected children.' }
    }
    $script:vmExists = $true; $script:childParent = $parent; $script:childExists = $false
    Assert-Throws { New-NestedVM -Name test -ParentVhd $parent -MemoryGB 4 } 'no expected child disk'
    $script:childExists = $true; $script:attachedDisk = $otherDisk
    Assert-Throws { New-NestedVM -Name test -ParentVhd $parent -MemoryGB 4 } 'not attached to its expected child disk'
    $script:vmExists = $false; $script:detachedDependents = $true
    Assert-Throws { New-NestedVM -Name test -ParentVhd $parent -MemoryGB 4 } 'Disconnected child disk'
    if ($script:vmMutations) { throw 'Unexpected attachments and detached chains must remain untouched.' }
}

function New-EdgePackage {
    param([string]$Version, [string]$InstallState = 'Installed', [bool]$NonRemovable = $false)
    [pscustomobject]@{
        PackageFullName = "Microsoft.MicrosoftEdge.Stable_${Version}_neutral__8wekyb3d8bbwe"
        Version = $Version
        NonRemovable = $NonRemovable
        PackageUserInformation = @([pscustomobject]@{ InstallState = $InstallState })
    }
}
function Get-AppxProvisionedPackage { param([switch]$Online) $script:provisioned }
function Get-AppxPackage {
    param([switch]$AllUsers, [string]$Name)
    if ($Name -ne 'Microsoft.MicrosoftEdge.Stable') { throw 'Cleanup must target Edge only.' }
    if ($AllUsers) { $script:allUsers } else { $script:installed }
}
function Remove-AppxPackage {
    param([string]$Package, [string]$ErrorAction)
    if ($script:removalFails) { throw 'Removal failed' }
    $script:removed += $Package
    $script:installed = @($script:installed | Where-Object PackageFullName -ne $Package)
    $script:allUsers = @($script:allUsers | Where-Object PackageFullName -ne $Package)
}

$old = New-EdgePackage '120.0.2210.61'
$current = New-EdgePackage '153.0.4234.32' 'Staged'
$script:provisioned = @([pscustomobject]@{
    DisplayName = 'Microsoft.MicrosoftEdge.Stable'
    PackageName = $current.PackageFullName
    Version = $current.Version
})
$script:installed = @($old)
$script:allUsers = @($old, $current)
$script:removed = @()
$script:removalFails = $false
Repair-TemplateEdgeRegistration
Repair-TemplateEdgeRegistration
if ($script:removed.Count -ne 1 -or $script:removed[0] -ne $old.PackageFullName) {
    throw 'Cleanup must remove only stale Edge and be rerunnable.'
}
$script:installed = @($current)
Repair-TemplateEdgeRegistration
if ($script:removed.Count -ne 1) { throw 'Provisioned Edge must be preserved.' }

$script:installed = @(New-EdgePackage '120.0.2210.61' 'Installed' $true)
Assert-Throws { Repair-TemplateEdgeRegistration } 'cannot be safely cleaned up'
$script:installed = @($old)
$savedProvisioned = $script:provisioned
$script:provisioned = @()
$script:allUsers = @($old)
Repair-TemplateEdgeRegistration
Repair-TemplateEdgeRegistration
if ($script:removed.Count -ne 2 -or $script:installed.Count -ne 0) {
    throw 'The known source-image registration must be removable without a provisioned replacement.'
}
$script:installed = @(New-EdgePackage '121.0.0.0')
Assert-Throws { Repair-TemplateEdgeRegistration } 'cannot be safely cleaned up'
$script:installed = @($old)
$script:provisioned = $savedProvisioned
$script:removalFails = $true
Assert-Throws { Repair-TemplateEdgeRegistration } 'Removal failed'
$script:removalFails = $false
$script:installed = @()
$script:allUsers = @($old)
Assert-Throws { Repair-TemplateEdgeRegistration } 'registrations remain'

$script:vmState = 'Off'
$script:diskRead = $false
$script:result = [pscustomobject]@{
    ExitCode = 0
    ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
    Error = ''
    Panther = ''
    SuccessTag = $true
}
function Get-VM { param($Name, $ErrorAction) [pscustomobject]@{ State = $script:vmState; Status = 'test' } }
function Read-TemplateGeneralizationResult {
    param($VhdPath)
    if ($script:vmState -ne 'Off') { throw 'Must not mount a running guest disk.' }
    $script:diskRead = $true
    $script:result
}
function Start-Sleep { param($Seconds) }

Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx'
if (-not $script:diskRead) { throw 'Must verify offline disk before accepting generalization.' }
$script:result.ImageState = 'IMAGE_STATE_COMPLETE'
$script:result.Panther = 'AppxSysprep.dll 0x80073cf2'
Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' } 'AppxSysprep.dll 0x80073cf2'
$script:result.ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
$script:result.ExitCode = 1
Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' } 'Sysprep failed'
$script:result.ExitCode = 0
$script:result.SuccessTag = $false
Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' } 'Sysprep failed'
$script:result = $null
Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' } 'Sysprep failed'
foreach ($state in @('Paused', 'Saved')) {
    $script:vmState = $state
    Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' } 'before verified generalization'
}
$script:vmState = 'Running'
$script:diskRead = $false
Assert-Throws { Wait-TemplateGeneralization -VMName 'test' -VhdPath 'test.vhdx' -TimeoutSeconds 0 } 'Timed out waiting for Sysprep'
if ($script:diskRead) { throw 'Must not mount a running guest disk.' }

function Invoke-WindowsGuest {
    param($VMName, $TimeoutSeconds, $ScriptBlock)
    if ($VMName -ne 'test') { throw 'Unexpected proof guest.' }
    if ($script:oobeQueryFails) { throw 'Native OOBE query failed.' }
    $index = [Math]::Min($script:oobeReads, $script:oobeStates.Count - 1)
    $script:oobeReads++
    $script:oobeStates[$index]
}
$script:oobeQueryFails = $false
$script:oobeReads = 0
$script:oobeStates = @(
    [pscustomobject]@{ Complete = $false; ImageState = 'IMAGE_STATE_UNDEPLOYABLE' },
    [pscustomobject]@{ Complete = $true; ImageState = 'IMAGE_STATE_COMPLETE' }
)
Wait-WindowsGuestOobe -VMName test
if ($script:oobeReads -ne 2) { throw 'OOBE must genuinely complete before proceeding.' }
$script:oobeReads = 0
$script:oobeStates = @([pscustomobject]@{ Complete = $false; ImageState = 'IMAGE_STATE_COMPLETE' })
Assert-Throws { Wait-WindowsGuestOobe -VMName test -TimeoutSeconds 0 } 'Windows first-boot setup did not complete'
$script:oobeStates = @([pscustomobject]@{ Complete = $true; ImageState = 'IMAGE_STATE_UNDEPLOYABLE' })
Assert-Throws { Wait-WindowsGuestOobe -VMName test -TimeoutSeconds 0 } 'Windows first-boot setup did not complete'
$script:oobeQueryFails = $true
Assert-Throws { Wait-WindowsGuestOobe -VMName test } 'Native OOBE query failed'
$source = $ast.Extent.Text
if ($source.IndexOf('Wait-WindowsGuestOobe -VMName $definition.Name') -gt $source.IndexOf('Rename-Computer -NewName $DesiredName')) {
    throw 'First-boot completion must precede guest renaming and its reboot.'
}
$activationCall = $ast.Find({
    param($n)
    $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Enable-WindowsServer2022AzureKms'
}, $true)
if (-not $activationCall -or $activationCall.Extent.StartOffset -lt $source.IndexOf('Wait-WindowsGuestOobe -VMName $definition.Name') -or
    $activationCall.Extent.EndOffset -gt $source.IndexOf('Rename-Computer -NewName $DesiredName')) {
    throw 'Activation must run after native OOBE completion and before rename/reboot.'
}
if ($source.Contains("Get-VM -Name 'JS-*'") -or $source.Contains('Rebuilding $Name because')) {
    throw 'Stage40 must not stop existing lab guests or automatically replace mismatched disks to rebuild a cache.'
}
if (-not $source.Contains('$unattend = New-WindowsServer2022Unattend -AdministratorPassword $AdministratorPassword') -or
    -not $source.Contains("Version = 'windows-server-2022-gvlk-v1'")) { throw 'Template generation must use the new answer file and versioned completion marker.' }
& {
    $loops = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'definition'
    }, $true))
    if ($loops.Count -ne 2) { throw 'Starting all guests and checking readiness must use separate phases.' }
    $definitions = @(
        @{ Name = 'dc'; Parent = 'windows'; Memory = 4; Linux = $false },
        @{ Name = 'sql1'; Parent = 'windows'; Memory = 8; Linux = $false },
        @{ Name = 'sql2'; Parent = 'windows'; Memory = 8; Linux = $false },
        @{ Name = 'sql3'; Parent = 'windows'; Memory = 8; Linux = $false },
        @{ Name = 'linux'; Parent = 'linux'; Memory = 4; Linux = $true }
    )
    $script:bootEvents = [Collections.Generic.List[string]]::new()
    function New-NestedVM {
        param($Name, $ParentVhd, $MemoryGB, [switch]$Linux)
        $script:bootEvents.Add("start:$Name")
    }
    function Wait-VMHeartbeat {
        param($VMName)
        if (@($script:bootEvents | Where-Object { $_ -like 'start:*' }).Count -ne 5) {
            throw 'No guest readiness wait may precede starting all guests.'
        }
        $script:bootEvents.Add("heartbeat:$VMName")
    }
    function Wait-WindowsGuestOobe {
        param($VMName)
        $script:bootEvents.Add("oobe:$VMName")
    }
    function Get-WindowsProvisioningHelperScript { 'mock-helper' }
    function Invoke-WindowsGuest {
        param($VMName, $ArgumentList, $ScriptBlock)
        if ("oobe:$VMName" -notin $script:bootEvents) { throw 'Native OOBE remains mandatory before activation or rename.' }
        if ($ScriptBlock.ToString() -like '*Rename-Computer*') { return $true }
    }
    function Restart-VM {
        param($Name, [switch]$Force)
        $script:bootEvents.Add("restart:$Name")
    }
    & ([scriptblock]::Create($loops[0].Extent.Text))
    & ([scriptblock]::Create($loops[1].Extent.Text))
    if (@($script:bootEvents | Where-Object { $_ -like 'restart:*' }).Count -ne 4) {
        throw 'Every renamed Windows guest must still be restarted.'
    }
    $sidLoop = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
            $node.Extent.Text.Contains('MachineSid = $machineSid')
    }, $true)
    if (-not $sidLoop -or -not $sidLoop.Extent.Text.Contains('Wait-VMHeartbeat -VMName $name') -or
        $sidLoop.Extent.StartOffset -lt $loops[1].Extent.EndOffset) {
        throw 'Post-reboot readiness and SID checks must follow initiation of all guest rename/reboots.'
    }
}
Write-Host 'Stage 40 regression checks passed.'
