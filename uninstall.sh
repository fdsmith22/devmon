#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# DevMon Uninstaller
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

info() { printf "${GREEN}[+]${NC} %s\n" "$1"; }

printf "\n${BOLD}DevMon Uninstaller${NC}\n"
printf "════════════════════\n\n"

# Stop agents
info "Unloading LaunchAgents..."
launchctl unload "$HOME/Library/LaunchAgents/com.devmon.monitor.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.devmon.cache-clean.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.devmon.menubar.plist" 2>/dev/null || true

# Kill menu bar app
pkill -f "DevMon.app/Contents/MacOS/DevMon" 2>/dev/null || true

# Remove files
info "Removing binaries..."
rm -f "$HOME/.local/bin/devmon"
rm -f "$HOME/.local/bin/devmon-menubar"
rm -f "$HOME/.local/bin/devmon-cache-clean"
rm -f "$HOME/.local/bin/devmon-build-menubar"

info "Removing app bundle..."
rm -rf "$HOME/.local/share/devmon"

info "Removing LaunchAgents..."
rm -f "$HOME/Library/LaunchAgents/com.devmon.monitor.plist"
rm -f "$HOME/Library/LaunchAgents/com.devmon.cache-clean.plist"
rm -f "$HOME/Library/LaunchAgents/com.devmon.menubar.plist"

printf "\n${BOLD}${GREEN}DevMon uninstalled.${NC}\n\n"
printf "  Config preserved at: ~/.config/devmon/\n"
printf "  Logs preserved at:   ~/Library/Logs/devmon/\n"
printf "  Remove manually if you don't need them.\n\n"
