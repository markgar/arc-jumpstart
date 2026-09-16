metadata description = 'Virtual network, NSG and optional Azure Bastion for the Arc Jumpstart landing zone.'

param location string
param namePrefix string
param tags object

@description('Address space for the landing-zone VNet.')
param vnetAddressPrefix string

@description('Subnet that hosts the nested-virtualization Hyper-V host.')
param hostSubnetPrefix string

@description('Subnet reserved for Azure Bastion. Must be at least /26.')
param bastionSubnetPrefix string

@description('Deploy Azure Bastion for browser-based RDP to the Hyper-V host.')
param deployBastion bool

var nsgName = '${namePrefix}-nsg-host'
var vnetName = '${namePrefix}-vnet'
var bastionName = '${namePrefix}-bastion'

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
    subnets: concat(
      [
        {
          name: 'snet-host'
          properties: {
            addressPrefix: hostSubnetPrefix
            networkSecurityGroup: {
              id: nsg.id
            }
          }
        }
      ],
      deployBastion
        ? [
            {
              name: 'AzureBastionSubnet'
              properties: {
                addressPrefix: bastionSubnetPrefix
              }
            }
          ]
        : []
    )
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployBastion) {
  name: '${bastionName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = if (deployBastion) {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output hostSubnetId string = '${vnet.id}/subnets/snet-host'
