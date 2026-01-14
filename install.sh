#!/bin/bash
# Nurl Installation Script for Linux/macOS
# Usage: curl -sSL https://raw.githubusercontent.com/chand45/Nurl/main/install.sh | bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NURL_HOME="$HOME/.nurl"
REPO_URL="https://raw.githubusercontent.com/chand45/Nurl/main"
NUSHELL_CONFIG_DIR="$HOME/.config/nushell"

echo -e "${BLUE}Installing Nurl - Terminal API Client${NC}"
echo ""

# Check if nushell is installed
if ! command -v nu &> /dev/null; then
    echo -e "${RED}Error: Nushell is not installed.${NC}"
    echo "Please install Nushell first: https://www.nushell.sh/book/installation.html"
    exit 1
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
    echo -e "${RED}Error: curl is not installed.${NC}"
    echo "Please install curl first."
    exit 1
fi

# Check if this is an update
IS_UPDATE=false
if [ -d "$NURL_HOME" ]; then
    IS_UPDATE=true
    echo -e "${YELLOW}Existing installation detected. Updating...${NC}"
fi

# Create directory structure
echo -e "[1/4] Creating ~/.nurl directory structure..."
mkdir -p "$NURL_HOME"
mkdir -p "$NURL_HOME/nu_modules"
mkdir -p "$NURL_HOME/collections"
mkdir -p "$NURL_HOME/chains"
mkdir -p "$NURL_HOME/history"

# Download core files
echo -e "[2/4] Downloading nurl files..."

# Download api.nu
curl -sSL "$REPO_URL/api.nu" -o "$NURL_HOME/api.nu"

# Download nu_modules
MODULES=("mod.nu" "http.nu" "auth.nu" "vars.nu" "history.nu" "chain.nu" "tui.nu" "log.nu")
for module in "${MODULES[@]}"; do
    curl -sSL "$REPO_URL/nu_modules/$module" -o "$NURL_HOME/nu_modules/$module"
done

# Download example collection (jsonplaceholder) - only on fresh install
if [ ! -d "$NURL_HOME/collections/jsonplaceholder" ]; then
    echo -e "  Downloading example collection: jsonplaceholder"
    mkdir -p "$NURL_HOME/collections/jsonplaceholder/environments"
    mkdir -p "$NURL_HOME/collections/jsonplaceholder/requests"

    # Collection metadata
    curl -sSL "$REPO_URL/collections/jsonplaceholder/collection.nuon" -o "$NURL_HOME/collections/jsonplaceholder/collection.nuon"
    curl -sSL "$REPO_URL/collections/jsonplaceholder/meta.nuon" -o "$NURL_HOME/collections/jsonplaceholder/meta.nuon"

    # Environments
    ENVS=("default.nuon" "dev.nuon" "staging.nuon")
    for env in "${ENVS[@]}"; do
        curl -sSL "$REPO_URL/collections/jsonplaceholder/environments/$env" -o "$NURL_HOME/collections/jsonplaceholder/environments/$env"
    done

    # Requests
    REQUESTS=("create-post.nuon" "delete-post.nuon" "get-comments.nuon" "get-post.nuon" "get-posts.nuon" "get-users.nuon" "update-post.nuon")
    for req in "${REQUESTS[@]}"; do
        curl -sSL "$REPO_URL/collections/jsonplaceholder/requests/$req" -o "$NURL_HOME/collections/jsonplaceholder/requests/$req"
    done
fi

# Download example chain - only on fresh install
if [ ! -f "$NURL_HOME/chains/example-workflow.nuon" ]; then
    echo -e "  Downloading example chain: example-workflow"
    curl -sSL "$REPO_URL/chains/example-workflow.nuon" -o "$NURL_HOME/chains/example-workflow.nuon"
fi

# Create default configuration (only if not exists)
echo -e "[3/4] Creating default configuration..."

if [ ! -f "$NURL_HOME/config.nuon" ]; then
    cat > "$NURL_HOME/config.nuon" << 'EOF'
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
EOF
fi

if [ ! -f "$NURL_HOME/variables.nuon" ]; then
    echo "{}" > "$NURL_HOME/variables.nuon"
fi

if [ ! -f "$NURL_HOME/secrets.nuon" ]; then
    cat > "$NURL_HOME/secrets.nuon" << 'EOF'
{
    tokens: {}
    oauth: {}
    api_keys: {}
    basic_auth: {}
}
EOF
fi

# Add to Nushell config
echo -e "[4/4] Configuring Nushell..."

# Ensure nushell config directory exists
mkdir -p "$NUSHELL_CONFIG_DIR"

# Check if config.nu exists, create if not
if [ ! -f "$NUSHELL_CONFIG_DIR/config.nu" ]; then
    touch "$NUSHELL_CONFIG_DIR/config.nu"
fi

# Check if already configured
if grep -q "source ~/.nurl/api.nu" "$NUSHELL_CONFIG_DIR/config.nu" 2>/dev/null || \
   grep -q 'source \$"(\$env.HOME)/.nurl/api.nu"' "$NUSHELL_CONFIG_DIR/config.nu" 2>/dev/null || \
   grep -q "source.*\.nurl/api\.nu" "$NUSHELL_CONFIG_DIR/config.nu" 2>/dev/null; then
    echo -e "  Nushell config already includes nurl"
else
    echo '' >> "$NUSHELL_CONFIG_DIR/config.nu"
    echo '# Nurl - Terminal API Client' >> "$NUSHELL_CONFIG_DIR/config.nu"
    echo 'source ~/.nurl/api.nu' >> "$NUSHELL_CONFIG_DIR/config.nu"
    echo -e "  Added nurl to Nushell config"
fi

echo ""
if [ "$IS_UPDATE" = true ]; then
    echo -e "${GREEN}✓ Nurl updated successfully!${NC}"
    echo ""
    echo "Your data is preserved:"
    echo "  - collections/    ✓"
    echo "  - secrets.nuon    ✓"
    echo "  - history/        ✓"
    echo "  - config.nuon     ✓"
    echo "  - variables.nuon  ✓"
else
    echo -e "${GREEN}✓ Nurl installed successfully!${NC}"
    echo ""
    echo "Included examples to get you started:"
    echo "  - jsonplaceholder collection (7 sample requests)"
    echo "  - example-workflow chain (request chaining demo)"
fi

echo ""
echo "Restart your terminal or run:"
echo -e "  ${BLUE}source ~/.nurl/api.nu${NC}"
echo ""
echo "Then try:"
echo -e "  ${BLUE}api help${NC}"
echo -e "  ${BLUE}api collection list${NC}"
echo -e "  ${BLUE}api send get-posts -c jsonplaceholder${NC}"
echo -e "  ${BLUE}api chain run example-workflow -c jsonplaceholder${NC}"
