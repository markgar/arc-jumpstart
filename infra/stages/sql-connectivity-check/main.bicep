metadata description = 'Read-only SQL connectivity diagnostic; no service, authentication, firewall or guest configuration changes.'
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param namePrefix string
param runId string
@secure()
param nestedWindowsPassword string

module diagnostic '../../modules/hostRunCommand.bicep' = {
  name: 'sql-connectivity-check'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'diagnostic-sql-connectivity'
    scriptContent: loadTextContent('../../../artifacts/scripts/inspect-sql-connectivity.ps1')
    runId: runId
    protectedScriptParameters: {
      items: [
        { name: 'NestedWindowsPassword', value: nestedWindowsPassword }
      ]
    }
    timeoutInSeconds: 240
  }
}
