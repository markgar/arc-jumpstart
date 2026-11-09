$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
$settings = Read-LabSettings (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot))
Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_LOCATION', 'NAME_PREFIX', 'NESTED_WINDOWS_PASSWORD')
$common = @('--subscription',$settings.AZURE_SUBSCRIPTION_ID,'--resource-group',$settings.AZURE_RESOURCE_GROUP,
    '--vm-name',"$($settings.NAME_PREFIX)-host")
$existing = (Invoke-LabAz (@('vm','run-command','list') + $common +
    @('--query',"[?name=='diagnostic-sql-connectivity'].name | [0]",'--output','tsv','--only-show-errors'))).Output.Trim()
if ($existing) {
    $state = (Invoke-LabAz (@('vm','run-command','show') + $common +
        @('--name',$existing,'--expand','instanceView','--query','instanceView.executionState','--output','tsv','--only-show-errors'))).Output.Trim()
    if ($state -notin @('Succeeded','Failed','Canceled','TimedOut')) { throw 'An earlier SQL diagnostic is not terminal; do not start a competing command.' }
}
$path = New-LabParameterFile @{
    location=$settings.AZURE_LOCATION;namePrefix=$settings.NAME_PREFIX
    nestedWindowsPassword=$settings.NESTED_WINDOWS_PASSWORD
    runId=[datetime]::UtcNow.ToString('yyyyMMddHHmmss')
}
try {
    [void](Invoke-LabAz @('deployment','group','create','--subscription',$settings.AZURE_SUBSCRIPTION_ID,
        '--resource-group',$settings.AZURE_RESOURCE_GROUP,'--name','arc-jumpstart-sql-connectivity-check',
        '--template-file',(Join-Path $PSScriptRoot '../infra/stages/sql-connectivity-check/main.bicep'),
        '--parameters',"@$path",'--output','none','--only-show-errors'))
    $result = Invoke-LabAz @('vm','run-command','show','--subscription',$settings.AZURE_SUBSCRIPTION_ID,
        '--resource-group',$settings.AZURE_RESOURCE_GROUP,'--vm-name',"$($settings.NAME_PREFIX)-host",
        '--name','diagnostic-sql-connectivity','--expand','instanceView',
        '--query','{state:instanceView.executionState,exit:instanceView.exitCode,output:instanceView.output,error:instanceView.error}',
        '--output','json','--only-show-errors')
    $execution = $result.Output | ConvertFrom-Json -ErrorAction Stop
    Write-Host (Protect-LabOutput ([string]$execution.output) $settings)
    if ($execution.error) { Write-Warning (Protect-LabOutput ([string]$execution.error) $settings) }
    if ($execution.state -ne 'Succeeded' -or $null -eq $execution.exit -or $execution.exit -ne 0 -or
        $execution.output -notlike '*SQL_GUEST_DIAGNOSTICS_COMPLETED*') {
        throw 'Read-only SQL diagnostics did not complete successfully. Do not retry an active operation.'
    }
}
finally { Remove-Item -LiteralPath $path -Force }
