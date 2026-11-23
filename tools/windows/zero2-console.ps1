param([Parameter(Mandatory=$true)][string]$Line,[int]$Seconds=12)
$ErrorActionPreference='Stop'
$p=[IO.Ports.SerialPort]::new('COM5',115200,'None',8,'One')
$p.WriteTimeout=4000
try {
    $p.Open(); $p.Write("`r"); Start-Sleep -Milliseconds 400
    $before=$p.ReadExisting()
    if ($before -notmatch 'orangepi@orangepizero2:') { throw "Unexpected console prompt: $before" }
    $marker='OPI'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $p.Write($Line+"; printf '\n%s%s\n' '$marker' '_DONE'`r")
    $end=[DateTime]::UtcNow.AddSeconds($Seconds); $buf=[Text.StringBuilder]::new()
    do { Start-Sleep -Milliseconds 100; [void]$buf.Append($p.ReadExisting()) } until ($buf.ToString().Contains($marker+'_DONE') -or [datetime]::UtcNow -gt $end)
    $buf.ToString()
    if (!$buf.ToString().Contains($marker+'_DONE')) {throw 'Console command still pending or output incomplete'}
} finally { $p.Dispose() }
