$labCommands = @{
    '10' = 'stage10-init-host'; '20' = 'stage20-host-network'
    '30' = 'stage30-images'; '40' = 'stage40-nested-vms'
    '45' = 'stage45-sql-install'; '50' = 'stage50-domain'
    '60' = 'stage60-sql-ag'; 'ssms' = 'stage-ssms'
}
$labLogs = @{
    '10' = '10-init-host'; '20' = '20-host-network'
    '30' = '30-download-images'; '40' = '40-create-nested-vms'
    '45' = '45-install-sql'; '50' = '50-configure-domain'
    '60' = '60-configure-sql-ag'; 'ssms' = 'install-host-ssms'
}

function Get-LabProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Protect-LabOutput {
    param([string]$Text, [hashtable]$Settings)
    $lines = [System.Collections.Generic.List[string]]::new()
    $suppress = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match 'Windows PowerShell transcript start|Host\s+Application\s*:') {
            if (-not $suppress) { $lines.Add('[Transcript startup header suppressed]') }
            $suppress = $true
        }
        elseif ($suppress) {
            if ($line -match '^\s*\*{6,}\s*$') { $suppress = $false }
        }
        else { $lines.Add($line) }
    }
    $safe = $lines -join "`n"
    $secrets = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $entries = @($Settings.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Key = $_.Key; Value = $_.Value }
    }) + @(Get-ChildItem Env: | ForEach-Object {
        [pscustomobject]@{ Key = $_.Name; Value = $_.Value }
    })
    foreach ($entry in $entries) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        if (-not $value) { continue }
        if ($key -match '(?i)password|passwd|secret|token|(^|_)sas(_|$)|key|connection.string') {
            [void]$secrets.Add($value)
            if ($key -match '(?i)sas') { [void]$secrets.Add($value.TrimStart('?')) }
        }
        foreach ($match in [regex]::Matches($value,
            '(?i)(?:^|[?&;])(?:sig|token|access_token|client_secret|password|AccountKey|SharedAccessKey|SharedAccessSignature)=([^&#;\s]+)')) {
            [void]$secrets.Add($match.Groups[1].Value)
        }
    }
    $variants = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($secret in $secrets) {
        foreach ($variant in @($secret, [uri]::UnescapeDataString($secret))) {
            if (-not $variant) { continue }
            [void]$variants.Add($variant)
            [void]$variants.Add([uri]::EscapeDataString($variant))
            [void]$variants.Add([System.Net.WebUtility]::HtmlEncode($variant))
            [void]$variants.Add($variant.Replace("'", "''"))
            [void]$variants.Add($variant.Replace('`', '``').Replace('$', '`$').Replace('"', '`"'))
            [void]$variants.Add((ConvertTo-Json -InputObject $variant -Compress).Trim('"'))
        }
    }
    foreach ($variant in ($variants | Sort-Object Length -Descending)) {
        $pattern = [regex]::Escape($variant)
        $pattern = [regex]::Replace($pattern, '%[0-9A-Fa-f]{2}', {
            param($match) '(?i:' + $match.Value + ')'
        })
        $safe = [regex]::Replace($safe, $pattern, '[REDACTED]')
    }
    return $safe
}

function Show-StageProgress {
    param([string]$Number, $Progress, [hashtable]$Settings)
    $start = [string](Get-LabProperty $Progress 'start')
    $elapsed = 'unknown'
    if ($start) {
        try {
            $duration = [datetimeoffset]::UtcNow - [datetimeoffset]::Parse($start)
            $elapsed = '{0:00}:{1:00}:{2:00}' -f
                [math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
        }
        catch [FormatException] { $elapsed = 'unknown' }
    }
    Write-Host "Stage=$Number"
    $state = Get-LabProperty $Progress 'state'
    $end = Get-LabProperty $Progress 'end'
    $output = Get-LabProperty $Progress 'output'
    $errorOutput = Get-LabProperty $Progress 'error'
    Write-Host "ExecutionState=$(if ($state) { $state } else { 'unknown' })"
    Write-Host "StartUtc=$(if ($start) { $start } else { 'unknown' })"
    Write-Host "EndUtc=$end"
    Write-Host "Elapsed=$elapsed"
    Write-Host 'LatestOutput:'
    Write-Host (Protect-LabOutput $(if ($output) { [string]$output } else {
        '(no output reported yet)' }) $Settings)
    if ($errorOutput) {
        Write-Warning (Protect-LabOutput ([string]$errorOutput) $Settings)
    }
}

function Show-LabStage {
    param([string]$Command, [string]$Number, [hashtable]$Settings)
    Assert-LabSettings $Settings @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'NAME_PREFIX')
    if ($Command -ne 'build-status' -and -not $labCommands.ContainsKey($Number)) {
        throw 'Stage must be one of 10, 20, 30, 40, 45, 50, 60 or ssms.'
    }
    Write-Warning 'Display redaction only: stored host transcripts remain sensitive and unchanged.'
    [void](Invoke-LabAz @('account', 'set', '--subscription', $Settings.AZURE_SUBSCRIPTION_ID))
    $args = @('vm', 'run-command')
    $hostArgs = @('--resource-group', $Settings.AZURE_RESOURCE_GROUP,
        '--vm-name', "$($Settings.NAME_PREFIX)-host")
    if ($Command -eq 'build-status') {
        $result = Invoke-LabAz ($args + @('list') + $hostArgs + @('--expand', 'instanceView', '--output', 'json', '--only-show-errors'))
        $commands = @(ConvertFrom-Json -InputObject $result.Output)
        $observed = @()
        foreach ($item in $commands) {
            $entry = $labCommands.GetEnumerator() | Where-Object Value -eq $item.name | Select-Object -First 1
            if (-not $entry) { continue }
            $observed += [pscustomobject]@{ Number = $entry.Key; View = $item.instanceView }
        }
        $active = @($observed | Where-Object {
            $state = Get-LabProperty $_.View 'executionState'
            $state -and $state -notin @('Succeeded', 'Failed', 'Canceled')
        } | Sort-Object Number)
        if ($active.Count) {
            Write-Host 'BuildState=Running'
            Write-Host "ActiveStages=$($active.Number -join ',')"
            $selected = $active
        }
        elseif ($observed.Count) {
            Write-Host 'BuildState=NoActiveStage'
            Write-Host 'ActiveStages='
            $selected = @($observed | Sort-Object {
                Get-LabProperty $_.View 'startTime'
            } -Descending | Select-Object -First 1)
            Write-Host "LatestStage=$($selected[0].Number)"
        }
        else {
            Write-Host 'BuildState=NotStarted'
            Write-Host 'ActiveStages='
            Write-Host 'No canonical stage Run Command was found. Stage 00 or local preflight may still be running.'
            return
        }
        foreach ($item in $selected) {
            Show-StageProgress $item.Number @{
                state = Get-LabProperty $item.View 'executionState'
                start = Get-LabProperty $item.View 'startTime'
                end = Get-LabProperty $item.View 'endTime'
                output = Get-LabProperty $item.View 'output'
                error = Get-LabProperty $item.View 'error'
            } $Settings
        }
        return
    }
    if ($Command -eq 'stage-progress') {
        $result = Invoke-LabAz ($args + @('show') + $hostArgs +
            @('--name', $labCommands[$Number], '--expand', 'instanceView',
              '--query', '{state:instanceView.executionState,start:instanceView.startTime,end:instanceView.endTime,output:instanceView.output,error:instanceView.error}',
              '--output', 'json', '--only-show-errors'))
        Show-StageProgress $Number (ConvertFrom-Json -InputObject $result.Output) $Settings
        return
    }
    $prefix = $labLogs[$Number]
    $script = @"
function Remove-TranscriptStartupHeader {
    param([Parameter(ValueFromPipeline)][string]`$Line)
    begin { `$suppress = `$false }
    process {
        if (`$Line -match 'Windows PowerShell transcript start|Host\s+Application\s*:') {
            if (-not `$suppress) { '[Transcript startup header suppressed]' }
            `$suppress = `$true
        } elseif (`$suppress) {
            if (`$Line -match '^\s*\*{6,}\s*`$') { `$suppress = `$false }
        } else { `$Line }
    }
}
`$ErrorActionPreference = 'Stop'
`$log = Get-ChildItem 'C:\ArcJumpstart\Logs\$prefix-*.log' -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not `$log) { throw 'No matching stage transcript was found.' }
Write-Host ('HostLog={0}' -f `$log.FullName)
Write-Host ('LastWriteUtc={0:o}' -f `$log.LastWriteTimeUtc)
Write-Host ('SizeBytes={0}' -f `$log.Length)
Get-Content -LiteralPath `$log.FullName -ErrorAction Stop |
    Remove-TranscriptStartupHeader | Select-Object -Last 200
"@
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("arc-jumpstart-stage-log-{0}.ps1" -f [guid]::NewGuid())
    try {
        [void][System.IO.File]::Create($path).Dispose()
        Protect-LabPath $path
        [System.IO.File]::WriteAllText($path, $script, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-LabAz @('vm', 'run-command', 'invoke', '--resource-group',
            $Settings.AZURE_RESOURCE_GROUP, '--name', "$($Settings.NAME_PREFIX)-host",
            '--command-id', 'RunPowerShellScript', '--scripts', "@$path",
            '--query', 'value[0].message', '--output', 'tsv', '--only-show-errors')
    }
    finally {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    Write-Host (Protect-LabOutput $result.Output $Settings)
}
