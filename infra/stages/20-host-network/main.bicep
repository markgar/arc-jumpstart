metadata description = 'Stage 20 - host networking: internal Hyper-V switch, NAT, and DHCP for the simulated on-premises network.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Address space of the simulated on-premises network behind the host.')
param nestedNetworkPrefix string = '192.168.128.0/24'

@description('Address of the host on the internal switch. Acts as default gateway for the nested guests.')
param nestedGatewayIp string = '192.168.128.1'

@description('First address handed out by DHCP. Keep the low addresses free for static assignments.')
param dhcpRangeStart string = '192.168.128.100'

param dhcpRangeEnd string = '192.168.128.200'

@description('Upstream DNS used before the domain controller exists.')
param bootstrapDnsServer string = '1.1.1.1'

param runId string

module hostNetwork '../../modules/hostRunCommand.bicep' = {
  name: 'stage20-host-network'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage20-host-network'
    scriptContent: loadTextContent('../../../artifacts/scripts/20-host-network.ps1')
    runId: runId
    timeoutInSeconds: 1800
    protectedScriptParameters: {
      items: []
    }
    scriptParameters: [
      {
        name: 'NestedNetworkPrefix'
        value: nestedNetworkPrefix
      }
      {
        name: 'NestedGatewayIp'
        value: nestedGatewayIp
      }
      {
        name: 'DhcpRangeStart'
        value: dhcpRangeStart
      }
      {
        name: 'DhcpRangeEnd'
        value: dhcpRangeEnd
      }
      {
        name: 'BootstrapDnsServer'
        value: bootstrapDnsServer
      }
    ]
  }
}
