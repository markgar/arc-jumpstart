# Embedded into stages 30 and 40 by Bicep; no workstation execution.
function Write-ImagePhase {
    param([string]$Message)
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage$ImageStage] $Message"
}

function Protect-ImageBuildDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict image-build files to SYSTEM and Administrators.' }
}

function Get-VerifiedIso {
    param([string]$Url, [string]$Sha256, [string]$Path)
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'An approved ISO SHA-256 checksum is required.' }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ImagePhase "Downloading $([IO.Path]::GetFileName($Path))."
        $partial = "$Path.partial"
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        try {
            # BITS streams large files without buffering an ISO in Windows PowerShell.
            Start-BitsTransfer -Source $Url -Destination $partial -ErrorAction Stop | Out-Null
        }
        catch {
            throw "ISO download failed ($($_.Exception.GetType().Name)). Check approved outbound access; do not bypass network policy."
        }
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $Sha256) {
            throw "ISO checksum mismatch at $partial. The file is preserved for diagnosis and will not be used."
        }
        Move-Item -LiteralPath $partial -Destination $Path
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {
        throw "Cached ISO checksum mismatch at $Path. Preserve the cache and investigate; no image will be built."
    }
    Write-ImagePhase "Verified SHA-256 for $([IO.Path]::GetFileName($Path))."
    return $Path
}

function New-EvaluationMediaRequest {
    param([uri]$Uri)
    [Net.HttpWebRequest]::Create($Uri)
}

function Resolve-EvaluationMediaUri {
    param([string]$Url)
    $current = [uri]$Url
    for ($redirect = 0; $redirect -le 6; $redirect++) {
        if ($current.Scheme -ne 'https' -or -not $current.IsDefaultPort -or $current.UserInfo -or
            $current.Host -notin @('go.microsoft.com', 'aka.ms', 'software-static.download.prss.microsoft.com', 'download.microsoft.com') -or
            ($current.Host -eq 'aka.ms' -and $current.AbsolutePath -cne '/WinServ2025iso-enus')) {
            throw 'Windows Evaluation download redirected outside the approved Microsoft HTTPS hosts.'
        }
        $request = New-EvaluationMediaRequest $current
        $request.AllowAutoRedirect = $false
        $request.Method = 'HEAD'
        $request.Timeout = 30000
        $response = $null
        try {
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                if (-not $response.Headers['Location']) { throw 'Windows media redirect has no destination.' }
                $current = [uri]::new($current, $response.Headers['Location'])
                continue
            }
            if ([int]$response.StatusCode -ne 200 -or $current.Host -eq 'go.microsoft.com' -or
                $current.AbsolutePath -notmatch '\.iso$' -or
                $response.ContentLength -lt 1GB -or $response.ContentLength -gt 10GB) {
                throw 'The official Windows source did not return a full Evaluation ISO.'
            }
            return $current.AbsoluteUri
        }
        finally { if ($response) { $response.Dispose() } }
    }
    throw 'Windows Evaluation download exceeded the redirect limit.'
}

function Get-WindowsEvaluationMedia {
    param([string]$Url, [string]$Sha256, [string]$Path)
    if ($Sha256 -cne 'auto') {
        return @{ Path = (Get-VerifiedIso -Url $Url -Sha256 $Sha256 -Path $Path); Sha256 = $Sha256 }
    }
    if ($Url -cnotin @(
        'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US',
        'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us')) {
        throw 'Automatic Windows verification requires the exact official Evaluation download source.'
    }
    $receipt = "$Path.source.json"
    if (-not (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $receipt)) {
        Write-ImagePhase 'Downloading Windows Evaluation directly on the Azure host from the verified Microsoft HTTPS source.'
        $source = Resolve-EvaluationMediaUri $Url
        $temporary = "$Path.partial.iso"
        if (Test-Path -LiteralPath $temporary) { throw 'A partial Windows ISO exists. Preserve it and diagnose the previous download before retrying.' }
        Start-BitsTransfer -Source $source -Destination $temporary -ErrorAction Stop | Out-Null
        $isoRoot = Mount-ImageIso $temporary
        try {
            $signature = Get-AuthenticodeSignature -FilePath (Join-Path $isoRoot 'setup.exe')
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
                throw 'Downloaded Windows Setup does not have a valid Microsoft signature; no media receipt will be written.'
            }
        }
        finally { Dismount-DiskImage -ImagePath $temporary | Out-Null }
        $hash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
        $record = @{
            Version = 1; RequestedUrl = $Url; ResolvedUrl = $source; Sha256 = $hash
            Size = (Get-Item -LiteralPath $temporary).Length; Verification = 'MicrosoftHttpsAndSetupSignature'
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Move-Item -LiteralPath $temporary -Destination $Path
        $record | ConvertTo-Json | Set-Content -LiteralPath "$receipt.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$receipt.tmp" -Destination $receipt
        Write-ImagePhase "Microsoft Setup signature verified; recorded Windows ISO SHA-256 $hash. This is a host-observed fingerprint, not a separately published checksum."
    }
    if (-not (Test-Path -LiteralPath $Path) -or -not (Test-Path -LiteralPath $receipt)) {
        throw 'Incomplete Windows media provenance. Preserve the ISO and diagnose before retrying.'
    }
    $record = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($record.Version -ne 1 -or $record.RequestedUrl -cne $Url -or
        $record.Verification -cne 'MicrosoftHttpsAndSetupSignature' -or
        $record.Sha256 -notmatch '^[a-f0-9]{64}$' -or
        (Get-Item -LiteralPath $Path).Length -ne $record.Size -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $record.Sha256) {
        throw 'Windows ISO does not match its verified source receipt. No image will be built.'
    }
    return @{ Path = $Path; Sha256 = $record.Sha256 }
}

function Test-ImageBuildReceipt {
    param([string]$Path, [hashtable]$Expected)
    $receipt = "$Path.ready"
    if (-not (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $receipt)) { return $false }
    if (-not (Test-Path -LiteralPath $Path) -or -not (Test-Path -LiteralPath $receipt)) {
        throw "Incomplete image cache at $Path. Preserve disks and any template VM; use the documented image-build recovery boundary."
    }
    $actual = Get-Content -LiteralPath $receipt -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($key in $Expected.Keys) {
        if ($actual.$key -cne $Expected[$key]) {
            throw "Incompatible image cache at $Path ($key changed). Use a fresh lab; never rewrite a disk with dependent guests."
        }
    }
    if (-not $actual.CompletedUtc) { throw "Image receipt has no completion evidence: $receipt." }
    return $true
}

function Write-ImageBuildReceipt {
    param([string]$Path, [hashtable]$Evidence)
    $record = $Evidence.Clone()
    $record.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json | Set-Content -LiteralPath "$Path.ready.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$Path.ready.tmp" -Destination "$Path.ready"
}

function Mount-ImageIso {
    param([string]$Path)
    $existing = Get-DiskImage -ImagePath $Path -ErrorAction Stop
    if ($existing.Attached) { throw "ISO is already mounted at $Path. Investigate the existing operation before retrying." }
    $mounted = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop
    $volumes = @($mounted | Get-Volume | Where-Object DriveLetter)
    if ($volumes.Count -ne 1) {
        Dismount-DiskImage -ImagePath $Path
        throw 'Expected exactly one mounted ISO volume.'
    }
    return "$($volumes[0].DriveLetter):\"
}

function New-ImageBuildDisk {
    param([string]$Path, [switch]$Installer)
    if (Test-Path -LiteralPath $Path) { throw "Image disk already exists at $Path; automatic replacement is forbidden." }
    $size = if ($Installer) { 8GB } else { 80GB }
    New-VHD -Path $Path -SizeBytes $size -Dynamic | Out-Null
    $mounted = Mount-VHD -Path $Path -NoDriveLetter -Passthru
    try {
        Initialize-Disk -Number $mounted.DiskNumber -PartitionStyle GPT | Out-Null
        $efiArgs = @{ DiskNumber = $mounted.DiskNumber; AssignDriveLetter = $true
            GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
        if ($Installer) { $efiArgs.UseMaximumSize = $true } else { $efiArgs.Size = 260MB }
        $efi = New-Partition @efiArgs
        if (-not $efi.DriveLetter) { throw 'The new image EFI partition has no drive letter; no host volume will be used as a fallback.' }
        $label = if ($Installer) { 'CIDATA' } else { 'SYSTEM' }
        $efi | Format-Volume -FileSystem FAT32 -NewFileSystemLabel $label -Confirm:$false | Out-Null
        $windowsPath = ''
        if (-not $Installer) {
            $reserved = @(Get-Partition -DiskNumber $mounted.DiskNumber |
                Where-Object GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
            if ($reserved.Count -gt 1) { throw 'Unexpected duplicate Microsoft Reserved partitions in the new image disk.' }
            if ($reserved.Count -eq 0) {
                New-Partition -DiskNumber $mounted.DiskNumber -Size 16MB `
                    -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
            }
            $windows = New-Partition -DiskNumber $mounted.DiskNumber -UseMaximumSize -AssignDriveLetter
            if (-not $windows.DriveLetter) { throw 'The new Windows partition has no drive letter.' }
            $windows | Format-Volume -FileSystem NTFS -NewFileSystemLabel Windows -Confirm:$false | Out-Null
            $windowsPath = "$($windows.DriveLetter):\"
        }
        return @{ EfiPath = "$($efi.DriveLetter):\"; WindowsPath = $windowsPath }
    }
    catch {
        Dismount-VHD -Path $Path
        throw
    }
}

function New-EvaluationUnattend {
    param([string]$Password)
    $escaped = [Security.SecurityElement]::Escape($Password)
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><AdministratorPassword><Value>$escaped</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function New-WindowsEvaluationImage {
    param([string]$Iso, [string]$Sha256, [string]$Path, [string]$Password,
        [ValidateSet('2022', '2025')][string]$WindowsServerVersion = '2022')
    $expected = @{
        Version = $(if ($WindowsServerVersion -eq '2025') { 'windows-2025-eval-media-v2' } else { 'windows-eval-media-v2' })
        IsoSha256 = $Sha256.ToLowerInvariant()
    }
    $expectedBuild = if ($WindowsServerVersion -eq '2025') { 26100 } else { 20348 }
    if (Test-ImageBuildReceipt -Path $Path -Expected $expected) {
        Write-ImagePhase 'Reusing the prepared Windows Evaluation disk; stage 40 still verifies native setup and activation.'
        return
    }
    $isoRoot = Mount-ImageIso $Iso
    $disk = $null
    try {
        $signature = Get-AuthenticodeSignature -FilePath (Join-Path $isoRoot 'setup.exe')
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
            throw 'Windows Evaluation setup must have a valid Microsoft signature.'
        }
        $wim = Join-Path $isoRoot 'sources\install.wim'
        $images = @(Get-WindowsImage -ImagePath $wim -ErrorAction Stop | ForEach-Object {
            Get-WindowsImage -ImagePath $wim -Index $_.ImageIndex -ErrorAction Stop
        } | Where-Object {
            $_.EditionId -eq 'ServerDatacenterEval' -and $_.InstallationType -eq 'Server' -and
            ([version]$_.Version).Build -eq $expectedBuild -and $_.Architecture -eq 9 -and
            $_.Languages -contains 'en-US'
        })
        if ($images.Count -ne 1) { throw "Require exactly one English x64 Windows Server $WindowsServerVersion Datacenter Evaluation Desktop Experience image." }
        Write-ImagePhase "Applying the Windows Server $WindowsServerVersion Evaluation image to a new local UEFI disk."
        $disk = New-ImageBuildDisk -Path $Path
        Expand-WindowsImage -ImagePath $wim -Index $images[0].ImageIndex `
            -ApplyPath $disk.WindowsPath -CheckIntegrity -ErrorAction Stop | Out-Null
        $panther = Join-Path $disk.WindowsPath 'Windows\Panther'
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        New-EvaluationUnattend -Password $Password |
            Set-Content -LiteralPath (Join-Path $panther 'Unattend.xml') -Encoding UTF8
        $offlineBoot = $WindowsServerVersion -eq '2025'
        $bcdboot = if ($offlineBoot) { Join-Path $env:windir 'System32\bcdboot.exe' }
            else { Join-Path $disk.WindowsPath 'Windows\System32\bcdboot.exe' }
        if (-not (Test-Path -LiteralPath $bcdboot)) { throw "Required BCDBoot executable is missing: $bcdboot" }
        New-Item -ItemType Directory -Path (Join-Path $disk.EfiPath 'EFI\Microsoft\Boot'),
            (Join-Path $disk.EfiPath 'EFI\Boot') -Force | Out-Null
        $boot = Invoke-ImageBcdBoot -Executable $bcdboot `
            -WindowsDirectory (Join-Path $disk.WindowsPath 'Windows') -SystemVolume $disk.EfiPath.TrimEnd('\') `
            -Offline:$offlineBoot
        foreach ($line in $boot.Output) { Write-ImagePhase "BCDBoot: $line" }
        if ($boot.ExitCode -ne 0) { throw "BCDBoot failed with exit code $($boot.ExitCode). Inspect the preceding boot-file diagnostics." }
        foreach ($bootFile in @('EFI\Microsoft\Boot\BCD', 'EFI\Microsoft\Boot\bootmgfw.efi', 'EFI\Boot\bootx64.efi')) {
            if (-not (Test-Path -LiteralPath (Join-Path $disk.EfiPath $bootFile) -PathType Leaf)) {
                throw "Windows UEFI boot file is missing after BCDBoot: $bootFile"
            }
        }
    }
    finally {
        if ($disk) { Dismount-VHD -Path $Path }
        Dismount-DiskImage -ImagePath $Iso
    }
    Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $true
    Write-ImageBuildReceipt -Path $Path -Evidence $expected
    Write-ImagePhase 'Windows base disk prepared. First boot, OOBE, generalization, and activation remain stage-40 gates.'
}

function Invoke-ImageBcdBoot {
    param([string]$Executable, [string]$WindowsDirectory, [string]$SystemVolume, [switch]$Offline)
    # Offline servicing uses the patched host tool without inheriting its BootEX selection.
    $arguments = @($WindowsDirectory, '/s', $SystemVolume, '/f', 'UEFI', '/v')
    if ($Offline) { $arguments += '/offline' }
    # Windows PowerShell must collect native stderr without interrupting the tool before it exits.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $Executable @arguments 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        if ($line -is [Management.Automation.ErrorRecord] -and
            $line.FullyQualifiedErrorId -notlike 'NativeCommandError*') {
            throw $line
        }
    }
    return @{ ExitCode = $exitCode; Output = @($output) }
}

function Get-ImageBuildSshKey {
    param([string]$Directory)
    $ssh = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue
    $keygen = Get-Command ssh-keygen.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $ssh -or -not $keygen) {
        $result = Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop
        if ($result.RestartNeeded) { throw 'OpenSSH Client installation requires a host restart. Complete that recovery before retrying stage 30.' }
        $ssh = Get-Command ssh.exe -CommandType Application -ErrorAction Stop
        $keygen = Get-Command ssh-keygen.exe -CommandType Application -ErrorAction Stop
    }
    $path = Join-Path $Directory 'ubuntu-ed25519'
    if (-not (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath "$path.pub")) {
        $process = Start-Process -FilePath $keygen.Source -ArgumentList "-q -t ed25519 -f `"$path`" -N `"`"" -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Image-build SSH key generation failed (exit $($process.ExitCode))." }
    }
    if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath "$path.pub")) {
        throw 'Incomplete image-build SSH key pair. Preserve the key directory; do not regenerate an identity used by a running build.'
    }
    # OpenSSH rejects a private key with inherited group access.
    & icacls.exe $path /inheritance:r /grant:r '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the host image-build SSH private key.' }
    return @{ Path = $path; PublicKey = (Get-Content -LiteralPath "$path.pub" -Raw).Trim(); Ssh = $ssh.Source }
}

function New-UbuntuAutoinstall {
    param([string[]]$PublicKeys)
    # JSON is a YAML subset; serialize key strings rather than interpolate YAML.
    "#cloud-config`n" + (@{
        autoinstall = @{
            version = 1
            'refresh-installer' = @{ update = $false }
            identity = @{ hostname = 'js-ubuntu-01'; username = 'jumpstart'; password = '*' }
            ssh = @{ 'install-server' = $true; 'allow-pw' = $false; 'authorized-keys' = $PublicKeys }
            network = @{ version = 2; ethernets = @{
                ethernet = @{ match = @{ name = 'e*' }; dhcp4 = $true; 'dhcp-identifier' = 'mac' }
            } }
            'user-data' = @{ users = @(@{
                name = 'jumpstart'; groups = @('adm', 'sudo'); shell = '/bin/bash'
                lock_passwd = $true; sudo = 'ALL=(ALL) NOPASSWD:ALL'; ssh_authorized_keys = $PublicKeys
            }) }
            storage = @{ layout = @{ name = 'direct'; match = @{ size = 'largest' } } }
            'late-commands' = @('curtin in-target --target=/target -- mkdir -p /var/lib/arc-jumpstart',
                'curtin in-target --target=/target -- touch /var/lib/arc-jumpstart/image-installed')
            shutdown = 'poweroff'
        }
    } | ConvertTo-Json -Depth 10)
}

function New-UbuntuInstallerImage {
    param([string]$Iso, [string]$Sha256, [string]$Path, [string[]]$PublicKeys)
    $expected = @{ Version = 'ubuntu-installer-media-v2'; IsoSha256 = $Sha256.ToLowerInvariant()
        PublicKeys = ($PublicKeys -join "`n") }
    if (Test-ImageBuildReceipt -Path $Path -Expected $expected) { return }
    $isoRoot = Mount-ImageIso $Iso
    $disk = $null
    try {
        foreach ($required in @('casper\vmlinuz', 'casper\initrd', 'EFI\BOOT\BOOTX64.EFI', 'boot\grub\grub.cfg')) {
            if (-not (Test-Path -LiteralPath (Join-Path $isoRoot $required))) { throw "Ubuntu ISO is missing $required." }
        }
        if (@(Get-ChildItem -LiteralPath $isoRoot -Recurse -File -Force |
            Where-Object Length -ge 4GB).Count) { throw 'Ubuntu installer contains a file too large for FAT32.' }
        Write-ImagePhase 'Preparing a local UEFI Ubuntu installer disk and NoCloud configuration.'
        $disk = New-ImageBuildDisk -Path $Path -Installer
        Get-ChildItem -LiteralPath $isoRoot -Force | Copy-Item -Destination $disk.EfiPath -Recurse -Force
        Get-ChildItem -LiteralPath $disk.EfiPath -Recurse -File -Force |
            ForEach-Object { $_.IsReadOnly = $false }
        $grubPath = Join-Path $disk.EfiPath 'boot\grub\grub.cfg'
        $grub = Get-Content -LiteralPath $grubPath -Raw
        $linuxLines = [regex]::Matches($grub, '(?m)^\s*linux\s+/casper/vmlinuz[^\r\n]*')
        if (-not $linuxLines.Count) { throw 'No supported Ubuntu installer kernel entry found; do not boot interactive setup.' }
        $grub = [regex]::Replace($grub, '(?m)^(\s*linux\s+/casper/vmlinuz)([^\r\n]*)', '$1 autoinstall ds=nocloud $2')
        $grub = [regex]::Replace($grub, '(?m)^\s*set timeout=.*$', 'set timeout=0')
        Set-Content -LiteralPath $grubPath -Value "set default=0`n$grub" -Encoding ASCII
        foreach ($directory in @('EFI\BOOT', 'EFI\ubuntu')) {
            $target = Join-Path $disk.EfiPath $directory
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'grub.cfg') -Encoding ASCII `
                -Value "search --no-floppy --label --set=root CIDATA`nconfigfile /boot/grub/grub.cfg"
        }
        # Windows PowerShell's UTF8 encoding adds a BOM that hides cloud-init's header.
        [IO.File]::WriteAllText((Join-Path $disk.EfiPath 'user-data'),
            (New-UbuntuAutoinstall -PublicKeys $PublicKeys), [Text.UTF8Encoding]::new($false))
        Set-Content -LiteralPath (Join-Path $disk.EfiPath 'meta-data') -Encoding ASCII `
            -Value 'instance-id: arc-jumpstart-ubuntu-image-v2'
    }
    finally {
        if ($disk) { Dismount-VHD -Path $Path }
        Dismount-DiskImage -ImagePath $Iso
    }
    Set-ItemProperty -LiteralPath $Path -Name IsReadOnly -Value $true
    Write-ImageBuildReceipt -Path $Path -Evidence $expected
}

function Initialize-InstallationMedia {
    param([string]$WindowsUrl, [string]$WindowsHash, [string]$UbuntuUrl,
        [string]$UbuntuHash, [string]$Password, [string]$PublicKey, [bool]$IncludeLinux = $true,
        [ValidateSet('2022', '2025')][string]$WindowsServerVersion = '2022')
    $cache = 'F:\ArcJumpstart\Images\InstallationMedia'
    Protect-ImageBuildDirectory $cache
    $windowsMedia = Get-WindowsEvaluationMedia -Url $WindowsUrl -Sha256 $WindowsHash -Path (Join-Path $cache "Windows-Server-$WindowsServerVersion.iso")
    New-WindowsEvaluationImage -Iso $windowsMedia.Path -Sha256 $windowsMedia.Sha256 `
        -Path (Join-Path $cache "Windows-Server-$WindowsServerVersion-Eval.vhdx") -Password $Password `
        -WindowsServerVersion $WindowsServerVersion
    if (-not $IncludeLinux) {
        Write-ImagePhase 'Linux explicitly excluded; no Ubuntu download, key generation, or installer preparation.'
        return
    }
    $keys = Join-Path $cache 'Keys'
    Protect-ImageBuildDirectory $keys
    $key = Get-ImageBuildSshKey -Directory $keys
    $ubuntuIso = Get-VerifiedIso -Url $UbuntuUrl -Sha256 $UbuntuHash -Path (Join-Path $cache 'Ubuntu-22.04.iso')
    New-UbuntuInstallerImage -Iso $ubuntuIso -Sha256 $UbuntuHash `
        -Path (Join-Path $cache 'Ubuntu-Installer.vhdx') -PublicKeys @($key.PublicKey, $PublicKey)
}

function Start-UbuntuImageBuild {
    param([string]$Sha256, [string]$PublicKey)
    $cache = 'F:\ArcJumpstart\Images\InstallationMedia'
    $path = Join-Path $cache 'Ubuntu-22.04.vhdx'
    $installer = Join-Path $cache 'Ubuntu-Installer.vhdx'
    $expected = @{ Version = 'ubuntu-base-media-v1'; IsoSha256 = $Sha256.ToLowerInvariant(); PublicKey = $PublicKey }
    if (Test-ImageBuildReceipt -Path $path -Expected $expected) { return @{ Ready = $true } }
    $key = Get-ImageBuildSshKey -Directory (Join-Path $cache 'Keys')
    $installerEvidence = @{ Version = 'ubuntu-installer-media-v2'; IsoSha256 = $Sha256.ToLowerInvariant()
        PublicKeys = (@($key.PublicKey, $PublicKey) -join "`n") }
    if (-not (Test-ImageBuildReceipt -Path $installer -Expected $installerEvidence)) { throw 'Run stage 30 to prepare the Ubuntu installer.' }
    $name = 'TEMPLATE-Ubuntu-22.04'
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        throw "Existing template VM $name requires diagnosis. Do not restart an installer or replace its target disk automatically."
    }
    $vmPath = Join-Path $cache $name
    New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
    # An installer only sees its own blank disk and disposable installer child.
    New-VHD -Path $path -Dynamic -SizeBytes 80GB | Out-Null
    $installerChild = Join-Path $vmPath 'installer.vhdx'
    New-VHD -Path $installerChild -ParentPath $installer -Differencing | Out-Null
    New-VM -Name $name -Generation 2 -MemoryStartupBytes 4GB -VHDPath $path `
        -Path $vmPath -SwitchName 'ArcJumpstartInternal' | Out-Null
    Set-VM -Name $name -ProcessorCount 2 -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled
    Add-VMHardDiskDrive -VMName $name -Path $installerChild
    $boot = Get-VMHardDiskDrive -VMName $name | Where-Object Path -eq $installerChild
    Set-VMFirmware -VMName $name -EnableSecureBoot Off -FirstBootDevice $boot
    Start-VM -Name $name
    Write-ImagePhase 'Ubuntu unattended installation started; preparing Windows while it runs.'
    return @{ Ready = $false; Name = $name; Path = $path; InstallerChild = $installerChild
        Key = $key; Expected = $expected; StartedUtc = [DateTime]::UtcNow }
}

function Wait-ImageVmOff {
    param([string]$Name, [datetime]$Deadline)
    do {
        $vm = Get-VM -Name $Name -ErrorAction Stop
        if ($vm.State -eq 'Off') { return }
        if ($vm.State -notin @('Running', 'Stopping')) { throw "Image builder $Name entered unexpected state $($vm.State). Preserve the VM and disks." }
        if ([DateTime]::UtcNow -ge $Deadline) { break }
        Write-ImagePhase "Waiting for $Name to shut down normally."
        Start-Sleep -Seconds 30
    } while ($true)
    throw "Image builder $Name did not shut down before its deadline. It is preserved; do not start a competing build."
}

function Complete-UbuntuImageBuild {
    param([hashtable]$Build, [int]$VerificationTimeoutSeconds = 900)
    if ($Build.Ready) { return }
    Wait-ImageVmOff -Name $Build.Name -Deadline $Build.StartedUtc.AddHours(1)
    $drives = @(Get-VMHardDiskDrive -VMName $Build.Name)
    $installer = @($drives | Where-Object Path -eq $Build.InstallerChild)
    $target = @($drives | Where-Object Path -eq $Build.Path)
    if ($installer.Count -ne 1 -or $target.Count -ne 1) { throw 'Unexpected Ubuntu image-builder disk attachments. Preserve the VM.' }
    $installer[0] | Remove-VMHardDiskDrive
    Set-VMFirmware -VMName $Build.Name -FirstBootDevice $target[0]
    Start-VM -Name $Build.Name
    $adapter = Get-VMNetworkAdapter -VMName $Build.Name
    $deadline = [DateTime]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
    $knownHosts = Join-Path (Split-Path -Parent $Build.Key.Path) 'known_hosts'
    $verified = $false
    do {
        $leases = @(Get-DhcpServerv4Lease -ScopeId '192.168.128.0' -ErrorAction Stop | Where-Object {
            ($_.ClientId -replace '-', '') -imatch "^(01)?$($adapter.MacAddress)$" -and $_.AddressState -eq 'Active'
        })
        if ($leases.Count -eq 1) {
            $address = [string]$leases[0].IPAddress
            $sshArgs = @('-i', $Build.Key.Path, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHosts",
                "jumpstart@$address")
            $output = & $Build.Key.Ssh @sshArgs 'test -f /var/lib/arc-jumpstart/image-installed && . /etc/os-release && test "$ID" = ubuntu && test "$VERSION_ID" = 22.04 && timeout 120 cloud-init status --wait && sudo -n true' 2>&1
            if ($LASTEXITCODE -eq 0) { $verified = $true; break }
        }
        Write-ImagePhase 'Waiting for installed Ubuntu SSH, cloud-init completion, and the installation receipt.'
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $verified) { throw 'Ubuntu installed-image verification failed. Preserve the template and inspect its console; no base-image ready marker will be written.' }
    $output = & $Build.Key.Ssh @sshArgs 'sudo -n systemctl poweroff' 2>&1
    if ($LASTEXITCODE -notin @(0, 255)) { throw "Ubuntu shutdown request failed (SSH exit $LASTEXITCODE)." }
    Wait-ImageVmOff -Name $Build.Name -Deadline ([DateTime]::UtcNow.AddMinutes(5))
    Remove-VM -Name $Build.Name -Force
    Set-ItemProperty -LiteralPath $Build.Path -Name IsReadOnly -Value $true
    Write-ImageBuildReceipt -Path $Build.Path -Evidence $Build.Expected
    Write-ImagePhase 'Ubuntu base disk passed installed-OS, SSH, cloud-init, and graceful-shutdown checks.'
}
