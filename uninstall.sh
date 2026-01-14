#!/bin/bash
# Nurl Uninstallation Script for Linux/macOS
# Usage: curl -sSL https://raw.githubusercontent.com/chand45/Nurl/main/uninstall.sh | bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NURL_HOME="$HOME/.nurl"
NUSHELL_CONFIG="$HOME/.config/nushell/config.nu"
BACKUP_DIR="$HOME/.nurl-backup-$(date +%Y%m%d-%H%M%S)"

echo -e "${BLUE}Uninstalling Nurl${NC}"
echo ""

# Check if nurl is installed
if [ ! -d "$NURL_HOME" ]; then
    echo -e "${YELLOW}Nurl is not installed at ~/.nurl${NC}"
    exit 0
fi

# Ask for confirmation
echo -e "${YELLOW}This will remove Nurl but preserve your data in a backup.${NC}"
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled"
    exit 0
fi

# Backup user data
echo "[1/3] Backing up user data..."
mkdir -p "$BACKUP_DIR"

# Copy user data files
if [ -f "$NURL_HOME/config.nuon" ]; then
    cp "$NURL_HOME/config.nuon" "$BACKUP_DIR/"
fi
if [ -f "$NURL_HOME/variables.nuon" ]; then
    cp "$NURL_HOME/variables.nuon" "$BACKUP_DIR/"
fi
if [ -f "$NURL_HOME/secrets.nuon" ]; then
    cp "$NURL_HOME/secrets.nuon" "$BACKUP_DIR/"
fi
if [ -d "$NURL_HOME/collections" ] && [ "$(ls -A $NURL_HOME/collections 2>/dev/null)" ]; then
    cp -r "$NURL_HOME/collections" "$BACKUP_DIR/"
fi
if [ -d "$NURL_HOME/chains" ] && [ "$(ls -A $NURL_HOME/chains 2>/dev/null)" ]; then
    cp -r "$NURL_HOME/chains" "$BACKUP_DIR/"
fi
if [ -d "$NURL_HOME/history" ] && [ "$(ls -A $NURL_HOME/history 2>/dev/null)" ]; then
    cp -r "$NURL_HOME/history" "$BACKUP_DIR/"
fi

# Remove nurl directory
echo "[2/3] Removing ~/.nurl..."
rm -rf "$NURL_HOME"

# Remove from Nushell config
echo "[3/3] Cleaning Nushell config..."
if [ -f "$NUSHELL_CONFIG" ]; then
    # Remove the nurl source line and comment
    sed -i.bak '/# Nurl - Terminal API Client/d' "$NUSHELL_CONFIG"
    sed -i.bak '/source.*\.nurl\/api\.nu/d' "$NUSHELL_CONFIG"
    rm -f "${NUSHELL_CONFIG}.bak"
fi

echo ""
echo -e "${GREEN}✓ Nurl uninstalled${NC}"
echo ""
echo "Your data has been backed up to:"
echo -e "  ${BLUE}$BACKUP_DIR${NC}"
echo ""
echo "To restore your data later, copy the backup contents to ~/.nurl/"
echo ""
echo "To fully remove all data (including backup), run:"
echo -e "  ${YELLOW}rm -rf $BACKUP_DIR${NC}"
