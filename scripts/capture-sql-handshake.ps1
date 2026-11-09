param(
    [ValidateSet('Preflight','Capture','Inspect','Safety')][string]$Action = 'Preflight',
    [ValidatePattern('^[a-zA-Z0-9-]*$')][string]$CaptureId = ''
)
$ErrorActionPreference = 'Stop'
if ($Action -eq 'Capture') {
    throw 'New paired captures are disabled: the guest timed-stop guard has not been validated. Inspect existing evidence instead.'
}
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')
. (Join-Path $PSScriptRoot 'stage-view.ps1')
$settings = Read-LabSettings (Get-LabEnvironmentFile (Split-Path -Parent $PSScriptRoot))
Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID','AZURE_RESOURCE_GROUP','AZURE_LOCATION','NAME_PREFIX','NESTED_WINDOWS_PASSWORD')
$common = @('--subscription',$settings.AZURE_SUBSCRIPTION_ID,'--resource-group',$settings.AZURE_RESOURCE_GROUP,
    '--vm-name',"$($settings.NAME_PREFIX)-host")
$existing = (Invoke-LabAz (@('vm','run-command','list') + $common +
    @('--query',"[?name=='diagnostic-sql-handshake-capture'].name | [0]",'--output','tsv','--only-show-errors'))).Output.Trim()
if ($existing) {
    $state = (Invoke-LabAz (@('vm','run-command','show') + $common +
        @('--name',$existing,'--expand','instanceView','--query','instanceView.executionState','--output','tsv','--only-show-errors'))).Output.Trim()
    if ($state -notin @('Succeeded','Failed','Canceled','TimedOut')) {
        throw 'An earlier packet diagnostic is not terminal; do not overwrite or start a competing capture.'
    }
}
$path = New-LabParameterFile @{
    location=$settings.AZURE_LOCATION;namePrefix=$settings.NAME_PREFIX;action=$Action;captureId=$CaptureId
    nestedWindowsPassword=$settings.NESTED_WINDOWS_PASSWORD
    runId=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,12)
}
try {
    [void](Invoke-LabAz @('deployment','group','create','--subscription',$settings.AZURE_SUBSCRIPTION_ID,
        '--resource-group',$settings.AZURE_RESOURCE_GROUP,'--name','arc-jumpstart-sql-handshake-capture',
        '--template-file',(Join-Path $PSScriptRoot '../infra/stages/sql-handshake-capture/main.bicep'),
        '--parameters',"@$path",'--output','none','--only-show-errors'))
    $result = Invoke-LabAz @('vm','run-command','show','--subscription',$settings.AZURE_SUBSCRIPTION_ID,
        '--resource-group',$settings.AZURE_RESOURCE_GROUP,'--vm-name',"$($settings.NAME_PREFIX)-host",
        '--name','diagnostic-sql-handshake-capture','--expand','instanceView',
        '--query','{state:instanceView.executionState,exit:instanceView.exitCode,output:instanceView.output,error:instanceView.error}',
        '--output','json','--only-show-errors')
    $execution = $result.Output | ConvertFrom-Json -ErrorAction Stop
    Write-Host (Protect-LabOutput ([string]$execution.output) $settings)
    if ($execution.error) { Write-Warning (Protect-LabOutput ([string]$execution.error) $settings) }
    if ($execution.state -ne 'Succeeded' -or $null -eq $execution.exit -or $execution.exit -ne 0 -or
        $execution.output -notlike '*SQL_PACKET_DIAGNOSTICS_COMPLETED*') {
        throw 'Packet diagnostics did not complete successfully. Check capture ownership and cleanup before retrying.'
    }
}
finally { Remove-Item -LiteralPath $path -Force }
