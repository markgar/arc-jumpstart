[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NestedNetworkPrefix,

    [Parameter(Mandatory)]
    [string]$NestedGatewayIp,

    [Parameter(Mandatory)]
    [string]$DhcpRangeStart,

    [Parameter(Mandatory)]
    [string]$DhcpRangeEnd,

    [Parameter(Mandatory)]
    [string]$BootstrapDnsServer,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$root = 'C:\ArcJumpstart'
$logRoot = Join-Path $root 'Logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
Start-Transcript -Path (Join-Path $logRoot "20-host-network-$RunId.log") -Force

function Enable-HyperVEnhancedSessionMode {
    Set-VMHost -EnableEnhancedSessionMode $true
    if (-not (Get-VMHost).EnableEnhancedSessionMode) {
        throw 'Hyper-V Enhanced Session Mode policy did not remain enabled.'
    }
}

try {
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage20] Configuring Hyper-V services, internal switch, NAT, and DHCP."
    if ($NestedNetworkPrefix -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\.0/24$') {
        throw 'This lab currently supports only a /24 nested network prefix.'
    }

    if ((Get-WindowsFeature Hyper-V).InstallState -ne 'Installed') {
        throw 'Hyper-V is not installed. Run stage 10 and wait for the host restart before retrying.'
    }
    if (-not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
        throw 'The Hyper-V hypervisor is not active. Restart the host after stage 10 and confirm the Azure VM size supports nested virtualization.'
    }

    Set-Service -Name vmms -StartupType Automatic
    Start-Service -Name vmms
    Enable-HyperVEnhancedSessionMode
    Set-Service -Name DHCPServer -StartupType Automatic
    Start-Service -Name DHCPServer

    if (-not (Get-VMSwitch -Name 'ArcJumpstartInternal' -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name 'ArcJumpstartInternal' -SwitchType Internal | Out-Null
    }

    $adapter = $null
    for ($attempt = 1; $attempt -le 30 -and -not $adapter; $attempt++) {
        $adapter = Get-NetAdapter -Name 'vEthernet (ArcJumpstartInternal)' -ErrorAction SilentlyContinue
        if (-not $adapter) {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $adapter) {
        throw 'The internal Hyper-V switch adapter did not appear within 60 seconds.'
    }
    $existingAddress = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -eq $NestedGatewayIp
    if (-not $existingAddress) {
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $NestedGatewayIp -PrefixLength 24 | Out-Null
    }

    $nat = Get-NetNat -Name 'ArcJumpstartNat' -ErrorAction SilentlyContinue
    if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $NestedNetworkPrefix) {
        Remove-NetNat -Name 'ArcJumpstartNat' -Confirm:$false
        $nat = $null
    }
    if (-not $nat) {
        New-NetNat -Name 'ArcJumpstartNat' -InternalIPInterfaceAddressPrefix $NestedNetworkPrefix | Out-Null
    }
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage20] Internal switch and NAT are ready; configuring DHCP scope and options."

    $scopeId = ($NestedNetworkPrefix -split '/')[0]
    $scope = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
    if (-not $scope) {
        Add-DhcpServerv4Scope `
            -Name 'Arc Jumpstart nested network' `
            -StartRange $DhcpRangeStart `
            -EndRange $DhcpRangeEnd `
            -SubnetMask '255.255.255.0' `
            -LeaseDuration 1.00:00:00 `
            -State Active
    }
    else {
        if ($scope.SubnetMask.IPAddressToString -ne '255.255.255.0') {
            throw "Existing DHCP scope $scopeId has subnet mask $($scope.SubnetMask), but this lab requires 255.255.255.0."
        }
        Set-DhcpServerv4Scope `
            -ScopeId $scopeId `
            -StartRange $DhcpRangeStart `
            -EndRange $DhcpRangeEnd `
            -LeaseDuration 1.00:00:00 `
            -State Active
    }
    Set-DhcpServerv4OptionValue `
        -ScopeId $scopeId `
        -Router $NestedGatewayIp `
        -DnsServer $BootstrapDnsServer `
        -Force

    Restart-Service DHCPServer
    Write-Host "$([DateTime]::UtcNow.ToString('o')) [stage20] Nested network $NestedNetworkPrefix is ready behind gateway $NestedGatewayIp."
}
finally {
    Stop-Transcript
}
