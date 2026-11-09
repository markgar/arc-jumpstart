function New-LabProofFrame {
    param([string]$RunId, [ValidateRange(1, 3)][int]$Sequence)
    $payload = [ordered]@{
        version = 1; proof = 'arc-progress-transport'; runId = $RunId
        sequence = $Sequence; at = [datetime]::UtcNow.ToString('o')
        phase = @('started', 'after-large-output', 'finished')[$Sequence - 1]
        message = 'UTF8-' + [char]0x2713
    } | ConvertTo-Json -Compress
    $frame = 'AJPROOF|' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    if ([Text.Encoding]::UTF8.GetByteCount($frame) -gt 1024) { throw 'Proof frame exceeded its byte budget.' }
    return $frame
}

function Read-LabProofFrames {
    param([string]$Output, [string]$RunId)
    $frames = @()
    $rejected = 0
    $foreign = 0
    foreach ($line in ($Output -split '\r?\n')) {
        if (-not $line.StartsWith('AJPROOF|')) { continue }
        try {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line.Substring(8)))
            $frame = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        }
        catch [FormatException] { $rejected++; continue }
        catch [ArgumentException] { $rejected++; continue }
        $sequence = 0
        if ($frame -isnot [pscustomobject] -or $frame.version -ne 1 -or
            $frame.proof -ne 'arc-progress-transport' -or
            -not [int]::TryParse([string]$frame.sequence, [ref]$sequence) -or
            $sequence -lt 1 -or $sequence -gt 3 -or
            $frame.phase -ne @('started', 'after-large-output', 'finished')[$sequence - 1] -or
            $frame.message -ne ('UTF8-' + [char]0x2713)) {
            $rejected++; continue
        }
        if ($frame.runId -cne $RunId) { $foreign++; continue }
        $frames += $frame
    }
    return @{ Frames = $frames; Rejected = $rejected; Foreign = $foreign }
}

function Test-LabProofCompletion {
    param($Progress, [string]$RunId, [string]$PreviousStart, [int]$LatestSequence)
    return $Progress.state -eq 'Succeeded' -and $null -ne $Progress.exit -and
        $Progress.exit -eq 0 -and $Progress.generation -ceq $RunId -and
        $Progress.start -and [string]$Progress.start -ne $PreviousStart -and $LatestSequence -eq 3
}

function Get-LabProofLiveSequences {
    param([array]$Observations, [string]$NativeEnd)
    $end = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($NativeEnd, [ref]$end)) { return }
    $Observations | Where-Object {
        $_.reportedState -eq 'Running' -and [datetimeoffset]$_.observedAt -lt $end
    } | Select-Object -ExpandProperty sequence -Unique
}
