[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$DomainNetbiosName,

    [Parameter(Mandatory)]
    [string]$ClusterName,

    [Parameter(Mandatory)]
    [string]$ClusterIp,

    [Parameter(Mandatory)]
    [string]$ListenerIp,

    [Parameter(Mandatory)]
    [string]$AvailabilityGroupName,

    [Parameter(Mandatory)]
    [string]$ListenerName,

    [Parameter(Mandatory)]
    [string]$SampleDatabaseName,

    [Parameter(Mandatory)]
    [string]$StandaloneDatabaseName,

    [Parameter(Mandatory)]
    [string]$SqlServiceAccountName,

    [Parameter(Mandatory)]
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [string]$SqlServiceAccountPassword,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "60-configure-sql-ag-$RunId.log") -Force

function New-PlainTextCredential {
    param(
        [Parameter(Mandatory)]
        [string]$Username,

        [Parameter(Mandatory)]
        [string]$Password
    )

    [pscredential]::new($Username, (ConvertTo-SecureString $Password -AsPlainText -Force))
}

function Wait-VMHeartbeat {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $heartbeat = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        if ($heartbeat.PrimaryStatusDescription -eq 'OK') {
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for heartbeat from $VMName."
}

function Invoke-GuestWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-Command `
                -VMName $VMName `
                -Credential $Credential `
                -ScriptBlock $ScriptBlock `
                -ArgumentList $ArgumentList `
                -ErrorAction Stop
        }
        catch {
            $authenticationFailure =
                $_.FullyQualifiedErrorId -match 'Authentication|InvalidCredential' -or
                $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::AuthenticationError -or
                $_.Exception -is [System.Security.Authentication.AuthenticationException] -or
                ("$($_.Exception.Message) $($_.ErrorDetails.Message)" -match '(?i)\bcredentials?\s+(is|are)\s+invalid\b|\bauthentication\s+failed\b|\blogon\s+failure\b|\buser\s*name or password is incorrect\b')
            if ($authenticationFailure) { throw }
            $transportFailure =
                $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -or
                $_.FullyQualifiedErrorId -like '*PSSessionStateBroken*'
            if (-not $transportFailure) {
                throw
            }
            if ((Get-Date) -ge $deadline) {
                throw
            }
            Start-Sleep -Seconds 15
        }
    } while ($true)
}

function Invoke-GuestLocalProcess {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [pscredential]$ConnectionCredential,

        [Parameter(Mandatory)]
        [pscredential]$ProcessCredential,

        [Parameter(Mandatory)]
        [string]$OperationName,

        [Parameter(Mandatory)]
        [string]$ScriptText,

        [int]$TimeoutSeconds = 1800
    )

    $attemptId = [guid]::NewGuid().ToString('N')
    $session = New-PSSession -VMName $VMName -Credential $ConnectionCredential -ErrorAction Stop
    $invocationReturned = $false
    try {
        # Keep the session alive until the credentialed local process exits.
        # Do not retry this invocation after transport failure: its outcome may
        # be unknown and the next run must inspect the durable process evidence.
        Invoke-Command -Session $session -ErrorAction Stop `
            -ArgumentList $ProcessCredential, $OperationName, $ScriptText, $TimeoutSeconds, $attemptId -ScriptBlock {
            param($LocalCredential, $Operation, $OperationScript, $BudgetSeconds, $AttemptId)
            $ErrorActionPreference = 'Stop'
            function Assert-LocalProcessCompletion {
                param($Process, $Completion, [string]$ExpectedAttempt, [string]$ExpectedIdentity, [DateTime]$SubmittedUtc)
                if (-not $Completion -or $Completion.AttemptId -cne $ExpectedAttempt) { throw 'Missing, stale or mismatched local-process completion evidence.' }
                if ($Completion.Status -notin @('Completed', 'Failed') -or $null -eq $Completion.ExitCode -or
                    -not $Completion.StartedUtc -or -not $Completion.CompletedUtc -or -not $Completion.ProcessStartUtc -or
                    $Completion.ProcessId -ne $Process.Id -or -not $Process.HasExited) {
                    throw 'Incomplete or invalid local-process identity/completion evidence.'
                }
                $started = ([DateTime]$Completion.StartedUtc).ToUniversalTime()
                $completed = ([DateTime]$Completion.CompletedUtc).ToUniversalTime()
                # Process.StartTime is not reliably available on the returned
                # Process object after -Wait. The child records its own birth
                # time while alive; correlate it with the native PID and nonce.
                $birth = ([DateTime]$Completion.ProcessStartUtc).ToUniversalTime()
                if ($birth -lt $SubmittedUtc -or $birth -gt $started -or $started -lt $SubmittedUtc -or $completed -lt $started) {
                    throw 'Stale local-process completion timestamps.'
                }
                if ($Process.ExitCode -ne $Completion.ExitCode) { throw 'Local-process exit code disagrees with its completion evidence.' }
                if ($Completion.Status -eq 'Failed' -or $Process.ExitCode -ne 0) {
                    throw "Local operation failed (exit $($Process.ExitCode)): $($Completion.Error) [$($Completion.ErrorId)]"
                }
                if ($Completion.Identity -ine $ExpectedIdentity -or $Completion.RemoteSession -ne $false -or $Completion.IsAdministrator -ne $true) {
                    throw 'Operation did not run as the intended elevated local domain process.'
                }
            }
            function Assert-NoActiveLabOperation {
                param([string]$Root)
                $activePath = Join-Path $Root 'active.json'
                $wrapperPattern = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape("$Root\") + '[A-Za-z0-9_-]+\\[a-f0-9]{32}\\wrapper\.ps1"?(?:\s|$)'
                $owned = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
                    Where-Object { $_.CommandLine -match $wrapperPattern })
                if (Test-Path $activePath) {
                    $active = Get-Content $activePath -Raw | ConvertFrom-Json
                    if (-not $active.AttemptId -or -not $active.ProcessId -or -not $active.ProcessStartUtc -or
                        -not $active.WrapperPath -or -not $active.ResultPath) { throw 'Invalid prior operation identity; inspect active.json before retrying.' }
                    $process = Get-Process -Id $active.ProcessId -ErrorAction SilentlyContinue
                    if ($process -and $process.StartTime.ToUniversalTime() -eq ([DateTime]$active.ProcessStartUtc).ToUniversalTime()) {
                        $command = $owned | Where-Object ProcessId -eq $active.ProcessId
                        $tokenMatches = $command -and $command.CommandLine.Contains($active.WrapperPath) -and $command.CommandLine.Contains($active.AttemptId)
                        throw "Prior operation process is still active: PID=$($active.ProcessId), start=$($active.ProcessStartUtc), attempt=$($active.AttemptId), commandTokenMatches=$([bool]$tokenMatches). Do not start overlapping cluster work."
                    }
                    # A reused PID is not proof that the old operation is alive.
                    # Nonetheless, a vanished process without a terminal receipt
                    # has an unknown outcome, not permission for a blind retry.
                    $prior = if (Test-Path $active.ResultPath) { Get-Content $active.ResultPath -Raw | ConvertFrom-Json } else { $null }
                    if (-not $prior -or $prior.AttemptId -cne $active.AttemptId -or
                        $prior.ProcessId -ne $active.ProcessId -or $prior.ProcessStartUtc -cne $active.ProcessStartUtc -or
                        $prior.Status -notin @('Completed', 'Failed') -or -not $prior.CompletedUtc -or $null -eq $prior.ExitCode -or
                        (($prior.Status -eq 'Completed') -ne ($prior.ExitCode -eq 0))) {
                        throw "Prior operation outcome is unknown; inspect $($active.ResultPath) before retrying."
                    }
                }
                if ($owned) { throw "An owned local-operation process remains active (PID $($owned.ProcessId -join ', ')); inspect its wrapper token/start time before retrying." }
            }

            if ($Operation -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid local operation name.' }
            $operationRoot = 'C:\ArcJumpstart\Operations'
            New-Item -ItemType Directory $operationRoot -Force | Out-Null
            & icacls.exe $operationRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not secure local-operation evidence.' }
            try { $controlLock = [IO.File]::Open("$operationRoot\observer.lock", 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { throw 'Another local-operation observer may still be active; inspect Operations before retrying.' }
            try {
                $legacy = @(Get-ScheduledTask -TaskName 'ArcJumpstart-*' -ErrorAction SilentlyContinue |
                    Where-Object State -in @('Queued', 'Running'))
                if ($legacy) { throw "Legacy tasks remain active: $($legacy.TaskName -join ', '). Inspect them; no automatic cancellation is permitted." }
                Assert-NoActiveLabOperation $operationRoot
                $operationLockPath = Join-Path $operationRoot 'operation.lock'
                try { $probeLock = [IO.File]::Open($operationLockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
                catch { throw 'A prior local operation still holds its execution lock; do not start another.' }
                $probeLock.Dispose()
                $attemptRoot = Join-Path $operationRoot "$Operation\$AttemptId"
                $scriptPath = Join-Path $attemptRoot 'wrapper.ps1'
                $actionPath = Join-Path $attemptRoot 'action.ps1'
                $resultPath = Join-Path $attemptRoot 'result.json'
                $requestPath = Join-Path $attemptRoot 'request.json'
                $activePath = Join-Path $operationRoot 'active.json'
                $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
                New-Item -ItemType Directory $attemptRoot -Force | Out-Null
                $submittedUtc = (Get-Date).ToUniversalTime()
                @{ AttemptId = $AttemptId; Operation = $Operation; SubmittedUtc = $submittedUtc.ToString('o'); BudgetSeconds = $BudgetSeconds } |
                    ConvertTo-Json | Set-Content $requestPath -Encoding UTF8
                Set-Content $actionPath $OperationScript -Encoding UTF8
                $wrappedScript = @"
`$ErrorActionPreference = 'Stop'
`$env:ARCJUMPSTART_OPERATION_ATTEMPT_ID = '$AttemptId'
`$result = [ordered]@{
    AttemptId = '$AttemptId'; Status = 'Running'; ProcessId = `$PID
    ProcessStartUtc = (Get-Process -Id `$PID).StartTime.ToUniversalTime().ToString('o')
    StartedUtc = [DateTime]::UtcNow.ToString('o'); CompletedUtc = `$null
    ExitCode = `$null; Error = ''; ErrorId = ''; ScriptStackTrace = ''
    Identity = ''; IsAdministrator = `$false; RemoteSession = `$true
}
function Get-LocalExecutionIdentity {
    `$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    `$principal = New-Object Security.Principal.WindowsPrincipal(`$identity)
    [pscustomobject]@{
        Identity = `$identity.Name
        IsAdministrator = `$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        RemoteSession = [bool](Get-Variable PSSenderInfo -ValueOnly -ErrorAction SilentlyContinue)
    }
}
function Save-OperationResult {
    `$result | ConvertTo-Json -Depth 5 | Set-Content '$resultPath.new' -Encoding UTF8
    Move-Item '$resultPath.new' '$resultPath' -Force
}
`$exitCode = 0
`$executionLock = `$null
try {
    `$executionLock = [IO.File]::Open('$operationLockPath', 'OpenOrCreate', 'ReadWrite', 'None')
    @{
        AttemptId = '$AttemptId'; Operation = '$Operation'; ProcessId = `$PID; ProcessStartUtc = `$result.ProcessStartUtc
        WrapperPath = '$scriptPath'; ResultPath = '$resultPath'
    } | ConvertTo-Json | Set-Content '$activePath.new' -Encoding UTF8
    Move-Item '$activePath.new' '$activePath' -Force
    Save-OperationResult
    `$identity = Get-LocalExecutionIdentity
    `$result.Identity = `$identity.Identity
    `$result.IsAdministrator = `$identity.IsAdministrator
    `$result.RemoteSession = `$identity.RemoteSession
    if (-not `$identity.IsAdministrator -or `$identity.RemoteSession) { throw 'An elevated local domain process is required for cluster operations.' }
    `$global:LASTEXITCODE = 0
    & '$actionPath'
    if (`$LASTEXITCODE -ne 0) { `$exitCode = `$LASTEXITCODE; throw "Local action exited with code `$exitCode." }
    `$result.Status = 'Completed'
}
catch {
    if (`$exitCode -eq 0) { `$exitCode = 1 }
    `$result.Status = 'Failed'
    `$result.Error = "`$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
    `$result.ErrorId = `$_.FullyQualifiedErrorId
    `$result.ScriptStackTrace = `$_.ScriptStackTrace
    [Console]::Error.WriteLine(`$result.Error)
}
finally {
    `$result.ExitCode = `$exitCode
    `$result.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    try { Save-OperationResult } catch { `$exitCode = 1; [Console]::Error.WriteLine(`$_.Exception.Message) }
    if (`$executionLock) { `$executionLock.Dispose() }
}
exit `$exitCode
"@
                Set-Content $scriptPath $wrappedScript -Encoding UTF8
                Write-Host "Local operation $Operation attempt=$AttemptId starting; evidence=$attemptRoot; budget=${BudgetSeconds}s. An active process is never terminated to enforce this budget."
                $process = Start-Process "$PSHOME\powershell.exe" -ArgumentList $arguments `
                    -Credential $LocalCredential -LoadUserProfile -Wait -PassThru -ErrorAction Stop `
                    -RedirectStandardOutput "$attemptRoot\stdout.log" -RedirectStandardError "$attemptRoot\stderr.log"
                $completion = if (Test-Path $resultPath) { Get-Content $resultPath -Raw | ConvertFrom-Json } else { $null }
                try {
                    @{
                        AttemptId = $AttemptId; ProcessId = $process.Id; ExitCode = $process.ExitCode
                        ObservedUtc = [DateTime]::UtcNow.ToString('o'); CompletionStatus = $completion.Status
                    } | ConvertTo-Json | Set-Content "$attemptRoot\exit-observation.json"
                }
                catch { Write-Warning "Could not save the exit observation: $($_.Exception.Message)" }
                Assert-LocalProcessCompletion $process $completion $AttemptId $LocalCredential.UserName $submittedUtc
                if ([DateTime]::UtcNow -gt $submittedUtc.AddSeconds($BudgetSeconds)) {
                    throw "Local operation completed successfully but exceeded its ${BudgetSeconds}s budget. No process was terminated. Inspect $attemptRoot."
                }
                Write-Host "Local operation $Operation attempt=$AttemptId completed with verified exit 0."
                return [pscustomobject]@{ Operation = $Operation; AttemptId = $AttemptId; ExitCode = 0; Evidence = $attemptRoot }
            }
            catch { throw "Local operation $Operation attempt=$AttemptId failed: $($_.Exception.Message). Evidence: $operationRoot\$Operation\$AttemptId" }
            finally { try { $controlLock.Dispose() } catch { } }
        }
        $invocationReturned = $true
    }
    finally {
        if ($invocationReturned) {
            try { Remove-PSSession $session -ErrorAction Stop } catch { Write-Warning "Session cleanup failed: $($_.Exception.Message)" }
        }
        else {
            Write-Warning "Failed/unknown invocation $OperationName attempt=$attemptId on $VMName. Session $($session.Id) was not explicitly removed; inspect Operations evidence and process identity before retrying."
        }
    }
}

function Invoke-SqlScalarOnGuest {
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [pscredential]$Credential,

        [Parameter(Mandatory)]
        [string]$Query
    )

    Invoke-GuestWithRetry `
        -VMName $VMName `
        -Credential $Credential `
        -ArgumentList $Query `
        -ScriptBlock {
            param($SqlQuery)
            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            $output = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q $SqlQuery 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "SQL scalar query failed: $(($output -join [Environment]::NewLine).Trim())"
            }
            ($output -join '').Trim()
        }
}

function Get-SqlServerModulePackage {
    # Microsoft-published, PowerShell 5.1-compatible, no external module dependencies.
    # Source/size/SHA512: https://www.powershellgallery.com/api/v2/Packages(Id='SqlServer',Version='22.4.5.1')
    $directory = 'F:\ArcJumpstart\SqlServerModule'
    $path = Join-Path $directory 'sqlserver.22.4.5.1.nupkg'
    $hash = 'fc07531bceece44a5b7ffb29a8fd8d0b07a1a9f0eb0cb4535646fb0025a990b606954fc657af8981c8b650b5b3226c4c79874edc2802a3c05fe909ba9053e9b4'
    New-Item -ItemType Directory $directory -Force | Out-Null
    if (-not (Test-Path $path)) {
        $request = [Net.HttpWebRequest]::Create('https://cdn.powershellgallery.com/packages/sqlserver.22.4.5.1.nupkg')
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 30000
        $response = $null; $inputStream = $null; $outputStream = $null
        try {
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -ne 47388419) {
                throw 'Unexpected response for the pinned SqlServer module.'
            }
            $inputStream = $response.GetResponseStream()
            $outputStream = [IO.File]::Open("$path.partial", 'Create', 'Write', 'None')
            $buffer = New-Object byte[] 65536
            $total = 0
            $deadline = [DateTime]::UtcNow.AddMinutes(10)
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $count
                if ($total -gt 47388419 -or [DateTime]::UtcNow -gt $deadline) { throw 'SqlServer module download exceeded its size/time limit.' }
                $outputStream.Write($buffer, 0, $count)
            }
            if ($total -ne 47388419) { throw 'Incomplete SqlServer module download.' }
        }
        finally {
            foreach ($resource in @($outputStream, $inputStream, $response)) {
                if ($resource) { try { $resource.Dispose() } catch { } }
            }
            try { $request.Abort() } catch { }
        }
        if ((Get-FileHash "$path.partial" -Algorithm SHA512).Hash -ine $hash) { throw 'SqlServer module published hash mismatch.' }
        Move-Item "$path.partial" $path
    }
    if ((Get-Item $path).Length -ne 47388419 -or (Get-FileHash $path -Algorithm SHA512).Hash -ine $hash) {
        throw 'Cached SqlServer module does not match the published package; investigate instead of importing it.'
    }
    [pscustomobject]@{ Path = $path; Hash = $hash; Version = '22.4.5.1' }
}

function Copy-SqlServerModuleToGuest {
    param([string]$VMName, [pscredential]$Credential, $Package)
    $session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
    try {
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory 'C:\ArcJumpstart\Modules' -Force | Out-Null
            & icacls.exe 'C:\ArcJumpstart\Modules' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not secure the SQL module directory.' }
        }
        Copy-Item $Package.Path -Destination 'C:\ArcJumpstart\Modules\sqlserver.22.4.5.1.nupkg' -ToSession $session -Force
        Invoke-Command -Session $session -ArgumentList $Package.Hash -ScriptBlock {
            param($ExpectedHash)
            $package = 'C:\ArcJumpstart\Modules\sqlserver.22.4.5.1.nupkg'
            if ((Get-FileHash $package -Algorithm SHA512).Hash -ine $ExpectedHash) { throw 'Transferred SqlServer module hash mismatch.' }
            $moduleRoot = 'C:\ArcJumpstart\Modules\SqlServer\22.4.5.1'
            if (-not (Test-Path "$moduleRoot\package.complete")) {
                if (Test-Path $moduleRoot) { throw 'Partial SqlServer module extraction exists; investigate before retrying.' }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [IO.Compression.ZipFile]::ExtractToDirectory($package, $moduleRoot)
                Set-Content "$moduleRoot\package.complete" $ExpectedHash
            }
            if ((Get-Content "$moduleRoot\package.complete" -Raw).Trim() -ine $ExpectedHash) { throw 'SqlServer module provenance mismatch.' }
            $manifest = Test-ModuleManifest "$moduleRoot\SqlServer.psd1" -ErrorAction Stop
            if ($manifest.Version -ne [version]'22.4.5.1') { throw 'Unexpected SqlServer module version.' }
        }
    }
    finally { Remove-PSSession $session }
}

function Assert-LabWindowsSetupComplete {
    # Query the native completion signal, not inferred registry flags.
    # https://learn.microsoft.com/windows/win32/api/oobenotification/nf-oobenotification-oobecomplete
    if (-not ('ArcJumpstart.Stage60Oobe' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace ArcJumpstart {
    public static class Stage60Oobe {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
    }
}
'@ -ErrorAction Stop
    }
    $complete = $false
    if (-not [ArcJumpstart.Stage60Oobe]::OOBEComplete([ref]$complete)) {
        $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [ComponentModel.Win32Exception]::new($nativeError, "OOBEComplete query failed on $env:COMPUTERNAME (Win32 error $nativeError); stage60 is blocked.")
    }
    if (-not $complete) {
        throw "Windows Setup is unfinished on $env:COMPUTERNAME (OOBEComplete=false); stage60 is blocked. Complete guest provisioning before configuring the cluster; do not forge setup flags."
    }
    Write-Host "Windows Setup completion verified on $env:COMPUTERNAME."
}

function Initialize-LabInstalledUpdateInventory {
    # Search uses the configured update source; Online changes only this searcher.
    # https://learn.microsoft.com/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search
    $updateSession = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
    $updateSession.ClientApplicationID = 'ArcJumpstart-InstalledUpdateInventory'
    $searcher = $updateSession.CreateUpdateSearcher()
    $searcher.Online = $false
    $initialized = $false
    try {
        $offline = $searcher.Search('IsInstalled=1')
    }
    catch {
        $comError = $_.Exception
        while ($comError -and $comError -isnot [Runtime.InteropServices.COMException]) {
            $comError = $comError.InnerException
        }
        if (-not $comError -or $comError.HResult -ne [Convert]::ToInt32('80248014', 16)) { throw }
        Write-Warning 'Offline installed-update inventory returned WU_E_DS_UNKNOWNSERVICE (0x80248014). Performing one online installed-metadata search using the configured update source; no updates are downloaded or installed.'
        $searcher.Online = $true
        $online = $searcher.Search('IsInstalled=1')
        if ($null -eq $online -or $online.ResultCode -ne 2) {
            throw "Online installed-update metadata search did not fully succeed (ResultCode=$($online.ResultCode)); cluster validation is blocked."
        }
        $searcher.Online = $false
        $offline = $searcher.Search('IsInstalled=1')
        $initialized = $true
    }
    if ($null -eq $offline -or $offline.ResultCode -ne 2) {
        throw "Offline installed-update inventory did not fully succeed (ResultCode=$($offline.ResultCode)); cluster validation is blocked."
    }
    Write-Host "Installed-update offline inventory verified: count=$($offline.Updates.Count), metadataInitialized=$initialized."
    [pscustomobject]@{
        ResultCode = $offline.ResultCode
        InstalledUpdateCount = $offline.Updates.Count
        MetadataInitialized = $initialized
    }
}

function Assert-LabClusterValidationReport {
    param(
        [string]$Html,
        [object[]]$Warnings = @(),
        [string]$ReportPath,
        [string[]]$SelectedCategories = @()
    )
    # Native reports are HTML, not XML (IMG/br/META need not be closed).
    function Get-ReportText([string]$Fragment) {
        $text = [Net.WebUtility]::HtmlDecode([regex]::Replace($Fragment, '<[^>]*>', ' '))
        [regex]::Replace($text, '\s+', ' ').Trim()
    }
    function Test-SinglePathMessage([string]$Text) {
        $Text -match '(?i)\bonly (one|a single) (pair of (network )?interfaces|network path)\b' -and
            $Text -notmatch '(?i)\b(error|failed|unsuccessful)\b|0x[0-9a-f]{8}'
    }
    $body = [regex]::Replace($Html, '(?is)<(script|style)\b.*?</\1>', '')
    $rows = @(
        foreach ($row in [regex]::Matches($body, '(?is)<tr\b[^>]*>(.*?)</tr\s*>')) {
            if ($row.Value -notmatch '(?i)<result\b') { continue }
            $cells = @([regex]::Matches($row.Value, '(?is)<td\b[^>]*>(.*?)</td\s*>'))
            $link = [regex]::Match($row.Value, '(?is)<a\b[^>]*\bhref\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a\s*>')
            $description = [regex]::Match($row.Value, '(?is)<description\b[^>]*>(.*?)</description\s*>')
            $icon = [regex]::Match($row.Value, '(?is)<IMG\b[^>]*\bname\s*=\s*["'']([^"'']+)["'']')
            if ($cells.Count -ne 3 -or -not $link.Success -or -not $description.Success -or -not $icon.Success) {
                throw 'Unrecognized cluster validation result row; inspect the retained native HTML.'
            }
            $name = Get-ReportText $link.Groups[2].Value
            $status = Get-ReportText $description.Groups[1].Value
            $target = [Net.WebUtility]::HtmlDecode($link.Groups[1].Value).Trim()
            if (-not $name -or $target -notmatch '^#\S+$' -or
                $status -notmatch '^(Succeeded|Success|Passed|Warning|Failed|Failure|Error|Canceled|Cancelled|Not Run)$') {
                throw "Unrecognized cluster validation result: '$name' / '$status'."
            }
            $iconStatus = $icon.Groups[1].Value -replace 'Img$', ''
            if ($status -match '^(Failed|Failure|Error|Canceled|Cancelled|Not Run)$' -or
                $iconStatus -match '^(Failed|Failure|Error|Canceled|Cancelled|NotRun)$') {
                throw "Cluster validation contains failed, canceled or unexecuted tests: $name ($status)."
            }
            if (($status -eq 'Warning' -and $iconStatus -ne 'Warning') -or
                ($status -ne 'Warning' -and $iconStatus -notmatch '^(Success|Succeeded|Passed)$')) {
                throw "Unrecognized or contradictory cluster validation icon/status: $name."
            }
            [pscustomobject]@{ Name = $name; Status = $status; Target = $target.Substring(1) }
        }
    )
    $categoryNames = @('Inventory', 'Network', 'System Configuration')
    $categories = @($rows | Where-Object Name -in $categoryNames)
    $tests = @($rows | Where-Object Name -notin $categoryNames)
    if (@($categories.Name | Sort-Object -Unique).Count -ne 3 -or -not $tests.Count) {
        throw 'Unrecognized cluster validation report: require the three selected categories and per-test results.'
    }
    if (-not ($tests.Status -match '^(Succeeded|Success|Passed)$')) { throw 'Cluster validation contains no successful tests; inspect the retained report.' }
    $warningTests = @($tests | Where-Object Status -eq 'Warning')
    foreach ($test in $warningTests) {
        if ($test.Name -ne 'Validate Network Communication') {
            throw "Cluster validation warning requires investigation: $($test.Name). Inspect its report details; category summaries or successful subchecks do not override a test warning."
        }
    }
    foreach ($category in @($categories | Where-Object Status -eq 'Warning')) {
        if ($category.Name -ne 'Network' -or -not $warningTests.Count) {
            throw "Cluster validation category warning requires investigation: $($category.Name); no allowed per-test warning explains it."
        }
    }
    if ($body -match '(?i)error retrieving the QFE information|0x80248014') {
        throw 'Cluster validation QFE retrieval error requires investigation, regardless of later software-update success text.'
    }
    # Resolve the warning test's own anchor, not the category anchor or the
    # entire report: unrelated text must never authorize this lab exception.
    $targets = @($rows.Target | Sort-Object -Unique)
    $anchors = @([regex]::Matches($body, '(?is)<[a-z][a-z0-9]*\b[^>]*\b(?:id|name)\s*=\s*["'']([^"'']+)["''][^>]*>') |
        Where-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) -in $targets })
    $networkDetails = @(
        foreach ($test in @($warningTests | Sort-Object Target -Unique)) {
            $anchor = @($anchors | Where-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) -eq $test.Target })
            if ($anchor.Count -ne 1) { throw 'Unrecognized network warning detail anchor; inspect the retained report.' }
            $start = $anchor[0].Index + $anchor[0].Length
            $next = $anchors | Where-Object Index -ge $start | Select-Object -First 1
            $end = if ($next) { $next.Index } else { $body.Length }
            $detail = Get-ReportText $body.Substring($start, $end - $start)
            if (-not (Test-SinglePathMessage $detail)) {
                throw 'Validate Network Communication warning requires investigation: its own detail does not establish only the known single-path limitation.'
            }
            $detail
        }
    )
    $selectedLabScope = $SelectedCategories.Count -eq 3 -and
        @($categoryNames | Where-Object { $_ -notin $SelectedCategories }).Count -eq 0
    $overallSummaryPrefix = 'Test Result: HadUnselectedTests, ClusterConditionallyApproved Testing has completed for the tests you selected. You should review the warnings in the Report. A cluster solution is supported by Microsoft only if you run all cluster validation tests, and all tests succeed (with or without warnings). Test report file path: '
    foreach ($warning in @($Warnings | ForEach-Object { Get-ReportText "$_" })) {
        # Native WarningVariable reports this summary rather than the detail.
        # Correlate only after this test's linked HTML detail has passed above.
        if ($networkDetails.Count -and
            $warning -cin @(
                'Network - Validate Network Communication: The test reported some warnings.',
                'Network - Validate Network Communication: The test reported some warnings..')) {
            continue
        }
        # This exact native summary describes our explicit no-storage selection,
        # not permission to overlook failed/unexecuted tests or additional flags.
        if ($networkDetails.Count -and $selectedLabScope -and $ReportPath -and
            $warning.StartsWith($overallSummaryPrefix, [StringComparison]::Ordinal) -and
            $warning.Substring($overallSummaryPrefix.Length).Equals($ReportPath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not $networkDetails.Count -or -not (Test-SinglePathMessage $warning) -or
            -not @($networkDetails | Where-Object { $_.Contains($warning) }).Count) {
            throw "Cluster validation warning requires investigation: $warning"
        }
    }
    if ($networkDetails.Count) {
        Write-Warning 'Accepted only Validate Network Communication single-path lab warning (not production HA); see retained test details.'
    }
}

function Test-LabListenerTcp {
    param([string]$Fqdn)
    $client = [Net.Sockets.TcpClient]::new()
    $pending = $null
    try {
        $pending = $client.BeginConnect($Fqdn, 1433, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) { throw 'Listener TCP1433 timed out.' }
        $client.EndConnect($pending)
    }
    finally {
        if ($pending) { $pending.AsyncWaitHandle.Close() }
        $client.Dispose()
    }
}

function Test-LabAgListener {
    param([string]$Fqdn, [string]$ExpectedIp, [string]$AgName, [string]$DatabaseName, [int]$TimeoutSeconds = 300)
    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $agLiteral = $AgName.Replace("'", "''")
    $databaseLiteral = $DatabaseName.Replace("'", "''")
    do {
        try {
            $addresses = @(Resolve-DnsName -Name $Fqdn -Type A -DnsOnly -ErrorAction Stop |
                Where-Object IPAddress | ForEach-Object IPAddress | Sort-Object -Unique)
            if ($addresses.Count -ne 1 -or $addresses[0] -ne $ExpectedIp) { throw 'Listener DNS does not resolve exclusively to its configured lab IP.' }
            Test-LabListenerTcp $Fqdn
            # The listener also uses a lab self-signed certificate. -C is an
            # explicit trust exception, not a request to disable encryption.
            $query = "SET NOCOUNT ON; IF DB_NAME() <> N'$databaseLiteral' OR ISNULL(sys.fn_hadr_is_primary_replica(N'$databaseLiteral'),0) <> 1 THROW 51000, 'Listener did not reach the intended primary database', 1; IF NOT EXISTS (SELECT 1 FROM sys.availability_groups ag JOIN sys.availability_databases_cluster db ON db.group_id = ag.group_id WHERE ag.name = N'$agLiteral' AND db.database_name = N'$databaseLiteral') THROW 51000, 'Listener reached the wrong availability group', 1; SELECT 1;"
            $output = & $sqlcmd -S "tcp:$Fqdn,1433" -E -b -C -l 15 -t 30 -d $DatabaseName -h -1 -W -Q $query 2>&1
            if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -ne '1') { throw "Listener SQL query failed: $($output -join ' ')" }
            Write-Host "Verified listener $Fqdn DNS=$ExpectedIp, TCP1433 and primary database $DatabaseName in $AgName."
            return
        }
        catch { $failure = $_.Exception.Message }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    throw "Listener readiness failed: $failure"
}

try {
    $dcName = 'JS-DC-01'
    $standaloneName = 'JS-SQL-01'
    $primaryName = 'JS-SQL-AG-01'
    $secondaryName = 'JS-SQL-AG-02'
    $sqlNodes = @($primaryName, $secondaryName)
    $domainCredential = New-PlainTextCredential `
        -Username "$DomainNetbiosName\Administrator" `
        -Password $NestedWindowsPassword
    $sqlServiceIdentity = "$DomainNetbiosName\$SqlServiceAccountName"
    $serviceAccountChanged = @{}
    foreach ($nodeName in $sqlNodes) {
        Write-Host "Checking Windows Setup completion on $nodeName."
        Invoke-Command -VMName $nodeName -Credential $domainCredential `
            -ScriptBlock ${function:Assert-LabWindowsSetupComplete} -ErrorAction Stop
    }
    $sqlServerModule = Get-SqlServerModulePackage

    Invoke-GuestWithRetry `
        -VMName $standaloneName `
        -Credential $domainCredential `
        -ArgumentList $StandaloneDatabaseName `
        -ScriptBlock {
            param($DatabaseName)
            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            $query = @"
IF DB_ID(N'$DatabaseName') IS NULL
BEGIN
    CREATE DATABASE [$DatabaseName];
END;
EXEC (N'USE [$DatabaseName];
    IF OBJECT_ID(N''dbo.MigrationWorkload'', N''U'') IS NULL
        CREATE TABLE dbo.MigrationWorkload (
            WorkloadId int IDENTITY(1,1) PRIMARY KEY,
            CapturedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
            Payload nvarchar(4000) NOT NULL
        );
    IF NOT EXISTS (SELECT 1 FROM dbo.MigrationWorkload)
        INSERT dbo.MigrationWorkload (Payload)
        SELECT TOP (1000) REPLICATE(CONVERT(nvarchar(36), NEWID()), 50)
        FROM sys.all_objects a CROSS JOIN sys.all_objects b;');
"@
            $output = & $sqlcmd -S localhost -E -b -C -Q $query 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create standalone migration database ${DatabaseName}: $(($output -join [Environment]::NewLine).Trim())"
            }
        }

    foreach ($nodeName in $sqlNodes) {
        Wait-VMHeartbeat -VMName $nodeName
        $nodePreparation = Invoke-GuestWithRetry `
            -VMName $nodeName `
            -Credential $domainCredential `
            -ArgumentList $sqlServiceIdentity, $SqlServiceAccountPassword `
            -ScriptBlock {
                param($ServiceIdentity, $ServicePassword)
                $featureResult = Install-WindowsFeature Failover-Clustering -IncludeManagementTools

                function Set-LabSqlServiceAccount {
                    param([string]$Identity, [string]$Password)
                    $namespace = 'root\Microsoft\SqlServer\ComputerManagement17'
                    $services = @(Get-CimInstance -Namespace $namespace -ClassName SqlService `
                        -Filter "ServiceName='MSSQLSERVER'" -ErrorAction Stop)
                    if ($services.Count -ne 1) {
                        throw 'Expected exactly one default MSSQLSERVER service in the SQL 2025 WMI provider.'
                    }
                    $service = $services[0]
                    if ($service.StartName -ieq $Identity) { return $false }
                    # Use SQL's provider, not Win32_Service, to update SQL-specific permissions.
                    $result = Invoke-CimMethod -InputObject $service -MethodName SetServiceAccount `
                        -Arguments @{ ServiceStartName = $Identity; ServiceStartPassword = $Password } -ErrorAction Stop
                    if ($null -eq $result.ReturnValue -or $result.ReturnValue -ne 0) {
                        throw "SQL WMI SetServiceAccount failed (return code $($result.ReturnValue))."
                    }
                    $updated = Get-CimInstance -Namespace $namespace -ClassName SqlService `
                        -Filter "ServiceName='MSSQLSERVER'" -ErrorAction Stop
                    if ($updated.StartName -ine $Identity) {
                        throw 'SQL WMI returned success but the service account did not change.'
                    }
                    return $true
                }
                $accountChanged = Set-LabSqlServiceAccount -Identity $ServiceIdentity -Password $ServicePassword

                if (-not (Get-NetFirewallRule -DisplayName 'Arc Jumpstart SQL Server' -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName 'Arc Jumpstart SQL Server' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
                }
                if (-not (Get-NetFirewallRule -DisplayName 'Arc Jumpstart HADR endpoint' -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -DisplayName 'Arc Jumpstart HADR endpoint' -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow | Out-Null
                }

                if ((Get-Service MSSQLSERVER).Status -ne 'Running') {
                    Start-Service MSSQLSERVER
                }

                [pscustomobject]@{
                    FeatureRestartNeeded = $featureResult.RestartNeeded -eq 'Yes'
                    ServiceAccountChanged = $accountChanged
                }
            }

        $serviceAccountChanged[$nodeName] = [bool]$nodePreparation.ServiceAccountChanged
        if ($nodePreparation.FeatureRestartNeeded) {
            Restart-VM -Name $nodeName -Force
            Wait-VMHeartbeat -VMName $nodeName
        }
    }

    $clusterState = Invoke-GuestWithRetry -VMName $primaryName -Credential $domainCredential -ArgumentList $ClusterName -ScriptBlock {
        param($TargetClusterName)
        if (-not (Test-Path 'HKLM:\Cluster')) {
            return [pscustomobject]@{
                Exists = $false
                Name = $null
                Nodes = @()
            }
        }

        Import-Module FailoverClusters
        $cluster = Get-Cluster -ErrorAction Stop
        [pscustomobject]@{
            Exists = $true
            Name = $cluster.Name
            Nodes = @((Get-ClusterNode -Cluster $cluster.Name -ErrorAction Stop).Name)
        }
    }

    if ($clusterState.Exists -and $clusterState.Name -ne $ClusterName) {
        throw "Node $primaryName already belongs to cluster $($clusterState.Name), not $ClusterName."
    }

    $inventoryScript = @"
function Initialize-LabInstalledUpdateInventory {
${function:Initialize-LabInstalledUpdateInventory}
}
Initialize-LabInstalledUpdateInventory | ConvertTo-Json
"@
    foreach ($nodeName in @($primaryName, $secondaryName)) {
        Invoke-GuestLocalProcess -VMName $nodeName -ConnectionCredential $domainCredential `
            -ProcessCredential $domainCredential -OperationName 'ArcJumpstart-InstalledUpdateInventory' `
            -ScriptText $inventoryScript -TimeoutSeconds 600
    }

    # Run locally under a credentialed domain process, preserving New-Cluster's
    # documented remoting/CredSSP restriction rather than relying on double-hop.
    # https://learn.microsoft.com/windows-server/failover-clustering/create-failover-cluster
    # https://learn.microsoft.com/powershell/module/failoverclusters/test-cluster
    $validationScript = @"
function Assert-LabClusterValidationReport {
${function:Assert-LabClusterValidationReport}
}
Import-Module FailoverClusters
`$reports = 'C:\ArcJumpstart\Logs\ClusterValidation'
New-Item -ItemType Directory `$reports -Force | Out-Null
Set-Location `$reports
`$reportName = Join-Path `$reports ('Validation-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
`$selectedCategories = @('Inventory', 'Network', 'System Configuration')
`$warnings = @()
`$report = @(Test-Cluster -Node '$primaryName', '$secondaryName' -Include `$selectedCategories -ReportName `$reportName -WarningVariable warnings -ErrorAction Stop)
`$warnings | Out-String | Set-Content ("`$reportName.warnings.txt")
'AG lab: no shared storage; Storage tests intentionally excluded. Both VMs share one physical host; this is not production fault isolation.' | Set-Content ("`$reportName.scope.txt")
if (`$report.Count -ne 1 -or -not (Test-Path `$report[0].FullName)) { throw 'Test-Cluster did not return its validation report.' }
Assert-LabClusterValidationReport -Html (Get-Content `$report[0].FullName -Raw) -Warnings `$warnings -ReportPath `$report[0].FullName -SelectedCategories `$selectedCategories
if (-not `$env:ARCJUMPSTART_OPERATION_ATTEMPT_ID) { throw 'Validation operation attempt identity is missing.' }
@{ AttemptId = `$env:ARCJUMPSTART_OPERATION_ATTEMPT_ID; ReportPath = `$report[0].FullName; Nodes = @('$primaryName', '$secondaryName'); ValidatedUtc = [DateTime]::UtcNow.ToString('o') } |
    ConvertTo-Json | Set-Content (Join-Path `$reports ("Validation-`$env:ARCJUMPSTART_OPERATION_ATTEMPT_ID.completed.json"))
"@
    $validationRun = Invoke-GuestLocalProcess -VMName $primaryName -ConnectionCredential $domainCredential `
        -ProcessCredential $domainCredential -OperationName 'ArcJumpstart-ValidateCluster' -ScriptText $validationScript
    Invoke-GuestWithRetry -VMName $primaryName -Credential $domainCredential `
        -ArgumentList $validationRun.AttemptId, $primaryName, $secondaryName -ScriptBlock {
            param($ExpectedAttempt, $FirstNode, $SecondNode)
            $proofPath = "C:\ArcJumpstart\Logs\ClusterValidation\Validation-$ExpectedAttempt.completed.json"
            if (-not $ExpectedAttempt -or -not (Test-Path $proofPath)) { throw 'Fresh cluster validation postcondition is missing; cluster creation is blocked.' }
            $proof = Get-Content $proofPath -Raw | ConvertFrom-Json
            if ($proof.AttemptId -cne $ExpectedAttempt -or -not $proof.ValidatedUtc -or
                @($proof.Nodes).Count -ne 2 -or $FirstNode -notin $proof.Nodes -or $SecondNode -notin $proof.Nodes -or
                -not $proof.ReportPath -or -not (Test-Path $proof.ReportPath)) {
                throw 'Fresh cluster validation report/nodes do not match this invocation; cluster creation is blocked.'
            }
        }

    if (-not $clusterState.Exists) {
        $clusterScript = @"
Import-Module FailoverClusters
New-Cluster -Name '$($ClusterName.Replace("'", "''"))' -Node '$($primaryName.Replace("'", "''"))', '$($secondaryName.Replace("'", "''"))' -StaticAddress '$($ClusterIp.Replace("'", "''"))' -NoStorage -Force -ErrorAction Stop | Out-Null
"@
        Invoke-GuestLocalProcess `
            -VMName $primaryName `
            -ConnectionCredential $domainCredential `
            -ProcessCredential $domainCredential `
            -OperationName 'ArcJumpstart-CreateCluster' `
            -ScriptText $clusterScript
    }
    elseif ($secondaryName -notin @($clusterState.Nodes)) {
        $addNodeScript = @"
Import-Module FailoverClusters
Add-ClusterNode -Cluster '$($ClusterName.Replace("'", "''"))' -Name '$($secondaryName.Replace("'", "''"))' -NoStorage -ErrorAction Stop | Out-Null
"@
        Invoke-GuestLocalProcess `
            -VMName $primaryName `
            -ConnectionCredential $domainCredential `
            -ProcessCredential $domainCredential `
            -OperationName 'ArcJumpstart-AddClusterNode' `
            -ScriptText $addNodeScript
    }

    $verifyClusterScript = @"
Import-Module FailoverClusters
`$cluster = Get-Cluster -Name '$($ClusterName.Replace("'", "''"))' -ErrorAction Stop
`$nodes = @(Get-ClusterNode -Cluster `$cluster.Name -ErrorAction Stop)
if (`$cluster.Name -ine '$($ClusterName.Replace("'", "''"))' -or `$nodes.Count -ne 2 -or
    '$primaryName' -notin `$nodes.Name -or '$secondaryName' -notin `$nodes.Name -or
    @(`$nodes | Where-Object State -ne 'Up').Count) {
    throw 'Cluster creation/membership postcondition failed: expected both SQL nodes Up in the intended cluster. Witness ACLs are blocked.'
}
"@
    Invoke-GuestLocalProcess -VMName $primaryName -ConnectionCredential $domainCredential `
        -ProcessCredential $domainCredential -OperationName 'ArcJumpstart-VerifyCluster' -ScriptText $verifyClusterScript

    Invoke-GuestWithRetry `
        -VMName $dcName `
        -Credential $domainCredential `
        -ArgumentList $DomainNetbiosName, $ClusterName, $ListenerName `
        -ScriptBlock {
            param($TargetNetbiosName, $TargetClusterName, $TargetListenerName)
            Import-Module ActiveDirectory
            function Get-ExpectedClusterComputer {
                param([string]$NetbiosName, [string]$Name)
                $identity = "$NetbiosName\${Name}$"
                if ((Get-ADDomain -ErrorAction Stop).NetBIOSName -ine $NetbiosName) {
                    throw "Expected cluster identity $identity is not in this DC's domain."
                }
                try { $computer = Get-ADComputer -Identity $Name -Properties SID, SamAccountName, Enabled -ErrorAction Stop }
                catch { throw "Expected cluster computer account $identity is absent or unreadable after cluster creation. Inspect cluster operation evidence; do not fabricate/precreate a CNO to mask the failure." }
                if (-not $computer -or $computer.SamAccountName -ine "${Name}$" -or -not $computer.SID -or -not $computer.Enabled) {
                    throw "Expected cluster computer account $identity is missing its SID, disabled, or mismatched. Witness ACLs are blocked."
                }
                return $computer
            }
            $clusterComputer = Get-ExpectedClusterComputer -NetbiosName $TargetNetbiosName -Name $TargetClusterName

            $witnessPath = 'C:\ClusterWitness'
            New-Item -ItemType Directory -Path $witnessPath -Force | Out-Null
            $clusterAccount = "$TargetNetbiosName\${TargetClusterName}$"
            $witnessAcl = Get-Acl $witnessPath
            $witnessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $clusterComputer.SID,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $witnessAcl.SetAccessRule($witnessRule)
            Set-Acl -Path $witnessPath -AclObject $witnessAcl

            $domainAdmins = "$TargetNetbiosName\Domain Admins"
            if (-not (Get-SmbShare -Name ClusterWitness -ErrorAction SilentlyContinue)) {
                New-SmbShare `
                    -Name ClusterWitness `
                    -Path $witnessPath `
                    -FullAccess $clusterAccount, $domainAdmins | Out-Null
            }
            else {
                Grant-SmbShareAccess -Name ClusterWitness -AccountName $clusterAccount -AccessRight Full -Force | Out-Null
                Grant-SmbShareAccess -Name ClusterWitness -AccountName $domainAdmins -AccessRight Full -Force | Out-Null
            }

            if (-not (Get-ADComputer -Filter "Name -eq '$TargetListenerName'")) {
                New-ADComputer -Name $TargetListenerName -Enabled $false
            }

            $listenerComputer = Get-ADComputer -Identity $TargetListenerName
            $listenerAcl = Get-Acl "AD:$($listenerComputer.DistinguishedName)"
            $clusterIdentity = $clusterComputer.SID
            $accessRule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new(
                $clusterIdentity,
                [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $listenerAcl.AddAccessRule($accessRule)
            Set-Acl -Path "AD:$($listenerComputer.DistinguishedName)" -AclObject $listenerAcl
        }

    $quorumScript = @"
Import-Module FailoverClusters
Set-ClusterQuorum -Cluster '$($ClusterName.Replace("'", "''"))' -FileShareWitness '\\$($dcName.Replace("'", "''"))\ClusterWitness' -ErrorAction Stop | Out-Null
"@
    Invoke-GuestLocalProcess `
        -VMName $primaryName `
        -ConnectionCredential $domainCredential `
        -ProcessCredential $domainCredential `
        -OperationName 'ArcJumpstart-SetQuorum' `
        -ScriptText $quorumScript

    foreach ($nodeName in $sqlNodes) {
        Copy-SqlServerModuleToGuest -VMName $nodeName -Credential $domainCredential -Package $sqlServerModule
        Invoke-GuestWithRetry `
            -VMName $nodeName `
            -Credential $domainCredential `
            -ArgumentList $sqlServiceIdentity, $serviceAccountChanged[$nodeName] `
            -ScriptBlock {
                param($ServiceIdentity, $ServiceAccountWasChanged)
                Import-Module 'C:\ArcJumpstart\Modules\SqlServer\22.4.5.1\SqlServer.psd1' -RequiredVersion '22.4.5.1' -ErrorAction Stop
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $before = & $sqlcmd -S localhost -E -b -C -l 15 -t 30 -h -1 -W -Q "SET NOCOUNT ON; SELECT SERVERPROPERTY('IsHadrEnabled');" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Could not read HADR state: $($before -join ' ')" }
                # Documented cmdlet uses SQL's configuration provider, including
                # WSFC service-SID permissions; do not substitute a registry write.
                # https://learn.microsoft.com/powershell/module/sqlserver/enable-sqlalwayson
                Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -NoServiceRestart -Confirm:$false -ErrorAction Stop
                $restartRequired = $ServiceAccountWasChanged -or ($before -join '').Trim() -ne '1'
                if ($restartRequired) {
                    Restart-Service MSSQLSERVER -Force
                }

                function Wait-LabSqlHadrReady {
                    param([ValidateRange(0, 3600)][int]$TimeoutSeconds = 600)
                    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                    $query = "SET NOCOUNT ON; SELECT CONCAT(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), ',', CONVERT(int, SERVERPROPERTY('HadrManagerStatus')));"
                    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                    do {
                        $savedPreference = $ErrorActionPreference
                        try {
                            # Windows PowerShell 5.1 wraps native stderr in ErrorRecords.
                            # Capture it for classification, then restore fail-fast behavior.
                            $ErrorActionPreference = 'Continue'
                            $probeOutput = & $sqlcmd -S localhost -E -b -C -l 15 -t 30 -h -1 -W -Q $query 2>&1
                            $exitCode = $LASTEXITCODE
                        }
                        finally { $ErrorActionPreference = $savedPreference }
                        $text = ($probeOutput -join [Environment]::NewLine).Trim()
                        if ($exitCode -eq 0) {
                            if ($text -eq '1,1') { return }
                            if ($text -notmatch '^[01],[012]$') { throw "Invalid HADR readiness result on ${env:COMPUTERNAME}: $text" }
                            # Observed on the new SQL process during startup; only 1,1 is ready.
                            if ($text.EndsWith(',2') -and $text -ne '1,2') { throw "SQL Server HADR manager failed to start on ${env:COMPUTERNAME}: $text" }
                        }
                        else {
                            $sqlError = $text -match '(?im)^\s*Msg\s+\d+\s*,|login failed|SSL Provider|certificate'
                            $startupConnectionError = $text -match '(?i)login timeout expired|actively refused|Named Pipes Provider:.*Could not open a connection|server was not found or was not accessible'
                            if ($sqlError -or -not $startupConnectionError) {
                                throw "HADR readiness query failed on $env:COMPUTERNAME (sqlcmd exit $exitCode); not a startup delay: $text"
                            }
                        }
                        if ((Get-Date) -ge $deadline) { break }
                        Write-Host "Waiting for HADR readiness on $env:COMPUTERNAME (sqlcmd exit $exitCode): $text"
                        Start-Sleep -Seconds 10
                    } while ((Get-Date) -lt $deadline)
                    throw "SQL Server on $env:COMPUTERNAME did not become HADR-ready within $TimeoutSeconds seconds. Last result (sqlcmd exit $exitCode): $text. Inspect this instance's SQL Server ERRORLOG for startup/HADR errors before retrying; no automatic restart was requested."
                }
                Wait-LabSqlHadrReady

                $escapedServiceIdentity = $ServiceIdentity.Replace(']', ']]')
                $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$ServiceIdentity')
    CREATE LOGIN [$escapedServiceIdentity] FROM WINDOWS;
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT [Hadr_endpoint]
        STATE = STARTED
        AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (ROLE = ALL);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$escapedServiceIdentity];
"@
                & $sqlcmd -S localhost -E -b -C -Q $query
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to configure the HADR endpoint.'
                }
            }
    }

    $agCount = [int](Invoke-SqlScalarOnGuest `
        -VMName $primaryName `
        -Credential $domainCredential `
        -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_groups WHERE name = N'$AvailabilityGroupName';")
    $agExists = $agCount -gt 0
    $currentPrimaryName = $primaryName

    if ($agExists) {
        $currentPrimaryName = $null
        foreach ($nodeName in $sqlNodes) {
            $role = Invoke-SqlScalarOnGuest `
                -VMName $nodeName `
                -Credential $domainCredential `
                -Query "SET NOCOUNT ON; SELECT COALESCE(MAX(rs.role_desc), '') FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON ag.group_id = rs.group_id WHERE rs.is_local = 1 AND ag.name = N'$AvailabilityGroupName';"
            if ($role -eq 'PRIMARY') {
                $currentPrimaryName = $nodeName
                break
            }
        }
        if (-not $currentPrimaryName) {
            throw "Availability group $AvailabilityGroupName exists, but neither replica reports the PRIMARY role."
        }
    }

    $currentSecondaryName = if ($currentPrimaryName -eq $primaryName) {
        $secondaryName
    }
    else {
        $primaryName
    }

    Invoke-GuestWithRetry `
        -VMName $currentPrimaryName `
        -Credential $domainCredential `
        -ArgumentList $SampleDatabaseName `
        -ScriptBlock {
            param($DatabaseName)
            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            $query = @"
IF DB_ID(N'$DatabaseName') IS NULL
BEGIN
    CREATE DATABASE [$DatabaseName];
    EXEC (N'USE [$DatabaseName];
        CREATE TABLE dbo.AssessmentWorkload (
            WorkloadId int IDENTITY(1,1) PRIMARY KEY,
            CapturedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
            Payload nvarchar(4000) NOT NULL
        );
        INSERT dbo.AssessmentWorkload (Payload)
        SELECT TOP (1000) REPLICATE(CONVERT(nvarchar(36), NEWID()), 50)
        FROM sys.all_objects a CROSS JOIN sys.all_objects b;');
END;
ALTER DATABASE [$DatabaseName] SET RECOVERY FULL;
DECLARE @backupDirectory nvarchar(4000);
EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'BackupDirectory',
    @backupDirectory OUTPUT;
IF @backupDirectory IS NULL
    THROW 50001, 'The SQL Server default backup directory was not found.', 1;
IF RIGHT(@backupDirectory, 1) NOT IN (N'\', N'/')
    SET @backupDirectory += N'\';
DECLARE @fullBackup nvarchar(4000) = @backupDirectory + N'$DatabaseName.bak';
DECLARE @logBackup nvarchar(4000) = @backupDirectory + N'$DatabaseName.trn';
BACKUP DATABASE [$DatabaseName] TO DISK = @fullBackup WITH INIT, CHECKSUM;
BACKUP LOG [$DatabaseName] TO DISK = @logBackup WITH INIT, CHECKSUM;
"@
            $output = & $sqlcmd -S localhost -E -b -C -Q $query 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to prepare ${DatabaseName}: $(($output -join [Environment]::NewLine).Trim())"
            }
        }

    if (-not $agExists) {
        Invoke-GuestWithRetry `
            -VMName $currentPrimaryName `
            -Credential $domainCredential `
            -ArgumentList $AvailabilityGroupName, $SampleDatabaseName, $primaryName, $secondaryName, $DomainName `
            -ScriptBlock {
                param($AgName, $DatabaseName, $FirstNode, $SecondNode, $DnsDomain)
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $query = @"
CREATE AVAILABILITY GROUP [$AgName]
FOR DATABASE [$DatabaseName]
REPLICA ON
    N'$FirstNode' WITH (
        ENDPOINT_URL = N'TCP://$FirstNode.$DnsDomain`:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
    ),
    N'$SecondNode' WITH (
        ENDPOINT_URL = N'TCP://$SecondNode.$DnsDomain`:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = AUTOMATIC,
        SEEDING_MODE = AUTOMATIC,
        SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
    );
"@
                $output = & $sqlcmd -S localhost -E -b -C -Q $query 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create availability group ${AgName}: $(($output -join [Environment]::NewLine).Trim())"
                }
            }
    }
    else {
        $secondaryReplicaCount = [int](Invoke-SqlScalarOnGuest `
            -VMName $currentPrimaryName `
            -Credential $domainCredential `
            -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_replicas r JOIN sys.availability_groups ag ON ag.group_id = r.group_id WHERE r.replica_server_name = N'$currentSecondaryName' AND ag.name = N'$AvailabilityGroupName';")
        if ($secondaryReplicaCount -eq 0) {
            Invoke-GuestWithRetry `
                -VMName $currentPrimaryName `
                -Credential $domainCredential `
                -ArgumentList $AvailabilityGroupName, $currentSecondaryName, $DomainName `
                -ScriptBlock {
                    param($AgName, $ReplicaName, $DnsDomain)
                    $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                    $query = @"
ALTER AVAILABILITY GROUP [$AgName]
ADD REPLICA ON N'$ReplicaName' WITH (
    ENDPOINT_URL = N'TCP://$ReplicaName.$DnsDomain`:5022',
    AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
    FAILOVER_MODE = AUTOMATIC,
    SEEDING_MODE = AUTOMATIC,
    SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
);
"@
                    $output = & $sqlcmd -S localhost -E -b -C -Q $query 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to add replica $ReplicaName to ${AgName}: $(($output -join [Environment]::NewLine).Trim())"
                    }
                }
        }
    }

    Invoke-GuestWithRetry `
        -VMName $currentSecondaryName `
        -Credential $domainCredential `
        -ArgumentList $AvailabilityGroupName, $SampleDatabaseName `
        -ScriptBlock {
            param($AgName, $DatabaseName)
            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            $joinOutput = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT COUNT(*)
FROM sys.dm_hadr_availability_replica_cluster_states
WHERE replica_server_name = @@SERVERNAME
  AND group_id = (SELECT group_id FROM sys.availability_groups WHERE name = N'$AgName')
  AND join_state <> 0;
"@ 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to read replica join state: $(($joinOutput -join [Environment]::NewLine).Trim())"
            }
            $joinCount = [int](($joinOutput -join '').Trim())

            if ($joinCount -eq 0) {
                $databaseStateOutput = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT COUNT(*)
FROM sys.dm_hadr_database_replica_states
WHERE is_local = 1
  AND group_id = (SELECT group_id FROM sys.availability_groups WHERE name = N'$AgName')
  AND database_id = DB_ID(N'$DatabaseName');
"@ 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to read secondary database state: $(($databaseStateOutput -join [Environment]::NewLine).Trim())"
                }
                $databaseExistsOutput = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$DatabaseName';" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to check for a conflicting secondary database: $(($databaseExistsOutput -join [Environment]::NewLine).Trim())"
                }
                if ([int](($databaseExistsOutput -join '').Trim()) -gt 0 -and [int](($databaseStateOutput -join '').Trim()) -eq 0) {
                    throw "Conflicting secondary database $DatabaseName is not a replica in $AgName. Investigate/back up its data; automatic DROP DATABASE or replacement is forbidden."
                }

                & $sqlcmd -S localhost -E -b -C -Q "ALTER AVAILABILITY GROUP [$AgName] JOIN;"
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to join the secondary to $AgName."
                }
            }

            & $sqlcmd -S localhost -E -b -C -Q "ALTER AVAILABILITY GROUP [$AgName] GRANT CREATE ANY DATABASE;"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to grant automatic seeding permissions for $AgName."
            }
        }

    $databaseInAg = [int](Invoke-SqlScalarOnGuest `
        -VMName $currentPrimaryName `
        -Credential $domainCredential `
        -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_databases_cluster db JOIN sys.availability_groups ag ON ag.group_id = db.group_id WHERE db.database_name = N'$SampleDatabaseName' AND ag.name = N'$AvailabilityGroupName';")
    if ($databaseInAg -eq 0) {
        Invoke-GuestWithRetry `
            -VMName $currentPrimaryName `
            -Credential $domainCredential `
            -ArgumentList $AvailabilityGroupName, $SampleDatabaseName `
            -ScriptBlock {
                param($AgName, $DatabaseName)
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $output = & $sqlcmd -S localhost -E -b -C -Q "ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$DatabaseName];" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to add $DatabaseName to ${AgName}: $(($output -join [Environment]::NewLine).Trim())"
                }
            }
    }

    $failedSeedingCount = [int](Invoke-SqlScalarOnGuest `
        -VMName $currentPrimaryName `
        -Credential $domainCredential `
        -Query @"
SET NOCOUNT ON;
SELECT COUNT(*)
FROM sys.dm_hadr_automatic_seeding seed
JOIN sys.availability_groups ag ON ag.group_id = seed.ag_id
JOIN sys.availability_replicas replica ON replica.replica_id = seed.ag_remote_replica_id
WHERE ag.name = N'$AvailabilityGroupName'
  AND seed.ag_db_id IN (SELECT group_database_id FROM sys.availability_databases_cluster WHERE group_id = ag.group_id AND database_name = N'$SampleDatabaseName')
  AND replica.replica_server_name = N'$currentSecondaryName'
  AND seed.failure_state IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM sys.dm_hadr_automatic_seeding newer
      WHERE newer.ag_db_id = seed.ag_db_id
        AND newer.ag_id = seed.ag_id
        AND newer.ag_remote_replica_id = seed.ag_remote_replica_id
        AND newer.start_time > seed.start_time
  );
"@)
    if ($failedSeedingCount -gt 0) {
        Write-Host "Restarting failed automatic seeding for $currentSecondaryName."
        Invoke-GuestWithRetry `
            -VMName $currentPrimaryName `
            -Credential $domainCredential `
            -ArgumentList $AvailabilityGroupName, $currentSecondaryName `
            -ScriptBlock {
                param($AgName, $ReplicaName)
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $output = & $sqlcmd -S localhost -E -b -C -Q "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$ReplicaName' WITH (SEEDING_MODE = AUTOMATIC);" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to restart automatic seeding for ${ReplicaName}: $(($output -join [Environment]::NewLine).Trim())"
                }
            }
    }

    Invoke-GuestWithRetry `
        -VMName $currentSecondaryName `
        -Credential $domainCredential `
        -ArgumentList $SampleDatabaseName, $AvailabilityGroupName `
        -TimeoutSeconds 1200 `
        -ScriptBlock {
            param($DatabaseName, $AgName)
            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            $deadline = (Get-Date).AddMinutes(15)
            do {
                $output = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q @"
SET NOCOUNT ON;
SELECT COUNT(*)
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON d.database_id = drs.database_id
WHERE drs.is_local = 1
  AND drs.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = N'$AgName')
  AND d.name = N'$DatabaseName'
  AND drs.synchronization_state_desc = N'SYNCHRONIZED'
  AND drs.synchronization_health_desc = N'HEALTHY';
"@ 2>&1
                if ($LASTEXITCODE -eq 0 -and ($output -join '').Trim() -eq '1') {
                    return
                }
                Start-Sleep -Seconds 15
            } while ((Get-Date) -lt $deadline)
            throw "Automatic seeding did not synchronize ${DatabaseName}: $(($output -join [Environment]::NewLine).Trim())"
        }

    $listenerCount = [int](Invoke-SqlScalarOnGuest `
        -VMName $currentPrimaryName `
        -Credential $domainCredential `
        -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.availability_group_listeners l JOIN sys.availability_groups ag ON ag.group_id = l.group_id WHERE l.dns_name = N'$ListenerName' AND ag.name = N'$AvailabilityGroupName';")
    if ($listenerCount -eq 0) {
        Invoke-GuestWithRetry `
            -VMName $currentPrimaryName `
            -Credential $domainCredential `
            -ArgumentList $AvailabilityGroupName, $ListenerName, $ListenerIp `
            -ScriptBlock {
                param($AgName, $AgListenerName, $AgListenerIp)
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $output = & $sqlcmd -S localhost -E -b -C -Q "ALTER AVAILABILITY GROUP [$AgName] ADD LISTENER N'$AgListenerName' (WITH IP ((N'$AgListenerIp', N'255.255.255.0')), PORT = 1433);" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create listener ${AgListenerName}: $(($output -join [Environment]::NewLine).Trim())"
                }
            }
    }

    Invoke-GuestWithRetry `
        -VMName $currentPrimaryName `
        -Credential $domainCredential `
        -ArgumentList $AvailabilityGroupName `
        -ScriptBlock {
            param($AgName)
            Import-Module FailoverClusters
            $offlineResources = Get-ClusterGroup -Name $AgName -ErrorAction Stop |
                Get-ClusterResource |
                Where-Object State -ne 'Online'
            if ($offlineResources) {
                throw "Availability-group cluster resources are offline: $(($offlineResources.Name) -join ', ')"
            }

            $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
            & $sqlcmd -S localhost -E -b -C -Q @"
SELECT
    ag.name AS availability_group,
    ar.replica_server_name,
    rs.role_desc,
    rs.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states rs ON ar.replica_id = rs.replica_id
WHERE ag.name = N'$AgName';
"@
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to report availability-group health for $AgName."
            }
        }
        # Run as a local domain-account process on the standalone SQL guest so the
        # remote integrated listener query does not depend on remoting delegation.
        $listenerScript = @"
function Test-LabListenerTcp {
${function:Test-LabListenerTcp}
}
function Test-LabAgListener {
${function:Test-LabAgListener}
}
Test-LabAgListener -Fqdn '$("$ListenerName.$DomainName".Replace("'", "''"))' -ExpectedIp '$($ListenerIp.Replace("'", "''"))' -AgName '$($AvailabilityGroupName.Replace("'", "''"))' -DatabaseName '$($SampleDatabaseName.Replace("'", "''"))'
"@
        Invoke-GuestLocalProcess -VMName $standaloneName -ConnectionCredential $domainCredential `
            -ProcessCredential $domainCredential -OperationName 'ArcJumpstart-VerifyListener' -ScriptText $listenerScript -TimeoutSeconds 420
}
finally {
    Stop-Transcript
}
