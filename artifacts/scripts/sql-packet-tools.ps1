function Get-SqlTraceAvailability {
    $ErrorActionPreference = 'Stop'
    $status = (& netsh.exe trace show status 2>&1 | Out-String)
    if ($status -notmatch 'no trace session currently in progress') {
        throw 'An existing or unrecognized netsh trace must remain untouched.'
    }
    [pscustomobject]@{
        Sessions=@(Get-NetEventSession | Select-Object Name)
        Providers=@(Get-NetEventPacketCaptureProvider | Select-Object SessionName)
    }
}

function Stop-OwnedSqlTrace {
    param([string]$Name,[string]$Root)
    $ErrorActionPreference = 'Stop'
    $mutex = New-Object Threading.Mutex($false,"Global\$Name")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(15000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Another owned trace cleanup is still running.' }
        $status = (& netsh.exe trace show status 2>&1 | Out-String)
        $path = Join-Path $Root 'packets.etl'
        if ($status.IndexOf($path,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $stop = (& netsh.exe trace stop 2>&1 | Out-String)
            if ($LASTEXITCODE) { throw "Owned netsh trace stop failed: $stop" }
        }
        elseif ($status -notmatch 'no trace session currently in progress') {
            throw 'Netsh trace ownership changed; refusing to stop another trace.'
        }
        $final = (& netsh.exe trace show status 2>&1 | Out-String)
        if ($final -notmatch 'no trace session currently in progress') {
            throw 'Owned trace termination could not be verified.'
        }
    }
    finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Start-SqlPacketCapture {
    param([string]$Root,[string]$Name,[ValidateSet('physical','both')][string]$CaptureType='physical')
    $ErrorActionPreference = 'Stop'
    $availability = Get-SqlTraceAvailability
    if ($availability.Sessions.Count -or $availability.Providers.Count) {
        throw 'An existing NetEvent session/provider must remain untouched. No new capture was started.'
    }
    if (Test-Path -LiteralPath $Root) { throw "Diagnostic directory already exists: $Root" }
    [void](New-Item -ItemType Directory -Path $Root -Force)
    & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE) { throw "Cannot protect diagnostic directory: $Root" }
    $guardPath = Join-Path $Root 'stop-owned-trace.ps1'
    $guard = "function Stop-OwnedSqlTrace {`n$(${function:Stop-OwnedSqlTrace}.ToString())`n}`n" + @"
`$ErrorActionPreference = 'Stop'
try { Stop-OwnedSqlTrace -Name '$Name' -Root '$Root' }
catch { `$_.Exception.Message | Set-Content -LiteralPath '$Root\watchdog-error.txt'; throw }
finally { Unregister-ScheduledTask -TaskName '$Name' -Confirm:`$false }
"@
    $guard | Set-Content -LiteralPath $guardPath -Encoding UTF8
    $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -NonInteractive -File `"$guardPath`""
    [void](Register-ScheduledTask -TaskName $Name -Action $taskAction `
        -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(8)) -User SYSTEM -RunLevel Highest)
    $start = (& netsh.exe trace start capture=yes "capturetype=$CaptureType" report=disabled correlation=disabled persistent=no `
        "tracefile=$(Join-Path $Root 'packets.etl')" maxsize=16 filemode=circular overwrite=no `
        'IPv4.SourceAddress=(192.168.128.1,192.168.128.11)' `
        'IPv4.DestinationAddress=(192.168.128.1,192.168.128.11)' 'Protocol=6' 2>&1 | Out-String)
    if ($LASTEXITCODE) { throw "Independent filtered capture failed to start: $start" }
    $status = (& netsh.exe trace show status 2>&1 | Out-String)
    if ($status.IndexOf((Join-Path $Root 'packets.etl'),[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Cannot verify ownership of the independent trace.'
    }
}

function Stop-SqlPacketCapture {
    param([string]$Name,[string]$Root)
    Stop-OwnedSqlTrace -Name $Name -Root $Root
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
    [pscustomobject]@{Computer=$env:COMPUTERNAME;OwnedSessionRemoved=$true;WatchdogRemoved=$true}
}

function Get-SqlCaptureSchema {
    param([string]$Root)
    $ErrorActionPreference = 'Stop'
    $path = Join-Path $Root 'packets.etl'
    $events = @(Get-WinEvent -Path $path -Oldest -MaxEvents 2048)
    $schemas = @($events | Group-Object ProviderName,Id | ForEach-Object {
        $first = $_.Group[0]
        $xml = [xml]$first.ToXml()
        [pscustomobject]@{
            Provider=$first.ProviderName;Id=$first.Id;Count=$_.Count
            Fields=@($xml.Event.EventData.Data | ForEach-Object { [string]$_.Name })
            Shapes=@($first.Properties | ForEach-Object {
                if ($null -eq $_.Value) { 'null' }
                elseif ($_.Value -is [array]) { $_.Value.GetType().Name + ':' + $_.Value.Length }
                else { $_.Value.GetType().Name }
            })
        }
    })
    $guardError = Join-Path $Root 'watchdog-error.txt'
    $watchdogError = if (Test-Path -LiteralPath $guardError) {
        (Get-Content -LiteralPath $guardError -Raw).Trim()
    } else { $null }
    [pscustomobject]@{Root=$Root;Bytes=(Get-Item -LiteralPath $path).Length;Events=$events.Count
        Schemas=$schemas;WatchdogError=$watchdogError}
}
