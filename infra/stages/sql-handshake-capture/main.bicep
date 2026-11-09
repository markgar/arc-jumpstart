metadata description = 'Opt-in, IP-pair/TCP-filtered independent host/guest trace; existing Packet Monitor is untouched.'
targetScope = 'resourceGroup'
param location string = resourceGroup().location
param namePrefix string
param runId string
@allowed(['Preflight', 'Capture', 'Inspect', 'Safety'])
param action string = 'Preflight'
param captureId string = ''
@secure()
param nestedWindowsPassword string

module diagnostic '../../modules/hostRunCommand.bicep' = {
  name: 'sql-handshake-capture'
  params: {
    location: location
    hostVmName: '${namePrefix}-host'
    stageName: 'diagnostic-sql-handshake-capture'
    scriptContent: replace(replace(loadTextContent('../../../artifacts/scripts/capture-sql-handshake.ps1'), '# PACKET_TOOLS', loadTextContent('../../../artifacts/scripts/sql-packet-tools.ps1')), '# PACKET_METADATA', loadTextContent('../../../artifacts/scripts/sql-packet-metadata.ps1'))
    runId: runId
    scriptParameters: [
      { name: 'Action', value: action }
      { name: 'CaptureId', value: captureId }
    ]
    protectedScriptParameters: {
      items: [
        { name: 'NestedWindowsPassword', value: nestedWindowsPassword }
      ]
    }
    timeoutInSeconds: 240
  }
}
