param(
    [Parameter(Mandatory)][string]$NestedWindowsPassword,
    [ValidateSet('Preflight','Capture','Inspect','Safety')][string]$Action = 'Preflight',
    [ValidatePattern('^[a-zA-Z0-9-]*$')][string]$CaptureId = '',
    [string]$RunId
)
$ErrorActionPreference = 'Stop'
if ($Action -eq 'Capture') {
    throw 'New paired captures are disabled: the guest timed-stop guard has not been validated. Inspect existing evidence instead.'
}
$credential = [pscredential]::new('JS-SQL-01\Administrator',
    (ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force))
$NestedWindowsPassword = $null
# PACKET_TOOLS
# PACKET_METADATA

function Get-PacketPreflight {
    $ErrorActionPreference = 'Continue'
    $status = (& pktmon.exe status 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE) { throw 'Packet Monitor status failed.' }
    $filters = (& pktmon.exe filter list 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE) { throw 'Packet Monitor filter inspection failed.' }
    [pscustomobject]@{Computer=$env:COMPUTERNAME;Utc=[datetime]::UtcNow.ToString('o');Status=$status;Filters=$filters}
}

$guestPreflight = Invoke-Command -VMName JS-SQL-01 -Credential $credential -ScriptBlock ${function:Get-PacketPreflight}
$hostPreflight = Get-PacketPreflight
if ($Action -eq 'Safety') {
    $read = {
        param([string]$StopSource,[string]$TraceId)
        $ErrorActionPreference='Stop'
        $trace = (& netsh.exe trace show status 2>&1 | Out-String).Trim()
        $captureRoot = if ($TraceId) { "C:\ArcJumpstart\Diagnostics\SqlHandshake\$TraceId" } else { $null }
        if ($captureRoot -and $trace.IndexOf((Join-Path $captureRoot 'packets.etl'),[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            & ([scriptblock]::Create($StopSource)) -Name "AJSql-$TraceId" -Root $captureRoot
            $trace = (& netsh.exe trace show status 2>&1 | Out-String).Trim()
        }
        $tasks = @(Get-ScheduledTask | Where-Object TaskName -like 'AJSql-*' |
            Select-Object TaskName,@{n='State';e={[string]$_.State}})
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore |
            Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction,AllowLocalFirewallRules,LogBlocked)
        $ports = @(Get-NetFirewallPortFilter -PolicyStore ActiveStore |
            Where-Object { $_.Protocol -in @('TCP','6','Any','256') -and $_.LocalPort -contains '1433' })
        $rules = @($ports | Get-NetFirewallRule | Where-Object { $_.Enabled -eq 'True' } | ForEach-Object {
            $address = $_ | Get-NetFirewallAddressFilter
            [pscustomobject]@{Name=$_.DisplayName;Action=[string]$_.Action;Direction=[string]$_.Direction
                Profile=[string]$_.Profile;Remote=@($address.RemoteAddress);Local=@($address.LocalAddress)
                SourceType=[string]$_.PolicyStoreSourceType}
        })
        $files = if ($captureRoot -and (Test-Path -LiteralPath $captureRoot)) {
            @(Get-ChildItem -LiteralPath $captureRoot -File |
                Select-Object Name,Length,@{n='WrittenUtc';e={$_.LastWriteTimeUtc.ToString('o')}})
        } else { @() }
        [pscustomobject]@{Computer=$env:COMPUTERNAME;Utc=[datetime]::UtcNow.ToString('o')
            Trace=$trace;Watchdogs=$tasks;Files=$files
            Network=@(Get-NetConnectionProfile | Select-Object InterfaceAlias,@{n='Category';e={[string]$_.NetworkCategory}})
            FirewallProfiles=$profiles;Explicit1433Rules=$rules}
    }
    Write-Output 'SQL_SAFETY_GUEST_READ_STARTED'
    $stopSource=(Get-Command Stop-OwnedSqlTrace).Definition
    $guestSafety=Invoke-Command -VMName JS-SQL-01 -Credential $credential -ScriptBlock $read -ArgumentList $stopSource,$CaptureId
    Write-Output 'SQL_SAFETY_HOST_READ_STARTED'
    [ordered]@{Guest=$guestSafety | Select-Object Computer,Utc,Trace,Watchdogs,Files,Network,FirewallProfiles,Explicit1433Rules
        Host=(& $read $stopSource $CaptureId)} | ConvertTo-Json -Depth 7 -Compress | Write-Output
    Write-Output 'SQL_PACKET_DIAGNOSTICS_COMPLETED'
    return
}
if ($Action -eq 'Preflight') {
    $hostTrace = (& netsh.exe trace show status 2>&1 | Out-String).Trim()
    $hostTraceExit = $LASTEXITCODE
    $help = (& netsh.exe trace show capturefilterhelp 2>&1 | Out-String)
    if ($LASTEXITCODE) { throw 'Independent trace filter help failed.' }
    $filterSyntax = @($help -split '\r?\n' | Where-Object { $_ -match 'IPv4\.|TCP\.|UDP\.|Port|Address|Example|Protocol' })
    $guestTrace = Invoke-Command -VMName JS-SQL-01 -Credential $credential -ScriptBlock {
        [pscustomobject]@{Status=(& netsh.exe trace show status 2>&1 | Out-String).Trim();Exit=$LASTEXITCODE}
    }
    [ordered]@{
        Host=@{Computer=$hostPreflight.Computer;Status=($hostPreflight.Status -split 'Packet Filters:')[0].Trim()
            Filters=if($hostPreflight.Filters -match 'SenseNdr'){'Existing SenseNdr filters; unchanged'}else{$hostPreflight.Filters}}
        Guest=$guestPreflight | Select-Object Computer,Utc,Status,Filters
        IndependentTrace=@{Host=$hostTrace;HostExit=$hostTraceExit;Guest=$guestTrace.Status;GuestExit=$guestTrace.Exit;FilterHelp=$filterSyntax}
        HostRoute=@(Find-NetRoute -RemoteIPAddress '192.168.128.11' |
            Select-Object IPAddress,InterfaceAlias,InterfaceIndex,NextHop)
    } | ConvertTo-Json -Depth 5 -Compress
    Write-Output 'SQL_PACKET_DIAGNOSTICS_COMPLETED'
    return
}
if (!$CaptureId) { $CaptureId = $RunId }
if ($CaptureId -notmatch '^[a-zA-Z0-9-]{10,70}$') { throw 'A valid capture identifier is required.' }
$root = "C:\ArcJumpstart\Diagnostics\SqlHandshake\$CaptureId"
$name = "AJSql-$CaptureId"
$helperNames = @('Get-SqlTraceAvailability','Stop-OwnedSqlTrace','Start-SqlPacketCapture',
    'Stop-SqlPacketCapture','Get-SqlCaptureSchema','Get-SqlNetworkUInt16','Get-SqlNetworkUInt32',
    'ConvertFrom-SqlPacketBytes','Get-SqlPacketMetadata')
$helpers = ($helperNames | ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }) -join "`n"
$session = New-PSSession -VMName JS-SQL-01 -Credential $credential
try {
    Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create($helpers))
    if ($Action -eq 'Capture') {
        $hostAvailability = Get-SqlTraceAvailability
        $guestAvailability = Invoke-Command -Session $session -ScriptBlock { Get-SqlTraceAvailability }
        if ($hostAvailability.Sessions.Count -or $hostAvailability.Providers.Count -or
            $guestAvailability.Sessions.Count -or $guestAvailability.Providers.Count) {
            throw 'An existing NetEvent session/provider prevents this independent capture. It was not changed.'
        }
        $route = @(Find-NetRoute -RemoteIPAddress '192.168.128.11' | Where-Object IPAddress)
        if ($route.Count -ne 1 -or $route[0].IPAddress -ne '192.168.128.1') {
            throw 'Host source address differs from the approved flow; capture was not started.'
        }
        $hostCleanup = $null
        $guestCleanup = $null
        try {
            Invoke-Command -Session $session -ScriptBlock {
                param($r,$n) Start-SqlPacketCapture -Root $r -Name $n
            } -ArgumentList $root,$name
            Start-SqlPacketCapture -Root $root -Name $name -CaptureType both
            $connection = New-Object System.Data.SqlClient.SqlConnection
            $connection.ConnectionString = 'Server=tcp:192.168.128.11,1433;Integrated Security=true;Encrypt=true;TrustServerCertificate=true;Connect Timeout=4;Pooling=false;ConnectRetryCount=0;Application Name=ArcJumpstartPacketProbe'
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $probe = @{Utc=[datetime]::UtcNow.ToString('o')}
            try { $connection.Open(); $probe.Result='Connected' }
            catch [System.Data.SqlClient.SqlException] {
                $probe.Result='SqlException';$probe.Number=$_.Exception.Number
                $probe.Message=($_.Exception.Message -split '\r?\n')[0]
            }
            finally { $timer.Stop();$probe.Seconds=[math]::Round($timer.Elapsed.TotalSeconds,2);$connection.Dispose() }
        }
        finally {
            try { $hostCleanup = Stop-SqlPacketCapture -Name $name -Root $root }
            finally {
                $guestCleanup = Invoke-Command -Session $session -ScriptBlock {
                    param($n,$r) Stop-SqlPacketCapture -Name $n -Root $r
                } -ArgumentList $name,$root
            }
            [ordered]@{CaptureId=$CaptureId;Probe=$probe;HostCleanup=$hostCleanup
                GuestCleanup=$guestCleanup | Select-Object Computer,OwnedSessionRemoved,WatchdogRemoved} |
                ConvertTo-Json -Compress -Depth 5 | Write-Output
        }
    }
    $hostSchema = Get-SqlCaptureSchema -Root $root
    $guestSchema = Invoke-Command -Session $session -ScriptBlock { param($r) Get-SqlCaptureSchema -Root $r } -ArgumentList $root
    $finalMonitor = Get-PacketPreflight
    if ($Action -eq 'Inspect') {
        $hm = Get-SqlPacketMetadata -Root $root
        $gm = Invoke-Command -Session $session -ScriptBlock { param($r) Get-SqlPacketMetadata -Root $r } -ArgumentList $root |
            Select-Object Decoded,DuplicateObservations,OtherEvents,PossibleTruncation,Columns,Rows
        [ordered]@{
            CaptureId=$CaptureId;Host=$hm;Guest=$gm
            WatchdogErrors=@{Host=$hostSchema.WatchdogError;Guest=$guestSchema.WatchdogError}
            ExistingPacketMonitorUnchanged=($finalMonitor.Filters -eq $hostPreflight.Filters -and
                $finalMonitor.Status -eq $hostPreflight.Status)
        } | ConvertTo-Json -Depth 8 -Compress | Write-Output
        if ($hm.Decoded -gt 0 -and $gm.Decoded -gt 0) {
            Write-Output 'SQL_PACKET_DIAGNOSTICS_COMPLETED'
            return
        }
    }
    [ordered]@{Host=$hostSchema;Guest=$guestSchema | Select-Object Root,Bytes,Events,Schemas
        ExistingPacketMonitorUnchanged=($finalMonitor.Filters -eq $hostPreflight.Filters -and
            $finalMonitor.Status -eq $hostPreflight.Status)} |
        ConvertTo-Json -Depth 8 -Compress | Write-Output
    Write-Output 'SQL_PACKET_DIAGNOSTICS_COMPLETED'
}
finally { Remove-PSSession -Session $session }
