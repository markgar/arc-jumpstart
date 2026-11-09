metadata description = 'Stage 00 - landing zone foundation: virtual network and NSG. Bastion is deployed separately.'

targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix (2-8 chars) used for resource names.')
@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Tags applied to every resource.')
param tags object = {
  project: 'arc-jumpstart-v2'
}

param vnetAddressPrefix string = '10.20.0.0/16'
param hostSubnetPrefix string = '10.20.1.0/24'
param bastionSubnetPrefix string = '10.20.250.0/26'
param privateEndpointSubnetPrefix string = '10.20.2.0/24'
param sqlMediaResourceGroup string
param operatorObjectId string
@description('Explicitly approved existing media account. Reference it without redeploying its account, container, policies or uploader roles.')
param existingSqlMediaAccountName string = ''
var sqlMediaAccountName = empty(existingSqlMediaAccountName) ? 'sqlmedia${uniqueString(subscription().subscriptionId, sqlMediaResourceGroup)}' : existingSqlMediaAccountName
var sqlMediaAccountId = resourceId(sqlMediaResourceGroup, 'Microsoft.Storage/storageAccounts', sqlMediaAccountName)

module network '../../modules/network.bicep' = {
  name: 'foundation-network'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    vnetAddressPrefix: vnetAddressPrefix
    hostSubnetPrefix: hostSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
  }
}

module sqlMedia '../../modules/sqlMediaStorage.bicep' = if (empty(existingSqlMediaAccountName)) {
  name: 'sql-media-storage'
  scope: resourceGroup(sqlMediaResourceGroup)
  params: {
    location: location
    accountName: sqlMediaAccountName
    operatorObjectId: operatorObjectId
  }
}
resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}
resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: '${namePrefix}-media-link'
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: network.outputs.vnetId } }
}
resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${namePrefix}-sql-media-pe'
  location: location
  properties: {
    subnet: { id: network.outputs.privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: { privateLinkServiceId: sqlMediaAccountId, groupIds: ['blob'] }
      }
    ]
  }
  dependsOn: [sqlMedia]
}
resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'blob'
  properties: { privateDnsZoneConfigs: [{ name: 'blob', properties: { privateDnsZoneId: zone.id } }] }
}
output vnetName string = network.outputs.vnetName
output hostSubnetId string = network.outputs.hostSubnetId
output sqlMedia object = {
  accountName: sqlMediaAccountName
  accountId: sqlMediaAccountId
  containerId: '${sqlMediaAccountId}/blobServices/default/containers/sql-media'
}
