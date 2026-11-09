function Test-LicensedSqlIso {
    param([string]$Path)
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt 1GB -or $size -gt 25GB) {
        throw 'SQL installation media must be between 1 and 25 GiB, not a download bootstrapper.'
    }
    $mountedHere = $false
    try {
        if (-not (Get-DiskImage -ImagePath $Path).Attached) {
            Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly | Out-Null
            $mountedHere = $true
        }
        $volumes = @(Get-DiskImage -ImagePath $Path | Get-Volume | Where-Object DriveLetter)
        if ($volumes.Count -ne 1) { throw 'SQL ISO must expose exactly one volume.' }
        $setup = "$($volumes[0].DriveLetter):\setup.exe"
        $signature = Get-AuthenticodeSignature $setup
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
            throw 'SQL setup must have a valid Microsoft signature.'
        }
        if ((Get-Item -LiteralPath $setup).VersionInfo.ProductMajorPart -ne 17) {
            throw 'Select SQL Server 2025 media, not an earlier release.'
        }
        $defaults = @(Get-ChildItem "$($volumes[0].DriveLetter):\" -Filter DefaultSetup.ini -File -Recurse)
        if ($defaults.Count -ne 1 -or -not [regex]::IsMatch(
                (Get-Content -LiteralPath $defaults[0].FullName -Raw),
                '(?im)^\s*PID\s*=\s*["\s]*[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}')) {
            throw 'Select authorized pre-keyed media. Separate product-key input is not supported.'
        }
    }
    finally { if ($mountedHere) { Dismount-DiskImage -ImagePath $Path | Out-Null } }
}
