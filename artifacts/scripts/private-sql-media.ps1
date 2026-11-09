function Get-PrivateSqlManifest {
    param([string]$AccountName, [string]$Destination, [switch]$AllowMissing)
    $found = Receive-PrivateSqlBlob -AccountName $AccountName -BlobName 'manifest.json' -Path $Destination -MaximumSize 1MB -AllowMissing:$AllowMissing
    if ($AllowMissing -and -not $found) { return $null }
    $manifest = Get-Content -LiteralPath $Destination -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($manifest.Version -ne 1 -or @($manifest.Media).Count -ne 2) { throw 'Invalid licensed SQL media manifest.' }
    foreach ($edition in @('Standard', 'Enterprise')) {
        $entry = @($manifest.Media | Where-Object Edition -ceq $edition)
        if ($entry.Count -ne 1 -or $entry[0].Name -cne "SQL2025-$edition-$($entry[0].Sha256).iso" -or
            $entry[0].Sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $entry[0].Size -lt 1GB -or $entry[0].Size -gt 25GB) {
            throw "Invalid licensed $edition media metadata."
        }
        if ($entry[0].PSObject.Properties.Name -contains 'SourceBlobName' -and
            (Get-RootSqlMediaEdition $entry[0].SourceBlobName) -cne $edition) {
            throw "Invalid licensed $edition source blob name."
        }
    }
    return $manifest
}

function New-PrivateSqlBlobRequest {
    param([string]$Uri)
    [Net.HttpWebRequest]::Create($Uri)
}

function Get-RootSqlMediaEdition {
    param([string]$Name)
    if ($Name -match '^(?:enu_sql_server_2025_(?<edition>standard|enterprise)_edition_x64_dvd_[a-f0-9]{8}|SQL2025-(?<edition>Standard|Enterprise)(?:-[a-z0-9_-]+)?)\.iso$') {
        if ($Matches.edition -ieq 'Standard') { return 'Standard' }
        return 'Enterprise'
    }
}

function Open-PrivateSqlBlobResponse {
    param($Request, [string]$BlobName, [switch]$AllowMissing)
    try { return $Request.GetResponse() }
    catch {
        $failure = $_.Exception
        while ($failure -and $failure -isnot [Net.WebException]) { $failure = $failure.InnerException }
        if (-not $failure) { throw }
        $response = $failure.Response
        try {
            if ($response) {
                $status = [int]$response.StatusCode
                $code = $response.Headers['x-ms-error-code']
                if ($AllowMissing -and $status -eq 404 -and $code -eq 'BlobNotFound') { return $null }
                throw "Private SQL blob $BlobName failed: HTTP $status ($code). Check upload completion and host managed-identity/operator permissions; no public or shared-key fallback is used."
            }
            throw "Private SQL blob $BlobName transport failed ($($failure.Status)). Check private DNS and network access."
        }
        finally { if ($response) { $response.Dispose() } }
    }
}

function Receive-PrivateSqlBlob {
    param([string]$AccountName, [string]$BlobName, [string]$Path, [long]$MaximumSize,
        [ValidateRange(1, 1500)][int]$TimeoutSeconds = 1500,
        [switch]$AllowMissing, [string]$IfMatch)
    if ($AccountName -notmatch '^[a-z0-9]{3,24}$' -or
        ($BlobName -cne 'manifest.json' -and -not (Get-RootSqlMediaEdition $BlobName))) {
        throw 'Invalid private SQL media source.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $token = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F' -TimeoutSec ([Math]::Min(30, $TimeoutSeconds))
    $request = New-PrivateSqlBlobRequest "https://$AccountName.blob.core.windows.net/sql-media/$BlobName"
    $request.AllowAutoRedirect = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    if ($IfMatch) { $request.Headers['If-Match'] = $IfMatch }
    $request.Headers['Authorization'] = "Bearer $($token.access_token)"
    $request.Headers['x-ms-version'] = '2023-11-03'
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        $response = Open-PrivateSqlBlobResponse -Request $request -BlobName $BlobName -AllowMissing:$AllowMissing
        if (-not $response) { return $false }
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt $MaximumSize -or $response.ContentLength -lt 1) {
            throw "Invalid private SQL blob response for $BlobName."
        }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
        $buffer = New-Object byte[] 65536
        $length = [long]0
        while ($true) {
            $remaining = [Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -lt 1) { throw "Private SQL download exceeded time budget: $BlobName." }
            if ($inputStream.CanTimeout) { $inputStream.ReadTimeout = [int][Math]::Min(30000, $remaining) }
            $count = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }
            $length += $count
            if ($length -gt $MaximumSize -or [DateTime]::UtcNow -gt $deadline) { throw "Private SQL download exceeded size/time budget: $BlobName." }
            $outputStream.Write($buffer, 0, $count)
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw "Private SQL download exceeded time budget: $BlobName." }
        if ($length -ne $response.ContentLength) { throw "Incomplete private SQL download: $BlobName." }
        if ($AllowMissing) { return $true }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        $token = $null
    }
}

function Get-RootSqlMediaBlobs {
    param([string]$AccountName)
    if ($AccountName -notmatch '^[a-z0-9]{3,24}$') { throw 'Invalid private SQL media account.' }
    $token = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F' -TimeoutSec 30
    $request = New-PrivateSqlBlobRequest "https://$AccountName.blob.core.windows.net/sql-media?restype=container&comp=list&maxresults=5000"
    $request.AllowAutoRedirect = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.Headers['Authorization'] = 'Bearer ' + $token.access_token
    $request.Headers['x-ms-version'] = '2023-11-03'
    $response = $null; $reader = $null
    try {
        $response = Open-PrivateSqlBlobResponse -Request $request -BlobName 'container listing'
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 16MB) {
            throw 'Invalid private SQL container listing response.'
        }
        $reader = [IO.StreamReader]::new($response.GetResponseStream())
        [xml]$listing = $reader.ReadToEnd()
        if ($listing.EnumerationResults.NextMarker) {
            throw 'SQL media container has more than 5000 entries. Use a dedicated media container or the desktop uploader.'
        }
        foreach ($blob in $listing.EnumerationResults.Blobs.Blob) {
            $edition = Get-RootSqlMediaEdition ([string]$blob.Name)
            if ($edition) {
                [pscustomobject]@{
                    Edition = $edition; Name = [string]$blob.Name
                    Size = [long]$blob.Properties.'Content-Length'; ETag = [string]$blob.Properties.Etag
                }
            }
        }
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $token = $null
    }
}

function Publish-PrivateSqlManifest {
    param([string]$AccountName, [string]$Path, [string]$WriteToken)
    if ($AccountName -notmatch '^[a-z0-9]{3,24}$' -or -not $WriteToken) {
        throw 'A valid account and the signed-in operator storage token are required to publish the manifest.'
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 1MB) { throw 'Invalid SQL manifest length.' }
    $request = New-PrivateSqlBlobRequest "https://$AccountName.blob.core.windows.net/sql-media/manifest.json"
    $request.Method = 'PUT'
    $request.AllowAutoRedirect = $false
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.ContentType = 'application/json'
    $request.ContentLength = $bytes.Length
    $request.Headers['Authorization'] = 'Bearer ' + $WriteToken
    $request.Headers['x-ms-version'] = '2023-11-03'
    $request.Headers['x-ms-blob-type'] = 'BlockBlob'
    $request.Headers['If-None-Match'] = '*'
    $response = $null; $stream = $null
    try {
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Dispose(); $stream = $null
        $response = Open-PrivateSqlBlobResponse -Request $request -BlobName 'manifest.json publication'
        if ([int]$response.StatusCode -ne 201) { throw 'SQL manifest publication did not return HTTP 201.' }
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        $WriteToken = $null
    }
}

function Initialize-PrivateSqlManifest {
    param([string]$AccountName, [string]$WorkDirectory, [string]$RunId, [string]$WriteToken)
    $destination = Join-Path $WorkDirectory "manifest-$RunId.json"
    $manifest = Get-PrivateSqlManifest -AccountName $AccountName -Destination $destination -AllowMissing
    if ($manifest) { return $manifest }
    Write-Host 'No SQL manifest exists. Inspecting the container root for uploaded Standard and Enterprise ISOs.'
    $blobs = @(Get-RootSqlMediaBlobs -AccountName $AccountName)
    foreach ($edition in @('Standard', 'Enterprise')) {
        $matches = @($blobs | Where-Object Edition -ceq $edition)
        if ($matches.Count -ne 1) {
            throw "Expected exactly one SQL Server 2025 $edition ISO in the sql-media container root; found $($matches.Count). Keep one per edition using the original enu_sql_server_2025_<edition>_edition_x64_dvd_<id>.iso name or SQL2025-<edition>.iso, or use the desktop uploader. No manifest was published."
        }
        if ($matches[0].Size -lt 1GB -or $matches[0].Size -gt 25GB -or -not $matches[0].ETag) {
            throw "Invalid $edition root ISO size or ETag. Finish the upload before continuing."
        }
    }
    if (-not $WriteToken) {
        throw 'Missing operator storage token. Run deploy.ps1 continue using the approved uploader Azure sign-in; the host managed identity remains read-only.'
    }
    $staging = Join-Path $WorkDirectory "root-uploads-$RunId"
    New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
    $entries = @()
    foreach ($blob in $blobs) {
        $path = Join-Path $staging $blob.Name
        Write-Host "Downloading and validating the existing $($blob.Edition) root ISO; no ISO is uploaded again."
        Receive-PrivateSqlBlob -AccountName $AccountName -BlobName $blob.Name -Path $path -MaximumSize $blob.Size -IfMatch $blob.ETag
        if ((Get-Item -LiteralPath $path).Length -ne $blob.Size) { throw 'Root SQL ISO length changed during registration.' }
        Test-LicensedSqlIso -Path $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $canonicalName = "SQL2025-$($blob.Edition)-$hash.iso"
        if ($blob.Name -cmatch '^SQL2025-(Standard|Enterprise)-[a-f0-9]{64}\.iso$' -and
            $blob.Name -cne $canonicalName) {
            throw 'Content-addressed SQL blob name does not match its downloaded SHA256.'
        }
        $entries += [pscustomobject]@{
            Edition = $blob.Edition; Name = $canonicalName; SourceBlobName = $blob.Name
            Size = $blob.Size; Sha256 = $hash
        }
    }
    @{ Version = 1; Media = $entries } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $destination -Encoding UTF8
    Publish-PrivateSqlManifest -AccountName $AccountName -Path $destination -WriteToken $WriteToken
    Write-Host 'Published the missing manifest for existing root uploads. Original ISO blobs are unchanged.'
    return Get-PrivateSqlManifest -AccountName $AccountName -Destination (Join-Path $staging 'published-manifest.json')
}
