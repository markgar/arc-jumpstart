function Get-SqlNetworkUInt16 {
    param([byte[]]$Bytes,[int]$Offset)
    [int]$Bytes[$Offset]*256 + [int]$Bytes[$Offset+1]
}

function Get-SqlNetworkUInt32 {
    param([byte[]]$Bytes,[int]$Offset)
    [long]$Bytes[$Offset]*16777216 + [long]$Bytes[$Offset+1]*65536 +
        [long]$Bytes[$Offset+2]*256 + [long]$Bytes[$Offset+3]
}

function ConvertFrom-SqlPacketBytes {
    param([byte[]]$Bytes)
    for ($ip=0; $ip -le [math]::Min(256,$Bytes.Length-40); $ip++) {
        if ($Bytes[$ip] -shr 4 -ne 4 -or $Bytes[$ip+9] -ne 6) { continue }
        $src = $Bytes[($ip+12)..($ip+15)] -join '.'
        $dst = $Bytes[($ip+16)..($ip+19)] -join '.'
        if (!(($src -eq '192.168.128.1' -and $dst -eq '192.168.128.11') -or
            ($src -eq '192.168.128.11' -and $dst -eq '192.168.128.1'))) { continue }
        $ihl = ($Bytes[$ip] -band 15)*4
        $tcp = $ip+$ihl
        $total = Get-SqlNetworkUInt16 $Bytes ($ip+2)
        if ($ihl -lt 20 -or $tcp+20 -gt $Bytes.Length -or
            ((Get-SqlNetworkUInt16 $Bytes ($ip+6)) -band 8191)) { continue }
        $sp = Get-SqlNetworkUInt16 $Bytes $tcp
        $dp = Get-SqlNetworkUInt16 $Bytes ($tcp+2)
        if ($sp -ne 1433 -and $dp -ne 1433) { continue }
        $tcpLength = ($Bytes[$tcp+12] -shr 4)*4
        $payloadLength = $total-$ihl-$tcpLength
        if ($tcpLength -lt 20 -or $payloadLength -lt 0) { continue }
        $payload = $tcp+$tcpLength
        $end = [math]::Min($Bytes.Length,$ip+$total)
        if ($payload -gt $end) { continue }
        $kind = '-'
        if ($payloadLength -gt 0 -and $payload -lt $end) {
            switch ($Bytes[$payload]) {
                0x12 { $kind='TDS-prelogin' }
                0x04 { $kind='TDS-reply' }
                0x10 { $kind='TDS-login' }
                0x15 { $kind='TLS-alert' }
                0x16 { $kind='TLS-handshake' }
                default { $kind='data' }
            }
            $tls = $payload
            if ($Bytes[$payload] -in @(0x12,0x04)) { $tls += 8 }
            if ($tls+6 -le $end -and $Bytes[$tls] -eq 0x16 -and $Bytes[$tls+1] -eq 3) {
                switch ($Bytes[$tls+5]) {
                    1 { $kind='TLS-clienthello' }
                    2 { $kind='TLS-serverhello' }
                }
            }
        }
        $direction = 'H>S'
        $port = $sp
        if ($src -eq '192.168.128.11') { $direction='S>H'; $port=$dp }
        return [pscustomobject]@{
            Direction=$direction;Port=$port;Flags=[int]$Bytes[$tcp+13]
            Seq=(Get-SqlNetworkUInt32 $Bytes ($tcp+4));Ack=(Get-SqlNetworkUInt32 $Bytes ($tcp+8))
            Payload=$payloadLength;Kind=$kind;Window=(Get-SqlNetworkUInt16 $Bytes ($tcp+14))
        }
    }
}

function Get-SqlPacketMetadata {
    param([string]$Root)
    $ErrorActionPreference = 'Stop'
    $records = [Collections.Generic.List[object]]::new()
    $unparsed = 0
    $duplicates = 0
    $seen = @{}
    foreach ($event in Get-WinEvent -Path (Join-Path $Root 'packets.etl') -Oldest -MaxEvents 2048) {
        $decoded = $null
        foreach ($property in $event.Properties) {
            if ($property.Value -is [byte[]]) {
                $decoded = ConvertFrom-SqlPacketBytes $property.Value
                if ($decoded) { break }
            }
        }
        if (!$decoded) { $unparsed++; continue }
        $key = "$($decoded.Direction)/$($decoded.Port)/$($decoded.Flags)/$($decoded.Seq)/$($decoded.Ack)/$($decoded.Payload)"
        $ticks = $event.TimeCreated.ToUniversalTime().Ticks
        if ($seen.ContainsKey($key) -and $ticks-$seen[$key] -le 20000) {
            $seen[$key]=$ticks;$duplicates++;continue
        }
        $seen[$key]=$ticks
        $records.Add(@($event.TimeCreated.ToUniversalTime().ToString('HH:mm:ss.fff'),
            $decoded.Direction,$decoded.Port,$decoded.Flags,$decoded.Seq,$decoded.Ack,
            $decoded.Payload,$decoded.Kind,$decoded.Window))
    }
    [pscustomobject]@{
        Decoded=$records.Count;DuplicateObservations=$duplicates;OtherEvents=$unparsed
        PossibleTruncation=($records.Count+$duplicates+$unparsed -eq 2048)
        Columns='UTC,dir,clientPort,TCPflags,seq,ack,payloadBytes,kind,window'
        Rows=$records.GetRange(0,[math]::Min(18,$records.Count)).ToArray()
    }
}
