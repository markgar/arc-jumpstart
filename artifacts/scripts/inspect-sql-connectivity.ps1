param([Parameter(Mandatory)][string]$NestedWindowsPassword, [string]$RunId)
$ErrorActionPreference = 'Stop'
$credential = [pscredential]::new('JS-SQL-01\Administrator',
    (ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force))
$NestedWindowsPassword = $null
$guest = Invoke-Command -VMName JS-SQL-01 -Credential $credential -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $service = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'"
    $instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
    $parameters = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer\Parameters"
    $logPath = @($parameters.PSObject.Properties | Where-Object { $_.Name -like 'SQLArg*' -and $_.Value -like '-e*' })[0].Value.Substring(2)
    $log = @(Get-Content -LiteralPath $logPath -Tail 160 |
        Where-Object { $_ -match '(?i)error:|failed|certificate|TLS|SSL|listening on|ready for client' } |
        Select-Object -Last 8 | ForEach-Object { $_.Substring(0, [math]::Min(230, $_.Length)) })
    $schannel = try {
        @(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Schannel';StartTime=(Get-Date).AddMinutes(-45)} -MaxEvents 3 -ErrorAction Stop |
            ForEach-Object { @{Id=$_.Id;At=$_.TimeCreated.ToUniversalTime().ToString('o');Message=$_.Message.Substring(0,[math]::Min(250,$_.Message.Length))} })
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
        @()
    }
    $sql = [Data.SqlClient.SqlConnection]::new('Server=lpc:localhost;Integrated Security=true;Encrypt=false;Connect Timeout=5')
    try {
        $sql.Open()
        $command = $sql.CreateCommand()
        $command.CommandTimeout = 5
        $command.CommandText = 'SELECT CONVERT(nvarchar(128),SERVERPROPERTY(''ServerName''))'
        $localSql = @{Connected=$true;Server=[string]$command.ExecuteScalar()}
    }
    catch [Data.SqlClient.SqlException] {
        $localSql = @{Connected=$false;Number=$_.Exception.Number;Message=$_.Exception.Message}
    }
    finally { $sql.Dispose() }
    $tcpSql = [Data.SqlClient.SqlConnection]::new('Server=tcp:127.0.0.1,1433;Integrated Security=true;Encrypt=true;TrustServerCertificate=true;Connect Timeout=5')
    try { $tcpSql.Open(); $loopback = @{Connected=$true} }
    catch [Data.SqlClient.SqlException] { $loopback = @{Connected=$false;Number=$_.Exception.Number;Message=$_.Exception.Message} }
    finally { $tcpSql.Dispose() }
    [pscustomobject]@{
        Computer=$env:COMPUTERNAME;Domain=(Get-CimInstance Win32_ComputerSystem).Domain
        SqlState=$service.State;SqlIdentity=$service.StartName;SqlPid=$service.ProcessId
        Listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -eq 1433 | Select-Object LocalAddress,OwningProcess)
        LocalSql=$localSql;EncryptedLoopbackSql=$loopback;SqlLog=$log;Schannel=$schannel
    }
}
$hostSql = foreach ($encrypt in @('true','false')) {
    $connection = [Data.SqlClient.SqlConnection]::new("Server=tcp:192.168.128.11,1433;Integrated Security=true;Encrypt=$encrypt;TrustServerCertificate=true;Connect Timeout=6;Pooling=false")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { $connection.Open(); @{Encrypt=$encrypt;Connected=$true;Seconds=$watch.Elapsed.TotalSeconds} }
    catch [Data.SqlClient.SqlException] { @{Encrypt=$encrypt;Connected=$false;Number=$_.Exception.Number;Seconds=[math]::Round($watch.Elapsed.TotalSeconds,1);Message=$_.Exception.Message} }
    finally { $connection.Dispose() }
}
[ordered]@{
    At=[datetime]::UtcNow.ToString('o')
    DomainController=@(Get-VM JS-DC-01 | Select-Object Name,@{n='State';e={[string]$_.State}})
    Guest=$guest | Select-Object Computer,Domain,SqlState,SqlIdentity,SqlPid,Listeners,LocalSql,EncryptedLoopbackSql,SqlLog,Schannel
    HostSql=@($hostSql)
    Switches=@(Get-VMSwitch | Select-Object Name,SwitchType,SoftwareRscEnabled)
} | ConvertTo-Json -Depth 7 -Compress
Write-Output 'SQL_GUEST_DIAGNOSTICS_COMPLETED'
