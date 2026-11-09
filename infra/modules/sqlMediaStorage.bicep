metadata description = 'Private licensed SQL media account; no anonymous, shared-key, or public-network access.'
param location string
param accountName string
param operatorObjectId string

resource account 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: accountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: { defaultAction: 'Deny', bypass: 'None' }
  }
}
resource service 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: account
  name: 'default'
}
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: service
  name: 'sql-media'
  properties: { publicAccess: 'None' }
}
resource uploader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorObjectId)) {
  name: guid(container.id, operatorObjectId, 'sql-media-uploader')
  scope: container
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}
output accountId string = account.id
output containerId string = container.id
