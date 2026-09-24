param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'stop', 'start', 'build-status', 'stage-progress',
        'stage-log', 'inventory', 'delete-infra')]
    [string]$Command,
    [Parameter(Position = 1)][string]$Value
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $settings = Read-LabSettings (Get-LabEnvironmentFile $repoRoot)
    Assert-LabSettings $settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if ($Command -in @('build-status', 'stage-progress', 'stage-log')) {
        . (Join-Path $PSScriptRoot 'stage-view.ps1')
        Show-LabStage $Command $Value $settings
        exit 0
    }
    [void](Invoke-LabAz @('account', 'set', '--subscription', $settings.AZURE_SUBSCRIPTION_ID))
    $rg = $settings.AZURE_RESOURCE_GROUP
    $hostName = "$($settings.NAME_PREFIX)-host"
    switch ($Command) {
        'status' {
            $result = Invoke-LabAz @('vm', 'get-instance-view', '--resource-group',
                $rg, '--name', $hostName, '--query',
                "{name:name,powerState:instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]}",
                '--output', 'table')
            Write-Host $result.Output
        }
        'stop' { [void](Invoke-LabAz @('vm', 'deallocate', '--resource-group', $rg,
                    '--name', $hostName, '--output', 'none')) }
        'start' { [void](Invoke-LabAz @('vm', 'start', '--resource-group', $rg,
                    '--name', $hostName, '--output', 'none')) }
        'delete-infra' {
            if ($Value -ne $rg) {
                throw "Confirm deletion by running: ./scripts/lab.ps1 delete-infra $rg"
            }
            [void](Invoke-LabAz @('group', 'delete', '--name', $rg, '--yes'))
        }
        'inventory' {
            $arcRg = if ($settings['ARC_RESOURCE_GROUP']) {
                $settings['ARC_RESOURCE_GROUP']
            } else { "${rg}-arc" }
            $queryFile = Join-Path $repoRoot 'queries/arc-sql-modeling-inventory.kql'
            $query = [System.IO.File]::ReadAllText($queryFile)
            $marker = '// __RESOURCE_GROUP_FILTER__'
            if (-not $query.Contains($marker)) { throw "Missing modeling query filter marker in $queryFile." }
            $escapedRg = $arcRg.Replace('\', '\\').Replace('"', '\"')
            $query = $query.Replace($marker, "| where resourceGroup =~ `"$escapedRg`"")
            $response = Invoke-LabAz @('graph', 'query', '--graph-query', $query,
                '--first', '1000', '--output', 'json', '--subscriptions',
                $settings.AZURE_SUBSCRIPTION_ID)
            $payload = ConvertFrom-Json -InputObject $response.Output
            if ($payload -is [array]) {
                $rows = @($payload)
                $total = $rows.Count
            }
            elseif ($null -ne $payload.data) {
                $rows = @($payload.data)
                $total = if ($null -ne $payload.totalRecords) {
                    [int]$payload.totalRecords
                } else { $rows.Count }
            }
            else { throw 'Azure CLI returned an unexpected Resource Graph response.' }
            if ($total -gt $rows.Count) {
                throw "The query returned $total records, exceeding the 1000-record export limit."
            }
            $root = if ($Value) { $Value } else { Join-Path $repoRoot 'out/arc-modeling' }
            if (-not (Test-Path -LiteralPath $root)) {
                [void](New-Item -ItemType Directory -Path $root -Force)
            }
            $destination = Join-Path $root (Get-Date -AsUTC -Format 'yyyyMMddTHHmmssZ')
            New-Item -ItemType Directory -Path $destination -ErrorAction Stop | Out-Null
            $raw = Join-Path $destination 'inventory.raw.json'
            $csv = Join-Path $destination 'inventory.csv'
            [System.IO.File]::WriteAllText($raw, ($response.Output.TrimEnd() + "`n"),
                [System.Text.UTF8Encoding]::new($false))
            $fields = @('RecordType', 'JoinKey', 'ParentJoinKey', 'ResourceId',
                'ResourceName', 'SubscriptionId', 'ResourceGroup', 'Location',
                'Tags', 'Properties')
            $records = foreach ($row in $rows) {
                $record = [ordered]@{}
                foreach ($field in $fields) { $record[$field] = $row.$field }
                [pscustomobject]$record
            }
            if ($records) {
                $records | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8
            }
            else {
                [System.IO.File]::WriteAllText($csv,
                    (($fields | ForEach-Object { '"' + $_ + '"' }) -join ',') + "`n",
                    [System.Text.UTF8Encoding]::new($false))
            }
            Write-Host "Exported $($rows.Count) records."
            Write-Host "Raw JSON: $raw"
            Write-Host "Modeling CSV: $csv"
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
