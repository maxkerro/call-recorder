# Windows Firewall: blocks ALL outbound network traffic of CallRecorder, whisper.cpp and (optionally) Ollama.
# Traffic to 127.0.0.1 is not affected, so everything keeps working; only the internet is cut off for these programs.
# Run once as Administrator:   powershell -ExecutionPolicy Bypass -File .\block-outbound.ps1
# Remove the rules later with: Get-NetFirewallRule -DisplayName 'CallRecorder block*' | Remove-NetFirewallRule
# Do the first-run downloads (setup-whisper.ps1, speaker models, ollama pull) BEFORE running this.
param([switch]$IncludeOllama)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')) {
    throw 'Run this in an Administrator PowerShell.'
}
$programs = @(
    (Join-Path $env:APPDATA 'CallRecorder\bin\whisper-cli.exe'),
    (Join-Path $env:APPDATA 'CallRecorder\bin\whisper-server.exe'),
    (Join-Path $PSScriptRoot 'node_modules\electron\dist\electron.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\CallRecorder\CallRecorder.exe')
)
if ($IncludeOllama) {
    $programs += (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe')
}
foreach ($p in $programs) {
    $name = "CallRecorder block - $(Split-Path $p -Leaf)"
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) { Write-Host "exists: $name"; continue }
    New-NetFirewallRule -DisplayName $name -Direction Outbound -Program $p -Action Block -Profile Any | Out-Null
    Write-Host "blocked outbound: $p"
}
Write-Host 'Done. Check with .\check-network.ps1 while recording.'
