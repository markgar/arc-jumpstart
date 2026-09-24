param(
    [string]$Url,
    [string]$Output,
    [ValidateSet('iso', 'pe')][string]$Format = 'iso',
    [string]$Sha256 = '',
    [ValidateRange(1, 2147483)][int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'

function Assert-MediaStructure {
    param([string]$Path, [string]$MediaFormat)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($MediaFormat -eq 'iso') {
            $signature = [byte[]]::new(5)
            for ($sector = 16; $sector -lt 32; $sector++) {
                [void]$stream.Seek($sector * 2048 + 1, [System.IO.SeekOrigin]::Begin)
                if ($stream.Read($signature, 0, 5) -eq 5 -and
                    [System.Text.Encoding]::ASCII.GetString($signature) -in
                    @('CD001', 'BEA01', 'NSR02', 'NSR03')) { return }
            }
            throw 'Downloaded file has no ISO/UDF volume descriptor.'
        }
        $header = [byte[]]::new(4)
        if ($stream.Read($header, 0, 2) -ne 2 -or
            [System.Text.Encoding]::ASCII.GetString($header, 0, 2) -ne 'MZ') {
            throw 'Downloaded file is not a Windows PE executable.'
        }
        [void]$stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin)
        if ($stream.Read($header, 0, 4) -ne 4) { throw 'Truncated executable header.' }
        $offset = [System.BitConverter]::ToInt32($header, 0)
        if ($offset -lt 0 -or $offset -gt $stream.Length - 4) {
            throw 'Downloaded file has no valid PE signature.'
        }
        [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
        if ($stream.Read($header, 0, 4) -ne 4 -or
            [System.Text.Encoding]::ASCII.GetString($header, 0, 4) -ne "PE`0`0") {
            throw 'Downloaded file has no valid PE signature.'
        }
    }
    finally { $stream.Dispose() }
}

function Save-LabMediaStream {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$InputStream,
        [Parameter(Mandatory)][string]$Destination,
        [string]$MediaFormat = 'iso',
        [Nullable[long]]$ContentLength,
        [string]$ExpectedSha256 = '',
        [System.Threading.CancellationToken]$CancellationToken =
            [System.Threading.CancellationToken]::None
    )
    if (Test-Path -LiteralPath $Destination) {
        throw 'Output already exists; choose a new path to avoid reusing stale media.'
    }
    $folder = Split-Path -Parent ([System.IO.Path]::GetFullPath($Destination))
    [void][System.IO.Directory]::CreateDirectory($folder)
    $temporary = Join-Path $folder ("{0}.partial" -f [guid]::NewGuid())
    $received = [long]0
    $started = [DateTime]::UtcNow
    $lastReport = $started
    try {
        $file = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew)
        try {
            $buffer = [byte[]]::new(1MB)
            while (($count = $InputStream.ReadAsync($buffer, 0, $buffer.Length,
                    $CancellationToken).GetAwaiter().GetResult()) -gt 0) {
                $file.Write($buffer, 0, $count)
                $received += $count
                if (([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 10) {
                    Write-Host ('Downloaded {0:N1} MiB' -f ($received / 1MB))
                    $lastReport = [DateTime]::UtcNow
                }
            }
        }
        finally { $file.Dispose() }
        $CancellationToken.ThrowIfCancellationRequested()
        if ($null -ne $ContentLength -and $received -ne $ContentLength) {
            throw "Truncated download: received $received of $ContentLength bytes."
        }
        Assert-MediaStructure $temporary $MediaFormat
        $hash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        if ($ExpectedSha256 -and $hash -ine $ExpectedSha256) {
            throw 'Downloaded media does not match the supplied SHA-256.'
        }
        [System.IO.File]::Move($temporary, $Destination, $false)
        Write-Host "Saved: $Destination"
        Write-Host ('Bytes: {0}; elapsed: {1:N1}s' -f $received,
            ([DateTime]::UtcNow - $started).TotalSeconds)
        Write-Host "SHA-256: $hash"
        Write-Host 'File structure verified. Windows execution, edition and licensing are not verified.'
        if (-not $ExpectedSha256) {
            Write-Host 'No published hash supplied: this checksum records the download, not its authenticity.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Invoke-LabMediaDownload {
    param([string]$SourceUrl, [string]$Destination, [string]$MediaFormat,
        [string]$ExpectedSha256, [int]$LimitSeconds)
    $source = $null
    if (-not [uri]::TryCreate($SourceUrl, [System.UriKind]::Absolute, [ref]$source) -or
        $source.Scheme -ne 'https') { throw 'Use an HTTPS media URL.' }
    if ($ExpectedSha256 -and $ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'SHA-256 must be 64 hexadecimal characters.'
    }
    if (Test-Path -LiteralPath $Destination) {
        throw 'Output already exists; choose a new path to avoid reusing stale media.'
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $deadline = [System.Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds($LimitSeconds))
    $headers = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource(
        $deadline.Token)
    try {
        $headers.CancelAfter([TimeSpan]::FromSeconds(60))
        $response = $client.GetAsync($source,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $headers.Token).GetAwaiter().GetResult()
        try {
            $response.EnsureSuccessStatusCode() | Out-Null
            if ($response.RequestMessage.RequestUri.Scheme -ne 'https') {
                throw 'Media download redirected to a non-HTTPS URL.'
            }
            $input = $response.Content.ReadAsStreamAsync($deadline.Token).GetAwaiter().GetResult()
            try {
                Save-LabMediaStream -InputStream $input -Destination $Destination `
                    -MediaFormat $MediaFormat -ContentLength $response.Content.Headers.ContentLength `
                    -ExpectedSha256 $ExpectedSha256 -CancellationToken $deadline.Token
            }
            finally { $input.Dispose() }
        }
        finally { $response.Dispose() }
    }
    finally {
        $headers.Dispose()
        $deadline.Dispose()
        $client.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $Url -or -not $Output) { throw 'Supply -Url and -Output.' }
        Invoke-LabMediaDownload -SourceUrl $Url -Destination $Output `
            -MediaFormat $Format -ExpectedSha256 $Sha256 -LimitSeconds $TimeoutSeconds
    }
    catch {
        $message = $_.Exception.Message -replace 'https?://[^\s''"]+', '[URL redacted]'
        [Console]::Error.WriteLine("Media check failed ($($_.Exception.GetType().Name)): $message")
        exit 1
    }
}
