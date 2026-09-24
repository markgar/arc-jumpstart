metadata description = 'Installs SSMS 22 on the existing Hyper-V host; independent of guest readiness.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

param runId string

module ssms '../../modules/hostRunCommand.bicep' = {
  name: 'stage-ssms'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage-ssms'
    scriptContent: loadTextContent('../../../artifacts/scripts/install-host-ssms.ps1')
    runId: runId
    timeoutInSeconds: 14400
    asyncExecution: true
    protectedScriptParameters: {
      items: []
    }
  }
}
