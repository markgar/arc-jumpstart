$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot '../artifacts/scripts/private-sql-media.ps1')
. (Join-Path $PSScriptRoot '../artifacts/scripts/sql-media-validation.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')." }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}
function Get-TestFunction {
    param([string]$Path, [string]$Name)
    $tree = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $node = $tree.Find({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing $Name" }
    $node.Extent.Text
}
$engine = Join-Path $PSScriptRoot '../artifacts/scripts/45-install-sql-engine.ps1'
foreach ($name in @('Get-LabSqlMediaProfile', 'Get-LabSqlEditionContract', 'Get-SqlSaPasswordText')) {
    . ([scriptblock]::Create((Get-TestFunction $engine $name)))
}
. ([scriptblock]::Create((Get-TestFunction (Join-Path $PSScriptRoot '../artifacts/scripts/45-install-sql.ps1') 'Get-LicensedSqlGuestEdition')))

$directory = Join-Path ([IO.Path]::GetTempPath()) "arc-private-media-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $settings = @{ RESOURCE_GROUP_ROOT = 'test'; AZURE_RESOURCE_GROUP = 'test-infra'; ARC_RESOURCE_GROUP = 'test-arc' }
    Assert-Equal (Get-LabSqlSettings $settings).Mode 'developer' 'Default media mode'
    Assert-Equal (Get-LabSqlSettings $settings).ResourceGroup 'test-media' 'Durable storage is outside disposable groups'
    $shared = $settings.Clone()
    $shared.SQL_MEDIA_ACCOUNT_NAME = 'sqlmediashared'
    Assert-Throws { Get-LabSqlSettings $shared } 'requires an explicit SQL_MEDIA_RESOURCE_GROUP'
    $shared.SQL_MEDIA_RESOURCE_GROUP = 'approved-media'
    Assert-Equal (Get-LabSqlSettings $shared).AccountName 'sqlmediashared' 'Explicit existing media account'
    $shared.SQL_MEDIA_ACCOUNT_NAME = 'INVALID'
    Assert-Throws { Get-LabSqlSettings $shared } 'valid existing storage account name'
    $settings.SQL_EDITION_MODE = 'licensed'
    Assert-Equal (Get-LabSqlSettings $settings).Mode 'licensed' 'Explicit licensed mode'
    $settings.SQL_MEDIA_RESOURCE_GROUP = 'test-infra'
    Assert-Throws { Get-LabSqlSettings $settings } 'must be separate'
    $settings.SQL_MEDIA_RESOURCE_GROUP = 'bad/name'
    Assert-Throws { Get-LabSqlSettings $settings } 'Invalid SQL_MEDIA_RESOURCE_GROUP'
    $settings.SQL_EDITION_MODE = 'evaluation'
    Assert-Throws { Get-LabSqlSettings $settings } 'developer or licensed'

    foreach ($vm in @('JS-SQL-01', 'JS-RETAIL-01', 'JS-INSIGHT-01')) {
        Assert-Equal (Get-LicensedSqlGuestEdition $vm) 'Standard' 'Standard workload assignment'
    }
    foreach ($vm in @('JS-SQL-AG-01', 'JS-SQL-AG-02')) {
        Assert-Equal (Get-LicensedSqlGuestEdition $vm) 'Enterprise' 'Full AG requires Enterprise'
    }
    Assert-Throws { Get-LicensedSqlGuestEdition JS-DC-01 } 'No licensed SQL edition profile'
    foreach ($edition in @('Standard', 'Enterprise')) {
        $contract = Get-LabSqlEditionContract $edition
        foreach ($developerOrEval in @(-2117995310, -1785266663, 610778273, -1592396055)) {
            if ($developerOrEval -in $contract.EditionIds) { throw 'Licensed readiness must not accept Developer or Evaluation.' }
        }
        foreach ($name in @('Developer Edition', 'Enterprise Developer Edition', 'Evaluation Edition')) {
            if ($name -match $contract.AnalysisPattern) { throw 'SSAS licensed readiness accepted a noncommercial edition.' }
        }
    }
    Assert-Equal (Get-LabSqlEditionContract Standard).EngineEdition 2 'Standard engine family'
    Assert-Equal ((Get-LabSqlEditionContract Enterprise).EditionIds -join ',') '1804890536,1872460670' 'Both licensed Enterprise IDs'

    & {
        $SqlSaPassword = ConvertTo-SecureString ('TestsOnly!Aa1234567890' + ('x' * 16)) -AsPlainText -Force
        $probeText = (Get-TestFunction $engine 'Test-InstalledEngine') -replace
            '\[System.Data.SqlClient.SqlConnection\]::new\(\s*', '(New-FakeSqlConnection '
        . ([scriptblock]::Create($probeText))
        function Get-LabSqlMediaProfile { @{ Edition = $script:expectedEdition } }
        function New-FakeSqlConnection {
            param([string]$ConnectionString)
            $settings = [Data.SqlClient.SqlConnectionStringBuilder]::new($ConnectionString)
            if (-not $settings.IntegratedSecurity) {
                if ($settings.DataSource -ne 'tcp:localhost,1433' -or $settings.UserID -ne 'sa' -or
                    -not $settings.Encrypt -or -not $settings.TrustServerCertificate -or $settings.Pooling -or
                    $settings.Password -cne ([pscredential]::new('sa', $SqlSaPassword)).GetNetworkCredential().Password) {
                    throw 'sa verification must use the configured credential over fresh encrypted TCP.'
                }
                $script:saConnections++
                if ($script:saConnectionFailure) { throw 'sa login rejected' }
            }
            $connection = [pscustomobject]@{}
            $connection | Add-Member ScriptMethod Open {}
            $connection | Add-Member ScriptMethod Dispose {}
            $connection | Add-Member ScriptMethod CreateCommand {
                $command = [pscustomobject]@{ CommandText = ''; CommandTimeout = 0 }
                $command | Add-Member ScriptMethod ExecuteReader {
                    $table = [Data.DataTable]::new()
                    foreach ($key in $script:engineRow.Keys) { [void]$table.Columns.Add($key) }
                    $row = $table.NewRow()
                    foreach ($key in $script:engineRow.Keys) { $row[$key] = $script:engineRow[$key] }
                    $table.Rows.Add($row)
                    return ,$table.CreateDataReader()
                }
                $command | Add-Member ScriptMethod ExecuteScalar {
                    if (-not $this.CommandText.Contains('ORIGINAL_LOGIN()') -or
                        -not $this.CommandText.Contains('IS_SRVROLEMEMBER')) { throw 'Verify the actual sa sysadmin identity.' }
                    return $script:saQueryResult
                }
                $command
            }
            $connection
        }
        $script:engineRow = @{
            ProductVersion = '17.0.1000.7'; WindowsOnly = 0; IsSysadmin = 1; SaEnabled = 1
            ServerName = $env:COMPUTERNAME; Probe = 1; Edition = 'test'
            EditionId = -1534726760; EngineEdition = 2
        }
        $script:engineRow.ServerName = 'JS-SQL-01'
        $savedName = $env:COMPUTERNAME
        $script:saConnections = 0; $script:saConnectionFailure = $false; $script:saQueryResult = 1
        try {
            $env:COMPUTERNAME = 'JS-SQL-01'
            foreach ($edition in @('EnterpriseDeveloper', 'Standard', 'Enterprise')) {
                $script:expectedEdition = $edition
                $contract = Get-LabSqlEditionContract $edition
                $script:engineRow.EngineEdition = $contract.EngineEdition
                foreach ($id in $contract.EditionIds) {
                    $script:engineRow.EditionId = $id
                    Assert-Equal (Test-InstalledEngine).EditionId ([string]$id) 'Actual row verification accepts the assigned edition'
                }
                foreach ($id in @(-2117995310, -1785266663, 610778273, -1592396055, -1534726760, 1872460670) |
                    Where-Object { $_ -notin $contract.EditionIds }) {
                    $script:engineRow.EditionId = $id
                    Assert-Throws { Test-InstalledEngine } 'never converted or replaced'
                }
            }
            $script:engineRow.EditionId = 1804890536
            foreach ($field in @('WindowsOnly', 'SaEnabled', 'IsSysadmin')) {
                $original = $script:engineRow[$field]
                $script:engineRow[$field] = 1 - $original
                Assert-Throws { Test-InstalledEngine } 'mixed mode'
                $script:engineRow[$field] = $original
            }
            $script:saConnectionFailure = $true
            Assert-Throws { Test-InstalledEngine } 'sa login rejected'
            $script:saConnectionFailure = $false; $script:saQueryResult = 0
            Assert-Throws { Test-InstalledEngine } 'Encrypted sa sysadmin query did not succeed'
            if ($script:saConnections -lt 4) { throw 'Every SQL edition must verify an actual sa login.' }
        }
        finally { $env:COMPUTERNAME = $savedName }
    }

    $profilePath = Join-Path $directory 'edition.json'
    Assert-Equal (Get-LabSqlMediaProfile -Path $profilePath).Edition 'EnterpriseDeveloper' 'Legacy profile remains Developer'
    $profile = @{ Version = 1; Edition = 'Standard'; Size = 1265688576; Sha256 = ('a' * 64); Name = "SQL2025-Standard-$('a' * 64).iso" }
    $profile | ConvertTo-Json | Set-Content -LiteralPath $profilePath
    Assert-Equal (Get-LabSqlMediaProfile -Path $profilePath).Edition 'Standard' 'Persist licensed profile for later verification'
    foreach ($invalid in @(
        @{ Version = 1; Edition = 'Evaluation'; Size = 1265688576; Sha256 = ('a' * 64); Name = 'setup.iso' },
        @{ Version = 1; Edition = 'Standard'; Size = 1265688576; Sha256 = ('a' * 64); Name = '..\setup.iso' },
        @{ Version = 2; Edition = 'Standard'; Size = 1265688576; Sha256 = ('a' * 64); Name = $profile.Name }
    )) {
        $invalid | ConvertTo-Json | Set-Content -LiteralPath $profilePath
        Assert-Throws { Get-LabSqlMediaProfile -Path $profilePath } 'Invalid licensed SQL edition profile'
    }

    & {
        function Receive-PrivateSqlBlob {
            param($AccountName, $BlobName, $Path, $MaximumSize, [switch]$AllowMissing)
            Assert-Equal $BlobName 'manifest.json' 'Only manifest is read at the pause checkpoint'
            $script:manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path
        }
        $standard = @{ Edition = 'Standard'; Size = 1265688576; Sha256 = ('a' * 64); Name = "SQL2025-Standard-$('a' * 64).iso" }
        $enterprise = @{ Edition = 'Enterprise'; Size = 1265688576; Sha256 = ('b' * 64); Name = "SQL2025-Enterprise-$('b' * 64).iso" }
        $script:manifest = @{ Version = 1; Media = @($standard, $enterprise) }
        Assert-Equal @(Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'manifest.json')).Media.Count 2 'Both editions are mandatory'
        $standard.SourceBlobName = 'enu_sql_server_2025_standard_edition_x64_dvd_226be01e.iso'
        Assert-Equal (Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'root-manifest.json')).Media[0].SourceBlobName $standard.SourceBlobName 'Root source is preserved'
        foreach ($invalidSource in @('../SQL2025-Standard.iso', 'nested/SQL2025-Standard.iso', 'SQL2025-Enterprise.iso', '', 'https://elsewhere/SQL2025-Standard.iso')) {
            $standard.SourceBlobName = $invalidSource
            Assert-Throws { Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'invalid-root.json') } 'source blob name'
        }
        $standard.Remove('SourceBlobName')
        $script:manifest.Media = @($standard, $standard)
        Assert-Throws { Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'duplicate.json') } 'Invalid licensed'
        $script:manifest.Media = @($standard, $enterprise)
        $standard.Name = '../elsewhere.iso'
        Assert-Throws { Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'path.json') } 'Invalid licensed'
    }
    & {
        function Receive-PrivateSqlBlob {
            param($AccountName, $BlobName, $Path, $MaximumSize, [switch]$AllowMissing)
            if (-not $AllowMissing) { throw 'Missing-manifest discovery must be explicit.' }
            return $false
        }
        Assert-Equal (Get-PrivateSqlManifest sqlmediatest (Join-Path $directory 'absent.json') -AllowMissing) $null 'Absent manifest is discoverable'
    }

    & {
        function Invoke-RestMethod {
            param($Headers, $Uri, $TimeoutSec)
            Assert-Equal $Headers.Metadata 'true' 'Use host managed identity'
            if ($Uri -notlike 'http://169.254.169.254/*resource=https%3A%2F%2Fstorage.azure.com%2F') { throw 'Unexpected token audience or endpoint.' }
            @{ access_token = 'fake-token' }
        }
        function New-PrivateSqlBlobRequest {
            param($Uri)
            Assert-Equal $Uri 'https://sqlmediatest.blob.core.windows.net/sql-media/manifest.json' 'Private account source'
            $request = [pscustomobject]@{ AllowAutoRedirect = $true; Timeout = 0; ReadWriteTimeout = 0; Headers = @{} }
            $request | Add-Member ScriptMethod GetResponse {
                if ($this.AllowAutoRedirect -or $this.Headers.Authorization -ne 'Bearer fake-token') {
                    throw 'Never forward managed-identity credentials through redirects.'
                }
                $response = [pscustomobject]@{ StatusCode = 200; ContentLength = $script:declaredLength }
                $response | Add-Member ScriptMethod GetResponseStream { [IO.MemoryStream]::new([byte[]](1, 2, 3)) }
                $response | Add-Member ScriptMethod Dispose { $script:disposed++ }
                $response
            }
            $request
        }
        $script:disposed = 0; $script:declaredLength = 3
        $output = Join-Path $directory 'download.bin'
        Receive-PrivateSqlBlob sqlmediatest manifest.json $output 10
        Assert-Equal (Get-Item -LiteralPath $output).Length 3 'Stream the whole blob'
        Assert-Equal $script:disposed 1 'Dispose HTTP response'
        Assert-Throws { Receive-PrivateSqlBlob sqlmediatest manifest.json $output 10 } 'already exists'
        Assert-Equal $script:disposed 2 'Dispose on exclusive-create failure'
        $script:declaredLength = 4
        Assert-Throws { Receive-PrivateSqlBlob sqlmediatest manifest.json (Join-Path $directory 'short.bin') 10 } 'Incomplete private SQL download'
        Assert-Throws { Receive-PrivateSqlBlob sqlmediatest '../other' (Join-Path $directory 'bad.bin') 10 } 'Invalid private SQL media source'
        $script:declaredLength = 11
        Assert-Throws { Receive-PrivateSqlBlob sqlmediatest manifest.json (Join-Path $directory 'large.bin') 10 } 'Invalid private SQL blob response'
    }

    Add-Type -TypeDefinition @'
using System.Net;
public sealed class ArcSqlTestResponse : WebResponse {
    public int StatusCode { get; set; }
    public bool Closed { get; private set; }
    private readonly WebHeaderCollection headers = new WebHeaderCollection();
    public override WebHeaderCollection Headers { get { return headers; } }
    public override void Close() { Closed = true; }
}
'@
    & {
        $script:errorResponse = [ArcSqlTestResponse]::new()
        $request = [pscustomobject]@{}
        $request | Add-Member ScriptMethod GetResponse {
            throw [Net.WebException]::new('Do not print raw authentication details.', $null,
                [Net.WebExceptionStatus]::ProtocolError, $script:errorResponse)
        }
        $script:errorResponse.StatusCode = 404
        $script:errorResponse.Headers['x-ms-error-code'] = 'BlobNotFound'
        Assert-Equal (Open-PrivateSqlBlobResponse $request manifest.json -AllowMissing) $null 'Only BlobNotFound permits discovery'
        Assert-Equal $script:errorResponse.Closed $true 'Dispose missing response'
        foreach ($status in @(403, 412, 500)) {
            $script:errorResponse = [ArcSqlTestResponse]::new()
            $script:errorResponse.StatusCode = $status
            $script:errorResponse.Headers['x-ms-error-code'] = 'TestFailure'
            Assert-Throws { Open-PrivateSqlBlobResponse $request manifest.json -AllowMissing } "HTTP $status (TestFailure)"
            Assert-Equal $script:errorResponse.Closed $true 'Dispose failed response'
        }
    }

    & {
        function Invoke-RestMethod { @{ access_token = 'fake-token' } }
        function New-PrivateSqlBlobRequest {
            param($Uri)
            if ($Uri -notlike 'https://sqlmediatest.blob.core.windows.net/sql-media?restype=container*') {
                throw 'List only the approved container.'
            }
            $request = [pscustomobject]@{ AllowAutoRedirect = $true; Timeout = 0; ReadWriteTimeout = 0; Headers = @{} }
            $request | Add-Member ScriptMethod GetResponse {
                if ($this.AllowAutoRedirect) { throw 'Do not redirect the identity token.' }
                $response = [pscustomobject]@{ StatusCode = 200; ContentLength = 1000 }
                $response | Add-Member ScriptMethod GetResponseStream {
                    $xml = '<EnumerationResults><Blobs>' +
                        '<Blob><Name>SQL2025-Standard.iso</Name><Properties><Content-Length>1265688576</Content-Length><Etag>"one"</Etag></Properties></Blob>' +
                        '<Blob><Name>enu_sql_server_2025_enterprise_edition_x64_dvd_dd8b2bab.iso</Name><Properties><Content-Length>1265688576</Content-Length><Etag>"two"</Etag></Properties></Blob>' +
                        '<Blob><Name>nested/SQL2025-Standard.iso</Name></Blob><Blob><Name>SQL2022-Standard.iso</Name></Blob>' +
                        '</Blobs><NextMarker>' + $script:nextMarker + '</NextMarker></EnumerationResults>'
                    [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($xml))
                }
                $response | Add-Member ScriptMethod Dispose {}
                $response
            }
            $request
        }
        $script:nextMarker = ''
        $blobs = @(Get-RootSqlMediaBlobs sqlmediatest)
        Assert-Equal $blobs.Count 2 'Only supported root ISO names are discovered'
        Assert-Equal $blobs[0].ETag '"one"' 'Capture source ETag for conditional download'
        Assert-Equal $blobs[1].Edition Enterprise 'Recognize original Microsoft filenames'
        $script:nextMarker = 'more'
        Assert-Throws { Get-RootSqlMediaBlobs sqlmediatest } 'more than 5000'
    }

    & {
        function Get-PrivateSqlManifest { [pscustomobject]@{ Version = 1; Media = @() } }
        function Get-RootSqlMediaBlobs { throw 'An existing manifest must not trigger discovery.' }
        function Publish-PrivateSqlManifest { throw 'An existing manifest must not be overwritten.' }
        Assert-Equal (Initialize-PrivateSqlManifest sqlmediatest $directory existing).Version 1 'Existing manifests need no write token'
    }

    & {
        $script:rootStandard = [pscustomobject]@{ Edition = 'Standard'; Name = 'SQL2025-Standard.iso'; Size = [long]1265688576; ETag = '"one"' }
        $script:rootEnterprise = [pscustomobject]@{ Edition = 'Enterprise'; Name = 'SQL2025-Enterprise.iso'; Size = [long]1265688576; ETag = '"two"' }
        $script:rootBlobs = @($script:rootStandard, $script:rootEnterprise)
        $script:published = 0; $script:rejectIso = $false
        $script:validated = [Collections.Generic.List[string]]::new()
        function Get-PrivateSqlManifest {
            param($AccountName, $Destination, [switch]$AllowMissing)
            if (-not $AllowMissing) { Get-Content -LiteralPath $script:publishedPath -Raw | ConvertFrom-Json }
        }
        function Get-RootSqlMediaBlobs { $script:rootBlobs }
        function Receive-PrivateSqlBlob {
            param($AccountName, $BlobName, $Path, $MaximumSize, $IfMatch)
            if ($BlobName -notin @('SQL2025-Standard.iso', 'SQL2025-Enterprise.iso') -or -not $IfMatch) {
                throw 'Download the existing root blob with its ETag, not the canonical destination name.'
            }
            [IO.File]::WriteAllText($Path, 'test bytes')
        }
        function Get-Item { param($LiteralPath) [pscustomobject]@{ Length = [long]1265688576 } }
        function Test-LicensedSqlIso {
            param($Path)
            $script:validated.Add($Path)
            if ($script:rejectIso) { throw 'Invalid Microsoft setup signature.' }
        }
        function Get-FileHash { [pscustomobject]@{ Hash = ('A' * 64) } }
        function Publish-PrivateSqlManifest {
            param($AccountName, $Path, $WriteToken)
            Assert-Equal $WriteToken 'fake-write-token' 'Use operator token only for publication'
            Assert-Equal $script:validated.Count 2 'Validate both media before publishing'
            $script:published++
            $script:publishedPath = $Path
        }
        $manifest = Initialize-PrivateSqlManifest sqlmediatest $directory registered fake-write-token
        Assert-Equal $script:published 1 'Publish exactly one manifest'
        Assert-Equal $manifest.Media[0].SourceBlobName 'SQL2025-Standard.iso' 'Keep original blobs in place'
        Assert-Equal $manifest.Media[0].Name "SQL2025-Standard-$('a' * 64).iso" 'Use canonical local media filenames'
        Assert-Equal $manifest.Media[1].Sha256 ('a' * 64) 'Hash actual downloaded media'
        foreach ($case in @('duplicate', 'missing', 'size', 'token', 'signature')) {
            $script:rootBlobs = @($script:rootStandard, $script:rootEnterprise)
            $script:rootStandard.Size = [long]1265688576
            $script:rejectIso = $false
            $writeToken = 'fake-write-token'
            switch ($case) {
                duplicate { $script:rootBlobs += $script:rootStandard; $message = 'exactly one' }
                missing { $script:rootBlobs = @($script:rootStandard); $message = 'exactly one' }
                size { $script:rootStandard.Size = 100; $message = 'size or ETag' }
                token { $writeToken = ''; $message = 'Missing operator storage token' }
                signature { $script:rejectIso = $true; $message = 'Invalid Microsoft' }
            }
            Assert-Throws { Initialize-PrivateSqlManifest sqlmediatest $directory $case $writeToken } $message
            Assert-Equal $script:published 1 'Never publish incomplete or invalid media'
        }
    }

    & {
        $script:manifestUpload = [IO.MemoryStream]::new()
        function New-PrivateSqlBlobRequest {
            param($Uri)
            Assert-Equal $Uri 'https://sqlmediatest.blob.core.windows.net/sql-media/manifest.json' 'Publish only the fixed manifest location'
            $request = [pscustomobject]@{
                Method = ''; AllowAutoRedirect = $true; Timeout = 0; ReadWriteTimeout = 0
                ContentType = ''; ContentLength = 0; Headers = @{}
            }
            $request | Add-Member ScriptMethod GetRequestStream { $script:manifestUpload }
            $request | Add-Member ScriptMethod GetResponse {
                Assert-Equal $this.Headers['If-None-Match'] '*' 'Never overwrite a concurrently published manifest'
                Assert-Equal $this.Method PUT 'Publish through Blob REST'
                Assert-Equal $this.AllowAutoRedirect $false 'Never redirect the operator token'
                $response = [pscustomobject]@{ StatusCode = 201 }
                $response | Add-Member ScriptMethod Dispose {}
                $response
            }
            $request
        }
        $path = Join-Path $directory 'publish.json'
        [IO.File]::WriteAllText($path, '{"Version":1}')
        Publish-PrivateSqlManifest sqlmediatest $path fake-write-token
        Assert-Equal ([Text.Encoding]::UTF8.GetString($script:manifestUpload.ToArray())) '{"Version":1}' 'Publish exact manifest bytes'
    }

    & {
        $script:isoSignature = 'O=Microsoft Corporation, C=US'
        $script:isoVersion = 17; $script:isoKey = $true; $script:dismounts = 0
        function Get-Item {
            param($LiteralPath)
            if ($LiteralPath -like '*.iso') { return [pscustomobject]@{ Length = [long]1265688576 } }
            [pscustomobject]@{ VersionInfo = @{ ProductMajorPart = $script:isoVersion } }
        }
        function Get-DiskImage { [pscustomobject]@{ Attached = $false } }
        function Mount-DiskImage { 'Incidental mount metadata' }
        function Dismount-DiskImage { $script:dismounts++; 'Incidental dismount metadata' }
        function Get-Volume {
            param([Parameter(ValueFromPipeline)]$InputObject)
            process { [pscustomobject]@{ DriveLetter = 'V' } }
        }
        function Get-AuthenticodeSignature { @{ Status = 'Valid'; SignerCertificate = @{ Subject = $script:isoSignature } } }
        function Get-ChildItem { [pscustomobject]@{ FullName = 'V:\x64\DefaultSetup.ini' } }
        function Get-Content {
            if ($script:isoKey) { 'PID="AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"' } else { '[OPTIONS]' }
        }
        Assert-Equal @(Test-LicensedSqlIso 'test.iso').Count 0 'Validation emits no incidental disk metadata'
        foreach ($case in @('signature', 'version', 'key')) {
            $script:isoSignature = 'O=Microsoft Corporation, C=US'; $script:isoVersion = 17; $script:isoKey = $true
            switch ($case) {
                signature { $script:isoSignature = 'O=Untrusted'; $message = 'Microsoft signature' }
                version { $script:isoVersion = 16; $message = 'SQL Server 2025' }
                key { $script:isoKey = $false; $message = 'pre-keyed media' }
            }
            Assert-Throws { Test-LicensedSqlIso 'test.iso' } $message
        }
        Assert-Equal $script:dismounts 4 'Dismount on success and all validation failures'
    }

    & {
        . ([scriptblock]::Create((Get-TestFunction (Join-Path $PSScriptRoot '../artifacts/scripts/45-install-sql.ps1') 'Get-LicensedSqlPayload')))
        $cache = Join-Path $directory 'licensed-cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        $RunId = 'root-routing'; $SqlMediaAccountName = 'sqlmediatest'
        $guestLibrary = ''; $script:engineScript = ''
        $script:receivedNames = [Collections.Generic.List[string]]::new()
        $script:payloadManifest = [pscustomobject]@{
            Media = @(
                [pscustomobject]@{
                    Edition = 'Standard'; Size = [long]1265688576; Sha256 = ('a' * 64)
                    Name = "SQL2025-Standard-$('a' * 64).iso"; SourceBlobName = 'SQL2025-Standard.iso'
                },
                [pscustomobject]@{
                    Edition = 'Enterprise'; Size = [long]1265688576; Sha256 = ('a' * 64)
                    Name = "SQL2025-Enterprise-$('a' * 64).iso"
                }
            )
        }
        function Get-PrivateSqlManifest { $script:payloadManifest }
        function Get-BudgetSeconds { 1200 }
        function Receive-PrivateSqlBlob {
            param($AccountName, $BlobName, $Path, $MaximumSize, $TimeoutSeconds)
            $script:receivedNames.Add($BlobName)
            [IO.File]::WriteAllText($Path, 'test media')
        }
        function Get-Item {
            param($LiteralPath)
            if ($LiteralPath -match '\.iso(?:\.partial)?$') {
                return [pscustomobject]@{ Length = [long]1265688576 }
            }
            Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath
        }
        function Get-FileHash { [pscustomobject]@{ Hash = ('A' * 64) } }
        Assert-Equal @(Get-LicensedSqlPayload).Count 10 'Prepare both guest payloads from the shared installer implementation'
        Assert-Equal $script:receivedNames[0] 'SQL2025-Standard.iso' 'Download original root name'
        Assert-Equal $script:receivedNames[1] "SQL2025-Enterprise-$('a' * 64).iso" 'Preserve desktop-uploader manifests without SourceBlobName'
        $script:payloadManifest.Media[0].SourceBlobName = 'SQL2025-Standard-other.iso'
        Assert-Throws { Get-LicensedSqlPayload } 'manifest changed'
    }
    Write-Host 'Private SQL media regression checks passed.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
