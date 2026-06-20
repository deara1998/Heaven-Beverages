# Run Flutter web with CORS disabled for local API testing.
# Usage: .\scripts\run_web.ps1

$chromeDataDir = Join-Path $env:TEMP "flutter_chrome_heaven_dev"

Write-Host "Starting Flutter web (Chrome, CORS disabled for dev)..." -ForegroundColor Cyan
Write-Host "Chrome profile: $chromeDataDir"

flutter run -d chrome `
  --web-browser-flag="--disable-web-security" `
  --web-browser-flag="--disable-site-isolation-trials" `
  --web-browser-flag="--user-data-dir=$chromeDataDir"
