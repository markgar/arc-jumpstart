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

module network '../../modules/network.bicep' = {
  name: 'foundation-network'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    vnetAddressPrefix: vnetAddressPrefix
    hostSubnetPrefix: hostSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
  }
}

output vnetName string = network.outputs.vnetName
output hostSubnetId string = network.outputs.hostSubnetId
