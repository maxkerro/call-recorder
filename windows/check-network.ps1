# Shows every network connection of CallRecorder and the tools it starts. Run it while recording.
# Expected: nothing except 127.0.0.1 / ::1. Anything else is printed.
$names = 'electron', 'CallRecorder', 'whisper-server', 'whisper-cli', 'ollama'
$local = '127.0.0.1', '::1', '0.0.0.0', '::'
$bad = @()
foreach ($n in $names) {
    foreach ($p in Get-Process -Name $n -ErrorAction SilentlyContinue) {
        $tcp = Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue
        foreach ($c in $tcp) {
            $row = [pscustomobject]@{ Process = $n; Pid = $p.Id; Local = "$($c.LocalAddress):$($c.LocalPort)"; Remote = "$($c.RemoteAddress):$($c.RemotePort)"; State = $c.State }
            $row | Format-Table -HideTableHeaders -AutoSize | Out-String -Width 200 | Write-Host -NoNewline
            if (($local -notcontains $c.RemoteAddress) -or ($c.State -eq 'Listen' -and $local[2..3] -contains $c.LocalAddress)) { $bad += $row }
        }
        foreach ($u in Get-NetUDPEndpoint -OwningProcess $p.Id -ErrorAction SilentlyContinue) {
            Write-Host "$n ($($p.Id)) UDP $($u.LocalAddress):$($u.LocalPort)"
        }
    }
}
Write-Host ''
if ($bad.Count -eq 0) { Write-Host 'OK: no connection leaves this PC and nothing listens on the network.' -ForegroundColor Green }
else { Write-Host 'ATTENTION: these connections/listeners are not limited to this PC:' -ForegroundColor Red; $bad | Format-Table }
