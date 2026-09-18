metadata description = 'Stages interactive Azure Arc device-code launchers on the Windows guests without connecting them.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

param subscriptionId string

param arcResourceGroup string

param arcLocation string

@secure()
param nestedWindowsPassword string

param runId string

module launchers '../../modules/hostRunCommand.bicep' = {
  name: 'stage-arc-launchers'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage-arc-launchers'
    scriptContent: loadTextContent('../../../artifacts/scripts/stage-arc-device-code-launchers.ps1')
    runId: runId
    timeoutInSeconds: 1800
    scriptParameters: [
      {
        name: 'SubscriptionId'
        value: subscriptionId
      }
      {
        name: 'ArcResourceGroup'
        value: arcResourceGroup
      }
      {
        name: 'ArcLocation'
        value: arcLocation
      }
      {
        name: 'LauncherScriptBase64'
        value: base64(loadTextContent('../../../artifacts/scripts/prepare-arc-device-code-launchers.ps1'))
      }
    ]
    protectedScriptParameters: {
      items: [
        {
          name: 'NestedWindowsPassword'
          value: nestedWindowsPassword
        }
      ]
    }
  }
}
