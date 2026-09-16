metadata description = 'Virtual network and NSG for the Arc Jumpstart landing zone, reserving a subnet for optional Bastion.'

param location string
param namePrefix string
param tags object

@description('Address space for the landing-zone VNet.')
param vnetAddressPrefix string

@description('Subnet that hosts the nested-virtualization Hyper-V host.')
param hostSubnetPrefix string

@description('Subnet reserved for Azure Bastion. Must be at least /26.')
param bastionSubnetPrefix string

var nsgName = '${namePrefix}-nsg-host'
var vnetName = '${namePrefix}-vnet'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-host'
        properties: {
          addressPrefix: hostSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output hostSubnetId string = '${vnet.id}/subnets/snet-host'
