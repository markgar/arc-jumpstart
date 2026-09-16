metadata description = 'Runs an embedded staged PowerShell artifact on the Hyper-V host via a managed Run Command.'

param location string

@description('Name of the existing Hyper-V host VM.')
param hostVmName string

@description('Short stage identifier used for the managed Run Command resource name.')
param stageName string

@description('PowerShell source embedded in the managed Run Command resource.')
param scriptContent string

@description('Changes on every wrapper invocation so the run command re-executes.')
param runId string

@description('Non-sensitive named parameters passed to the script.')
param scriptParameters array = []

@description('Sensitive named parameters passed to the script.')
@secure()
param protectedScriptParameters object

@description('Maximum execution time for the managed run command.')
@minValue(60)
@maxValue(14400)
param timeoutInSeconds int = 5400

@description('Return the ARM deployment after the script starts. The caller must poll instance view to terminal completion.')
param asyncExecution bool = false

resource hostVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: hostVmName
}

resource runCommand 'Microsoft.Compute/virtualMachines/runCommands@2025-11-01' = {
  parent: hostVm
  name: stageName
  location: location
  properties: {
    asyncExecution: asyncExecution
    treatFailureAsDeploymentFailure: true
    timeoutInSeconds: timeoutInSeconds
    source: {
      script: scriptContent
    }
    parameters: concat(scriptParameters, [
      {
        name: 'RunId'
        value: runId
      }
    ])
    protectedParameters: protectedScriptParameters.items
  }
}
