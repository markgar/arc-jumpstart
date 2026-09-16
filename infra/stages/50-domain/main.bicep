metadata description = 'Stage 50 - Active Directory: promotes the domain controller and joins the Windows guests to the domain.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Fully qualified Active Directory domain name.')
param domainName string = 'jumpstart.lab'

@description('NetBIOS name of the domain.')
@maxLength(15)
param domainNetbiosName string = 'JUMPSTART'

param dcStaticIp string = '192.168.128.10'

param standaloneSqlStaticIp string = '192.168.128.11'

param agNode1StaticIp string = '192.168.128.12'

param agNode2StaticIp string = '192.168.128.13'

param nestedGatewayIp string = '192.168.128.1'

param dhcpScopeId string = '192.168.128.0'

@description('DNS forwarder configured on the lab domain controller.')
param upstreamDnsServer string = '1.1.1.1'

@description('Domain account used to run the SQL Server service on the availability group nodes.')
param sqlServiceAccountName string = 'svc-sql'

@secure()
@description('Local administrator password baked into the prebuilt VHDX images.')
param nestedWindowsPassword string

@secure()
@description('Directory Services Restore Mode password for the new forest.')
param safeModePassword string

@secure()
@description('Password assigned to the SQL Server service account.')
param sqlServiceAccountPassword string

param runId string

module domain '../../modules/hostRunCommand.bicep' = {
  name: 'stage50-domain'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage50-domain'
    scriptContent: loadTextContent('../../../artifacts/scripts/50-configure-domain.ps1')
    runId: runId
    timeoutInSeconds: 5400
    scriptParameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'DomainNetbiosName'
        value: domainNetbiosName
      }
      {
        name: 'DcStaticIp'
        value: dcStaticIp
      }
      {
        name: 'UpstreamDnsServer'
        value: upstreamDnsServer
      }
      {
        name: 'StandaloneSqlStaticIp'
        value: standaloneSqlStaticIp
      }
      {
        name: 'AgNode1StaticIp'
        value: agNode1StaticIp
      }
      {
        name: 'AgNode2StaticIp'
        value: agNode2StaticIp
      }
      {
        name: 'NestedGatewayIp'
        value: nestedGatewayIp
      }
      {
        name: 'DhcpScopeId'
        value: dhcpScopeId
      }
      {
        name: 'SqlServiceAccountName'
        value: sqlServiceAccountName
      }
    ]
    protectedScriptParameters: {
      items: [
        {
          name: 'NestedWindowsPassword'
          value: nestedWindowsPassword
        }
        {
          name: 'SafeModePassword'
          value: safeModePassword
        }
        {
          name: 'SqlServiceAccountPassword'
          value: sqlServiceAccountPassword
        }
      ]
    }
  }
}
