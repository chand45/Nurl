# Nurl Installation Script for Windows
# Usage: irm https://raw.githubusercontent.com/chand45/Nurl/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

# Configuration
$NurlHome = "$env:USERPROFILE\.nurl"
$RepoUrl = "https://raw.githubusercontent.com/chand45/Nurl/main"
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

# Download example collection (jsonplaceholder) - only on fresh install
if (-not (Test-Path "$NurlHome\collections\jsonplaceholder")) {
    Write-Host "  Downloading example collection: jsonplaceholder"
    New-Item -ItemType Directory -Force -Path "$NurlHome\collections\jsonplaceholder\environments" | Out-Null
    New-Item -ItemType Directory -Force -Path "$NurlHome\collections\jsonplaceholder\requests" | Out-Null

    # Collection metadata
    Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/collection.nuon" -OutFile "$NurlHome\collections\jsonplaceholder\collection.nuon" -UseBasicParsing
    Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/meta.nuon" -OutFile "$NurlHome\collections\jsonplaceholder\meta.nuon" -UseBasicParsing

    # Environments
    $Envs = @("default.nuon", "dev.nuon", "staging.nuon")
    foreach ($env in $Envs) {
        Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/environments/$env" -OutFile "$NurlHome\collections\jsonplaceholder\environments\$env" -UseBasicParsing
    }

    # Requests
    $Requests = @("create-post.nuon", "delete-post.nuon", "get-comments.nuon", "get-post.nuon", "get-posts.nuon", "get-users.nuon", "update-post.nuon")
    foreach ($req in $Requests) {
        Invoke-WebRequest -Uri "$RepoUrl/collections/jsonplaceholder/requests/$req" -OutFile "$NurlHome\collections\jsonplaceholder\requests\$req" -UseBasicParsing
    }
}

# Download example chain - only on fresh install
if (-not (Test-Path "$NurlHome\chains\example-workflow.nuon")) {
    Write-Host "  Downloading example chain: example-workflow"
    Invoke-WebRequest -Uri "$RepoUrl/chains/example-workflow.nuon" -OutFile "$NurlHome\chains\example-workflow.nuon" -UseBasicParsing
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
    Write-Host ""
    Write-Host "Included examples to get you started:"
    Write-Host "  - jsonplaceholder collection (7 sample requests)"
    Write-Host "  - example-workflow chain (request chaining demo)"
}

Write-Host ""
Write-Host "Restart your terminal or run:"
Write-Host '  source ~/.nurl/api.nu' -ForegroundColor Blue
Write-Host ""
Write-Host "Then try:"
Write-Host "  api help" -ForegroundColor Blue
Write-Host "  api collection list" -ForegroundColor Blue
Write-Host "  api send get-posts -c jsonplaceholder" -ForegroundColor Blue
Write-Host "  api chain run example-workflow -c jsonplaceholder" -ForegroundColor Blue
