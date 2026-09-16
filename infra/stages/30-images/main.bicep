metadata description = 'Stage 30 - base images: downloads the prebuilt Jumpstart VHDX images onto the Hyper-V host data disk.'

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

param runId string

module images '../../modules/hostRunCommand.bicep' = {
  name: 'stage30-images'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage30-images'
    scriptContent: loadTextContent('../../../artifacts/scripts/30-download-images.ps1')
    runId: runId
    timeoutInSeconds: 14400
    asyncExecution: true
    protectedScriptParameters: {
      items: [
        {
          name: 'ImageSourceSasToken'
          value: imageSourceSasToken
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
    ]
  }
}
