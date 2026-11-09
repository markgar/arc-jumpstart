metadata description = 'Stage 40 - nested guests: creates workload guests and an optional unused Windows VM for a future Migrate appliance. SQL/SSAS features are installed separately in stage 45.'

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

@description('Windows Server VHDX downloaded or prepared in stage 30.')
param windowsImageFileName string = imageMode == 'installation-media' ? 'InstallationMedia/Windows-Server-${windowsServerVersion}-Eval.vhdx' : 'ArcBox-Win2K22.vhdx'

@description('Linux VHDX downloaded in stage 30 or installed locally during stage 40.')
param linuxImageFileName string = imageMode == 'installation-media' ? 'InstallationMedia/Ubuntu-22.04.vhdx' : 'ArcBox-Ubuntu-01.vhdx'

@allowed(['jumpstart', 'installation-media'])
param imageMode string = 'installation-media'
param includeLinux bool = true
param includeAppliance bool = true
@allowed(['2022', '2025'])
param windowsServerVersion string = '2025'
@allowed(['azure-kms', 'evaluation'])
param windowsLicenseMode string = imageMode == 'installation-media' ? 'evaluation' : 'azure-kms'
param ubuntuIsoSha256 string = ''
param linuxSshPublicKey string = ''

@secure()
@description('Local administrator password matching the prebuilt image, or set during installation-media setup.')
param nestedWindowsPassword string

param runId string

module nestedVms '../../modules/hostRunCommand.bicep' = {
  name: 'stage40-nested-vms'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage40-nested-vms'
    scriptContent: replace(loadTextContent('../../../artifacts/scripts/40-create-nested-vms.ps1'), '# IMAGE_MEDIA_HELPERS', loadTextContent('../../../artifacts/scripts/image-media.ps1'))
    runId: runId
    timeoutInSeconds: imageMode == 'installation-media' ? 14400 : 5400
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
      { name: 'ImageMode', value: imageMode }
      { name: 'IncludeLinux', value: string(includeLinux) }
      { name: 'IncludeAppliance', value: string(includeAppliance) }
      { name: 'WindowsServerVersion', value: windowsServerVersion }
      { name: 'WindowsLicenseMode', value: windowsLicenseMode }
      { name: 'UbuntuIsoSha256', value: ubuntuIsoSha256 }
      { name: 'LinuxSshPublicKey', value: linuxSshPublicKey }
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
