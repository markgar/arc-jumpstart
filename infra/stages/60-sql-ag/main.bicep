metadata description = 'Stage 60 - SQL Server availability group: builds the failover cluster and an Always On availability group across the two SQL nodes.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

param domainName string = 'jumpstart.lab'

param domainNetbiosName string = 'JUMPSTART'

@description('Cluster name object created in Active Directory.')
@maxLength(15)
param clusterName string = 'JS-SQLCLU'

@description('Static cluster IP address. Must sit outside the DHCP range.')
param clusterIp string = '192.168.128.20'

@description('Availability group listener IP address. Must sit outside the DHCP range.')
param listenerIp string = '192.168.128.21'

@description('Availability group name.')
param availabilityGroupName string = 'JS-AG-01'

@description('Availability group listener name.')
@maxLength(15)
param listenerName string = 'JS-AG-LSTN'

@description('Sample database seeded into the availability group.')
param sampleDatabaseName string = 'JumpstartDB'

@description('Sample database created on the standalone SQL Server for the migration exercise.')
param standaloneDatabaseName string = 'JumpstartStandaloneDB'

param sqlServiceAccountName string = 'svc-sql'

@secure()
param nestedWindowsPassword string

@secure()
param sqlServiceAccountPassword string

param runId string

module sqlAg '../../modules/hostRunCommand.bicep' = {
  name: 'stage60-sql-ag'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage60-sql-ag'
    scriptContent: loadTextContent('../../../artifacts/scripts/60-configure-sql-ag.ps1')
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
        name: 'ClusterName'
        value: clusterName
      }
      {
        name: 'ClusterIp'
        value: clusterIp
      }
      {
        name: 'ListenerIp'
        value: listenerIp
      }
      {
        name: 'AvailabilityGroupName'
        value: availabilityGroupName
      }
      {
        name: 'ListenerName'
        value: listenerName
      }
      {
        name: 'SampleDatabaseName'
        value: sampleDatabaseName
      }
      {
        name: 'StandaloneDatabaseName'
        value: standaloneDatabaseName
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
          name: 'SqlServiceAccountPassword'
          value: sqlServiceAccountPassword
        }
      ]
    }
  }
}
