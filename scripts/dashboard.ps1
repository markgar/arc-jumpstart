param([switch]$Snapshot, [switch]$Serve, [ValidateRange(0, 65535)][int]$Port = 0)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
. (Join-Path $PSScriptRoot 'dashboard-state.ps1')
try {
    $settings = Read-LabSettings (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot))
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if ($Snapshot) { Save-LabDashboardSnapshot $settings }
    $path = Get-LabDashboardPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw 'No dashboard evidence file exists. Run dashboard.ps1 -Snapshot once, or start a deployment with the saved runner.'
    }
    Write-Host "Redacted build evidence: $path"
    if ($Serve) {
        $node = Get-Command node -CommandType Application -ErrorAction Stop
        & $node.Source (Join-Path $PSScriptRoot '../dashboard/server.mjs') --state $path --port $Port
        if ($LASTEXITCODE -ne 0) { throw "Dashboard server exited with code $LASTEXITCODE." }
    }
}
catch { Write-Error $_.Exception.Message; exit 1 }
