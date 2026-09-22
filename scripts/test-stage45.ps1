$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../artifacts/scripts/45-install-sql.ps1'
$enginePath = Join-Path $PSScriptRoot '../artifacts/scripts/45-install-sql-engine.ps1'
function Parse-Script {
    param([string]$Text)
    $tokens = $null
    $errors = $null
    $tree = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join "`n") }
    $tree
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}
function Assert-EngineArguments {
    param([string]$Arguments)
    $features = [regex]::Matches($Arguments, '(?i)(?:^|\s)/FEATURES=([^\s]+)')
    if ($features.Count -ne 1 -or $features[0].Groups[1].Value -cne 'SQLENGINE') {
        throw 'Lab preparation must install FEATURES=SQLENGINE only.'
    }
    if ($Arguments -match '(?i)AZUREEXTENSION|(?:^|\s)/(?:AZURE|ARC)[A-Z]*|azcmagent|AzureConnectedMachineAgent') {
        throw 'Arc and Arc SQL extension onboarding must remain user-operated.'
    }
}
function Get-FunctionText {
    param($Tree, [string]$Name)
    $node = $Tree.Find({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing function $Name" }
    $node.Extent.Text
}
function Get-EmbeddedScript {
    param([string]$Name)
    $node = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $Name)
    }, $true)
    $node.Right.Expression.Value
}
$ast = Parse-Script (Get-Content $scriptPath -Raw)
$engineAst = Parse-Script (Get-Content $enginePath -Raw)
$guestLibrary = Get-EmbeddedScript guestLibrary
$guestInstall = Get-EmbeddedScript guestInstall
$sqlGuestWorker = Get-EmbeddedScript sqlGuestWorker
$guestAst = Parse-Script $guestLibrary
$installAst = Parse-Script $guestInstall
$workerAst = Parse-Script $sqlGuestWorker
. ([scriptblock]::Create($guestLibrary))
foreach ($name in @('Get-BudgetSeconds', 'Wait-BoundedJob', 'Complete-SqlGuest', 'Get-MicrosoftPackage',
    'Assert-DownloadedPackage', 'Get-SqlMediaCacheAction', 'Get-SqlMediaDefinition',
    'Assert-MicrosoftDownloadUri', 'Receive-MicrosoftDownload', 'Invoke-ParallelSqlGuests',
    'Invoke-SqlGuest', 'Wait-SqlGuest', 'Copy-SqlPayload', 'Export-SqlGuestLogs', 'Write-StageLog')) {
    . ([scriptblock]::Create((Get-FunctionText $ast $name)))
}
$script:stageDeadlineUtc = [DateTime]::UtcNow.AddMinutes(235)
$script:phaseDeadlineUtc = $null
$script:guestDeadlineUtc = $null

# The sole engine implementation is embedded by Bicep, not copied into a runner.
$bicep = Get-Content (Join-Path $PSScriptRoot '../infra/stages/45-sql-install/main.bicep') -Raw
foreach ($text in @("name: 'EngineScriptBase64'", "base64(loadTextContent('../../../artifacts/scripts/45-install-sql-engine.ps1'))",
    'timeoutInSeconds: 14400', 'protectedScriptParameters:')) {
    if (-not $bicep.Contains($text)) { throw "Missing stage wiring: $text" }
}
if (-not $guestInstall.Contains('& "$work\45-install-sql-engine.ps1" -PassThru') -or
    $ast.Extent.Text.Contains('/FEATURES=SQLENGINE')) { throw 'Canonical stage must reuse the proven engine file, not another setup implementation.' }
foreach ($tree in @($ast, $installAst, $guestAst, $engineAst)) {
    if ($tree.Find({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('Start-ScheduledTask', 'Register-ScheduledTask', 'New-ScheduledTaskAction', 'Stop-Process')
    }, $true)) { throw 'No scheduled installation or forced installer termination is permitted.' }
}
$heldText = Get-FunctionText $ast Complete-SqlGuest
if ($heldText.Contains('Start-Job') -or -not $heldText.Contains('Invoke-Command -Session $session') -or
    -not $heldText.Contains('New-PSSession -VMName')) { throw 'Installer must execute synchronously in a held session.' }
if ($ast.Extent.Text.Contains('SqlWmiManagement') -or $heldText.Contains('Prepared')) { throw 'Obsolete task/managed WMI dependencies must be removed.' }
$payloadText = Get-FunctionText $ast Get-SqlPayload
foreach ($obsolete in @('vc_redist', 'msodbcsql.msi', 'MsSqlCmdLnUtils', 'Invoke-NativeSetup')) {
    if ($payloadText.Contains($obsolete) -or $guestInstall.Contains($obsolete) -or $guestLibrary.Contains($obsolete)) {
        throw "No separate prerequisite download/install is permitted: $obsolete"
    }
}
if (-not (Get-FunctionText $guestAst Get-SqlCmdPath).Contains('Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE')) {
    throw 'Use the CLI bundled with SQL2025 engine media.'
}
$pathText = Get-FunctionText $guestAst Set-SqlCmdMachinePath
if (-not $pathText.Contains("SetEnvironmentVariable('Path', `$newPath, 'Machine')") -or
    -not $pathText.Contains('$env:Path = $newPath')) { throw 'PATH must be refreshed for both machine and current Direct session.' }
foreach ($text in @('/FEATURES=SQLENGINE', '/SQLSYSADMINACCOUNTS=', '-Wait -PassThru', '$row.EditionId -ne -2117995310',
    '$row.EngineEdition -ne 3', '$row.WindowsOnly -ne 1', '$row.IsSysadmin -ne 1')) {
    if (-not $engineAst.Extent.Text.Contains($text)) { throw "Missing proven engine contract: $text" }
}
Assert-EngineArguments '/Q /FEATURES=SQLENGINE'
foreach ($arguments in @('/FEATURES=SQLENGINE,AZUREEXTENSION', '/FEATURES=SQLENGINE /FEATURES=AZUREEXTENSION', '/FEATURES=SQL')) {
    Assert-Throws { Assert-EngineArguments $arguments } 'SQLENGINE only'
}
foreach ($flag in @('/AZUREEXTENSION', '/AZURETENANTID=example', '/AZURESUBSCRIPTIONID=example',
    '/AZURESERVICEPRINCIPALSECRET=example', '/ARCONBOARD=true', 'azcmagent connect')) {
    Assert-Throws { Assert-EngineArguments "/FEATURES=SQLENGINE $flag" } 'user-operated'
}

& {
    $guard = $ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('duplicate guest names')
    }
    $selector = [scriptblock]::Create("[CmdletBinding()]`n" + $ast.ParamBlock.Extent.Text + "`n" + $guard.Extent.Text + "`n" + '$VmNames')
    $inputs = @{ NestedWindowsPassword = 'dummy'; SqlDownloadUrl = 'dummy'; RunId = 'test'; EngineScriptBase64 = 'dummy' }
    Assert-Equal ((& $selector @inputs) -join ',') 'JS-SQL-01,JS-SQL-AG-01,JS-SQL-AG-02' 'Default all three guests'
    Assert-Equal ((& $selector @inputs -VmNames JS-SQL-01) -join ',') 'JS-SQL-01' 'One guest smoke'
    Assert-Equal ((& $selector @inputs -VmNames JS-SQL-AG-02,JS-SQL-01) -join ',') 'JS-SQL-AG-02,JS-SQL-01' 'Preserve order'
    Assert-Throws { & $selector @inputs -VmNames @() } 'VmNames'
    Assert-Throws { & $selector @inputs -VmNames $null } 'VmNames'
    Assert-Throws { & $selector @inputs -VmNames '' } 'VmNames'
    Assert-Throws { & $selector @inputs -VmNames JS-DC-01 } 'VmNames'
    Assert-Throws { & $selector @inputs -VmNames JS-SQL-01,js-sql-01 } 'duplicate guest names'
    if (-not $ast.Extent.Text.Contains('Invoke-ParallelSqlGuests -Names $VmNames')) {
        throw 'Canonical coordinator must use the selected guests.'
    }
}
& {
    try {
        Assert-Equal (Get-BudgetSeconds 30 test) 30 'Bound operation budget'
        $script:phaseDeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        Assert-Throws { Get-BudgetSeconds 30 test } 'Execution budget exhausted'
    } finally { $script:phaseDeadlineUtc = $null }
}

# Exercise the real engine try/catch/finally using mocked Windows boundaries.
& {
    $engineTry = $engineAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }
    $engineCode = [scriptblock]::Create($engineTry.Extent.Text)
    $logs = 'logs'; $IsoPath = 'media.iso'; $mountedHere = $false
    $lock = [pscustomobject]@{}
    $lock | Add-Member ScriptMethod Dispose {}
    function New-Item { param($ItemType, $Path, [switch]$Force) }
    function Set-Content { param($Path, $Encoding, [Parameter(ValueFromPipeline)]$Value) process {} }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) if ($script:queued) { @{ State = 'Queued' } } }
    function Get-Process { param($Name, $ErrorAction) }
    function Get-Service { param($Name, $ErrorAction) $script:services }
    function Test-Path { param($Path) $Path -like '*Instance Names*' -and $script:names.Count -gt 0 }
    function Get-ItemProperty {
        param($Path)
        $p = [ordered]@{}
        foreach ($name in $script:names) { $p[$name] = 'id' }
        [pscustomobject]$p
    }
    function Get-ChildItem { param($Path, [switch]$Directory, $ErrorAction) if ($script:orphaned) { 'orphan' } }
    function Get-Item { param($Path) @{ Length = 1265688576 } }
    function Get-FileHash { param($Path, $Algorithm) @{ Hash = $mediaHash } }
    function Get-DiskImage { param($ImagePath) @{ Attached = $false } }
    function Mount-DiskImage { param($ImagePath, $StorageType, $Access) }
    function Dismount-DiskImage { param($ImagePath) }
    function Get-Volume { param([Parameter(ValueFromPipeline)]$InputObject) process { @{ DriveLetter = 'D' } } }
    function Get-AuthenticodeSignature { param($Path) @{ Status = 'Valid'; SignerCertificate = @{ Subject = 'O=Microsoft Corporation,C=US' } } }
    function Test-InstalledEngine { if ($script:badEngine) { throw 'wrong edition or authentication' }; @{ EditionId = -2117995310 } }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
        if (-not $Wait -or -not $PassThru) { throw 'Engine must use proven synchronous wait.' }
        Assert-EngineArguments $ArgumentList
        $script:engineStarts++
        @{ ExitCode = $script:engineCode }
    }
    $script:queued = $false; $script:orphaned = $false; $script:badEngine = $false
    $script:services = @(@{ Name = 'MSSQLSERVER' }); $script:names = @('MSSQLSERVER')
    $script:engineStarts = 0
    $result = [ordered]@{ Status = 'Running'; Engine = $null; Error = ''; SetupExitCode = $null }
    & $engineCode
    Assert-Equal $result.Status 'VerifiedExisting' 'Healthy engine must be reused'
    Assert-Equal $script:engineStarts 0 'Never replace healthy engine'
    $script:badEngine = $true
    Assert-Throws { & $engineCode } 'wrong edition'
    $script:badEngine = $false
    $script:names = @('MSSQLSERVER', 'OTHER')
    Assert-Throws { & $engineCode } 'automatic repair or replacement is forbidden'
    $script:names = @(); $script:services = @()
    $script:orphaned = $true
    Assert-Throws { & $engineCode } 'Orphaned SQL instance files'
    $script:orphaned = $false; $script:queued = $true
    Assert-Throws { & $engineCode } 'active or queued'
    $script:queued = $false
    $mediaHash = 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851'
    foreach ($code in @(0, 3010, 1603, 1618, 1641, -2061893606)) {
        $script:engineCode = $code
        if ($code -notin @(0, 3010)) { Assert-Throws { & $engineCode } "exit code $code" }
        else {
            & $engineCode
            Assert-Equal $result.Status $(if ($code -eq 0) { 'InstalledAndVerified' } else { 'RebootRequired' }) 'Engine completion status'
        }
    }
}

& {
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
        Assert-Equal $Namespace 'root\Microsoft\SqlServer\ComputerManagement17' 'Native SQL WMI17'
        Assert-Equal $ClassName 'SqlService' 'Native service class'
        Assert-Equal $Filter "ServiceName='MSSQLSERVER'" 'Default service only'
        if ($script:wmiPresent) { @{ ServiceName = 'MSSQLSERVER' } }
    }
    $script:wmiPresent = $true
    Test-SqlWmiReady
    $script:wmiPresent = $false
    Assert-Throws { Test-SqlWmiReady } 'native SQL WMI'
}
& {
    function Test-Path { param($Path) $true }
    function Get-Item { param($Path) @{ VersionInfo = @{ ProductMajorPart = $script:major } } }
    $script:major = 17
    if (-not (Get-SqlCmdPath)) { throw 'CLI product version must be used, not file version.' }
    $script:major = 15
    Assert-Throws { Get-SqlCmdPath } 'Unexpected sqlcmd generation'
}
& {
    $saved = $env:COMPUTERNAME
    try {
        $env:COMPUTERNAME = 'Host'
        Assert-Throws { Assert-SqlGuestIdentity } 'never on the Hyper-V host'
        $env:COMPUTERNAME = 'JS-SQL-01'
        function Get-Service { param($Name) @{ Status = 'Running' } }
        function Test-SqlWmiReady {}
        function Get-SqlCmdPath { 'Invoke-FakeSqlCmd' }
        function Get-Command { param($Name, $CommandType, $ErrorAction) @{ Source = 'Invoke-FakeSqlCmd' } }
        function Get-SqlCallerName { 'JS-SQL-01\Administrator' }
        function Invoke-FakeSqlCmd {
            param($S, [switch]$E, [switch]$b, [switch]$C, $l, $t, $h, [switch]$W, $Q)
            if ($S -ne 'localhost' -or -not $E -or -not $b -or -not $C -or $l -ne 15 -or $t -ne 30) {
                throw 'Local integrated bounded query with explicit lab certificate trust required.'
            }
            foreach ($term in @('IS_SRVROLEMEMBER', 'IsIntegratedSecurityOnly', 'ProductMajorVersion', 'EditionID', '-2117995310', 'SELECT 1')) {
                if (-not $Q.Contains($term)) { throw "Missing readiness condition: $term" }
            }
            $global:LASTEXITCODE = $script:queryCode
            '1'
        }
        $script:queryCode = 0
        Assert-Equal (Test-SqlReady) $true 'Live CLI readiness'
        $script:queryCode = 1
        Assert-Throws { Test-SqlReady } 'integrated SQL readiness failed'
    } finally { $env:COMPUTERNAME = $saved }
}

# Media provenance, published pins and signature behavior remain unchanged.
$source = 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso'
$media = @(Get-SqlMediaDefinition $source)
Assert-Equal $media[0].Size 1265688576 'Published ISO size'
Assert-Equal $media[0].Sha256 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851' 'Published ISO hash'
Assert-Equal (Get-SqlMediaCacheAction $source $null $false) 'Initialize' 'Bind empty cache'
Assert-Equal (Get-SqlMediaCacheAction $source @{ Source = $source } $true) 'Reuse' 'Reuse bound cache'
Assert-Throws { Get-SqlMediaCacheAction "$source?new" @{ Source = $source } $true } 'source URI changed'
Assert-Throws { Get-SqlMediaCacheAction $source $null $true } 'provenance cannot be established'
foreach ($invalid in @($source.Replace('EntDev', 'StdDev'), $source.Replace('2025', '2022'), 'https://aka.ms/bootstrap.exe')) {
    Assert-Throws { Get-SqlMediaDefinition $invalid } 'verified direct SQL2025 Enterprise Developer'
}
foreach ($invalid in @('http://download.microsoft.com/file.exe', 'https://example.com/file.exe', 'https://user@download.microsoft.com/file.exe')) {
    Assert-Throws { Get-MicrosoftPackage $invalid fake.exe fake.exe } 'official Microsoft HTTPS'
}
& {
    function Get-Item { param($Path) @{ Length = 1265688576 } }
    function Get-FileHash { param($Path, $Algorithm) @{ Hash = $media[0].Sha256 } }
    function Assert-MicrosoftSignature { param($Path) $script:signatures++ }
    $script:signatures = 0
    Assert-DownloadedPackage media.iso $media[0].Sha256 $media[0].Size
    Assert-Throws { Assert-DownloadedPackage media.iso } 'published SHA256 and size'
    Assert-Throws { Assert-DownloadedPackage media.iso wrong 1265688576 } 'hash mismatch'
    Assert-Throws { Assert-DownloadedPackage media.iso $media[0].Sha256 1 } 'Unexpected media length'
    Assert-DownloadedPackage tools.msi
    Assert-Equal $script:signatures 1 'Small installers retain Microsoft signature validation'
}
& {
    $script:hasReceipt = $false; $script:receipts = 0
    function Test-Path { param($Path) if ($Path.EndsWith('.json')) { $script:hasReceipt } else { $true } }
    function Get-Content { param($Path, [switch]$Raw) @{ Source = $source; Hash = $media[0].Sha256 } | ConvertTo-Json }
    function Get-FileHash { param($Path, $Algorithm) @{ Hash = $media[0].Sha256 } }
    function Get-Item { param($Path) @{ Length = $media[0].Size } }
    function Receive-MicrosoftDownload { throw 'Verified media must not download again.' }
    function Set-Content { param($Path, $Encoding, [Parameter(ValueFromPipeline)]$Value) process { $script:receipts++ } }
    Get-MicrosoftPackage $source media.iso $media[0].Name $media[0].Sha256 $media[0].Size
    Assert-Equal $script:receipts 1 'Recover interrupted receipt after published-pin validation'
    $script:hasReceipt = $true
    Get-MicrosoftPackage $source media.iso $media[0].Name $media[0].Sha256 $media[0].Size
    Assert-Equal $script:receipts 1 'Reuse valid cache without rewriting'
}

$downloadText = Get-FunctionText $ast Receive-MicrosoftDownload
foreach ($text in @('GetResponseStream()', 'New-Object byte[] 65536', '$inputStream.Read(', '$outputStream.Write(',
    'AllowAutoRedirect = $false', '$request.Timeout', '$request.ReadWriteTimeout', '$inputStream.ReadTimeout')) {
    if (-not $downloadText.Contains($text)) { throw "Missing streaming contract: $text" }
}
if ((Parse-Script $downloadText).Find({
    param($n)
    ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest') -or
    ($n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member.Value -eq 'Content')
}, $true)) { throw 'HTTP response body must never be buffered.' }
& {
    $streamPath = Join-Path (Get-Location) ('.stage45-stream-' + [guid]::NewGuid().ToString('N') + '.bin')
    $script:bytes = New-Object byte[] 65543
    $script:bytes[65542] = 123
    $script:finalUri = 'https://download.microsoft.com/test/media.iso'
    $script:declared = 65543; $script:status = 200; $script:location = ''; $script:requests = 0
    function New-MicrosoftDownloadRequest {
        param($Uri)
        $script:requests++
        $r = [pscustomobject]@{ AllowAutoRedirect = $true; Timeout = 0; ReadWriteTimeout = 0 }
        $r | Add-Member ScriptMethod GetResponse {
            if ($this.AllowAutoRedirect -or $this.Timeout -le 0 -or $this.ReadWriteTimeout -le 0) { throw 'Unbounded HTTP request.' }
            $response = [pscustomobject]@{ ResponseUri = [uri]$script:finalUri; ContentLength = $script:declared; StatusCode = $script:status; Headers = @{ Location = $script:location } }
            $response | Add-Member ScriptMethod GetResponseStream { [IO.MemoryStream]::new($script:bytes, $false) }
            $response | Add-Member ScriptMethod Dispose {}
            $response
        }
        $r | Add-Member ScriptMethod Abort {}
        $r
    }
    try {
        Receive-MicrosoftDownload $script:finalUri $streamPath media.iso 65543 10
        $actual = [IO.File]::ReadAllBytes($streamPath)
        Assert-Equal $actual.Length 65543 'Preserve streamed chunks'
        Assert-Equal $actual[65542] 123 'Preserve final short chunk'
        $script:declared = 65544
        Assert-Throws { Receive-MicrosoftDownload $script:finalUri $streamPath media.iso 65543 10 } 'Unexpected HTTP media length'
        Assert-Throws { Receive-MicrosoftDownload $script:finalUri $streamPath media.iso 0 10 } 'Incomplete HTTP download'
        $script:declared = -1
        Assert-Throws { Receive-MicrosoftDownload $script:finalUri $streamPath media.iso 4 10 } 'exceeded size limit'
        $script:finalUri = 'https://download.microsoft.com/wrong.iso'
        Assert-Throws { Receive-MicrosoftDownload $script:finalUri $streamPath media.iso 65543 10 } 'Unexpected download destination'
        $script:status = 302
        foreach ($uri in @('http://download.microsoft.com/media.iso', 'https://example.com/media.iso', 'https://user@download.microsoft.com/media.iso', 'https://download.microsoft.com:8443/media.iso')) {
            $script:location = $uri; $script:requests = 0
            Assert-Throws { Receive-MicrosoftDownload 'https://aka.ms/media' $streamPath media.iso 65543 10 } 'official Microsoft HTTPS'
            Assert-Equal $script:requests 1 'Never contact forbidden redirect'
        }
        $script:location = 'https://aka.ms/media'
        Assert-Throws { Receive-MicrosoftDownload 'https://aka.ms/media' $streamPath media.iso 65543 10 } 'redirect limit'
        Assert-Throws { Receive-MicrosoftDownload 'https://aka.ms/media' $streamPath media.iso 65543 0 } 'deadline exceeded'
    } finally { Remove-Item $streamPath -Force -ErrorAction SilentlyContinue }
}

# Exercise guest orchestration; only the external engine-file call is replaced
# with a mock. Its exact real invocation is asserted above.
& {
    $guestTry = $installAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }
    $code = [scriptblock]::Create($guestTry.Extent.Text.Replace('& "$work\45-install-sql-engine.ps1" -PassThru', 'Invoke-FakeEngine'))
    $work = 'C:\ArcJumpstart\Sql2025'; $logs = 'logs'
    $guestLock = [pscustomobject]@{}
    $guestLock | Add-Member ScriptMethod Dispose {}
    $script:guestDeadlineUtc = [DateTime]::UtcNow.AddHours(1)
    function Get-Content { param($Path, [switch]$Raw) '{"Files":[{"Name":"media.iso","Hash":"valid"}]}' }
    function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
    function Get-FileHash { param($Path, $Algorithm) @{ Hash = $script:transferHash } }
    function Get-Service { param($Name, $ErrorAction) @{ Status = 'Running' } }
    function Get-Process { param($Name, $ErrorAction) }
    function Invoke-FakeEngine {
        $script:engineInvocations++
        if ($script:engineFailure) { throw 'engine error 1603' }
        @{ Status = $script:engineStatus; SetupExitCode = $script:setupExitCode }
    }
    function Test-Path { param($Path) $false }
    function Get-SqlCmdPath { if ($script:cliPresent) { 'sqlcmd.exe' } }
    function Start-Process { throw 'No separate native installer is permitted in guest orchestration.' }
    function Set-SqlCmdMachinePath { param($SqlCmdPath) $script:pathRefreshes++ }
    function Wait-SqlReady { $script:readinessCalls++; $true }
    function Set-Content {
        param($Path, $Encoding, [Parameter(ValueFromPipeline)]$Value)
        process { if ($script:saveFailure) { throw 'cannot save result' } }
    }
    function Write-Warning { param($Message, $WarningAction) }
    function Reset-GuestScenario {
        $script:transferHash = 'valid'; $script:engineStatus = 'VerifiedExisting'; $script:setupExitCode = 0
        $script:engineFailure = $false; $script:engineInvocations = 0
        $script:cliPresent = $true
        $script:pathRefreshes = 0; $script:readinessCalls = 0; $script:saveFailure = $false
    }
    Reset-GuestScenario
    $result = [ordered]@{ Status = 'Running'; Engine = $null; Error = '' }
    $out = & $code
    Assert-Equal $out.Status 'Verified' 'Healthy engine and bundled CLI are verified without installation'
    Assert-Equal $script:pathRefreshes 1 'Refresh PATH without a reboot'
    Assert-Equal $script:readinessCalls 1 'Readiness remains mandatory'
    Reset-GuestScenario
    $script:cliPresent = $false
    Assert-Throws { & $code } 'SQL Setup did not supply bundled sqlcmd 17'
    Assert-Equal $script:readinessCalls 0 'Missing bundled CLI cannot be accepted or replaced'
    Reset-GuestScenario
    $script:engineStatus = 'RebootRequired'; $script:setupExitCode = 3010
    $out = & $code
    Assert-Equal $out.Status 'RebootRequired' 'Engine3010 returns only after setup completed'
    Assert-Equal $script:readinessCalls 0 'Readiness follows reboot, never precedes it'
    Reset-GuestScenario
    $script:cliPresent = $false; $script:saveFailure = $true
    Assert-Throws { & $code } 'SQL Setup did not supply bundled sqlcmd 17'
    Reset-GuestScenario
    $script:engineFailure = $true
    Assert-Throws { & $code } 'engine error 1603'
    Assert-Equal $script:readinessCalls 0 'No readiness after engine failure'
    Reset-GuestScenario
    $script:transferHash = 'corrupt'
    Assert-Throws { & $code } 'Transferred media hash mismatch'
    Assert-Equal $script:engineInvocations 0 'No engine invocation with corrupt payload'
    $script:guestDeadlineUtc = $null
}

# Reboots happen after synchronous completion, never for a PATH refresh.
& {
    $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString dummy -AsPlainText -Force))
    $RunId = 'test'; $script:payload = @('cached.iso')
    function Wait-SqlGuest { param($VMName, $PreviousBoot) 'boot' }
    function Invoke-SqlGuest { param($VMName, $ScriptBlock) if ($ScriptBlock.ToString().Contains('shutdown.exe')) { $script:reboots++ } }
    function Copy-SqlPayload { param($VMName, $Files) }
    function New-PSSession { param($VMName, $Credential, $ErrorAction) 'session' }
    function Remove-PSSession { param($Session, $ErrorAction) $script:closed++ }
    function Write-StageLog { param($Message) }
    function Invoke-Command {
        param($Session, $ScriptBlock, $ArgumentList, $ErrorAction)
        Assert-Equal $Session 'session' 'Use held session'
        if ($script:invokeFailure) { throw 'native failure 1603' }
        @{ Status = $script:statuses.Dequeue() }
    }
    $script:reboots = 0; $script:closed = 0; $script:invokeFailure = $false
    $script:statuses = [Collections.Generic.Queue[string]]::new()
    $script:statuses.Enqueue('Verified')
    Complete-SqlGuest JS-SQL-01
    Assert-Equal $script:reboots 0 'Healthy verification does not reboot'
    Assert-Equal $script:closed 1 'Release session only after return'
    $script:statuses.Enqueue('RebootRequired'); $script:statuses.Enqueue('Verified')
    Complete-SqlGuest JS-SQL-01
    Assert-Equal $script:reboots 1 '3010 triggers one reconnect and verification'
    $script:invokeFailure = $true
    Assert-Throws { Complete-SqlGuest JS-SQL-01 } 'native failure 1603'
    Assert-Equal $script:reboots 1 'Never reboot on native failure'
    $script:phaseDeadlineUtc = $null
}
& {
    $hostTry = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] }
    $code = [scriptblock]::Create("[CmdletBinding()]`n" + $ast.ParamBlock.Extent.Text +
        "`ntry { throw [InvalidOperationException]::new('original secret-value') }`n" +
        $hostTry.CatchClauses[0].Extent.Text + "`nfinally " + $hostTry.Finally.Extent.Text)
    . ([scriptblock]::Create((Get-FunctionText $ast Write-StageLog)))
    $logRoot = '.'; $logFile = 'unused'; $lock = [pscustomobject]@{}
    $lock | Add-Member ScriptMethod Dispose { throw 'cleanup failure' }
    function Test-Path { param($Path) $true }
    function Write-Host { param($Object) }
    function Add-Content {
        param($Path, $Value)
        if ($script:failLogging) { throw 'logging failure' }
        $script:failureLog = $Value
    }
    $inputs = @{ NestedWindowsPassword = 'secret-value'; SqlDownloadUrl = 'unused'; RunId = 'test'; EngineScriptBase64 = 'unused' }
    $script:failLogging = $false
    Assert-Throws { & $code @inputs } 'original secret-value'
    if ($script:failureLog.Contains('secret-value') -or -not $script:failureLog.Contains('System.InvalidOperationException') -or
        -not $script:failureLog.Contains('ScriptStackTrace:')) { throw 'Missing sanitized failure diagnostics.' }
    $script:failLogging = $true
    Assert-Throws { & $code @inputs } 'original secret-value'
}
# Installer workers must never use the stoppable probe/copy wait helper.
$parallelAst = Parse-Script (Get-FunctionText $ast Invoke-ParallelSqlGuests)
foreach ($tree in @($parallelAst, $workerAst)) {
    if ($tree.Find({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('Stop-Job', 'Wait-BoundedJob', 'Remove-PSSession')
    }, $true)) { throw 'Coordinator must drain installer workers, not stop or close their sessions.' }
}
if ($heldText.Contains('Get-SqlPayload')) { throw 'Guest workers must not race on shared cache preparation.' }
& {
    $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString dummy -AsPlainText -Force))
    $RunId = 'parallel-test'; $logRoot = '.'
    function Get-VM { param($Name, $ErrorAction) @{ State = 'Running' } }
    function Get-SqlPayload {
        $script:payloadCalls++
        $script:events += 'payload'
        if (-not $script:phaseDeadlineUtc) { throw 'Shared download must retain its bounded phase.' }
        'cached.iso'
    }
    function Start-Job {
        param($Name, $ScriptBlock, [object[]]$ArgumentList, $ErrorAction)
        $context = $ArgumentList[0]
        $script:events += "start:$($context.VMName)"
        $script:starts++
        Assert-Equal $script:payloadCalls 1 'Prepare shared payload exactly once before any worker'
        Assert-Equal $script:phaseDeadlineUtc $null 'Workers must not inherit the media phase'
        Assert-Equal ($context.Payload -join ',') 'cached.iso' 'Pass immutable shared payload paths'
        if ($context.Credential -isnot [pscredential]) { throw 'Pass credential objects, never plain passwords.' }
        if (-not $context.Definitions.Contains('function Complete-SqlGuest')) { throw 'Reuse existing function definitions.' }
        if ($script:launchFailure -eq $context.VMName) { throw 'worker launch failure' }
        $job = [pscustomobject]@{ Name = $context.VMName; State = 'Running' }
        $script:jobs += $job
        $script:peak = [Math]::Max($script:peak, @($script:jobs | Where-Object State -eq 'Running').Count)
        $job
    }
    function Wait-Job {
        param($Job, $Timeout, [switch]$Force, $ErrorAction)
        Assert-Equal $script:starts $script:expectedStarts 'Attempt all selected workers before waiting'
        $script:events += "wait:$($Job.Name)"
        if ($script:waitFailure) { $script:waitFailure = $false; throw 'transient wait failure' }
        $Job.State = if ($script:processFailure -eq $Job.Name) { 'Failed' } else { 'Completed' }
        $Job
    }
    function Receive-Job {
        param($Job, $ErrorAction)
        $script:events += "receive:$($Job.Name)"
        if ($Job.State -eq 'Running') { throw 'Never receive before worker completion.' }
        if ($script:processFailure -eq $Job.Name) { throw 'worker process failed' }
        [pscustomobject]@{
            VMName = $Job.Name
            Status = if ($Job.Name -eq $script:guestFailure) { 'Failed' } else { 'Verified' }
            Error = if ($Job.Name -eq $script:guestFailure) { 'native1603' } else { '' }
            LogFile = "$($Job.Name).log"
        }
    }
    function Remove-Job {
        param($Job, [switch]$Force, $ErrorAction)
        if ($Force -or $Job.State -eq 'Running') { throw 'Do not force-remove active installer workers.' }
        $script:events += "remove:$($Job.Name)"
        $script:removed++
        if ($Job.Name -eq $script:cleanupFailure) { throw 'worker cleanup failure' }
    }
    function Stop-Job { throw 'Never stop an installer worker.' }
    function Start-Sleep { param($Seconds) }
    function Write-StageLog { param($Message) }
    function Reset-ParallelScenario {
        $script:payloadCalls = 0; $script:starts = 0; $script:expectedStarts = 3
        $script:events = @(); $script:jobs = @(); $script:removed = 0; $script:peak = 0
        $script:guestFailure = ''; $script:launchFailure = ''; $script:processFailure = ''; $script:cleanupFailure = ''; $script:waitFailure = $false
    }
    $all = @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')
    Reset-ParallelScenario
    Invoke-ParallelSqlGuests $all
    Assert-Equal ($script:events[0..3] -join ',') 'payload,start:JS-SQL-01,start:JS-SQL-AG-01,start:JS-SQL-AG-02' 'Download then launch all before waiting'
    Assert-Equal $script:peak 3 'Default concurrency is three, never more'
    Assert-Equal $script:removed 3 'Drain and remove every completed worker'
    foreach ($selection in @(@('JS-SQL-01'), @('JS-SQL-AG-02', 'JS-SQL-01'))) {
        Reset-ParallelScenario
        $script:expectedStarts = $selection.Count
        Invoke-ParallelSqlGuests $selection
        Assert-Equal (($script:jobs | ForEach-Object Name) -join ',') ($selection -join ',') 'Only selected guests start'
        Assert-Equal $script:peak $selection.Count 'Selection bounds concurrency'
    }
    Assert-Throws { Invoke-ParallelSqlGuests @($all + 'JS-SQL-01') } 'Names'
    Assert-Throws { Invoke-ParallelSqlGuests @() } 'Names'
    Assert-Throws { Invoke-ParallelSqlGuests JS-SQL-01,js-sql-01 } 'Duplicate SQL guest'
    foreach ($failureKind in @('guestFailure', 'launchFailure', 'processFailure', 'waitFailure', 'cleanupFailure')) {
        Reset-ParallelScenario
        if ($failureKind -eq 'waitFailure') { $script:waitFailure = $true }
        else { Set-Variable -Scope Script -Name $failureKind -Value 'JS-SQL-01' }
        Assert-Throws { Invoke-ParallelSqlGuests $all } 'after all started workers finished'
        Assert-Equal $script:starts 3 'One failed guest/launch must not prevent other starts'
        Assert-Equal @($script:jobs | Where-Object State -eq 'Running').Count 0 'All started siblings finish before aggregated failure'
        Assert-Equal $script:removed $script:jobs.Count 'All started workers are collected on failure'
        if ($script:events -notcontains 'receive:JS-SQL-AG-02') { throw 'Final sibling must be collected despite earlier failure.' }
    }
}

# Run the real worker wrapper in three local PowerShell jobs with mock Windows
# boundaries. This exercises process isolation and PSCredential serialization.
& {
    $definitions = @'
function Import-Module { param($Name, $ErrorAction) }
function Write-StageLog { param($Message) }
function Complete-SqlGuest {
    param($VMName)
    if ($script:phaseDeadlineUtc) { throw 'A worker inherited another phase.' }
    if ($script:payload.Count -ne 1 -or $script:payload[0] -ne 'shared.iso') { throw 'Missing shared payload.' }
    $script:phaseDeadlineUtc = $VMName
    Start-Sleep -Milliseconds 150
    if ($script:phaseDeadlineUtc -ne $VMName) { throw 'Guest phase state leaked between workers.' }
    if ($VMName -eq 'JS-SQL-AG-01') { throw 'failure containing secret-value' }
}
function Export-SqlGuestLogs { param($VMName) }
'@
    $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'secret-value' -AsPlainText -Force))
    $jobs = @()
    try {
        foreach ($name in @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')) {
            $context = [pscustomobject]@{
                VMName = $name; Credential = $credential; Definitions = $definitions; Payload = @('shared.iso')
                GuestInstall = ''; LogRoot = (Get-Location).Path; RunId = 'isolation-test'
                DeadlineUtc = [DateTime]::UtcNow.AddMinutes(68).ToString('o')
            }
            $jobs += Start-Job -ScriptBlock ([scriptblock]::Create($sqlGuestWorker)) -ArgumentList $context
        }
        Wait-Job -Job $jobs | Out-Null
        $records = @(Receive-Job -Job $jobs -ErrorAction Stop)
        Assert-Equal $records.Count 3 'Each worker returns one structured result'
        Assert-Equal @($records | Where-Object Status -eq 'Verified').Count 2 'Sibling failure must not affect healthy workers'
        $failed = $records | Where-Object Status -eq 'Failed'
        Assert-Equal $failed.VMName 'JS-SQL-AG-01' 'Failure attributed to the correct guest'
        if ($failed.Error.Contains('secret-value') -or -not $failed.Error.Contains('[REDACTED]')) { throw 'Worker error must redact credentials before serialization.' }
        Assert-Equal @($records.LogFile | Sort-Object -Unique).Count 3 'Each guest owns a distinct host log'
        foreach ($record in $records) {
            if ($record.LogFile -notlike "*-$($record.VMName).log") { throw 'Guest log ownership is ambiguous.' }
        }
    }
    finally {
        foreach ($job in $jobs) {
            Wait-Job -Job $job | Out-Null
            Remove-Job -Job $job
        }
    }
}
Write-Host 'Stage 45 regression checks passed.'
