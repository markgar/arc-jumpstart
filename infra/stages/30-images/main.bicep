metadata description = 'Stage 30 - image cache: downloads Jumpstart disks or builds local installation-media disks on the Hyper-V host.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Container that holds the base VHDX images. Point this at your own storage account to avoid depending on the public Jumpstart account.')
#disable-next-line no-hardcoded-env-urls
param imageSourceUrl string = 'https://jumpstartprodsg.blob.core.windows.net/arcbox/prod'

@description('Semicolon-separated list of VHDX file names to download.')
param imageFileNames string = 'ArcBox-Win2K22.vhdx;ArcBox-Ubuntu-01.vhdx'

@secure()
@description('Optional container SAS token for private source images, without a leading question mark.')
param imageSourceSasToken string = ''

@allowed(['jumpstart', 'installation-media'])
param imageMode string = 'installation-media'
param includeLinux bool = true
@allowed(['2022', '2025'])
param windowsServerVersion string = '2025'
param windowsIsoUrl string = ''
param windowsIsoSha256 string = ''
param ubuntuIsoUrl string = ''
param ubuntuIsoSha256 string = ''
param linuxSshPublicKey string = ''
@secure()
param nestedWindowsPassword string = ''

param runId string

module images '../../modules/hostRunCommand.bicep' = {
  name: 'stage30-images'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage30-images'
    scriptContent: replace(loadTextContent('../../../artifacts/scripts/30-download-images.ps1'), '# IMAGE_MEDIA_HELPERS', loadTextContent('../../../artifacts/scripts/image-media.ps1'))
    runId: runId
    timeoutInSeconds: 14400
    asyncExecution: true
    protectedScriptParameters: {
      items: [
        {
          name: 'ImageSourceSasToken'
          value: imageSourceSasToken
        }
        {
          name: 'NestedWindowsPassword'
          value: nestedWindowsPassword
        }
      ]
    }
    scriptParameters: [
      {
        name: 'ImageSourceUrl'
        value: imageSourceUrl
      }
      {
        name: 'ImageFileNames'
        value: imageFileNames
      }
      { name: 'ImageMode', value: imageMode }
      { name: 'IncludeLinux', value: string(includeLinux) }
      { name: 'WindowsServerVersion', value: windowsServerVersion }
      { name: 'WindowsIsoUrl', value: windowsIsoUrl }
      { name: 'WindowsIsoSha256', value: windowsIsoSha256 }
      { name: 'UbuntuIsoUrl', value: ubuntuIsoUrl }
      { name: 'UbuntuIsoSha256', value: ubuntuIsoSha256 }
      { name: 'LinuxSshPublicKey', value: linuxSshPublicKey }
    ]
  }
}
