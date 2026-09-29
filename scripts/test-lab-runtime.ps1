$ErrorActionPreference = 'Stop'
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-lab-test-{0}" -f [guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$originalEnv = $env:ENV_FILE
try {
    $env:ENV_FILE = Join-Path $directory 'lab.env'
    [System.IO.File]::WriteAllLines($env:ENV_FILE, @(
        'AZURE_SUBSCRIPTION_ID=mock-sub'
        'AZURE_RESOURCE_GROUP=mock-infra'
        'NAME_PREFIX=mock'
        'ARC_RESOURCE_GROUP=mock-arc'))
    $global:LabGraphQuery = ''
    $global:LabEmptyGraph = $false
    function az {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account' -and $args[1] -eq 'set') { return '' }
        if ($args[0] -eq 'graph' -and $args[1] -eq 'query') {
            $global:LabGraphQuery = $args[([array]::IndexOf($args, '--graph-query') + 1)]
            if ($global:LabEmptyGraph) {
                return '{"count":0,"totalRecords":0,"data":[]}'
            }
            return '{"count":1,"totalRecords":1,"data":[{"RecordType":"SQL_INSTANCE","ResourceName":"JS-SQL-01","Properties":"{\"status\":\"Online\"}","SqlServiceType":"Engine","AssessmentUploadTime":"2026-09-29T17:00:00Z","SqlMiRecommendation":"{\"recommendationStatus\":\"Ready\"}","FailoverCluster":"{\"sample\":\"quoted, metadata\"}","MigrationAssessment":"{\"enabled\":true}"}]}'
        }
        throw 'Unexpected Azure CLI operation in inventory export.'
    }
    $output = Join-Path $directory 'exports'
    & (Join-Path $PSScriptRoot 'lab.ps1') -Command inventory -Value $output
    if ($global:LabGraphQuery -notmatch 'resourceGroup =~ "mock-arc"') {
        throw 'Inventory query did not scope the Arc resource group.'
    }
    $csv = @(Get-ChildItem -LiteralPath $output -Filter inventory.csv -Recurse)
    if ($csv.Count -ne 1) { throw 'Inventory CSV was not produced.' }
    $record = Import-Csv -LiteralPath $csv[0].FullName
    if ($record.ResourceName -ne 'JS-SQL-01' -or
        $record.Properties -ne '{"status":"Online"}') {
        throw 'Inventory CSV lost raw modeling fields.'
    }
    if ($record.SqlServiceType -ne 'Engine' -or
        $record.AssessmentUploadTime -notmatch '^2026-09-29T17:00:00(\.0+)?(Z|\+00:00)$' -or
        $record.SqlMiRecommendation -ne '{"recommendationStatus":"Ready"}' -or
        $record.FailoverCluster -ne '{"sample":"quoted, metadata"}' -or
        $record.MigrationAssessment -ne '{"enabled":true}') {
        throw "Inventory CSV lost component, assessment or HA fields: $($record | ConvertTo-Json -Compress)"
    }
    $projection = ($global:LabGraphQuery -split '\| project\s*\r?\n', 2)[1] -split '\| order by', 2
    $expectedFields = @($projection[0] -split '\r?\n' |
        Where-Object { $_.Trim() } |
        ForEach-Object { ($_.Trim().TrimEnd(',') -split '\s*=\s*', 2)[0] })
    $actualFields = @($record.PSObject.Properties.Name)
    if (($expectedFields -join ',') -ne ($actualFields -join ',')) {
        throw 'Inventory CSV schema differs from the customer ARG query projection.'
    }
    foreach ($expected in @('skuRecommendationResults', 'assessmentUploadTime', 'serverAssessments',
        'properties.failoverCluster', 'properties.serviceType', 'OTHER_SQL_CHILD', 'ARC_EXTENSION')) {
        if (-not $global:LabGraphQuery.Contains($expected)) {
            throw "Inventory query is missing $expected."
        }
    }
    if ($global:LabGraphQuery -match '(?i)microsoft\.compute/|jsarc|JS-SQL|JS-RETAIL|JS-INSIGHT|\|\s*(join|mv-expand|take|limit)\b') {
        throw 'Customer query must remain host-independent and retain unjoined resource rows.'
    }
    $global:LabEmptyGraph = $true
    $emptyOutput = Join-Path $directory 'empty'
    & (Join-Path $PSScriptRoot 'lab.ps1') -Command inventory -Value $emptyOutput
    $emptyCsv = @(Get-ChildItem -LiteralPath $emptyOutput -Filter inventory.csv -Recurse)
    if ($emptyCsv.Count -ne 1 -or
        (Get-Content -LiteralPath $emptyCsv[0].FullName).Count -ne 1) {
        throw 'Empty inventory must retain a CSV header without inventing rows.'
    }
    $emptyHeader = @(Get-Content -LiteralPath $emptyCsv[0].FullName)[0]
    if ($emptyHeader -ne @(Get-Content -LiteralPath $csv[0].FullName)[0]) {
        throw 'Empty inventory header differs from populated inventory.'
    }
    Write-Host 'PowerShell lab-management regression checks passed.'
}
finally {
    $env:ENV_FILE = $originalEnv
    Remove-Item -LiteralPath $directory -Recurse -Force
    Remove-Variable LabGraphQuery -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable LabEmptyGraph -Scope Global -ErrorAction SilentlyContinue
}
