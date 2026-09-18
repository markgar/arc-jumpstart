metadata description = 'Optional daily auto-shutdown policy for the existing Hyper-V host.'

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@minLength(2)
@maxLength(8)
param namePrefix string = 'jsarc'

@description('Whether the daily host auto-shutdown schedule is enabled.')
param enabled bool

@description('Daily shutdown time in 24-hour HHmm format, such as 2200.')
@minLength(4)
@maxLength(4)
param shutdownTime string

@description('Windows time-zone ID used by the Azure schedule, such as Central Standard Time.')
param timeZoneId string

param tags object = {
  project: 'arc-jumpstart-v2'
}

var hostVmName = '${namePrefix}-host'

resource hostVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: hostVmName
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${hostVmName}'
  location: location
  tags: tags
  properties: {
    status: enabled ? 'Enabled' : 'Disabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: timeZoneId
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: hostVm.id
  }
}

output scheduleName string = autoShutdown.name
output scheduleStatus string = autoShutdown.properties.status
