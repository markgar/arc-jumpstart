metadata description = 'Stage 10 - Hyper-V host: a nested-virtualization-capable Azure VM that plays the role of the on-premises hypervisor.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

param tags object = {
  project: 'arc-jumpstart-v2'
}

@description('Resource ID of the subnet created in stage 00.')
param hostSubnetId string

@description('VM size. Must support nested virtualization (Dv3/Ev3 or newer) and have enough RAM for the nested guests.')
param hostVmSize string = 'Standard_E16s_v7'

@description('Local administrator name on the Hyper-V host.')
param adminUsername string

@secure()
@description('Local administrator password on the Hyper-V host.')
param adminPassword string

@description('Size of the data disk that stores nested VM images and virtual machines.')
@minValue(256)
@maxValue(4096)
param dataDiskSizeGB int = 1024

@description('Set Standard security only during VM creation; Azure rejects this property on later updates.')
param setStandardSecurityType bool = true

param runId string

var hostVmName = '${namePrefix}-host'

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${hostVmName}-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: hostSubnetId
          }
        }
      }
    ]
  }
}

resource hostVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: hostVmName
  location: location
  tags: tags
  properties: union({
    hardwareProfile: {
      vmSize: hostVmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: '${hostVmName}-osdisk'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          name: '${hostVmName}-datadisk'
          lun: 0
          createOption: 'Empty'
          caching: 'None'
          diskSizeGB: dataDiskSizeGB
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: take(hostVmName, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
        patchSettings: {
          patchMode: 'Manual'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }, setStandardSecurityType ? {
    securityProfile: {
      securityType: 'Standard'
    }
  } : {})
}

module initHost '../../modules/hostRunCommand.bicep' = {
  name: 'stage10-init-host'
  params: {
    location: location
    hostVmName: hostVm.name
    stageName: 'stage10-init-host'
    scriptContent: loadTextContent('../../../artifacts/scripts/10-init-host.ps1')
    runId: runId
    timeoutInSeconds: 3600
    scriptParameters: [
      {
        name: 'DataDiskSizeGB'
        value: string(dataDiskSizeGB)
      }
    ]
    protectedScriptParameters: {
      items: []
    }
  }
}

output hostVmName string = hostVm.name
output hostPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
