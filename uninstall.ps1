# Nurl Uninstallation Script for Windows
# Usage: irm https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.ps1 | iex

$ErrorActionPreference = "Stop"

# Configuration
$NurlHome = "$env:USERPROFILE\.nurl"
$NushellConfig = "$env:APPDATA\nushell\config.nu"
$BackupDir = "$env:USERPROFILE\.nurl-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

Write-Host "Uninstalling Nurl" -ForegroundColor Blue
Write-Host ""

# Check if nurl is installed
if (-not (Test-Path $NurlHome)) {
    Write-Host "Nurl is not installed at ~/.nurl" -ForegroundColor Yellow
    exit 0
}

# Ask for confirmation
Write-Host "This will remove Nurl but preserve your data in a backup." -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Continue? [y/N]"

if ($confirm -notmatch "^[yY]") {
    Write-Host "Cancelled"
    exit 0
}

# Backup user data
Write-Host "[1/3] Backing up user data..."
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# Copy user data files
if (Test-Path "$NurlHome\config.nuon") {
    Copy-Item "$NurlHome\config.nuon" $BackupDir
}
if (Test-Path "$NurlHome\variables.nuon") {
    Copy-Item "$NurlHome\variables.nuon" $BackupDir
}
if (Test-Path "$NurlHome\secrets.nuon") {
    Copy-Item "$NurlHome\secrets.nuon" $BackupDir
}
if ((Test-Path "$NurlHome\collections") -and (Get-ChildItem "$NurlHome\collections" -ErrorAction SilentlyContinue)) {
    Copy-Item -Recurse "$NurlHome\collections" $BackupDir
}
if ((Test-Path "$NurlHome\chains") -and (Get-ChildItem "$NurlHome\chains" -ErrorAction SilentlyContinue)) {
    Copy-Item -Recurse "$NurlHome\chains" $BackupDir
}
if ((Test-Path "$NurlHome\history") -and (Get-ChildItem "$NurlHome\history" -ErrorAction SilentlyContinue)) {
    Copy-Item -Recurse "$NurlHome\history" $BackupDir
}

# Remove nurl directory
Write-Host "[2/3] Removing ~/.nurl..."
Remove-Item -Recurse -Force $NurlHome

# Remove from Nushell config
Write-Host "[3/3] Cleaning Nushell config..."
if (Test-Path $NushellConfig) {
    $content = Get-Content $NushellConfig | Where-Object {
        $_ -notmatch "# Nurl - Terminal API Client" -and
        $_ -notmatch "\.nurl[/\\]api\.nu"
    }
    $content | Set-Content $NushellConfig
}

Write-Host ""
Write-Host "Nurl uninstalled" -ForegroundColor Green
Write-Host ""
Write-Host "Your data has been backed up to:"
Write-Host "  $BackupDir" -ForegroundColor Blue
Write-Host ""
Write-Host "To restore your data later, copy the backup contents to ~/.nurl/"
Write-Host ""
Write-Host "To fully remove all data (including backup), run:"
Write-Host "  Remove-Item -Recurse -Force $BackupDir" -ForegroundColor Yellow
