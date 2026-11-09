$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot '../artifacts/scripts/image-media.ps1')

function Assert-MediaThrows {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}

$directory = Join-Path ([IO.Path]::GetTempPath()) "arc-media-test-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $directory | Out-Null
$originalWindir = $env:windir
try {
    $env:windir = Join-Path $directory 'host-windows'
    New-Item -ItemType Directory -Path (Join-Path $env:windir 'System32') | Out-Null
    Set-Content -LiteralPath (Join-Path $env:windir 'System32/bcdboot.exe') -Value fixture
    $diagnosticAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'inspect-image-media.ps1'), [ref]$null, [ref]$null)
    if ($diagnosticAst.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains 'InitializeBoot') {
        throw 'Image diagnostic/recovery options must be bound by a script parameter block.'
    }

    $bootShim = Join-Path $directory 'image-bcdboot.ps1'
    Set-Content -LiteralPath $bootShim -Value @'
if ($args.Count -notin @(6, 7) -or $args[0] -ne 'W:\Windows' -or
    $args[1] -ne '/s' -or $args[2] -ne 'S:' -or $args[3] -ne '/f' -or
    $args[4] -ne 'UEFI' -or $args[5] -ne '/v') { throw 'Invalid boot-file arguments.' }
if ($args.Count -eq 7 -and $args[6] -ne '/offline') { throw 'Require explicit offline servicing.' }
'Native boot diagnostic'
Write-Error -Message 'Native diagnostic on stderr' -ErrorId NativeCommandError
$global:LASTEXITCODE = if ($args.Count -eq 7) { -1058471934 } else { 7 }
'@
    $bootResult = Invoke-ImageBcdBoot $bootShim 'W:\Windows' 'S:'
    if ($bootResult -isnot [hashtable] -or $bootResult.ExitCode -ne 7 -or
        $bootResult.Output[0] -ne 'Native boot diagnostic' -or
        "$($bootResult.Output[1])" -ne 'Native diagnostic on stderr' -or $ErrorActionPreference -ne 'Stop') {
        throw 'Preserve the exact boot-tool exit code and diagnostic output.'
    }
    $offlineResult = Invoke-ImageBcdBoot $bootShim 'W:\Windows' 'S:' -Offline
    if ($offlineResult.ExitCode -ne -1058471934 -or $offlineResult.Output[0] -ne 'Native boot diagnostic') {
        throw 'Offline servicing must preserve native security failures, not retry or report success.'
    }
    Set-Content -LiteralPath $bootShim -Value @'
Write-Error -Message 'Native servicing warning' -ErrorId NativeCommandError
$global:LASTEXITCODE = 0
'@
    $warningResult = Invoke-ImageBcdBoot $bootShim 'W:\Windows' 'S:'
    if ($warningResult.ExitCode -ne 0 -or "$($warningResult.Output[0])" -ne 'Native servicing warning') {
        throw 'Collect native warnings and await the real exit status; output-file gates determine completeness.'
    }
    Assert-MediaThrows {
        Invoke-ImageBcdBoot (Join-Path $directory 'missing-bcdboot.exe') 'W:\Windows' 'S:'
    } 'not recognized'
    $global:LASTEXITCODE = 0

    & {
        $script:reservedCount = 1
        $script:reservedCreated = 0
        function New-VHD { param($Path, $SizeBytes, [switch]$Dynamic) }
        function Mount-VHD { param($Path, [switch]$NoDriveLetter, [switch]$Passthru) @{ DiskNumber = 42 } }
        function Initialize-Disk {
            param($Number, $PartitionStyle)
            if ($Number -ne 42 -or $PartitionStyle -ne 'GPT') { throw 'Only initialize the new image disk.' }
        }
        function Get-Partition {
            param($DiskNumber)
            if ($DiskNumber -ne 42) { throw 'Only inspect the new image disk.' }
            for ($i = 0; $i -lt $script:reservedCount; $i++) {
                @{ GptType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' }
            }
        }
        function New-Partition {
            param($DiskNumber, $Size, $GptType, [switch]$AssignDriveLetter, [switch]$UseMaximumSize)
            if ($DiskNumber -ne 42) { throw 'Only partition the new image disk.' }
            if ($GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}') { $script:reservedCreated++ }
            @{ DriveLetter = $(if ($UseMaximumSize) { 'W' } else { 'S' }) }
        }
        function Format-Volume { param($FileSystem, $NewFileSystemLabel, $Confirm) }
        function Dismount-VHD { param($Path) }
        $layout = New-ImageBuildDisk (Join-Path $directory 'layout.vhdx')
        if ($script:reservedCreated -ne 0 -or $layout.EfiPath -ne 'S:\' -or $layout.WindowsPath -ne 'W:\') {
            throw 'Reuse the MSR automatically created by Windows GPT initialization.'
        }
        $script:reservedCount = 0
        [void](New-ImageBuildDisk (Join-Path $directory 'layout-without-msr.vhdx'))
        if ($script:reservedCreated -ne 1) { throw 'Create an MSR only when Windows did not already create one.' }
        $script:reservedCount = 2
        Assert-MediaThrows { New-ImageBuildDisk (Join-Path $directory 'bad-layout.vhdx') } 'duplicate Microsoft Reserved'
    }

    $settings = @{
        IMAGE_MODE = 'installation-media'
        WINDOWS_ISO_URL = 'https://example.invalid/windows.iso'
        WINDOWS_ISO_SHA256 = 'a' * 64
        UBUNTU_ISO_URL = 'https://example.invalid/ubuntu.iso'
        UBUNTU_ISO_SHA256 = 'b' * 64
        LINUX_SSH_PUBLIC_KEY = 'ssh-ed25519 YWJj test-key'
    }
    $media = Get-LabImageSettings $settings
    if (-not $media.IncludeLinux) { throw 'Linux must remain enabled by default.' }
    $windowsOnly = $settings.Clone()
    $windowsOnly.INCLUDE_LINUX = 'false'
    foreach ($key in @('UBUNTU_ISO_URL', 'UBUNTU_ISO_SHA256', 'LINUX_SSH_PUBLIC_KEY')) { $windowsOnly.Remove($key) }
    if ((Get-LabImageSettings $windowsOnly).IncludeLinux) { throw 'Windows-only mode must not require Linux settings.' }
    $windowsOnly.INCLUDE_LINUX = 'FALSE'
    Assert-MediaThrows { Get-LabImageSettings $windowsOnly } 'INCLUDE_LINUX'
    & {
        function Join-Path { param($Path, $ChildPath) "$Path/$ChildPath" }
        function Protect-ImageBuildDirectory { param($Path) }
        function Get-WindowsEvaluationMedia { param($Url, $Sha256, $Path) @{ Path = 'windows.iso'; Sha256 = $Sha256 } }
        function New-WindowsEvaluationImage { param($Iso, $Sha256, $Path, $Password, $WindowsServerVersion) $script:windowsPrepared = $true }
        function Get-ImageBuildSshKey { throw 'Do not generate Linux keys when excluded.' }
        function Get-VerifiedIso { throw 'Do not download Ubuntu when excluded.' }
        function New-UbuntuInstallerImage { throw 'Do not prepare Ubuntu when excluded.' }
        $script:windowsPrepared = $false
        Initialize-InstallationMedia -WindowsUrl fixture -WindowsHash ('a' * 64) -IncludeLinux:$false
        if (-not $script:windowsPrepared) { throw 'Windows media must still be prepared when Linux is excluded.' }
    }
    if ($media.LicenseMode -ne 'evaluation' -or
        $media.WindowsFileName -ne 'InstallationMedia/Windows-Server-2022-Eval.vhdx' -or
        $media.LinuxFileName -ne 'InstallationMedia/Ubuntu-22.04.vhdx') { throw 'Media settings do not route to the independent cache.' }
    if ((Get-LabImageSettings @{}).WindowsFileName -ne 'ArcBox-Win2K22.vhdx') { throw 'Legacy defaults changed.' }
    if ((Get-LabImageSettings @{ WINDOWS_IMAGE_FILE_NAME = 'custom.vhdx' }).WindowsFileName -ne 'custom.vhdx') { throw 'Legacy overrides changed.' }
    $official = $settings.Clone()
    $official.WINDOWS_ISO_URL = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
    $official.WINDOWS_ISO_SHA256 = 'auto'
    [void](Get-LabImageSettings $official)
    $server2025 = $official.Clone()
    $server2025.WINDOWS_SERVER_VERSION = '2025'
    $server2025.INCLUDE_APPLIANCE_VM = 'true'
    $server2025.WINDOWS_ISO_URL = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us'
    $newMedia = Get-LabImageSettings $server2025
    if ($newMedia.WindowsServerVersion -cne '2025' -or
        $newMedia.WindowsFileName -cne 'InstallationMedia/Windows-Server-2025-Eval.vhdx' -or
        -not $newMedia.IncludeAppliance -or (Get-LabImageSettings @{}).IncludeAppliance) {
        throw 'Server 2025 and appliance selection must be explicit without changing existing lab defaults.'
    }
    Assert-MediaThrows { Get-LabImageSettings @{ WINDOWS_SERVER_VERSION = '2025' } } 'require IMAGE_MODE'
    Assert-MediaThrows { Get-LabImageSettings @{ WINDOWS_SERVER_VERSION = '2026' } } 'WINDOWS_SERVER_VERSION'
    Assert-MediaThrows { Get-LabImageSettings @{ INCLUDE_APPLIANCE_VM = 'TRUE' } } 'INCLUDE_APPLIANCE_VM'
    $wrong2025Source = $server2025.Clone()
    $wrong2025Source.WINDOWS_ISO_URL = $official.WINDOWS_ISO_URL
    Assert-MediaThrows { Get-LabImageSettings $wrong2025Source } 'official Windows Server 2025'
    $notOfficial = $official.Clone()
    $notOfficial.WINDOWS_ISO_URL = 'https://example.invalid/media.iso'
    Assert-MediaThrows { Get-LabImageSettings $notOfficial } 'restricted to the official'
    foreach ($invalid in @(
        @{ IMAGE_MODE = 'other' }, @{ WINDOWS_ISO_SHA256 = 'bad' },
        @{ UBUNTU_ISO_URL = 'http://example.invalid/linux.iso' },
        @{ WINDOWS_ISO_URL = 'https://user:password@example.invalid/windows.iso' },
        @{ LINUX_SSH_PUBLIC_KEY = '-----BEGIN OPENSSH PRIVATE KEY-----' })) {
        $copy = $settings.Clone()
        foreach ($key in $invalid.Keys) { $copy[$key] = $invalid[$key] }
        Assert-MediaThrows { Get-LabImageSettings $copy } '*'
    }

    $diskPath = Join-Path $directory 'base.vhdx'
    $evidence = @{ Version = 'fixture-v1'; IsoSha256 = 'a' * 64 }
    if (Test-ImageBuildReceipt $diskPath $evidence) { throw 'Missing disks are not ready.' }
    Set-Content -LiteralPath $diskPath -Value fixture
    Assert-MediaThrows { Test-ImageBuildReceipt $diskPath $evidence } 'Incomplete image cache'
    Write-ImageBuildReceipt $diskPath $evidence
    if (-not (Test-ImageBuildReceipt $diskPath $evidence)) { throw 'Valid receipts must be reusable.' }
    Assert-MediaThrows { Test-ImageBuildReceipt $diskPath @{ Version = 'fixture-v2' } } 'Incompatible image cache'
    $record = Get-Content "$diskPath.ready" -Raw | ConvertFrom-Json
    if ((Get-Content "$diskPath.ready" -Raw) -notmatch '"CompletedUtc":\s*"[^"]+Z"') { throw 'Record real UTC completion evidence.' }

    & {
        $script:publisherDownloads = 0
        $script:blockedRedirect = $false
        $script:viaAlias = $false
        $script:publisherSignature = 'Valid'
        function New-EvaluationMediaRequest {
            param($Uri)
            $request = [pscustomobject]@{
                AllowAutoRedirect = $true; Method = ''; Timeout = 0; Uri = $Uri
            }
            $request | Add-Member ScriptMethod GetResponse {
                if ($this.AllowAutoRedirect -or $this.Method -ne 'HEAD') { throw 'Resolve each HTTPS redirect explicitly.' }
                $redirecting = $this.Uri.Host -in @('go.microsoft.com', 'aka.ms')
                $next = if ($script:blockedRedirect) { 'https://example.invalid/source.iso' }
                    elseif ($script:viaAlias -and $this.Uri.Host -eq 'go.microsoft.com') { 'https://aka.ms/WinServ2025iso-enus' }
                    else { 'https://software-static.download.prss.microsoft.com/source.iso' }
                $response = [pscustomobject]@{
                    StatusCode = $(if ($redirecting) { 302 } else { 200 })
                    Headers = @{ Location = $next }; ContentLength = 5GB
                }
                $response | Add-Member ScriptMethod Dispose {}
                $response
            }
            $request
        }
        function Start-BitsTransfer {
            param($Source, $Destination, $ErrorAction)
            $script:publisherDownloads++
            Set-Content -LiteralPath $Destination -Value official-media-fixture
        }
        function Mount-ImageIso { param($Path) $directory }
        function Dismount-DiskImage {
            param($ImagePath)
            [pscustomobject]@{ Path = 'MSFT_DiskImage:diagnostic-metadata'; Attached = $false }
        }
        function Get-AuthenticodeSignature {
            param($FilePath)
            @{ Status = $script:publisherSignature; SignerCertificate = @{ Subject = 'O=Microsoft Corporation,C=US' } }
        }
        $path = Join-Path $directory 'publisher.iso'
        $media = Get-WindowsEvaluationMedia $official.WINDOWS_ISO_URL auto $path
        if ($media -isnot [hashtable] -or $media.Path -cne $path -or
            $media.Sha256 -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path "$path.source.json")) {
            throw 'Record the verified host-side Windows fingerprint.'
        }
        [void](Get-WindowsEvaluationMedia $official.WINDOWS_ISO_URL auto $path)
        if ($script:publisherDownloads -ne 1) { throw 'Never download verified Windows media again on cache reuse.' }
        $script:viaAlias = $true
        $newPath = Join-Path $directory 'publisher-2025.iso'
        $newMedia = Get-WindowsEvaluationMedia $server2025.WINDOWS_ISO_URL auto $newPath
        if ($newMedia.Path -cne $newPath -or $script:publisherDownloads -ne 2) {
            throw 'The official Server 2025 source must resolve its approved Microsoft alias.'
        }
        Assert-MediaThrows { Resolve-EvaluationMediaUri 'https://aka.ms/not-an-approved-iso' } 'outside the approved Microsoft HTTPS hosts'
        $script:viaAlias = $false
        Set-Content -LiteralPath $path -Value changed
        Assert-MediaThrows { Get-WindowsEvaluationMedia $official.WINDOWS_ISO_URL auto $path } 'verified source receipt'
        $script:blockedRedirect = $true
        Assert-MediaThrows { Resolve-EvaluationMediaUri $official.WINDOWS_ISO_URL } 'outside the approved Microsoft HTTPS hosts'
        $script:blockedRedirect = $false
        $script:publisherSignature = 'HashMismatch'
        $bad = Join-Path $directory 'bad-publisher.iso'
        Assert-MediaThrows { Get-WindowsEvaluationMedia $official.WINDOWS_ISO_URL auto $bad } 'valid Microsoft signature'
        if ((Test-Path $bad) -or (Test-Path "$bad.source.json")) { throw 'Unsigned media must never be published or adopted.' }
        Assert-MediaThrows { Get-WindowsEvaluationMedia 'https://example.invalid/windows.iso' auto $bad } 'exact official'
    }

    & {
        function Start-BitsTransfer {
            param($Source, $Destination, $ErrorAction)
            $script:downloadCount++
            Set-Content -LiteralPath $Destination -Value verified-media
        }
        $script:downloadCount = 0
        $fixture = Join-Path $directory 'fixture.iso'
        Set-Content -LiteralPath $fixture -Value verified-media
        $hash = (Get-FileHash $fixture -Algorithm SHA256).Hash
        $path = Join-Path $directory 'download.iso'
        [void](Get-VerifiedIso 'https://example.invalid/media.iso' $hash $path)
        [void](Get-VerifiedIso 'https://example.invalid/media.iso' $hash $path)
        if ($script:downloadCount -ne 1) { throw 'Reuse verified local downloads.' }
        Assert-MediaThrows { Get-VerifiedIso 'https://example.invalid/media.iso' ('f' * 64) $path } 'Cached ISO checksum mismatch'
        $badPath = Join-Path $directory 'bad.iso'
        Assert-MediaThrows { Get-VerifiedIso 'https://example.invalid/media.iso' ('f' * 64) $badPath } 'ISO checksum mismatch'
        if (Test-Path $badPath) { throw 'Never publish an unverified download.' }
    }

    [xml]$answer = New-EvaluationUnattend -Password 'FakeOnly<&>"123!'
    $ns = [Xml.XmlNamespaceManager]::new($answer.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    if ($answer.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns).InnerText -cne 'FakeOnly<&>"123!' -or
        $answer.SelectNodes('//u:ProductKey', $ns).Count) { throw 'Initial Evaluation setup must preserve escaped credentials without installing a KMS key.' }

    & {
        $source = Join-Path $directory 'windows-iso'
        $target = Join-Path $directory 'windows-mount'
        $efi = Join-Path $directory 'efi-mount'
        New-Item -ItemType Directory -Path (Join-Path $source 'sources'), $target, $efi -Force | Out-Null
        $script:wrongEdition = $false
        $script:bootFailure = $false
        $script:mountedWindows = 0
        $script:mountedIso = 0
        function Mount-ImageIso { param($Path) $script:mountedIso++; $source }
        function Get-AuthenticodeSignature {
            param($FilePath)
            @{ Status = $(if ($script:badWindowsSignature) { 'HashMismatch' } else { 'Valid' })
                SignerCertificate = @{ Subject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US' } }
        }
        function Dismount-DiskImage { param($ImagePath) $script:mountedIso-- }
        function Get-WindowsImage {
            param($ImagePath, $Index, $ErrorAction)
            if (-not $Index) { return @(@{ ImageIndex = 1 }, @{ ImageIndex = 4 }) }
            @{ ImageIndex = $Index; EditionId = $(if ($script:wrongEdition) { 'ServerDatacenter' } else { 'ServerDatacenterEval' })
                InstallationType = $(if ($Index -eq 1) { 'Server Core' } else { 'Server' })
                Version = "10.0.$script:wimBuild.1"; Architecture = 9; Languages = @('en-US') }
        }
        function New-ImageBuildDisk {
            param($Path)
            if (Test-Path -LiteralPath $Path) { throw 'Do not replace an existing disk.' }
            $script:mountedWindows++
            Set-Content -LiteralPath $Path -Value fixture
            @{ EfiPath = $efi; WindowsPath = $target }
        }
        function Expand-WindowsImage {
            param($ImagePath, $Index, $ApplyPath, [switch]$CheckIntegrity, $ErrorAction)
            if ($Index -ne 4 -or -not $CheckIntegrity) { throw 'Apply the validated Desktop Experience image with integrity checking.' }
            New-Item -ItemType Directory -Path (Join-Path $target 'Windows/System32') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'Windows/System32/bcdboot.exe') -Value fixture
        }
        function Invoke-ImageBcdBoot {
            param($Executable, $WindowsDirectory, $SystemVolume, [switch]$Offline)
            $expectedExecutable = if ($script:wimBuild -eq 26100) { Join-Path $env:windir 'System32/bcdboot.exe' }
                else { Join-Path $target 'Windows/System32/bcdboot.exe' }
            if ($Executable -cne $expectedExecutable -or $Offline.IsPresent -ne ($script:wimBuild -eq 26100) -or
                $WindowsDirectory -cne (Join-Path $target 'Windows') -or $SystemVolume -cne $efi.TrimEnd('\')) {
                throw 'Use native offline BCDBoot for 2025, legacy image BCDBoot for 2022, and only the image volumes.'
            }
            if (-not (Test-Path (Join-Path $efi 'EFI/Microsoft/Boot') -PathType Container) -or
                -not (Test-Path (Join-Path $efi 'EFI/Boot') -PathType Container)) {
                throw 'Create the new image EFI destination directories before invoking BCDBoot.'
            }
            foreach ($bootFile in @('EFI/Microsoft/Boot/BCD', 'EFI/Microsoft/Boot/bootmgfw.efi', 'EFI/Boot/bootx64.efi')) {
                $bootPath = Join-Path $efi $bootFile
                if ($script:missingBootFile -eq $bootFile) {
                    if (Test-Path $bootPath) { Remove-Item -LiteralPath $bootPath }
                }
                else { Set-Content -LiteralPath $bootPath -Value fixture }
            }
            @{ ExitCode = $(if ($script:bootFailure -and $Offline) { -1058471934 }
                elseif ($script:bootFailure) { 1 } else { 0 }); Output = @('Boot-file diagnostic fixture') }
        }
        function Dismount-VHD { param($Path) $script:mountedWindows-- }
        function Set-ItemProperty { param($LiteralPath, $Name, $Value) }
        $script:wimBuild = 20348
        $windowsPath = Join-Path $directory 'windows-base.vhdx'
        New-WindowsEvaluationImage fixture ('a' * 64) $windowsPath 'FakeOnly<&>"123!'
        if ($script:mountedWindows -ne 0 -or $script:mountedIso -ne 0 -or -not (Test-Path "$windowsPath.ready")) {
            throw 'Windows preparation must unmount all media before publishing a receipt.'
        }
        [xml]$xml = Get-Content (Join-Path $target 'Windows/Panther/Unattend.xml') -Raw
        $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        if ($xml.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns).InnerText -cne 'FakeOnly<&>"123!') { throw 'Stage-40 Administrator credentials must match initial setup.' }
        $newWindowsPath = Join-Path $directory 'windows-2025-base.vhdx'
        Assert-MediaThrows {
            New-WindowsEvaluationImage fixture ('a' * 64) $newWindowsPath 'JS123!!' -WindowsServerVersion 2025
        } 'Windows Server 2025'
        if (Test-Path $newWindowsPath) { throw 'A Server 2022 WIM must not produce a Server 2025 disk.' }
        $script:wimBuild = 26100
        New-WindowsEvaluationImage fixture ('a' * 64) $newWindowsPath 'JS123!!' -WindowsServerVersion 2025
        if ((Get-Content "$newWindowsPath.ready" -Raw | ConvertFrom-Json).Version -cne 'windows-2025-eval-media-v2') {
            throw 'Server 2025 media needs separate cache provenance.'
        }
        Assert-MediaThrows {
            New-WindowsEvaluationImage fixture ('a' * 64) $newWindowsPath 'JS123!!' -WindowsServerVersion 2022
        } 'Incompatible image cache'
        $oldWindowsPath = Join-Path $directory 'old-windows-2025.vhdx'
        Copy-Item -LiteralPath $newWindowsPath -Destination $oldWindowsPath
        $oldReceipt = Get-Content "$newWindowsPath.ready" -Raw | ConvertFrom-Json
        $oldReceipt.Version = 'windows-2025-eval-media-v1'
        $oldReceipt | ConvertTo-Json | Set-Content "$oldWindowsPath.ready"
        Assert-MediaThrows {
            New-WindowsEvaluationImage fixture ('a' * 64) $oldWindowsPath 'JS123!!' -WindowsServerVersion 2025
        } 'Incompatible image cache'
        $script:wimBuild = 20348
        $script:wrongEdition = $true
        $wrongPath = Join-Path $directory 'wrong-windows.vhdx'
        Assert-MediaThrows { New-WindowsEvaluationImage fixture ('a' * 64) $wrongPath fake } 'Require exactly one'
        if (Test-Path $wrongPath) { throw 'Reject unsupported media before disk creation.' }
        $script:wrongEdition = $false
        $script:badWindowsSignature = $true
        Assert-MediaThrows { New-WindowsEvaluationImage fixture ('a' * 64) (Join-Path $directory 'unsigned.vhdx') fake } 'valid Microsoft signature'
        $script:badWindowsSignature = $false
        $script:bootFailure = $true
        $badPath = Join-Path $directory 'unbootable.vhdx'
        Assert-MediaThrows { New-WindowsEvaluationImage fixture ('a' * 64) $badPath fake } 'BCDBoot failed'
        if ((Test-Path "$badPath.ready") -or $script:mountedWindows -ne 0 -or $script:mountedIso -ne 0) {
            throw 'Failed boot preparation must clean mounts but preserve a non-ready disk for diagnosis.'
        }
        $script:wimBuild = 26100
        $blockedPath = Join-Path $directory 'blocked-windows-2025.vhdx'
        Assert-MediaThrows {
            New-WindowsEvaluationImage fixture ('a' * 64) $blockedPath fake -WindowsServerVersion 2025
        } 'BCDBoot failed with exit code -1058471934'
        if ((Test-Path "$blockedPath.ready") -or $script:mountedWindows -ne 0 -or $script:mountedIso -ne 0) {
            throw 'A Server 2025 native security failure must not publish readiness or leave media mounted.'
        }
        $script:bootFailure = $false
        foreach ($missing in @('EFI/Microsoft/Boot/BCD', 'EFI/Microsoft/Boot/bootmgfw.efi', 'EFI/Boot/bootx64.efi')) {
            $script:missingBootFile = $missing
            $incompletePath = Join-Path $directory ("missing-{0}.vhdx" -f [IO.Path]::GetFileName($missing))
            Assert-MediaThrows {
                New-WindowsEvaluationImage fixture ('a' * 64) $incompletePath fake -WindowsServerVersion 2025
            } 'Windows UEFI boot file is missing after BCDBoot'
            if ((Test-Path "$incompletePath.ready") -or $script:mountedWindows -ne 0 -or $script:mountedIso -ne 0) {
                throw 'Native success alone must not publish an image missing any required UEFI boot file.'
            }
        }
    }

    & {
        $source = Join-Path $directory 'iso'
        $target = Join-Path $directory 'mounted'
        foreach ($path in @('casper', 'EFI/BOOT', 'boot/grub')) {
            New-Item -ItemType Directory -Path (Join-Path $source $path) -Force | Out-Null
        }
        foreach ($path in @('casper/vmlinuz', 'casper/initrd', 'EFI/BOOT/BOOTX64.EFI')) {
            Set-Content -LiteralPath (Join-Path $source $path) -Value fixture
        }
        Set-Content -LiteralPath (Join-Path $source 'boot/grub/grub.cfg') -Value @'
set timeout=30
menuentry "Try or Install Ubuntu Server" {
    linux /casper/vmlinuz ---
    initrd /casper/initrd
}
'@
        function Mount-ImageIso { param($Path) $source }
        function Dismount-DiskImage { param($ImagePath) }
        function New-ImageBuildDisk {
            param($Path, [switch]$Installer)
            if (-not $Installer) { throw 'Use an isolated FAT32 installer disk.' }
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath $Path -Value fixture
            @{ EfiPath = $target }
        }
        function Dismount-VHD { param($Path) $script:dismounts++ }
        function Set-ItemProperty { param($LiteralPath, $Name, $Value) }
        function Set-Content {
            [CmdletBinding()]
            param($LiteralPath, [Parameter(ValueFromPipeline)]$Value, $Encoding)
            process {
                $encoder = if ($Encoding -eq 'UTF8') { [Text.UTF8Encoding]::new($true) }
                    else { [Text.Encoding]::ASCII }
                [IO.File]::WriteAllText($LiteralPath, [string]$Value, $encoder)
            }
        }
        $script:dismounts = 0
        $installerPath = Join-Path $directory 'installer.vhdx'
        New-UbuntuInstallerImage -Iso fixture -Sha256 ('b' * 64) -Path $installerPath `
            -PublicKeys @('ssh-ed25519 YWJj host', 'ssh-ed25519 ZGVm learner')
        $grub = Get-Content (Join-Path $target 'boot/grub/grub.cfg') -Raw
        if ($grub -notmatch 'set timeout=0' -or $grub -notmatch 'linux /casper/vmlinuz autoinstall ds=nocloud') { throw 'Boot must select unattended setup without keyboard interaction.' }
        $userData = Get-Content (Join-Path $target 'user-data') -Raw
        $seedBytes = [IO.File]::ReadAllBytes((Join-Path $target 'user-data'))
        if ([Text.Encoding]::ASCII.GetString($seedBytes, 0, 13) -cne '#cloud-config') {
            throw 'cloud-init must see #cloud-config at byte zero, including on Windows PowerShell 5.1.'
        }
        $config = ($userData -replace '^#cloud-config\s*', '') | ConvertFrom-Json
        if ($config.autoinstall.storage.layout.match.size -ne 'largest' -or
            $config.autoinstall.identity.password -ne '*' -or $config.autoinstall.ssh.'allow-pw' -ne $false -or
            $config.autoinstall.ssh.'authorized-keys'.Count -ne 2 -or
            $config.autoinstall.shutdown -ne 'poweroff' -or $script:dismounts -ne 1) {
            throw 'Ubuntu must target only its isolated blank disk, use supplied SSH keys, and shut down for installed-OS verification.'
        }
        if ($config.autoinstall.network.ethernets.ethernet.'dhcp-identifier' -ne 'mac') { throw 'DHCP identity must be discoverable without a preinstalled KVP daemon.' }
    }

    & {
        $build = @{ Ready = $false; Name = 'TEMPLATE-Ubuntu-22.04'; StartedUtc = [DateTime]::UtcNow
            Path = (Join-Path $directory 'ubuntu.vhdx'); InstallerChild = 'installer-child'
            Key = @{ Path = (Join-Path $directory 'key'); Ssh = 'Invoke-MediaFakeSsh' }
            Expected = @{ Version = 'ubuntu-base-media-v1' } }
        $script:sshFailure = $false
        $script:sealed = $false
        function Wait-ImageVmOff { param($Name, $Deadline) }
        function Get-VMHardDiskDrive {
            param($VMName)
            @(@{ Path = $build.Path }, @{ Path = $build.InstallerChild })
        }
        function Remove-VMHardDiskDrive { param([Parameter(ValueFromPipeline)]$Drive) }
        function Set-VMFirmware { param($VMName, $FirstBootDevice) }
        function Start-VM { param($Name) }
        function Get-VMNetworkAdapter { param($VMName) @{ MacAddress = '001122334455' } }
        function Get-DhcpServerv4Lease {
            param($ScopeId, $ErrorAction)
            @{ ClientId = '01-00-11-22-33-44-55'; AddressState = 'Active'; IPAddress = '192.168.128.100' }
        }
        function Invoke-MediaFakeSsh {
            if ($args -contains 'sudo -n systemctl poweroff') {
                if (-not $script:verifiedSsh) { throw 'No shutdown before installed-OS verification.' }
                $global:LASTEXITCODE = 255
            }
            else {
                if ($args[-1] -notlike '*image-installed*cloud-init status --wait*sudo -n true*') { throw 'Verify actual installed OS, cloud-init, and administrative access.' }
                $script:verifiedSsh = -not $script:sshFailure
                $global:LASTEXITCODE = if ($script:sshFailure) { 1 } else { 0 }
            }
        }
        function Remove-VM { param($Name, [switch]$Force) if (-not $script:verifiedSsh) { throw 'Preserve failed templates.' } }
        function Set-ItemProperty { param($LiteralPath, $Name, $Value) $script:sealed = $true }
        function Start-Sleep { param($Seconds) }
        Complete-UbuntuImageBuild $build
        if (-not $script:sealed -or -not (Test-Path "$($build.Path).ready")) { throw 'Only seal after installed OS verification and graceful shutdown.' }
        Remove-Item -LiteralPath "$($build.Path).ready"
        $script:sshFailure = $true
        $script:sealed = $false
        Assert-MediaThrows { Complete-UbuntuImageBuild $build -VerificationTimeoutSeconds 0 } 'Ubuntu installed-image verification failed'
        if ($script:sealed -or (Test-Path "$($build.Path).ready")) { throw 'Failed Ubuntu installation must not look ready.' }
    }

    foreach ($stage in @('30-download-images', '40-create-nested-vms')) {
        $source = Get-Content (Join-Path $PSScriptRoot "../artifacts/scripts/$stage.ps1") -Raw
        $helper = Get-Content (Join-Path $PSScriptRoot '../artifacts/scripts/image-media.ps1') -Raw
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($source.Replace('# IMAGE_MEDIA_HELPERS', $helper), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join "`n") }
    }
    Write-Host 'Installation-media regression checks passed.'
}
finally {
    $env:windir = $originalWindir
    Remove-Item -LiteralPath $directory -Recurse -Force
}
