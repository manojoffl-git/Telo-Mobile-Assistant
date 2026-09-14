$ErrorActionPreference = "Stop"

Write-Host "=== Telo Agent MVP setup ===" -ForegroundColor Cyan

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter was not found in PATH. Install Flutter first."
}

if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    throw "Python launcher 'py' was not found."
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$mobile = Join-Path $root "mobile"
$backend = Join-Path $root "backend"

Write-Host "`nCreating Flutter project..." -ForegroundColor Yellow
Push-Location $mobile
flutter create .
flutter pub get
Pop-Location

Write-Host "`nInstalling Python backend..." -ForegroundColor Yellow
Push-Location $backend
py -m venv .venv
& ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install -r requirements.txt
Pop-Location

Write-Host "`nSetup shell complete." -ForegroundColor Green
Write-Host "Now:"
Write-Host "1. Copy backend\.env.example to backend\.env and add your keys."
Write-Host "2. Keep the supplied lib/main.dart, MainActivity.kt and AndroidManifest.xml."
Write-Host "3. Run backend\token_server.py."
Write-Host "4. Run backend\agent.py dev."
Write-Host "5. Run flutter run from mobile."
