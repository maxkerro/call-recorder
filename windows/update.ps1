# Pull the latest code, install dependencies and start CallRecorder (Windows).
# Run from the windows folder:  powershell -ExecutionPolicy Bypass -File .\update.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
Get-Process -Name 'CallRecorder', 'electron' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "*$PSScriptRoot*" -or $_.ProcessName -eq 'CallRecorder' } | Stop-Process -Force
git pull
npm install
npm start
