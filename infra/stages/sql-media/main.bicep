metadata description = 'Stage the licensed-media uploader or verify/register existing root uploads using the private Blob endpoint.'
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param namePrefix string = 'jsarc'
param accountName string
param tenantId string
@allowed(['prepare', 'check'])
param action string = 'prepare'
@secure()
param manifestWriteToken string = ''
param runId string
module prepare '../../modules/hostRunCommand.bicep' = {
  name: 'sql-media-launcher'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage-sql-media'
    scriptContent: replace(replace(loadTextContent('../../../artifacts/scripts/prepare-sql-media.ps1'), '# PRIVATE_SQL_MEDIA_HELPERS', loadTextContent('../../../artifacts/scripts/private-sql-media.ps1')), '# SQL_MEDIA_VALIDATION', loadTextContent('../../../artifacts/scripts/sql-media-validation.ps1'))
    runId: runId
    timeoutInSeconds: 3600
    scriptParameters: [
      { name: 'AccountName', value: accountName }
      { name: 'TenantId', value: tenantId }
      { name: 'Action', value: action }
      { name: 'UploadScriptBase64', value: base64(replace(loadTextContent('../../../artifacts/scripts/upload-sql-media.ps1'), '# SQL_MEDIA_VALIDATION', loadTextContent('../../../artifacts/scripts/sql-media-validation.ps1'))) }
    ]
    protectedScriptParameters: {
      items: empty(manifestWriteToken) ? [] : [
        { name: 'ManifestWriteToken', value: manifestWriteToken }
      ]
    }
  }
}
