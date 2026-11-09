$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'artifacts/scripts/sql-packet-tools.ps1')
. (Join-Path $root 'artifacts/scripts/sql-packet-metadata.ps1')
function Assert-Capture($Condition,$Message) { if (!$Condition) { throw $Message } }
foreach ($file in @('artifacts/scripts/sql-packet-tools.ps1','artifacts/scripts/sql-packet-metadata.ps1','artifacts/scripts/capture-sql-handshake.ps1','scripts/capture-sql-handshake.ps1')) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$null,[ref]$errors)
    Assert-Capture (!$errors) "PowerShell parsing failed: $file"
}
$hostSource = Get-Content (Join-Path $root 'artifacts/scripts/capture-sql-handshake.ps1') -Raw
$tools = Get-Content (Join-Path $root 'artifacts/scripts/sql-packet-tools.ps1') -Raw
Assert-Capture ($hostSource -match 'Pooling=false' -and $hostSource -match 'Connect Timeout=4' -and
    $hostSource -match 'ConnectRetryCount=0') 'Probe must use one fresh, bounded physical connection.'
Assert-Capture ($hostSource -notmatch 'pktmon\.exe\s+(?:start|stop|filter\s+(?:add|remove))' -and
    $tools -notmatch 'pktmon\.exe') 'Existing Packet Monitor state must never be changed.'
Assert-Capture ($tools -match 'IPv4.SourceAddress=\(192.168.128.1,192.168.128.11\)' -and
    $tools -match 'IPv4.DestinationAddress=\(192.168.128.1,192.168.128.11\)' -and
    $tools -match "'Protocol=6'") 'Both endpoint and TCP filters must be explicit.'
Assert-Capture ($tools -match 'AddSeconds\(8\)' -and $tools -match 'maxsize=16') 'Time and storage watchdog limits are required.'
Assert-Capture ($tools -match 'report=disabled correlation=disabled') 'Do not collect unrelated diagnostic reports or correlation data.'
Assert-Capture ($tools -match "CaptureType='physical'" -and
    $hostSource -match 'Start-SqlPacketCapture -Root \$root -Name \$name -CaptureType both') 'Only the Hyper-V host may request virtual-switch capture.'
Assert-Capture ($tools -match 'inheritance:r' -and $tools -match 'S-1-5-18' -and $tools -match 'S-1-5-32-544') 'Traces require protected Windows ACLs.'
$fakeRoot = Join-Path $root 'nonexistent-test-trace'
$script:traceStatus = "Running: $(Join-Path $fakeRoot 'packets.etl')"
$script:stops = 0
function netsh.exe {
    if ($args[1] -eq 'stop') { $script:stops++; $script:traceStatus='There is no trace session currently in progress.' }
    $global:LASTEXITCODE=0
    $script:traceStatus
}
Stop-OwnedSqlTrace -Name owned -Root $fakeRoot
Assert-Capture ($script:stops -eq 1) 'Owned trace was not stopped.'
Stop-OwnedSqlTrace -Name owned -Root $fakeRoot
Assert-Capture ($script:stops -eq 1) 'Cleanup must do nothing when no trace is running.'
$script:traceStatus='Running: other-owner.etl'
$refused = $false
try { Stop-OwnedSqlTrace -Name owned -Root $fakeRoot }
catch { $refused=$_.Exception.Message -like '*ownership changed*' }
Assert-Capture ($refused -and $script:stops -eq 1) 'Another owner''s trace must never be stopped.'
function Get-SqlTraceAvailability { [pscustomobject]@{Sessions=@('existing');Providers=@()} }
$refused = $false
try { Start-SqlPacketCapture -Root 'unused' -Name 'test' }
catch { $refused = $_.Exception.Message -like '*existing NetEvent*' }
Assert-Capture $refused 'Capture must refuse an existing NetEvent session before creating resources.'
$packet = [byte[]]::new(68)
$packet[14]=0x45;$packet[17]=54;$packet[23]=6
$packet[26]=192;$packet[27]=168;$packet[28]=128;$packet[29]=1
$packet[30]=192;$packet[31]=168;$packet[32]=128;$packet[33]=11
$packet[34]=0xC0;$packet[35]=1;$packet[36]=5;$packet[37]=0x99
$packet[38]=255;$packet[39]=255;$packet[40]=255;$packet[41]=254
$packet[46]=0x50;$packet[47]=24;$packet[54]=0x12
$packet[62]=0x16;$packet[63]=3;$packet[64]=3;$packet[67]=1
$metadata = ConvertFrom-SqlPacketBytes $packet
Assert-Capture ($metadata.Kind -eq 'TLS-clienthello' -and $metadata.Payload -eq 14 -and
    $metadata.Seq -eq 4294967294 -and $metadata.Port -eq 49153 -and $metadata.Direction -eq 'H>S') 'Packet/TDS-wrapped TLS decoding failed.'
$packet[17]=40;$packet[47]=2
$metadata = ConvertFrom-SqlPacketBytes $packet
Assert-Capture ($metadata.Kind -eq '-' -and $metadata.Payload -eq 0 -and $metadata.Flags -eq 2) 'SYN decoding must not treat bytes beyond the IP length as payload.'
$packet[33]=12
Assert-Capture ($null -eq (ConvertFrom-SqlPacketBytes $packet)) 'Unrelated IP traffic must not become packet metadata.'
$packet[33]=11
$packet[17]=54;$packet[47]=24
$start = [datetime]::UtcNow
$script:fakeEvents = @(
    [pscustomobject]@{TimeCreated=$start;Properties=@([pscustomobject]@{Value=$packet})}
    [pscustomobject]@{TimeCreated=$start.AddTicks(1000);Properties=@([pscustomobject]@{Value=$packet})}
    [pscustomobject]@{TimeCreated=$start.AddSeconds(1);Properties=@([pscustomobject]@{Value=$packet})}
    [pscustomobject]@{TimeCreated=$start;Properties=@([pscustomobject]@{Value='unrelated metadata'})}
)
function Get-WinEvent { param($Path,[switch]$Oldest,$MaxEvents) $script:fakeEvents }
$summary = Get-SqlPacketMetadata -Root $fakeRoot
Assert-Capture ($summary.Decoded -eq 2 -and $summary.DuplicateObservations -eq 1 -and
    $summary.OtherEvents -eq 1 -and $summary.Rows.Count -eq 2) 'Metadata must suppress cross-layer duplicates without hiding later retransmissions.'
Write-Host 'SQL packet capture safety checks passed.'
