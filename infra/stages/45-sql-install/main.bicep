metadata description = 'Stage 45 - install SQL Server Developer on the three clean Windows guests before domain setup.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('HTTPS URL of the SQL Server 2025 Enterprise Developer media source.')
param sqlDownloadUrl string

@secure()
@description('Local Administrator password for the nested Windows guests.')
param nestedWindowsPassword string

param runId string

module sqlInstall '../../modules/hostRunCommand.bicep' = {
  name: 'stage45-sql-install'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'stage45-sql-install'
    scriptContent: loadTextContent('../../../artifacts/scripts/45-install-sql.ps1')
    runId: runId
    timeoutInSeconds: 14400
    asyncExecution: true
    scriptParameters: [
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
      ]
    }
  }
}
