<#
.SYNOPSIS
Installs SQL Server 2025 Enterprise Developer on the plain Windows SQL guests.
.DESCRIPTION
Run as SYSTEM on the Hyper-V host, after stage 40 and before stage 50.
VmNames defaults to all three SQL guests. For a one-guest smoke test, pass
-VmNames JS-SQL-01 through a separate managed command such as smoke-sql-install.
The canonical stage45 invocation must omit the selector (or select all three)
before downstream stages proceed. Up to three selected guests run concurrently.
Developer is licensed for development/test ONLY. Running this stage accepts the
SQL Server, Microsoft ODBC, command-line utilities and VC++ license terms:
https://aka.ms/useterms
https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt
https://learn.microsoft.com/sql/connect/odbc/windows/system-requirements-installation-and-driver-files
https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-download-install

SqlDownloadUrl is the verified Enterprise Developer ISO, NOT a bootstrapper:
https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso
Its URL, length and SHA256 are published in the signed SQL2025-SSEI-EntDev.exe
manifest, reached from the official downloads page's Enterprise Developer link
https://go.microsoft.com/fwlink/?linkid=2344711 . The ISO returned HTTP 200 on
2026-09-16. No bootstrapper is executed, patched or given a version-check bypass.
Standard Developer, Evaluation, generic media and other major versions are
rejected. No PID override is used. setup.exe runs ONLY inside SQL guests.
Windows Server 2022 is supported; SQL 2025 requires .NET Framework 4.7.2.
SQL Setup supplies its drivers, runtime and sqlcmd 17 under Client SDK\ODBC\180.
No separate CLI, ODBC or VC++ installers are downloaded or executed.
https://learn.microsoft.com/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2025
https://learn.microsoft.com/sql/connect/odbc/windows/system-requirements-installation-and-driver-files
The localhost readiness probe uses -C to trust the lab's self-signed SQL
certificate without disabling connection encryption. This is lab-only.

Host cache: F:\ArcJumpstart\Sql2025. Guest work: C:\ArcJumpstart\Sql2025.
Previous-version caches/tasks are left untouched; existing engines are never
upgraded or replaced automatically.
Logs: C:\ArcJumpstart\Logs on both machines, including copied SQL Setup logs.
No password is written into a script, task, configuration file or transcript.
The password MUST be supplied as a protected RunCommand parameter, not public
settings. Use the existing 14400-second managed RunCommand timeout. This stage
has a 235-minute overall deadline, a 25-minute shared media phase and an isolated
68-minute budget per concurrent guest (including copying, reboots and readiness).
EngineScriptBase64 is the UTF-8 engine script embedded by the stage Bicep.
Installation holds a PowerShell Direct session until Start-Process -Wait
returns inside each host worker; there are no guest scheduled tasks. Admission
checks reserve 45 minutes for setup. These
are admission budgets, not forced process timeouts: an active installer is
never stopped to meet a deadline. An unusually hung installer can outlive the
managed command's four-hour cap and requires operator diagnosis.
All started host workers are drained, even after a sibling fails. Installer
workers are never force-stopped; the host cache lock is held until they finish.
Only the three SQL guests may be rebooted.
Failed/partial installs require operator diagnosis or stage-40 guest rebuild;
this stage never repairs, upgrades, uninstalls or overwrites an existing engine.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlDownloadUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$')]
    [string]$RunId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$EngineScriptBase64,

    [ValidateNotNullOrEmpty()]
    [ValidateCount(1, 3)]
    [ValidateSet('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')]
    [string[]]$VmNames = @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')
)

$ErrorActionPreference = 'Stop'
if (@($VmNames | Sort-Object -Unique).Count -ne $VmNames.Count) {
    throw 'VmNames must not contain duplicate guest names (case-insensitive).'
}
$ProgressPreference = 'SilentlyContinue'
$script:stageDeadlineUtc = [DateTime]::UtcNow.AddMinutes(235)
$script:phaseDeadlineUtc = $null

function Get-BudgetSeconds {
    param([int]$RequestedSeconds, [string]$Operation)
    $seconds = $RequestedSeconds
    foreach ($deadline in @($script:stageDeadlineUtc, $script:phaseDeadlineUtc)) {
        if ($deadline) {
            $seconds = [Math]::Min($seconds, [Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds))
        }
    }
    if ($seconds -lt 1) { throw "Execution budget exhausted: $Operation. Guest state/logs are preserved; do not automatically reinstall." }
    return [int]$seconds
}

function Wait-BoundedJob {
    param($Job, [int]$TimeoutSeconds, [string]$Operation)
    try {
        $TimeoutSeconds = Get-BudgetSeconds $TimeoutSeconds $Operation
        if (-not (Wait-Job -Job $Job -Timeout $TimeoutSeconds)) {
            throw "Timed out: $Operation. No installer is run in this bounded job."
        }
        Receive-Job -Job $Job -ErrorAction Stop
        if ($Job.State -ne 'Completed') { throw "Failed: $Operation ($($Job.State))." }
    }
    finally {
        if ($Job.State -in @('Running', 'NotStarted', 'Blocked')) { Stop-Job -Job $Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SqlGuest {
    param([string]$VMName, [scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSeconds = 120)
    $guestCredential = [pscredential]::new("$VMName\Administrator", $credential.Password)
    $job = Start-Job -ArgumentList $VMName, $guestCredential, $ScriptBlock.ToString(), $ArgumentList -ScriptBlock {
        param($Name, $Credential, $Code, $Arguments)
        $ErrorActionPreference = 'Stop'
        Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock ([scriptblock]::Create($Code)) -ArgumentList $Arguments
    }
    Wait-BoundedJob -Job $job -TimeoutSeconds $TimeoutSeconds -Operation "PowerShell Direct on $VMName"
}

function Wait-SqlGuest {
    param([string]$VMName, [string]$PreviousBoot = '', [int]$TimeoutSeconds = 240)
    $deadline = [DateTime]::UtcNow.AddSeconds((Get-BudgetSeconds $TimeoutSeconds "guest readiness on $VMName"))
    do {
        try {
            $boot = Invoke-SqlGuest -VMName $VMName -TimeoutSeconds 30 -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            }
            if ($boot -and $boot -ne $PreviousBoot) { return $boot }
        }
        catch { $lastFailure = $_.Exception.Message }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for local Administrator PowerShell Direct on $VMName. $lastFailure"
}

function Assert-MicrosoftSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Invalid Microsoft signature: $Path"
    }
}

function Assert-DownloadedPackage {
    param([string]$Path, [string]$ExpectedSha256 = '', [long]$ExpectedSize = 0)
    if ($ExpectedSize -and (Get-Item $Path).Length -ne $ExpectedSize) { throw "Unexpected media length: $Path" }
    if ($ExpectedSha256 -and (Get-FileHash $Path -Algorithm SHA256).Hash -ine $ExpectedSha256) {
        throw "Microsoft published media hash mismatch: $Path"
    }
    if ([IO.Path]::GetExtension($Path) -ieq '.iso') {
        if (-not $ExpectedSha256 -or -not $ExpectedSize) { throw 'ISO media requires a published SHA256 and size.' }
    }
    else { Assert-MicrosoftSignature $Path }
}

function Assert-MicrosoftDownloadUri {
    param([uri]$Source)
    if ($Source.Scheme -ne 'https' -or $Source.UserInfo -or -not $Source.IsDefaultPort -or
        $Source.Host -notin @('go.microsoft.com', 'aka.ms', 'download.microsoft.com', 'download.visualstudio.microsoft.com')) {
        throw 'Downloads must use an official Microsoft HTTPS source without credentials.'
    }
}

function New-MicrosoftDownloadRequest {
    param([uri]$Uri)
    [Net.HttpWebRequest]::Create($Uri)
}

function Receive-MicrosoftDownload {
    param([string]$Uri, [string]$Path, [string]$ExpectedFileName,
        [long]$ExpectedSize, [int]$TimeoutSeconds)
    # HttpWebRequest streams on Windows PowerShell 5.1. Invoke-WebRequest's
    # -PassThru can buffer the entire ISO despite -OutFile.
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $current = [uri]$Uri
    $maximumSize = if ($ExpectedSize -gt 0) { $ExpectedSize } else { 512MB }
    for ($redirects = 0; $redirects -le 10; $redirects++) {
        $request = $null
        $response = $null
        $inputStream = $null
        $outputStream = $null
        try {
            Assert-MicrosoftDownloadUri $current
            $remaining = [Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -lt 1) { throw 'HTTP download deadline exceeded.' }
            $request = New-MicrosoftDownloadRequest $current
            $request.AllowAutoRedirect = $false
            $request.Timeout = [int][Math]::Min($remaining, 30000)
            $request.ReadWriteTimeout = [int][Math]::Min($remaining, 30000)
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                if (-not $response.Headers['Location']) { throw 'HTTP redirect has no destination.' }
                $current = [uri]::new($current, $response.Headers['Location'])
                continue
            }
            $final = $response.ResponseUri
            Assert-MicrosoftDownloadUri $final
            if ([int]$response.StatusCode -ne 200 -or
                $final.Host -notin @('download.microsoft.com', 'download.visualstudio.microsoft.com') -or
                [uri]::UnescapeDataString($final.Segments[-1]) -ine $ExpectedFileName) {
                throw "Unexpected download destination/status for $ExpectedFileName."
            }
            $declaredSize = [long]$response.ContentLength
            if ($declaredSize -gt $maximumSize -or
                ($ExpectedSize -gt 0 -and $declaredSize -ge 0 -and $declaredSize -ne $ExpectedSize)) {
                throw "Unexpected HTTP media length for $ExpectedFileName."
            }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Open($Path, 'Create', 'Write', 'None')
            $buffer = New-Object byte[] 65536
            $received = [long]0
            while ($true) {
                $remaining = [Math]::Floor(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($remaining -lt 1) { throw 'HTTP download deadline exceeded.' }
                if ($inputStream.CanTimeout) { $inputStream.ReadTimeout = [int][Math]::Min($remaining, 30000) }
                $count = $inputStream.Read($buffer, 0, $buffer.Length)
                if ($count -eq 0) { break }
                $received += $count
                if ($received -gt $maximumSize) { throw "HTTP download exceeded size limit for $ExpectedFileName." }
                $outputStream.Write($buffer, 0, $count)
            }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'HTTP download deadline exceeded.' }
            if ($received -eq 0 -or ($declaredSize -ge 0 -and $received -ne $declaredSize) -or
                ($ExpectedSize -gt 0 -and $received -ne $ExpectedSize)) {
                throw "Incomplete HTTP download for $ExpectedFileName."
            }
            $outputStream.Flush()
            return
        }
        finally {
            foreach ($resource in @($outputStream, $inputStream, $response)) {
                if ($resource) { try { $resource.Dispose() } catch { } }
            }
            if ($request) { try { $request.Abort() } catch { } }
        }
    }
    throw 'HTTP download exceeded the redirect limit.'
}

function Get-MicrosoftPackage {
    param([string]$Uri, [string]$Path, [string]$ExpectedFileName,
        [string]$ExpectedSha256 = '', [long]$ExpectedSize = 0, [int]$DownloadTimeoutSeconds = 90)
    $source = [uri]$Uri
    Assert-MicrosoftDownloadUri $source
    $receiptPath = "$Path.json"
    if ((Test-Path $Path) -and (Test-Path $receiptPath)) {
        $receipt = Get-Content $receiptPath -Raw | ConvertFrom-Json
        if ($receipt.Source -ceq $Uri -and $receipt.Hash -eq (Get-FileHash $Path -Algorithm SHA256).Hash) {
            Assert-DownloadedPackage $Path $ExpectedSha256 $ExpectedSize
            return
        }
        throw "Cache mismatch: $Path. Inspect/remove this package and its receipt before retrying."
    }
    if ((Test-Path $Path) -and $ExpectedSha256 -and $ExpectedSize) {
        # Published media pins, not a filename or an incomplete receipt, allow
        # recovery after interruption between the download and receipt write.
        Assert-DownloadedPackage $Path $ExpectedSha256 $ExpectedSize
        @{ Source = $Uri; Hash = (Get-FileHash $Path -Algorithm SHA256).Hash } |
            ConvertTo-Json | Set-Content $receiptPath -Encoding UTF8
        return
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $timeout = Get-BudgetSeconds $DownloadTimeoutSeconds "downloading $ExpectedFileName"
            Receive-MicrosoftDownload -Uri $Uri -Path "$Path.partial" -ExpectedFileName $ExpectedFileName `
                -ExpectedSize $ExpectedSize -TimeoutSeconds $timeout
            Move-Item "$Path.partial" $Path -Force
            Assert-DownloadedPackage $Path $ExpectedSha256 $ExpectedSize
            @{ Source = $Uri; Hash = (Get-FileHash $Path -Algorithm SHA256).Hash } |
                ConvertTo-Json | Set-Content $receiptPath -Encoding UTF8
            return
        }
        catch {
            if ($attempt -eq 2) { throw }
            Start-Sleep -Seconds 10
        }
    }
}

# Shared only with the guest runner/probes; defining it does not execute guest code.
$guestLibrary = @'
function Assert-SqlGuestIdentity {
    if ($env:COMPUTERNAME -notin @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')) {
        throw 'SQL installation is permitted only inside the three SQL guests, never on the Hyper-V host.'
    }
}

function Get-SqlCmdPath {
    $path = "$env:ProgramFiles\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE"
    if (Test-Path $path) {
        if ((Get-Item $path).VersionInfo.ProductMajorPart -ne 17) {
            throw "Unexpected sqlcmd generation at $path; expected SQL Server 2025 bundled sqlcmd 17."
        }
        return $path
    }
    return $null
}

function Get-SqlCallerName {
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Test-SqlWmiReady {
    $services = @(Get-CimInstance -Namespace 'root\Microsoft\SqlServer\ComputerManagement17' `
        -ClassName SqlService -Filter "ServiceName='MSSQLSERVER'" -OperationTimeoutSec 30 -ErrorAction Stop)
    if ($services.Count -ne 1 -or $services[0].ServiceName -ne 'MSSQLSERVER') {
        throw 'Stage 60 prerequisite failed: native SQL WMI cannot enumerate MSSQLSERVER.'
    }
}

function Set-SqlCmdMachinePath {
    param([string]$SqlCmdPath)
    $bin = Split-Path $SqlCmdPath -Parent
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $rest = @($machinePath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $bin.TrimEnd('\') })
    $newPath = @($bin) + $rest -join ';'
    if ($machinePath -cne $newPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine') }
    $env:Path = $newPath + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Test-SqlReady {
    Assert-SqlGuestIdentity
    if ((Get-Service MSSQLSERVER).Status -ne 'Running') { throw 'MSSQLSERVER is not running.' }
    Test-SqlWmiReady
    $expected = Get-SqlCmdPath
    $command = Get-Command sqlcmd.exe -CommandType Application -ErrorAction Stop
    if (-not $expected -or $command.Source -ine $expected) { throw 'Bundled sqlcmd 17 must resolve from the machine PATH.' }
    $identity = Get-SqlCallerName
    if ($identity -ine "$env:COMPUTERNAME\Administrator") { throw 'Readiness must run as the local VM Administrator, not SYSTEM or a domain account.' }
    # Trust only this lab's local self-signed certificate, matching stages 50/60.
    # EditionID -2117995310 identifies Enterprise Developer in major 17; Standard
    # Developer is -1785266663. EngineEdition 3 alone also includes Evaluation.
    # https://learn.microsoft.com/sql/t-sql/functions/serverproperty-transact-sql
    $query = "SET NOCOUNT ON; IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0) <> 1 THROW 51000, 'Local Administrator is not sysadmin', 1; IF ISNULL(CONVERT(int,SERVERPROPERTY('IsIntegratedSecurityOnly')),0) <> 1 THROW 51000, 'Windows authentication required', 1; IF ISNULL(CONVERT(int,SERVERPROPERTY('ProductMajorVersion')),0) <> 17 OR ISNULL(CONVERT(int,SERVERPROPERTY('EditionID')),0) <> -2117995310 OR ISNULL(CONVERT(int,SERVERPROPERTY('EngineEdition')),0) <> 3 THROW 51000, 'SQL Server 2025 Enterprise Developer required', 1; IF CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')) <> CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) THROW 51000, 'Default instance server name mismatch', 1; SELECT 1;"
    $output = & $expected -S localhost -E -b -C -l 15 -t 30 -h -1 -W -Q $query 2>&1
    if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -ne '1') {
        throw "Local Administrator integrated SQL readiness failed: $($output -join ' ')"
    }
    return $true
}

function Wait-SqlReady {
    param([int]$TimeoutSeconds = 120)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try { return Test-SqlReady }
        catch { $failure = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    throw "SQL did not pass live readiness: $failure"
}

'@

$guestInstall = @'
param([string]$AttemptId, [string]$DeadlineUtc)
$ErrorActionPreference = 'Stop'
$script:guestDeadlineUtc = [DateTime]::Parse($DeadlineUtc).ToUniversalTime()
. 'C:\ArcJumpstart\Sql2025\guest-library.ps1'
Assert-SqlGuestIdentity
$work = 'C:\ArcJumpstart\Sql2025'
$logs = "C:\ArcJumpstart\Logs\45-install-sql\$AttemptId"
New-Item -ItemType Directory $logs -Force | Out-Null
$guestLock = [IO.File]::Open("$work\stage45-session.lock", 'OpenOrCreate', 'ReadWrite', 'None')
$result = [ordered]@{ Status = 'Running'; Logs = $logs; Error = ''; Engine = $null }
try {
    $manifest = Get-Content "$work\payload.json" -Raw | ConvertFrom-Json
    foreach ($file in $manifest.Files) {
        $path = Join-Path $work $file.Name
        if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $file.Hash) { throw "Transferred media hash mismatch: $path" }
    }
    $engineReserve = if (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue) { 120 } else { 2700 }
    if (($script:guestDeadlineUtc - [DateTime]::UtcNow).TotalSeconds -lt $engineReserve) {
        throw 'Guest execution budget exhausted before the synchronous engine invocation.'
    }
    $engine = & "$work\45-install-sql-engine.ps1" -PassThru
    $result.Engine = $engine
    if ($engine.Status -eq 'RebootRequired' -and $engine.SetupExitCode -eq 3010) {
        $result.Status = 'RebootRequired'
        return [pscustomobject]$result
    }
    if ($engine.Status -notin @('InstalledAndVerified', 'VerifiedExisting')) {
        throw "Unexpected engine result: $($engine.Status). Readiness cannot be claimed."
    }
    $cmd = Get-SqlCmdPath
    if (-not $cmd) {
        throw 'SQL Setup did not supply bundled sqlcmd 17 in Client SDK\ODBC\180. Diagnose the installation; no alternate CLI will be installed.'
    }
    Set-SqlCmdMachinePath $cmd
    $null = Wait-SqlReady
    $result.Status = 'Verified'
    [pscustomobject]$result
}
catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
    $result['ExceptionType'] = $_.Exception.GetType().FullName
    $result['ScriptStackTrace'] = $_.ScriptStackTrace
    throw
}
finally {
    $setupLogs = "$env:ProgramFiles\Microsoft SQL Server\170\Setup Bootstrap\Log"
    if (Test-Path $setupLogs) {
        try { Copy-Item $setupLogs "$logs\SetupBootstrap" -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Could not copy setup logs: $($_.Exception.Message)" -WarningAction Continue }
    }
    try { $result | ConvertTo-Json -Depth 6 | Set-Content "$logs\result.json" -Encoding UTF8 }
    catch { Write-Warning "Could not save guest result: $($_.Exception.Message)" -WarningAction Continue }
    try { $guestLock.Dispose() } catch { }
}
'@

function Write-StageLog {
    param([string]$Message)
    $safe = $Message.Replace($NestedWindowsPassword, '[REDACTED]')
    $line = '{0} {1}' -f [DateTime]::UtcNow.ToString('o'), $safe
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

function Get-SqlMediaDefinition {
    param([string]$Source)
    $root = 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU'
    $name = 'SQLServer2025-x64-ENU-EntDev.iso'
    if ($Source -cne "$root/$name") {
        throw "SqlDownloadUrl must be the verified direct SQL2025 Enterprise Developer ISO, not Standard Developer, Evaluation, a bootstrapper, or a different release: $root/$name"
    }
    [pscustomobject]@{
        Name = $name
        Uri = "$root/$name"
        Size = 1265688576
        Sha256 = 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851'
    }
}

function Get-SqlMediaCacheAction {
    param([string]$Source, $Binding, [bool]$HasArtifacts)
    if ($Binding) {
        if ($Binding.Source -cne $Source) {
            throw 'SQL media source URI changed. The existing cache is not reusable; inspect and explicitly clear the SQL cache before changing source.'
        }
        return 'Reuse'
    }
    if ($HasArtifacts) {
        throw 'SQL cache has no source binding; provenance cannot be established. Inspect and explicitly clear this cache rather than adopting existing ISO files.'
    }
    return 'Initialize'
}

function Get-SqlPayload {
    $mediaDefinition = @(Get-SqlMediaDefinition $SqlDownloadUrl)
    $bindingPath = Join-Path $cache 'source.json'
    $binding = if (Test-Path $bindingPath) { Get-Content $bindingPath -Raw | ConvertFrom-Json } else { $null }
    $artifacts = @(Get-ChildItem $cache -Force | Where-Object Name -ne 'stage45.lock')
    $cacheAction = Get-SqlMediaCacheAction $SqlDownloadUrl $binding ($artifacts.Count -gt 0)
    if ($cacheAction -ne 'Reuse') {
        @{ Source = $SqlDownloadUrl; MediaKind = 'EnterpriseDeveloperIso' } | ConvertTo-Json | Set-Content "$bindingPath.new" -Encoding UTF8
        Move-Item "$bindingPath.new" $bindingPath -Force
    }
    $media = Join-Path $cache 'Media'
    New-Item -ItemType Directory $media -Force | Out-Null
    $mediaFiles = @()
    foreach ($file in $mediaDefinition) {
        $path = Join-Path $media $file.Name
        Get-MicrosoftPackage $file.Uri $path $file.Name $file.Sha256 $file.Size 1200
        $mediaFiles += $path
    }
    $files = @($mediaFiles)
    $guestLibrary | Set-Content "$cache\guest-library.ps1" -Encoding UTF8
    $script:engineScript | Set-Content "$cache\45-install-sql-engine.ps1" -Encoding UTF8
    $files += @("$cache\guest-library.ps1", "$cache\45-install-sql-engine.ps1")
    @{
        MediaKind = 'EnterpriseDeveloperIso'
        IsoName = 'SQLServer2025-x64-ENU-EntDev.iso'
        Files = @($files | ForEach-Object { @{ Name = Split-Path $_ -Leaf; Hash = (Get-FileHash $_ -Algorithm SHA256).Hash } })
    } | ConvertTo-Json -Depth 4 | Set-Content "$cache\payload.json" -Encoding UTF8
    return @($files + @("$cache\payload.json"))
}

function Copy-SqlPayload {
    param([string]$VMName, [string[]]$Files)
    $guestCredential = [pscredential]::new("$VMName\Administrator", $credential.Password)
    $job = Start-Job -ArgumentList $VMName, $guestCredential, $Files -ScriptBlock {
        param($Name, $Credential, $Files)
        $ErrorActionPreference = 'Stop'
        $session = $null
        try {
            $session = New-PSSession -VMName $Name -Credential $Credential
            Invoke-Command -Session $session -ScriptBlock {
                New-Item -ItemType Directory 'C:\ArcJumpstart\Sql2025' -Force | Out-Null
                # Only administrators and SYSTEM may modify the guest payload.
                & icacls.exe 'C:\ArcJumpstart\Sql2025' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Could not secure SQL staging directory.' }
            }
            foreach ($file in $Files) {
                $name = Split-Path $file -Leaf
                $hash = (Get-FileHash $file -Algorithm SHA256).Hash
                $same = Invoke-Command -Session $session -ArgumentList $name, $hash -ScriptBlock {
                    param($Name, $Hash)
                    $path = Join-Path 'C:\ArcJumpstart\Sql2025' $Name
                    (Test-Path $path) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $Hash
                }
                if (-not $same) { Copy-Item $file -Destination "C:\ArcJumpstart\Sql2025\$name" -ToSession $session -Force }
            }
        }
        finally { if ($session) { Remove-PSSession $session } }
    }
    Wait-BoundedJob $job 480 "media transfer to $VMName"
}

function Export-SqlGuestLogs {
    param([string]$VMName)
    $destination = Join-Path $logRoot "45-install-sql-$RunId-$VMName"
    $guestCredential = [pscredential]::new("$VMName\Administrator", $credential.Password)
    $job = Start-Job -ArgumentList $VMName, $guestCredential, $destination -ScriptBlock {
        param($Name, $Credential, $Destination)
        $ErrorActionPreference = 'Stop'
        $session = $null
        try {
            $session = New-PSSession -VMName $Name -Credential $Credential
            New-Item -ItemType Directory $Destination -Force | Out-Null
            foreach ($path in @('C:\ArcJumpstart\Logs\45-install-sql', 'C:\ArcJumpstart\Logs\45-sql-engine')) {
                $exists = Invoke-Command -Session $session -ArgumentList $path -ScriptBlock { param($Path) Test-Path $Path }
                if ($exists) { Copy-Item $path -FromSession $session -Destination $Destination -Recurse -Force }
            }
        }
        finally { if ($session) { Remove-PSSession $session } }
    }
    try { Wait-BoundedJob $job 60 "log collection from $VMName" }
    catch {
        try { Write-StageLog "Could not collect $VMName logs; original guest logs are preserved. $($_.Exception.Message)" }
        catch { }
    }
}

function Complete-SqlGuest {
    param([string]$VMName)
    $script:phaseDeadlineUtc = [DateTime]::UtcNow.AddMinutes(68)
    $null = Wait-SqlGuest $VMName
    Invoke-SqlGuest $VMName -ScriptBlock {
        $tasks = @(Get-ScheduledTask -TaskName 'ArcJumpstart-InstallSql*' -ErrorAction SilentlyContinue)
        if (($tasks | Where-Object State -in @('Running', 'Queued')) -or
            (Get-Process -Name setup, ScenarioEngine -ErrorAction SilentlyContinue)) {
            throw 'A legacy SQL task or installer is active. Do not overwrite its payload or start another installation.'
        }
    }
    if (-not $script:payload) { throw 'The coordinator must prepare shared media before starting any guest worker.' }
    Copy-SqlPayload $VMName $script:payload
    for ($reboots = 0; $reboots -le 1; $reboots++) {
        $remaining = Get-BudgetSeconds 4080 "held SQL session on $VMName"
        $deadlineUtc = [DateTime]::UtcNow.AddSeconds($remaining).ToString('o')
        $guestCredential = [pscredential]::new("$VMName\Administrator", $credential.Password)
        $session = $null
        try {
            $session = New-PSSession -VMName $VMName -Credential $guestCredential -ErrorAction Stop
            $attemptId = "$RunId-$([guid]::NewGuid().ToString('N'))"
            Write-StageLog "$VMName starting synchronous engine verification/install and bundled CLI readiness ($attemptId)."
            $result = Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create($guestInstall)) `
                -ArgumentList $attemptId, $deadlineUtc -ErrorAction Stop
            $null = Get-BudgetSeconds 1 "completed synchronous installation on $VMName"
            if ($result.Status -eq 'Verified') {
                Write-StageLog "$VMName verified: SQL 2025 Enterprise Developer, integrated sysadmin SELECT 1, bundled sqlcmd 17, native SQL WMI."
                return
            }
            if ($result.Status -ne 'RebootRequired') { throw "Unexpected guest status: $($result.Status)." }
        }
        finally {
            if ($session) { try { Remove-PSSession $session -ErrorAction Stop } catch { } }
        }
        if ($reboots -eq 1) { throw "$VMName exceeded the bounded installer reboot count." }
        $boot = Wait-SqlGuest $VMName
        Write-StageLog "Rebooting $VMName only after a completed installer returned 3010."
        Invoke-SqlGuest $VMName -ScriptBlock {
            & "$env:SystemRoot\System32\shutdown.exe" /r /t 5 /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not schedule SQL guest reboot.' }
        }
        $null = Wait-SqlGuest $VMName -PreviousBoot $boot
    }
}

$sqlGuestWorker = @'
param($Context)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. ([scriptblock]::Create($Context.Definitions))
$credential = $Context.Credential
$NestedWindowsPassword = $credential.GetNetworkCredential().Password
$RunId = $Context.RunId
$logRoot = $Context.LogRoot
$logFile = Join-Path $logRoot "45-install-sql-$RunId-$($Context.VMName).log"
$guestInstall = $Context.GuestInstall
$script:stageDeadlineUtc = [DateTime]::Parse($Context.DeadlineUtc).ToUniversalTime()
$script:phaseDeadlineUtc = $null
$script:payload = @($Context.Payload)
$status = 'Verified'
$failureText = ''
try {
    Import-Module Hyper-V -ErrorAction Stop
    Complete-SqlGuest $Context.VMName
}
catch {
    $status = 'Failed'
    $failureText = "[$($_.Exception.GetType().FullName)] $($_.Exception.Message)`nScriptStackTrace: $($_.ScriptStackTrace)"
    $failureText = $failureText.Replace($NestedWindowsPassword, '[REDACTED]')
    try { Write-StageLog "$($Context.VMName) failed: $failureText" } catch { }
}
finally {
    $script:phaseDeadlineUtc = $null
    try { Export-SqlGuestLogs $Context.VMName } catch { }
    $credential = $null
    Remove-Variable NestedWindowsPassword -ErrorAction SilentlyContinue
}
[pscustomobject]@{ VMName = $Context.VMName; Status = $status; Error = $failureText; LogFile = $logFile }
'@

function Invoke-ParallelSqlGuests {
    param(
        [ValidateNotNullOrEmpty()]
        [ValidateCount(1, 3)]
        [ValidateSet('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')]
        [string[]]$Names
    )
    if (@($Names | Sort-Object -Unique).Count -ne $Names.Count) { throw 'Duplicate SQL guest selection is forbidden.' }
    foreach ($name in $Names) {
        if ((Get-VM -Name $name -ErrorAction Stop).State -ne 'Running') { throw "$name must be running after stage 40." }
    }
    $script:phaseDeadlineUtc = [DateTime]::UtcNow.AddMinutes(25)
    Write-StageLog 'Preparing and verifying the shared SQL media cache before launching guest workers.'
    try { $payload = @(Get-SqlPayload) }
    finally { $script:phaseDeadlineUtc = $null }
    # Ship the existing function definitions, not a second hand-maintained
    # installer implementation. Each Windows PowerShell job has isolated state.
    $definitions = (@(
        foreach ($name in @('Get-BudgetSeconds', 'Wait-BoundedJob', 'Invoke-SqlGuest', 'Wait-SqlGuest',
            'Copy-SqlPayload', 'Export-SqlGuestLogs', 'Complete-SqlGuest', 'Write-StageLog')) {
            "function $name {`n$((Get-Command $name -CommandType Function).Definition)`n}"
        }
    ) -join "`n")
    $workers = [Collections.Generic.List[object]]::new()
    $failures = [Collections.Generic.List[string]]::new()
    try {
        Write-StageLog "Launching $($Names.Count) independent SQL guest workers."
        foreach ($name in $Names) {
            try {
                $context = [pscustomobject]@{
                    VMName = $name; Credential = $credential; Definitions = $definitions
                    Payload = $payload; GuestInstall = $guestInstall; LogRoot = $logRoot; RunId = $RunId
                    DeadlineUtc = $script:stageDeadlineUtc.ToString('o')
                }
                $job = Start-Job -Name "stage45-$RunId-$name" -ScriptBlock ([scriptblock]::Create($sqlGuestWorker)) `
                    -ArgumentList $context -ErrorAction Stop
                $workers.Add([pscustomobject]@{ VMName = $name; Job = $job })
            }
            catch { $failures.Add("$name worker launch failed: $($_.Exception.Message)") }
        }
    }
    finally {
        # Do not use Wait-BoundedJob here: it is exclusively for non-installer
        # probes/copies. Never close a sibling's held installer session on failure.
        foreach ($worker in $workers) {
            while ($worker.Job.State -notin @('Completed', 'Failed', 'Stopped')) {
                Write-StageLog "$($worker.VMName) worker remains $($worker.Job.State); waiting without terminating its installer."
                try { Wait-Job -Job $worker.Job -Timeout 30 -Force -ErrorAction Stop | Out-Null }
                catch {
                    $failures.Add("$($worker.VMName) worker wait failed: $($_.Exception.Message)")
                    Start-Sleep -Seconds 1
                }
            }
            try {
                $results = @(Receive-Job -Job $worker.Job -ErrorAction Stop)
                if ($worker.Job.State -ne 'Completed' -or $results.Count -ne 1 -or
                    $results[0].VMName -ne $worker.VMName -or $results[0].Status -ne 'Verified') {
                    throw "Worker state $($worker.Job.State). $($results.Error -join '; ')"
                }
                Write-StageLog "$($worker.VMName) worker passed; host log: $($results[0].LogFile)"
            }
            catch { $failures.Add("$($worker.VMName): $($_.Exception.Message)") }
            finally {
                # Only terminal jobs reach here; no -Force and no Stop-Job.
                try { Remove-Job -Job $worker.Job -ErrorAction Stop }
                catch { $failures.Add("$($worker.VMName) worker cleanup failed: $($_.Exception.Message)") }
            }
        }
    }
    if ($failures.Count) {
        throw "Stage 45 guest failures after all started workers finished:`n$($failures -join "`n")"
    }
}

$logRoot = 'C:\ArcJumpstart\Logs'
$cache = 'F:\ArcJumpstart\Sql2025'
$logFile = Join-Path $logRoot "45-install-sql-$RunId.log"
$credential = [pscredential]::new('Administrator', (ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force))
$script:payload = $null
$lock = $null
try {
    $script:engineScript = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EngineScriptBase64))
    $parseTokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($script:engineScript, [ref]$parseTokens, [ref]$parseErrors)
    if ([string]::IsNullOrWhiteSpace($script:engineScript) -or $parseErrors.Count) { throw 'EngineScriptBase64 must contain a valid PowerShell engine script.' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
        throw 'Stage 45 must run as SYSTEM on the Windows Hyper-V host.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    New-Item -ItemType Directory $logRoot, $cache -Force | Out-Null
    & icacls.exe $cache /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not secure host SQL cache.' }
    $lock = [IO.File]::Open("$cache\stage45.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    Write-StageLog "Starting SQL installation stage for: $($VmNames -join ', '). No SQL engine is installed on the host."
    Invoke-ParallelSqlGuests -Names $VmNames
    Write-StageLog "Stage 45 completed: $($VmNames.Count) selected SQL guest(s) passed live readiness checks: $($VmNames -join ', ')."
}
catch {
    $failure = $_
    try {
        if (Test-Path $logRoot) {
            Write-StageLog "Stage 45 failed [$($failure.Exception.GetType().FullName)]: $($failure.Exception.Message)`nScriptStackTrace: $($failure.ScriptStackTrace)"
        }
    }
    catch { }
    throw
}
finally {
    if ($lock) { try { $lock.Dispose() } catch { } }
    $credential = $null
    # Do not assign null/empty to a ValidateNotNullOrEmpty parameter during
    # unwinding: parameter validation would replace the original exception.
    Remove-Variable -Name NestedWindowsPassword -ErrorAction SilentlyContinue
}
