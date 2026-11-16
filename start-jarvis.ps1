# Starts the local, voice-only JARVIS (CyberVerse) stack and opens it in the browser.
# Everything listens on this machine only (127.0.0.1 / localhost).
# Usage:  powershell -ExecutionPolicy Bypass -File .\start-jarvis.ps1
#         powershell -ExecutionPolicy Bypass -File .\start-jarvis.ps1 -Stop

param([switch]$Stop)

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logs = Join-Path $root "logs"
$pidFile = Join-Path $logs "jarvis.pids"

function Stop-Jarvis {
    if (Test-Path $pidFile) {
        foreach ($id in Get-Content $pidFile) {
            # /T also stops child processes (npm -> node)
            & taskkill /PID $id /T /F 2>$null | Out-Null
        }
        Remove-Item $pidFile -Confirm:$false
    }
    Write-Host "JARVIS stopped."
}

if ($Stop) { Stop-Jarvis; exit 0 }

if (Test-Path $pidFile) { Stop-Jarvis }
New-Item -ItemType Directory -Force $logs | Out-Null

# Ollama must be running for the local LLM.
if (-not (Get-Process ollama -ErrorAction SilentlyContinue)) {
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

# Load config/env into this process so child processes inherit it.
foreach ($line in Get-Content (Join-Path $root "config\env")) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
}
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUNBUFFERED = "1"

$procs = @()

# 1. Python inference server (Whisper + Ollama + Windows speech) on 127.0.0.1:50051
$procs += Start-Process -FilePath (Join-Path $root ".venv\Scripts\python.exe") `
    -ArgumentList "-m", "inference.server", "--config", "config/cyberverse.yaml" `
    -WorkingDirectory $root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $logs "inference.out.log") `
    -RedirectStandardError (Join-Path $logs "inference.log")

Write-Host "Starting inference server (loads Whisper, takes ~20s)..."
$ready = $false
foreach ($i in 1..60) {
    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort 50051 -State Listen -ErrorAction SilentlyContinue) { $ready = $true; break }
}
if (-not $ready) { Write-Host "Inference server did not start. See logs\inference.log"; $procs.Id | Set-Content $pidFile; exit 1 }

# 2. Go API server on 127.0.0.1:8080
$procs += Start-Process -FilePath (Join-Path $root "bin\cyberverse-server.exe") `
    -ArgumentList "--config", "..\config\cyberverse.yaml" `
    -WorkingDirectory (Join-Path $root "server") -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $logs "server.out.log") `
    -RedirectStandardError (Join-Path $logs "server.log")

# 3. Web frontend on localhost:5173
$procs += Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm run dev" `
    -WorkingDirectory (Join-Path $root "frontend") -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $logs "frontend.log") `
    -RedirectStandardError (Join-Path $logs "frontend.err.log")

$procs.Id | Set-Content $pidFile
Start-Sleep -Seconds 5
Start-Process "http://localhost:5173"
Write-Host "JARVIS is running at http://localhost:5173  (logs in $logs)"
Write-Host "To stop:  powershell -ExecutionPolicy Bypass -File .\start-jarvis.ps1 -Stop"
