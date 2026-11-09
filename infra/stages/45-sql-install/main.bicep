metadata description = 'Stage 45 - install assigned SQL Server Developer engine and SSAS features on five clean Windows guests before domain setup.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('HTTPS URL of the SQL Server 2025 Enterprise Developer media source.')
param sqlDownloadUrl string
@allowed(['developer', 'licensed'])
param sqlEditionMode string = 'developer'
param sqlMediaAccountName string = ''

@secure()
@description('Local Administrator password for the nested Windows guests.')
param nestedWindowsPassword string

@secure()
@minLength(32)
@maxLength(128)
@description('One private sa password shared by all four Database Engine instances in this lab.')
param sqlSaPassword string

param runId string

module sqlInstall '../../modules/hostRunCommand.bicep' = {
  name: 'stage45-sql-install'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage45-sql-install'
    scriptContent: replace(loadTextContent('../../../artifacts/scripts/45-install-sql.ps1'), '# PRIVATE_SQL_MEDIA_HELPERS', loadTextContent('../../../artifacts/scripts/private-sql-media.ps1'))
    runId: runId
    timeoutInSeconds: 14400
    asyncExecution: true
    scriptParameters: [
      { name: 'SqlEditionMode', value: sqlEditionMode }
      { name: 'SqlMediaAccountName', value: sqlMediaAccountName }
      {
        name: 'EngineScriptBase64'
        value: base64(loadTextContent('../../../artifacts/scripts/45-install-sql-engine.ps1'))
      }
      {
        name: 'SqlDownloadUrl'
        value: sqlDownloadUrl
      }
    ]
    protectedScriptParameters: {
      items: [
        {
          name: 'NestedWindowsPassword'
          value: nestedWindowsPassword
        }
        {
          name: 'SqlSaPassword'
          value: sqlSaPassword
        }
      ]
    }
  }
}
