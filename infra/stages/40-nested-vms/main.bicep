metadata description = 'Stage 40 - nested guests: creates four Windows servers from one generalized Windows parent and one Linux guest. SQL Server is installed separately in stage 45.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Memory assigned to the domain controller, in GB.')
param dcMemoryGB int = 4

@description('Memory assigned to each SQL Server guest, in GB.')
param sqlMemoryGB int = 8

@description('Memory assigned to the Linux guest, in GB.')
param linuxMemoryGB int = 4

@description('Static address given to the domain controller on the nested network.')
param dcStaticIp string = '192.168.128.10'

param nestedGatewayIp string = '192.168.128.1'

@description('Windows Server VHDX file downloaded in stage 30.')
param windowsImageFileName string = 'ArcBox-Win2K22.vhdx'

@description('Linux VHDX file downloaded in stage 30.')
param linuxImageFileName string = 'ArcBox-Ubuntu-01.vhdx'

@secure()
@description('Local administrator password baked into the prebuilt VHDX images.')
param nestedWindowsPassword string

param runId string

module nestedVms '../../modules/hostRunCommand.bicep' = {
  name: 'stage40-nested-vms'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage40-nested-vms'
    scriptContent: loadTextContent('../../../artifacts/scripts/40-create-nested-vms.ps1')
    runId: runId
    timeoutInSeconds: 5400
    scriptParameters: [
      {
        name: 'DcMemoryGB'
        value: string(dcMemoryGB)
      }
      {
        name: 'SqlMemoryGB'
        value: string(sqlMemoryGB)
      }
      {
        name: 'LinuxMemoryGB'
        value: string(linuxMemoryGB)
      }
      {
        name: 'DcStaticIp'
        value: dcStaticIp
      }
      {
        name: 'NestedGatewayIp'
        value: nestedGatewayIp
      }
      {
        name: 'WindowsImageFileName'
        value: windowsImageFileName
      }
      {
        name: 'LinuxImageFileName'
        value: linuxImageFileName
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
