<#
 One-time setup for the Whisper engine on Windows. Installs ffmpeg, downloads whisper.cpp (whisper-cli.exe and
 whisper-server.exe) and the models:
   large-v3-q5_0        (~1.1 GB)  most accurate; used for "Transcribe file…" and the transcript check
   large-v3-turbo-q5_0  (~550 MB)  fast; used for the live transcript
   silero VAD           (<1 MB)    skips silence/music so Whisper doesn't invent text
 Everything runs locally; no audio leaves your PC. Safe to re-run: existing files are kept.

 Run:   powershell -ExecutionPolicy Bypass -File .\setup-whisper.ps1
 Options:
   -Cuda            use the NVIDIA GPU build of whisper.cpp (needs an NVIDIA GPU + current driver)
   -FromZip <file>  use a whisper.cpp Windows zip you downloaded yourself (must contain whisper-cli.exe, whisper-server.exe)
#>
param([switch]$Cuda, [string]$FromZip = "")
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the progress bar

$support = Join-Path $env:APPDATA 'CallRecorder'
$bin     = Join-Path $support 'bin'
$models  = Join-Path $support 'models'
New-Item -ItemType Directory -Force -Path $bin, $models | Out-Null

function Download($url, $dest) {
    Write-Host "  downloading $(Split-Path $dest -Leaf) …"
    Invoke-WebRequest -Uri $url -OutFile "$dest.part" -UseBasicParsing -Headers @{ 'User-Agent' = 'CallRecorder' }
    Move-Item -Force "$dest.part" $dest
}

# --- ffmpeg ---------------------------------------------------------------------------------------------------------
Write-Host "`n[1/3] ffmpeg"
$haveFfmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or
              (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'))
if ($haveFfmpeg) { Write-Host "  found." }
else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is missing. Install ffmpeg yourself (https://www.gyan.dev/ffmpeg/builds/) and put ffmpeg.exe into $bin, then re-run."
    }
    winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
}

# --- whisper.cpp ----------------------------------------------------------------------------------------------------
Write-Host "`n[2/3] whisper.cpp (whisper-cli.exe, whisper-server.exe)"
if ((Test-Path (Join-Path $bin 'whisper-cli.exe')) -and (Test-Path (Join-Path $bin 'whisper-server.exe'))) {
    Write-Host "  already installed in $bin"
} else {
    $zip = Join-Path $env:TEMP 'whisper-bin.zip'
    if ($FromZip) {
        Copy-Item -Force $FromZip $zip
    } else {
        $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=40' `
                                      -Headers @{ 'User-Agent' = 'CallRecorder' }
        $pattern = if ($Cuda) { '^whisper-cublas-.*-bin-x64\.zip$' } else { '^whisper-bin-x64\.zip$' }
        $asset = $null
        foreach ($r in $releases) {                       # newest release that ships a Windows build
            $asset = $r.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
            if ($asset) { break }
        }
        if (-not $asset) {
            throw @"
Could not find a Windows build of whisper.cpp on GitHub automatically.
Download a Windows zip from https://github.com/ggml-org/whisper.cpp/releases (look for 'whisper-bin-x64.zip'),
then run:  .\setup-whisper.ps1 -FromZip C:\path\to\that.zip
"@
        }
        Write-Host "  using $($asset.name)"
        Download $asset.browser_download_url $zip
    }
    $tmp = Join-Path $env:TEMP 'whisper-unzip'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Force $zip $tmp
    $cli = Get-ChildItem -Path $tmp -Recurse -Filter 'whisper-cli.exe' | Select-Object -First 1
    if (-not $cli) { throw "whisper-cli.exe is not inside the zip. Use a build from the whisper.cpp releases page." }
    Copy-Item -Force (Join-Path $cli.DirectoryName '*') $bin     # exe + the DLLs next to it
    if (-not (Test-Path (Join-Path $bin 'whisper-server.exe'))) {
        Write-Warning "whisper-server.exe is not in this build. Live transcription needs it: download a build that includes it and re-run with -FromZip."
    }
    Remove-Item -Force $zip; Remove-Item -Recurse -Force $tmp
}

# --- models ---------------------------------------------------------------------------------------------------------
Write-Host "`n[3/3] models"
$hf = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main'
$files = @(
    @{ name = 'ggml-large-v3-q5_0.bin';       url = "$hf/ggml-large-v3-q5_0.bin" },
    @{ name = 'ggml-large-v3-turbo-q5_0.bin'; url = "$hf/ggml-large-v3-turbo-q5_0.bin" },
    @{ name = 'ggml-silero-v5.1.2.bin';       url = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin' }
)
foreach ($f in $files) {
    $dest = Join-Path $models $f.name
    if (Test-Path $dest) { Write-Host "  already present: $($f.name)" } else { Download $f.url $dest }
}

Write-Host "`nDone. Restart CallRecorder."
Write-Host "Optional, for call summaries: install Ollama (https://ollama.com/download) and run:  ollama pull qwen2.5:7b"
