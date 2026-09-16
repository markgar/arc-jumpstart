[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DomainName,

    [Parameter(Mandatory)]
    [string]$DomainNetbiosName,

    [Parameter(Mandatory)]
    [string]$DcStaticIp,

    [Parameter(Mandatory)]
    [string]$UpstreamDnsServer,

    [Parameter(Mandatory)]
    [string]$StandaloneSqlStaticIp,

    [Parameter(Mandatory)]
    [string]$AgNode1StaticIp,

    [Parameter(Mandatory)]
    [string]$AgNode2StaticIp,

    [Parameter(Mandatory)]
    [string]$NestedGatewayIp,

    [Parameter(Mandatory)]
    [string]$DhcpScopeId,

    [Parameter(Mandatory)]
    [string]$SqlServiceAccountName,

    [Parameter(Mandatory)]
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [string]$SafeModePassword,

    [Parameter(Mandatory)]
    [string]$SqlServiceAccountPassword,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "50-configure-domain-$RunId.log") -Force

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

function Test-GuestAuthenticationFailure {
    param([System.Management.Automation.ErrorRecord]$Failure)
    return $Failure.FullyQualifiedErrorId -match 'InvalidCredential|Authentication' -or
        $Failure.Exception.Message -like '*credential is invalid*'
}

function Resolve-LabDcCredential {
    param(
        [string]$VMName,
        [string]$ExpectedDomain,
        [pscredential]$DomainCredential,
        [pscredential]$LocalCredential
    )
    foreach ($candidate in @($DomainCredential, $LocalCredential)) {
        try {
            Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage50] Starting domain, DNS, member join, and SQL access configuration."
            $system = Invoke-Command -VMName $VMName -Credential $candidate -ErrorAction Stop -ScriptBlock {
                Get-CimInstance Win32_ComputerSystem | Select-Object Domain, DomainRole
            }
        }
        catch {
            if (-not (Test-GuestAuthenticationFailure $_)) { throw }
            continue
        }
        if ($system.DomainRole -ge 4 -and $system.Domain -ine $ExpectedDomain) {
            throw 'The existing domain controller belongs to a different domain.'
        }
        return $candidate
    }
    throw "Neither qualified domain nor local Administrator credentials could authenticate to $VMName."
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
            if (Test-GuestAuthenticationFailure $_) {
                throw "Authentication failed on $VMName for $($Credential.UserName); not retrying invalid credentials."
            }
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

try {
    $dcName = 'JS-DC-01'
    $memberNames = @('JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')
    $localCredential = New-PlainTextCredential -Username "$dcName\Administrator" -Password $NestedWindowsPassword
    $domainCredential = New-PlainTextCredential `
        -Username "$DomainNetbiosName\Administrator" `
        -Password $NestedWindowsPassword

    Wait-VMHeartbeat -VMName $dcName
    $dcCredential = Resolve-LabDcCredential -VMName $dcName -ExpectedDomain $DomainName `
        -DomainCredential $domainCredential -LocalCredential $localCredential
    Write-Host 'Preparing domain-controller roles, internal DNS, and service startup.'
    $featureRestart = Invoke-GuestWithRetry -VMName $dcName -Credential $dcCredential `
        -ArgumentList $DcStaticIp, $UpstreamDnsServer -ScriptBlock {
            param($DcIp, $DnsForwarder)
            $features = Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
            if (-not $features.Success) { throw 'Installing AD DS and DNS roles failed.' }
            function Initialize-LabDcServices {
                param([string]$Address, [string]$Forwarder)
                $interfaces = @(Get-NetIPAddress -IPAddress $Address -AddressFamily IPv4 -ErrorAction Stop)
                if ($interfaces.Count -ne 1) { throw 'Expected exactly one interface with the domain controller static IP.' }
                Set-Service DNS -StartupType Automatic -ErrorAction Stop
                Start-Service DNS -ErrorAction Stop
                Set-Service ADWS -StartupType Automatic -ErrorAction Stop
                Set-DnsClientServerAddress -InterfaceIndex $interfaces[0].InterfaceIndex -ServerAddresses $Address -ErrorAction Stop
                Set-DnsServerForwarder -IPAddress $Forwarder -UseRootHint $true -ErrorAction Stop
                Clear-DnsClientCache
            }
            Initialize-LabDcServices -Address $DcIp -Forwarder $DnsForwarder
            return $features.RestartNeeded -eq 'Yes'
        }
    if ($featureRestart) {
        Restart-VM -Name $dcName -Force
        Wait-VMHeartbeat -VMName $dcName -TimeoutSeconds 1200
    }
    $needsPromotion = Invoke-GuestWithRetry -VMName $dcName -Credential $dcCredential -ScriptBlock {
        (Get-CimInstance Win32_ComputerSystem).DomainRole -lt 4
    }

    if ($needsPromotion) {
        Write-Host "Promoting $dcName into the $DomainName forest."
        Invoke-GuestWithRetry `
            -VMName $dcName `
            -Credential $dcCredential `
            -ArgumentList $DomainName, $DomainNetbiosName, $SafeModePassword `
            -ScriptBlock {
                param($ForestName, $NetbiosName, $RestorePassword)
                Import-Module ADDSDeployment
                Install-ADDSForest `
                    -DomainName $ForestName `
                    -DomainNetbiosName $NetbiosName `
                    -ForestMode WinThreshold `
                    -DomainMode WinThreshold `
                    -InstallDns `
                    -SafeModeAdministratorPassword (ConvertTo-SecureString $RestorePassword -AsPlainText -Force) `
                    -NoRebootOnCompletion `
                    -Force
            }

        Restart-VM -Name $dcName -Force
        Wait-VMHeartbeat -VMName $dcName -TimeoutSeconds 1200
    }

    Write-Host 'Verifying local ADWS, AD-integrated DNS zones, and domain discovery.'
    Invoke-GuestWithRetry `
        -VMName $dcName `
        -Credential $domainCredential `
        -ArgumentList $SqlServiceAccountName, $SqlServiceAccountPassword, $DomainName, $DcStaticIp `
        -TimeoutSeconds 1200 `
        -ScriptBlock {
            param($ServiceAccountName, $ServiceAccountPassword, $ExpectedDomain, $DnsAddress)
            Set-Service ADWS -StartupType Automatic -ErrorAction Stop
            Start-Service ADWS -ErrorAction Stop
            # The local endpoint avoids depending on DNS discovery while bootstrapping DNS.
            Import-Module ActiveDirectory -WarningAction SilentlyContinue
            $domain = $null
            $deadline = (Get-Date).AddMinutes(2)
            do {
                try {
                    $domain = Get-ADDomain -Server localhost -ErrorAction Stop
                    break
                }
                catch {
                    $lastFailure = $_.Exception.Message
                    Start-Sleep -Seconds 10
                }
            } while ((Get-Date) -lt $deadline)
            if (-not $domain) {
                throw "Local ADWS did not become ready within two minutes: $lastFailure"
            }
            if ($domain.DNSRoot -ine $ExpectedDomain -or $domain.Forest -ine $ExpectedDomain) {
                throw 'Existing domain/forest does not match the intended single-domain lab. No DNS zones will be changed.'
            }
            function Initialize-LabAdDnsZones {
                param([string]$DnsDomain)
                foreach ($definition in @(
                    @{ Name = $DnsDomain; Scope = 'Domain' },
                    @{ Name = "_msdcs.$DnsDomain"; Scope = 'Forest' })) {
                    $zone = Get-DnsServerZone -ErrorAction Stop |
                        Where-Object ZoneName -eq $definition.Name
                    if (-not $zone) {
                        Write-Host "Creating missing AD-integrated DNS zone $($definition.Name)."
                        Add-DnsServerPrimaryZone -Name $definition.Name -ReplicationScope $definition.Scope `
                            -DynamicUpdate Secure -ErrorAction Stop
                        $zone = Get-DnsServerZone -Name $definition.Name -ErrorAction Stop
                    }
                    if (-not $zone.IsDsIntegrated -or $zone.ZoneType -ne 'Primary' -or $zone.DynamicUpdate -ne 'Secure') {
                        throw "DNS zone $($definition.Name) must be AD-integrated, primary, and secure-update-only."
                    }
                }
            }
            Initialize-LabAdDnsZones -DnsDomain $ExpectedDomain
            function Register-LabDcDns {
                param([string]$DnsDomain, [int]$ShareTimeoutSeconds = 120)
                $shareDeadline = (Get-Date).AddSeconds($ShareTimeoutSeconds)
                do {
                    $shares = @(Get-SmbShare -ErrorAction Stop | Select-Object -ExpandProperty Name)
                    if ($shares -contains 'SYSVOL' -and $shares -contains 'NETLOGON') { break }
                    if ((Get-Date) -ge $shareDeadline) {
                        throw 'SYSVOL and NETLOGON shares are not ready. Inspect DFS Replication events; do not force SysvolReady.'
                    }
                    Start-Sleep -Seconds 5
                } while ($true)
                $dcRecord = Get-DnsServerResourceRecord -ZoneName "_msdcs.$DnsDomain" -ErrorAction Stop |
                    Where-Object {
                        $_.HostName -ieq '_ldap._tcp.dc' -and $_.RecordType -eq 'SRV' -and
                        $_.RecordData.DomainName.TrimEnd('.') -ieq "$env:COMPUTERNAME.$DnsDomain" -and
                        $_.RecordData.Port -eq 389
                    }
                Clear-DnsClientCache
                if (-not $dcRecord) {
                    # A previously failed Netlogon registration can remain pending after DNS is repaired.
                    Write-Host 'LDAP SRV record is missing; restarting Netlogon to register against the repaired DNS zones.'
                    Restart-Service Netlogon -ErrorAction Stop
                }
                Register-DnsClient -ErrorAction Stop
                $registration = & nltest.exe /dsregdns 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Registering domain-controller DNS records failed: $($registration -join ' ')"
                }
            }
            Register-LabDcDns -DnsDomain $ExpectedDomain
            $deadline = (Get-Date).AddMinutes(2)
            $discoveryReady = $false
            do {
                try {
                    $records = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$ExpectedDomain" -Type SRV `
                        -Server $DnsAddress -ErrorAction Stop)
                    if (-not ($records | Where-Object { $_.NameTarget -ieq "$env:COMPUTERNAME.$ExpectedDomain" -and $_.Port -eq 389 })) {
                        throw 'The LDAP SRV record does not identify this domain controller.'
                    }
                    $null = Get-ADDomain -Identity $ExpectedDomain -ErrorAction Stop
                    $discoveryReady = $true
                    break
                }
                catch {
                    $lastFailure = $_.Exception.Message
                    Start-Sleep -Seconds 10
                }
            } while ((Get-Date) -lt $deadline)
            if (-not $discoveryReady) { throw "Domain DNS discovery failed: $lastFailure" }
            Write-Host "ADWS and DNS discovery verified for $ExpectedDomain."

            if (-not (Get-ADUser -Filter "SamAccountName -eq '$ServiceAccountName'")) {
                New-ADUser `
                    -Name 'SQL Server service' `
                    -SamAccountName $ServiceAccountName `
                    -UserPrincipalName "$ServiceAccountName@$($domain.DNSRoot)" `
                    -AccountPassword (ConvertTo-SecureString $ServiceAccountPassword -AsPlainText -Force) `
                    -Enabled $true `
                    -PasswordNeverExpires $true
            }
        }

    Set-DhcpServerv4OptionValue -ScopeId $DhcpScopeId -DnsServer $DcStaticIp -DnsDomain $DomainName -Force
    Restart-Service DHCPServer

    $memberAddresses = @{
        'JS-SQL-01' = $StandaloneSqlStaticIp
        'JS-SQL-AG-01' = $AgNode1StaticIp
        'JS-SQL-AG-02' = $AgNode2StaticIp
    }

    foreach ($memberName in $memberNames) {
        Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage50] Configuring domain membership and SQL access on $memberName."
        $memberCredential = New-PlainTextCredential -Username "$memberName\Administrator" -Password $NestedWindowsPassword
        Wait-VMHeartbeat -VMName $memberName
        $joinRequired = Invoke-GuestWithRetry `
            -VMName $memberName `
            -Credential $memberCredential `
            -ArgumentList $DomainName, $DcStaticIp, $DomainNetbiosName, $NestedWindowsPassword, $memberAddresses[$memberName], $NestedGatewayIp `
            -ScriptBlock {
                param($TargetDomain, $DnsServer, $TargetNetbiosName, $DomainAdminPassword, $StaticIp, $Gateway)
                $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                $currentAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object IPAddress -eq $StaticIp
                if (-not $currentAddress) {
                    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
                    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                    Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -IPAddress $StaticIp `
                        -PrefixLength 24 `
                        -DefaultGateway $Gateway | Out-Null
                }
                function Wait-LabMemberAddress {
                    param([int]$InterfaceIndex, [string]$Address, [int]$TimeoutSeconds = 30)
                    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                    do {
                        $addresses = @(Get-NetIPAddress -InterfaceIndex $InterfaceIndex -IPAddress $Address `
                            -AddressFamily IPv4 -ErrorAction Stop)
                        if ($addresses.Count -ne 1) { throw "Expected exactly one configured member address $Address." }
                        $state = [string]$addresses[0].AddressState
                        if ($state -eq 'Preferred') { return }
                        if ($state -ne 'Tentative') { throw "Member address $Address is not usable (state: $state). Check for address conflicts." }
                        if ((Get-Date) -ge $deadline) { throw "Member address $Address remained Tentative for $TimeoutSeconds seconds." }
                        Write-Host "Waiting for member address $Address to finish duplicate-address detection."
                        Start-Sleep -Seconds 1
                    } while ($true)
                }
                Wait-LabMemberAddress -InterfaceIndex $adapter.ifIndex -Address $StaticIp
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServer
                if ((Get-CimInstance Win32_ComputerSystem).Domain -ne $TargetDomain) {
                    function Confirm-LabMemberDomainDiscovery {
                        param([string]$DnsDomain)
                        Clear-DnsClientCache -ErrorAction Stop
                        $discovery = & nltest.exe "/dsgetdc:$DnsDomain" /force 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Member cannot discover $DnsDomain after configuring DNS. Domain join was not attempted: $($discovery -join ' ')"
                        }
                        Write-Host "Member DC discovery verified for $DnsDomain."
                    }
                    Confirm-LabMemberDomainDiscovery -DnsDomain $TargetDomain
                    $joinCredential = [pscredential]::new(
                        "$TargetNetbiosName\Administrator",
                        (ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force)
                    )
                    Add-Computer -DomainName $TargetDomain -Credential $JoinCredential -Force
                    return $true
                }
                return $false
            }

        if ($joinRequired) {
            Restart-VM -Name $memberName -Force
            Wait-VMHeartbeat -VMName $memberName
        }

        Invoke-GuestWithRetry `
            -VMName $memberName `
            -Credential $memberCredential `
            -ArgumentList $DomainNetbiosName, $memberName `
            -ScriptBlock {
                param($TargetNetbiosName, $ExpectedServerName)
                $sqlcmd = (Get-Command sqlcmd.exe -ErrorAction Stop).Source
                $deadline = (Get-Date).AddMinutes(10)
                $sqlReady = $false
                do {
                    $service = Get-Service MSSQLSERVER -ErrorAction SilentlyContinue
                    if ($service.Status -eq 'Running') {
                        & $sqlcmd -S localhost -E -b -C -Q 'SELECT 1;' *> $null
                        if ($LASTEXITCODE -eq 0) {
                            $sqlReady = $true
                            break
                        }
                    }
                    Start-Sleep -Seconds 10
                } while ((Get-Date) -lt $deadline)
                if (-not $sqlReady) {
                    throw 'SQL Server did not become ready within 10 minutes.'
                }

                $domainAdmins = "$TargetNetbiosName\Domain Admins"
                $escapedDomainAdmins = $domainAdmins.Replace(']', ']]')
                $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$domainAdmins')
    CREATE LOGIN [$escapedDomainAdmins] FROM WINDOWS;
IF IS_SRVROLEMEMBER(N'sysadmin', N'$domainAdmins') <> 1
    ALTER SERVER ROLE sysadmin ADD MEMBER [$escapedDomainAdmins];
"@
                & $sqlcmd -S localhost -E -b -C -Q $query
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to grant SQL sysadmin to $domainAdmins."
                }

                $nameOutput = & $sqlcmd -S localhost -E -b -C -h -1 -W -Q 'SET NOCOUNT ON; SELECT name FROM sys.servers WHERE server_id = 0;' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to read SQL Server's local server name: $(($nameOutput -join [Environment]::NewLine).Trim())"
                }
                $reportedName = ($nameOutput -join '').Trim()
                if ($reportedName -ne $ExpectedServerName) {
                    $newName = $ExpectedServerName.Replace("'", "''")
                    $renameQuery = if ([string]::IsNullOrWhiteSpace($reportedName) -or $reportedName -eq 'NULL') {
                        "EXEC master.dbo.sp_addserver N'$newName', N'local';"
                    }
                    else {
                        $oldName = $reportedName.Replace("'", "''")
                        "EXEC master.dbo.sp_dropserver N'$oldName'; EXEC master.dbo.sp_addserver N'$newName', N'local';"
                    }
                    & $sqlcmd -S localhost -E -b -C -Q $renameQuery
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to update SQL Server's local name to $ExpectedServerName."
                    }
                    Restart-Service MSSQLSERVER -Force
                }
            }
    }

    Invoke-GuestWithRetry -VMName $dcName -Credential $domainCredential -ScriptBlock {
        Get-ADComputer -Filter 'Name -like "JS-*"' |
            Select-Object Name, DNSHostName, Enabled |
            Format-Table -AutoSize
    }
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage50] Domain, DNS, member trust, and domain-admin SQL access checks completed."
}
finally {
    Stop-Transcript
}
