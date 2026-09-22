$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../artifacts/scripts/50-configure-domain.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($name in @('Initialize-LabDcServices', 'Initialize-LabAdDnsZones', 'Register-LabDcDns', 'Wait-LabMemberAddress', 'Confirm-LabMemberDomainDiscovery',
    'Wait-LabTcpPort', 'Test-GuestAuthenticationFailure', 'Resolve-LabDcCredential', 'Invoke-GuestWithRetry')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing helper $name." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}
function Get-NetIPAddress {
    param($IPAddress, $AddressFamily, $ErrorAction, $InterfaceIndex)
    if ($PSBoundParameters.ContainsKey('InterfaceIndex')) {
        if ($InterfaceIndex -ne 7 -or $IPAddress -ne '192.168.128.12' -or $AddressFamily -ne 'IPv4') { throw 'Wrong member address query.' }
        $index = [Math]::Min($script:addressReads, $script:addressStates.Count - 1)
        $script:addressReads++
        return [pscustomobject]@{ AddressState = $script:addressStates[$index] }
    }
    if ($IPAddress -ne '192.168.128.10' -or $AddressFamily -ne 'IPv4') { throw 'Wrong DC address.' }
    $script:interfaces
}
function Set-Service {
    param($Name, $StartupType, $ErrorAction)
    if ($Name -notin @('DNS', 'ADWS') -or $StartupType -ne 'Automatic') { throw 'Expected automatic domain services.' }
    $script:automatic += $Name
}
function Start-Service { param($Name, $ErrorAction) $script:started += $Name }
function Set-DnsClientServerAddress {
    param($InterfaceIndex, $ServerAddresses, $ErrorAction)
    if ($InterfaceIndex -ne 7 -or $ServerAddresses -ne '192.168.128.10') { throw 'DC must use its own DNS on the correct interface.' }
    $script:localDns = $true
}
function Set-DnsServerForwarder {
    param($IPAddress, $UseRootHint, $ErrorAction)
    if (-not $script:localDns -or $IPAddress -ne '1.1.1.1' -or -not $UseRootHint) { throw 'External DNS belongs in forwarders, after local resolver configuration.' }
}
function Clear-DnsClientCache { $script:cleared = $true }
$script:interfaces = @([pscustomobject]@{ InterfaceIndex = 7 })
$script:automatic = @()
$script:started = @()
$script:localDns = $false
$script:cleared = $false
Initialize-LabDcServices -Address '192.168.128.10' -Forwarder '1.1.1.1'
if ($script:automatic -notcontains 'ADWS' -or $script:automatic -notcontains 'DNS' -or
    $script:started -notcontains 'DNS' -or -not $script:cleared) { throw 'DC service/bootstrap requirements were not applied.' }
$script:interfaces = @()
Assert-Throws { Initialize-LabDcServices -Address '192.168.128.10' -Forwarder '1.1.1.1' } 'exactly one'

function Get-DnsServerZone {
    param($Name, $ErrorAction)
    if ($Name) { $script:zones | Where-Object ZoneName -eq $Name } else { $script:zones }
}
function Add-DnsServerPrimaryZone {
    param($Name, $ReplicationScope, $DynamicUpdate, $ErrorAction)
    $expectedScope = if ($Name -eq 'jumpstart.lab') { 'Domain' } else { 'Forest' }
    if ($ReplicationScope -ne $expectedScope -or $DynamicUpdate -ne 'Secure') { throw 'Incorrect AD DNS zone settings.' }
    $script:added++
    $script:zones += [pscustomobject]@{ ZoneName = $Name; IsDsIntegrated = $true; ZoneType = 'Primary'; DynamicUpdate = 'Secure' }
}
$script:zones = @()
$script:added = 0
Initialize-LabAdDnsZones -DnsDomain 'jumpstart.lab'
if ($script:added -ne 2) { throw 'Both missing AD zones must be created.' }
Initialize-LabAdDnsZones -DnsDomain 'jumpstart.lab'
if ($script:added -ne 2) { throw 'Existing healthy DNS zones must be retained.' }
$script:zones[0].IsDsIntegrated = $false
Assert-Throws { Initialize-LabAdDnsZones -DnsDomain 'jumpstart.lab' } 'must be AD-integrated'
$script:zones[0].IsDsIntegrated = $true
$script:zones[0].DynamicUpdate = 'NonsecureAndSecure'
Assert-Throws { Initialize-LabAdDnsZones -DnsDomain 'jumpstart.lab' } 'secure-update-only'

$savedComputerName = $env:COMPUTERNAME
$env:COMPUTERNAME = 'JS-DC-01'
function Get-SmbShare { param($ErrorAction) $script:shares | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
function Get-DnsServerResourceRecord {
    param($ZoneName, $ErrorAction)
    if ($ZoneName -ne '_msdcs.jumpstart.lab') { throw 'Wrong DC discovery zone.' }
    if ($script:recordReadFails) { throw 'DNS record read failed.' }
    $script:records
}
function Restart-Service {
    param($Name, $ErrorAction)
    if ($Name -ne 'Netlogon' -or -not $script:cleared) { throw 'Netlogon restart must follow DNS cache clearing.' }
    $script:netlogonRestarts++
}
function Register-DnsClient { param($ErrorAction) $script:clientRegistrations++ }
function nltest.exe {
    param($Action)
    if ($Action -eq '/dsgetdc:jumpstart.lab') {
        if ($args -notcontains '/force' -or -not $script:cleared) { throw 'Member discovery must clear DNS cache and force DC rediscovery.' }
        $script:locatorCalls++
        $global:LASTEXITCODE = $script:locatorExitCode
        'DC locator result.'
        return
    }
    if ($Action -ne '/dsregdns') { throw 'Expected DC DNS registration.' }
    $global:LASTEXITCODE = $script:registrationExitCode
    'Registration requested.'
}
try {
    $script:shares = @('SYSVOL', 'NETLOGON')
    $script:records = @()
    $script:recordReadFails = $false
    $script:netlogonRestarts = 0
    $script:clientRegistrations = 0
    $script:registrationExitCode = 0
    $script:cleared = $false
    Register-LabDcDns -DnsDomain jumpstart.lab
    if ($script:netlogonRestarts -ne 1 -or $script:clientRegistrations -ne 1) { throw 'Missing SRV must refresh Netlogon and client registrations.' }
    $script:records = @([pscustomobject]@{
        HostName = '_ldap._tcp.dc'; RecordType = 'SRV'
        RecordData = [pscustomobject]@{ DomainName = 'JS-DC-01.jumpstart.lab.'; Port = 389 }
    })
    Register-LabDcDns -DnsDomain jumpstart.lab
    if ($script:netlogonRestarts -ne 1) { throw 'A healthy existing DC record must not restart Netlogon.' }
    $script:registrationExitCode = 5
    Assert-Throws { Register-LabDcDns -DnsDomain jumpstart.lab } 'Registering domain-controller DNS records failed'
    $script:registrationExitCode = 0
    $script:recordReadFails = $true
    Assert-Throws { Register-LabDcDns -DnsDomain jumpstart.lab } 'DNS record read failed'
    $script:recordReadFails = $false
    $script:shares = @('SYSVOL')
    Assert-Throws { Register-LabDcDns -DnsDomain jumpstart.lab -ShareTimeoutSeconds 0 } 'SYSVOL and NETLOGON shares are not ready'
    if ($script:netlogonRestarts -ne 1) { throw 'Failed prerequisites must not restart Netlogon.' }
} finally {
    $env:COMPUTERNAME = $savedComputerName
}

$source = $ast.Extent.Text
function Start-Sleep { param($Seconds) $script:addressWaits++ }
$script:addressReads = 0
$script:addressWaits = 0
$script:addressStates = @('Tentative', 'Preferred')
Wait-LabMemberAddress -InterfaceIndex 7 -Address '192.168.128.12'
if ($script:addressWaits -ne 1 -or $script:addressReads -ne 2) { throw 'A tentative member address must become Preferred before continuing.' }
$script:addressReads = 0
$script:addressStates = @('Preferred')
Wait-LabMemberAddress -InterfaceIndex 7 -Address '192.168.128.12'
if ($script:addressWaits -ne 1) { throw 'An existing usable member address must not wait.' }
foreach ($state in 'Duplicate', 'Invalid', 'Deprecated') {
    $script:addressReads = 0
    $script:addressStates = @($state)
    Assert-Throws { Wait-LabMemberAddress -InterfaceIndex 7 -Address '192.168.128.12' } 'not usable'
}
$script:addressReads = 0
$script:addressStates = @('Tentative')
Assert-Throws { Wait-LabMemberAddress -InterfaceIndex 7 -Address '192.168.128.12' -TimeoutSeconds 0 } 'remained Tentative'
if ($source.IndexOf('Wait-LabMemberAddress -InterfaceIndex') -gt $source.IndexOf('Confirm-LabMemberDomainDiscovery -DnsDomain')) {
    throw 'Member address readiness must precede DC discovery.'
}
$script:locatorCalls = 0
$script:locatorExitCode = 0
$script:cleared = $false
Confirm-LabMemberDomainDiscovery -DnsDomain jumpstart.lab
if ($script:locatorCalls -ne 1) { throw 'Member readiness must execute DC discovery.' }
$script:locatorExitCode = 1355
Assert-Throws { Confirm-LabMemberDomainDiscovery -DnsDomain jumpstart.lab } 'Domain join was not attempted'
if ($script:locatorCalls -ne 2) { throw 'Failed member discovery must fail explicitly without hidden retries.' }
if ($source.IndexOf('Confirm-LabMemberDomainDiscovery -DnsDomain') -gt $source.IndexOf('Add-Computer -DomainName')) {
    throw 'Member DC discovery must precede domain join.'
}
if ($source.IndexOf('Initialize-LabDcServices -Address') -gt $source.IndexOf('Install-ADDSForest') -or
    $source.IndexOf('Start-Service ADWS') -gt $source.IndexOf('Get-ADDomain -Server localhost') -or
    $source.IndexOf('Initialize-LabAdDnsZones -DnsDomain') -gt $source.IndexOf('Get-ADDomain -Identity $ExpectedDomain')) {
    throw 'DNS/service bootstrap must precede promotion and discovery-based AD queries.'
}
if ($source -notmatch "New-NetFirewallRule[\s\S]+-LocalPort 1433[\s\S]+-RemoteAddress [`$]NestedSubnetCidr" -or
    $source -notmatch 'Wait-LabTcpPort -Address [`$]memberAddresses\[[`$]memberName\] -Port 1433') {
    throw 'Every SQL member must allow TCP 1433 only from the nested subnet and prove host reachability.'
}

$password = ConvertTo-SecureString 'test-only-password' -AsPlainText -Force
$domainCredential = [pscredential]::new('JUMPSTART\Administrator', $password)
$localCredential = [pscredential]::new('JS-DC-01\Administrator', $password)
function Invoke-Command {
    param($VMName, $Credential, $ScriptBlock, $ArgumentList, $ErrorAction)
    $script:attempts += $Credential.UserName
    if ($script:transportFails) { throw 'transport unavailable' }
    if ($Credential.UserName -notin $script:validUsers) { throw 'The credential is invalid.' }
    [pscustomobject]@{ Domain = $script:actualDomain; DomainRole = $script:domainRole }
}
$resolve = {
    Resolve-LabDcCredential -VMName JS-DC-01 -ExpectedDomain jumpstart.lab `
        -DomainCredential $domainCredential -LocalCredential $localCredential
}
$script:transportFails = $false
$script:actualDomain = 'jumpstart.lab'
$script:domainRole = 5
$script:validUsers = @('JUMPSTART\Administrator')
$script:attempts = @()
if ((& $resolve).UserName -ne 'JUMPSTART\Administrator' -or $script:attempts.Count -ne 1) {
    throw 'Promoted DC must use qualified domain credentials without local-account retries.'
}
$script:validUsers = @('JS-DC-01\Administrator')
$script:domainRole = 2
$script:actualDomain = 'WORKGROUP'
$script:attempts = @()
if ((& $resolve).UserName -ne 'JS-DC-01\Administrator' -or $script:attempts.Count -ne 2) {
    throw 'Fresh DC must fall back once to qualified local credentials.'
}
$script:validUsers = @()
$script:attempts = @()
Assert-Throws $resolve 'Neither qualified'
if ($script:attempts.Count -ne 2) { throw 'Credential selection must be bounded to two candidates.' }
$script:attempts = @()
Assert-Throws { Invoke-GuestWithRetry -VMName JS-DC-01 -Credential $domainCredential -ScriptBlock {} } 'not retrying invalid credentials'
if ($script:attempts.Count -ne 1) { throw 'Invalid credentials must not enter the transport retry loop.' }
$script:transportFails = $true
Assert-Throws $resolve 'transport unavailable'
$script:transportFails = $false
$script:validUsers = @('JUMPSTART\Administrator')
$script:domainRole = 5
$script:actualDomain = 'different.lab'
Assert-Throws $resolve 'different domain'
Write-Output 'Stage 50 DC services, DNS bootstrap, credential selection, and rerun checks passed.'
