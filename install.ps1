# Nurl Installation Script for Windows
# Usage: irm https://raw.githubusercontent.com/chand45/Nurl/cg/add_installation_scripts/install.ps1 | iex

$ErrorActionPreference = "Stop"

# Configuration
$NurlHome = "$env:USERPROFILE\.nurl"
$RepoUrl = "https://raw.githubusercontent.com/chand45/Nurl/cg/add_installation_scripts"
$NushellConfigDir = "$env:APPDATA\nushell"

Write-Host "Installing Nurl - Terminal API Client" -ForegroundColor Blue
Write-Host ""

# Check if nushell is installed
$nuPath = Get-Command nu -ErrorAction SilentlyContinue
if (-not $nuPath) {
    Write-Host "Error: Nushell is not installed." -ForegroundColor Red
    Write-Host "Please install Nushell first: https://www.nushell.sh/book/installation.html"
    exit 1
}

# Check if this is an update
$IsUpdate = Test-Path $NurlHome

if ($IsUpdate) {
    Write-Host "Existing installation detected. Updating..." -ForegroundColor Yellow
}

# Create directory structure
Write-Host "[1/4] Creating ~/.nurl directory structure..."
New-Item -ItemType Directory -Force -Path $NurlHome | Out-Null
New-Item -ItemType Directory -Force -Path "$NurlHome\nu_modules" | Out-Null
New-Item -ItemType Directory -Force -Path "$NurlHome\collections" | Out-Null
New-Item -ItemType Directory -Force -Path "$NurlHome\chains" | Out-Null
New-Item -ItemType Directory -Force -Path "$NurlHome\history" | Out-Null

# Download core files
Write-Host "[2/4] Downloading nurl files..."

# Download api.nu
Invoke-WebRequest -Uri "$RepoUrl/api.nu" -OutFile "$NurlHome\api.nu" -UseBasicParsing

# Download nu_modules
$Modules = @("mod.nu", "http.nu", "auth.nu", "vars.nu", "history.nu", "chain.nu", "tui.nu", "log.nu")
foreach ($module in $Modules) {
    Invoke-WebRequest -Uri "$RepoUrl/nu_modules/$module" -OutFile "$NurlHome\nu_modules\$module" -UseBasicParsing
}

# Create default configuration (only if not exists)
Write-Host "[3/4] Creating default configuration..."

if (-not (Test-Path "$NurlHome\config.nuon")) {
    # Use WriteAllText to avoid BOM - Nushell's nuon parser doesn't handle BOM
    $configContent = @'
{
    default_headers: {
        "Content-Type": "application/json"
        "Accept": "application/json"
    }
    timeout_seconds: 30
    history_retention_days: 30
    editor: "code"
    colors: {
        success: "green"
        error: "red"
        warning: "yellow"
        info: "blue"
    }
}
'@
    [System.IO.File]::WriteAllText("$NurlHome\config.nuon", $configContent)
}

if (-not (Test-Path "$NurlHome\variables.nuon")) {
    [System.IO.File]::WriteAllText("$NurlHome\variables.nuon", "{}")
}

if (-not (Test-Path "$NurlHome\secrets.nuon")) {
    $secretsContent = @'
{
    tokens: {}
    oauth: {}
    api_keys: {}
    basic_auth: {}
}
'@
    [System.IO.File]::WriteAllText("$NurlHome\secrets.nuon", $secretsContent)
}

# Add to Nushell config
Write-Host "[4/4] Configuring Nushell..."

# Ensure nushell config directory exists
New-Item -ItemType Directory -Force -Path $NushellConfigDir | Out-Null

# Check if config.nu exists, create if not
$ConfigPath = "$NushellConfigDir\config.nu"
if (-not (Test-Path $ConfigPath)) {
    New-Item -ItemType File -Path $ConfigPath | Out-Null
}

# Check if already configured
$ConfigContent = Get-Content $ConfigPath -Raw -ErrorAction SilentlyContinue
if ($ConfigContent -match "\.nurl[/\\]api\.nu") {
    Write-Host "  Nushell config already includes nurl"
} else {
    Add-Content -Path $ConfigPath -Value ""
    Add-Content -Path $ConfigPath -Value "# Nurl - Terminal API Client"
    # Use ~ which Nushell expands at parse-time (source requires parse-time constants)
    Add-Content -Path $ConfigPath -Value 'source ~/.nurl/api.nu'
    Write-Host "  Added nurl to Nushell config"
}

Write-Host ""
if ($IsUpdate) {
    Write-Host "Nurl updated successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your data is preserved:"
    Write-Host "  - collections/    OK"
    Write-Host "  - secrets.nuon    OK"
    Write-Host "  - history/        OK"
    Write-Host "  - config.nuon     OK"
    Write-Host "  - variables.nuon  OK"
} else {
    Write-Host "Nurl installed successfully!" -ForegroundColor Green
}

Write-Host ""
Write-Host "Restart your terminal or run:"
Write-Host '  source ~/.nurl/api.nu' -ForegroundColor Blue
Write-Host ""
Write-Host "Then try:"
Write-Host "  api help" -ForegroundColor Blue
Write-Host "  api get https://jsonplaceholder.typicode.com/posts/1" -ForegroundColor Blue
