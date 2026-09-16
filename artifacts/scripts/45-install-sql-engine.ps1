<#
.SYNOPSIS
Installs or verifies only the SQL engine inside a clean, specialized SQL guest.
.DESCRIPTION
Run as the guest's local Administrator, keeping the session open until return.
Requires the verified SQL Server 2025 Enterprise Developer ISO staged locally.
Does not install tools, onboard Arc, schedule tasks, or reboot the guest.
Returns JSON by default; -PassThru returns a structured result for stage 45.
Running this script accepts the development/test-only SQL Server license terms.
https://learn.microsoft.com/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt
https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process#notes
#>
[CmdletBinding()]
param(
    [string]$IsoPath = 'C:\ArcJumpstart\Sql2025\SQLServer2025-x64-ENU-EntDev.iso',
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -notin @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')) {
    throw 'Run this script inside a SQL guest, never on the Hyper-V host.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($identity.Name -ine "$env:COMPUTERNAME\Administrator" -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'An elevated session as the guest local Administrator is required.'
}

function Test-InstalledEngine {
    Add-Type -AssemblyName System.Data
    # Trust the lab's local self-signed certificate for this localhost-only probe.
    $connection = [System.Data.SqlClient.SqlConnection]::new(
        'Data Source=localhost;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15')
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = 30
        $command.CommandText = @"
SET NOCOUNT ON;
SELECT CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) AS Edition,
       CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS ProductVersion,
       CONVERT(int,SERVERPROPERTY('EditionID')) AS EditionId,
       CONVERT(int,SERVERPROPERTY('EngineEdition')) AS EngineEdition,
       CONVERT(int,SERVERPROPERTY('IsIntegratedSecurityOnly')) AS WindowsOnly,
       IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin,
       CONVERT(nvarchar(128),SERVERPROPERTY('ServerName')) AS ServerName,
       1 AS Probe;
"@
        $table = [System.Data.DataTable]::new()
        $reader = $command.ExecuteReader()
        try { $table.Load($reader) } finally { $reader.Dispose() }
        $row = $table.Rows[0]
        if ($row.ProductVersion -notmatch '^17\.' -or $row.EditionId -ne -2117995310 -or $row.EngineEdition -ne 3 -or
            $row.WindowsOnly -ne 1 -or $row.IsSysadmin -ne 1 -or
            $row.ServerName -ine $env:COMPUTERNAME -or $row.Probe -ne 1) {
            throw 'SQL must be 2025 Enterprise Developer, Windows-only, with local Administrator sysadmin and the correct server name.'
        }
        [pscustomobject]@{
            Edition = $row.Edition
            ProductVersion = $row.ProductVersion
            EditionId = $row.EditionId
            WindowsOnly = $row.WindowsOnly
            IsSysadmin = $row.IsSysadmin
            ServerName = $row.ServerName
            Probe = $row.Probe
        }
    }
    finally { $connection.Dispose() }
}

$work = 'C:\ArcJumpstart\Sql2025'
New-Item -ItemType Directory $work -Force | Out-Null
$lock = [IO.File]::Open("$work\engine-install.lock", 'OpenOrCreate', 'ReadWrite', 'None')
$mountedHere = $false
$logs = 'C:\ArcJumpstart\Logs\45-sql-engine\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$result = [ordered]@{ Status = 'Running'; SetupExitCode = $null; Logs = $logs; Engine = $null; Error = '' }
try {
    New-Item -ItemType Directory $logs -Force | Out-Null
    $result | ConvertTo-Json -Depth 4 | Set-Content "$logs\result.json" -Encoding UTF8
    $tasks = @(Get-ScheduledTask -TaskName 'ArcJumpstart-InstallSql*' -ErrorAction SilentlyContinue)
    if ($tasks | Where-Object State -in @('Running', 'Queued')) {
        throw 'A legacy SQL installation task is active or queued. Diagnose it before running another installer.'
    }
    if (Get-Process -Name setup, ScenarioEngine -ErrorAction SilentlyContinue) {
        throw 'Another SQL Setup process is active. No concurrent installation is permitted.'
    }
    $services = @(Get-Service -Name 'MSSQLSERVER', 'MSSQL$*' -ErrorAction SilentlyContinue)
    $instanceKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    $instanceNames = @()
    if (Test-Path $instanceKey) {
        $instanceNames = @((Get-ItemProperty $instanceKey).PSObject.Properties.Name |
            Where-Object { $_ -notlike 'PS*' })
    }
    if ($services.Count -or $instanceNames.Count) {
        if ($services.Count -ne 1 -or $services[0].Name -ne 'MSSQLSERVER' -or
            $instanceNames.Count -ne 1 -or $instanceNames[0] -ne 'MSSQLSERVER') {
            throw 'Existing or partial SQL installation requires diagnosis; automatic repair or replacement is forbidden.'
        }
        $result.Engine = Test-InstalledEngine
        $result.Status = 'VerifiedExisting'
    }
    else {
        if (Get-ChildItem "$env:ProgramFiles\Microsoft SQL Server\MSSQL*" -Directory -ErrorAction SilentlyContinue) {
            throw 'Orphaned SQL instance files exist. Diagnose the partial installation before retrying.'
        }
        foreach ($key in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
            if (Test-Path $key) { throw "Windows requires a reboot before SQL Setup: $key" }
        }
        if ((Get-Item $IsoPath).Length -ne 1265688576 -or
            (Get-FileHash $IsoPath -Algorithm SHA256).Hash -ine 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851') {
            throw 'ISO does not match the verified SQL Server 2025 Enterprise Developer release.'
        }
        if (-not (Get-DiskImage -ImagePath $IsoPath).Attached) {
            Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -Access ReadOnly | Out-Null
            $mountedHere = $true
        }
        $volumes = @(Get-DiskImage -ImagePath $IsoPath | Get-Volume | Where-Object DriveLetter)
        if ($volumes.Count -ne 1) { throw 'SQL media must expose exactly one drive.' }
        $setup = "$($volumes[0].DriveLetter):\setup.exe"
        $signature = Get-AuthenticodeSignature $setup
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
            throw 'SQL Setup must have a valid Microsoft signature.'
        }
        $arguments = '/Q /ACTION=Install /FEATURES=SQLENGINE /INSTANCENAME=MSSQLSERVER /IACCEPTSQLSERVERLICENSETERMS /SUPPRESSPRIVACYSTATEMENTNOTICE /INDICATEPROGRESS /UPDATEENABLED=False /USEMICROSOFTUPDATE=False /SQLSVCSTARTUPTYPE=Automatic /AGTSVCSTARTUPTYPE=Automatic /TCPENABLED=1 /NPENABLED=0 /SQLSVCACCOUNT="NT SERVICE\MSSQLSERVER" /AGTSVCACCOUNT="NT SERVICE\SQLSERVERAGENT" /SQLSYSADMINACCOUNTS="' + $env:COMPUTERNAME + '\Administrator"'
        Write-Host "Starting synchronous SQL Setup on $env:COMPUTERNAME. Logs: $logs"
        $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru `
            -RedirectStandardOutput "$logs\setup.stdout.log" -RedirectStandardError "$logs\setup.stderr.log"
        $result.SetupExitCode = $process.ExitCode
        if ($process.ExitCode -eq 3010) {
            $result.Status = 'RebootRequired'
        }
        elseif ($process.ExitCode -eq 0) {
            $result.Engine = Test-InstalledEngine
            $result.Status = 'InstalledAndVerified'
        }
        else {
            throw "SQL Setup failed with exit code $($process.ExitCode). Read $env:ProgramFiles\Microsoft SQL Server\170\Setup Bootstrap\Log\Summary.txt"
        }
    }
}
catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
    $result['ExceptionType'] = $_.Exception.GetType().FullName
    $result['ScriptStackTrace'] = $_.ScriptStackTrace
    throw
}
finally {
    try { if ($mountedHere) { Dismount-DiskImage -ImagePath $IsoPath | Out-Null } }
    catch { Write-Warning "Could not dismount SQL media: $($_.Exception.Message)" -WarningAction Continue }
    try { $result | ConvertTo-Json -Depth 4 | Set-Content "$logs\result.json" -Encoding UTF8 }
    catch { Write-Warning "Could not save SQL result: $($_.Exception.Message)" -WarningAction Continue }
    try { $lock.Dispose() } catch { }
}
if ($PassThru) { [pscustomobject]$result } else { $result | ConvertTo-Json -Depth 4 }
