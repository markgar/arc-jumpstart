metadata description = 'Opt-in synthetic progress transport canary. No guest, service, network or disk changes.'
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param namePrefix string
param commandName string
param runId string

module proof '../../modules/hostRunCommand.bicep' = {
  name: commandName
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: commandName
    runId: runId
    scriptContent: replace(loadTextContent('../../../artifacts/scripts/prove-progress-transport.ps1'), '# PROGRESS_PROOF_FUNCTIONS', loadTextContent('../../../scripts/progress-proof.ps1'))
    protectedScriptParameters: {
      items: []
    }
    timeoutInSeconds: 240
    asyncExecution: true
  }
}
