param accountName string
param principalId string
resource account 'Microsoft.Storage/storageAccounts@2023-05-01' existing = { name: accountName }
resource service 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = { parent: account, name: 'default' }
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = { parent: service, name: 'sql-media' }
resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(container.id, principalId, 'host-media-reader')
  scope: container
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  }
}
