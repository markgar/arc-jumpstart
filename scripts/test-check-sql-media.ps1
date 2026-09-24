$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'check-sql-media.ps1')

function Assert-RejectedMedia {
    param([byte[]]$Bytes, [string]$Destination, [string]$Reason,
        [Nullable[long]]$Length, [string]$Hash = '', [string]$MediaFormat = 'iso')
    $stream = [System.IO.MemoryStream]::new($Bytes)
    try {
        $errorText = ''
        try {
            Save-LabMediaStream -InputStream $stream -Destination $Destination `
                -MediaFormat $MediaFormat -ContentLength $Length -ExpectedSha256 $Hash |
                Out-Null
        }
        catch { $errorText = $_.Exception.Message }
        if ($errorText -notlike "*$Reason*") {
            throw "Expected $Reason rejection, got: $errorText"
        }
        if (Test-Path -LiteralPath $Destination) {
            throw 'A rejected download left a published file.'
        }
        if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $Destination) `
                -Filter '*.partial').Count) {
            throw 'A rejected download left a partial file.'
        }
    }
    finally { $stream.Dispose() }
}

$folder = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-media-test-{0}" -f [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $folder)
try {
    $bytes = [byte[]]::new(16 * 2048 + 1 + 5 + 2048)
    [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, 16 * 2048 + 1)
    $expected = [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($bytes))
    $output = Join-Path $folder 'valid.iso'
    $stream = [System.IO.MemoryStream]::new($bytes)
    try {
        Save-LabMediaStream -InputStream $stream -Destination $output `
            -MediaFormat iso -ContentLength ([long]$bytes.Length) `
            -ExpectedSha256 $expected | Out-Null
    }
    finally { $stream.Dispose() }
    if (-not [System.Linq.Enumerable]::SequenceEqual(
            [byte[]][System.IO.File]::ReadAllBytes($output), [byte[]]$bytes)) {
        throw 'Complete ISO content was not preserved.'
    }
    if (@(Get-ChildItem -LiteralPath $folder -Filter '*.partial').Count) {
        throw 'Successful download left a partial file.'
    }
    $stream = [System.IO.MemoryStream]::new($bytes)
    try {
        $rejected = $false
        try {
            Save-LabMediaStream -InputStream $stream -Destination $output -MediaFormat iso
        }
        catch { $rejected = $_.Exception.Message -like '*already exists*' }
        if (-not $rejected -or (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -ne $expected) {
            throw 'An existing file was overwritten.'
        }
    }
    finally { $stream.Dispose() }

    Assert-RejectedMedia -Bytes ([System.Text.Encoding]::UTF8.GetBytes('<html>not SQL media</html>')) `
        -Destination (Join-Path $folder 'html.iso') -Reason 'volume descriptor'
    Assert-RejectedMedia -Bytes $bytes -Destination (Join-Path $folder 'short.iso') `
        -Length ([long]$bytes.Length + 100) -Reason 'Truncated download'
    Assert-RejectedMedia -Bytes $bytes -Destination (Join-Path $folder 'wrong.iso') `
        -Hash ('0' * 64) -Reason 'SHA-256'
    $pe = [byte[]]::new(256)
    [System.Text.Encoding]::ASCII.GetBytes('MZ').CopyTo($pe, 0)
    [BitConverter]::GetBytes([int]128).CopyTo($pe, 0x3C)
    [System.Text.Encoding]::ASCII.GetBytes("PE`0`0").CopyTo($pe, 128)
    $peOutput = Join-Path $folder 'valid.exe'
    $stream = [System.IO.MemoryStream]::new($pe)
    try {
        Save-LabMediaStream -InputStream $stream -Destination $peOutput `
            -MediaFormat pe -ContentLength ([long]$pe.Length) | Out-Null
    }
    finally { $stream.Dispose() }
    if (-not (Test-Path -LiteralPath $peOutput)) { throw 'Valid PE media was rejected.' }
    Assert-RejectedMedia -Bytes $bytes -Destination (Join-Path $folder 'bad.exe') `
        -MediaFormat pe -Reason 'Windows PE'

    $rejected = $false
    try {
        Invoke-LabMediaDownload -SourceUrl 'http://example.test/media.iso' `
            -Destination (Join-Path $folder 'insecure.iso') -MediaFormat iso `
            -ExpectedSha256 '' -LimitSeconds 10
    }
    catch { $rejected = $_.Exception.Message -like '*HTTPS*' }
    if (-not $rejected) { throw 'HTTP media URL was accepted.' }
    Write-Host 'PowerShell media checker regressions passed.'
}
finally { Remove-Item -LiteralPath $folder -Recurse -Force }
