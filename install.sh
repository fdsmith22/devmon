#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# DevMon Installer
# One-command install for macOS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

# --- Pre-flight checks ---

if [[ "$(uname)" != "Darwin" ]]; then
    error "DevMon only supports macOS. Detected: $(uname)"
fi

if ! command -v swiftc &>/dev/null; then
    error "Swift compiler not found. Install Xcode Command Line Tools: xcode-select --install"
fi

printf "\n${BOLD}DevMon Installer${NC}\n"
printf "════════════════════\n\n"

# --- Create directories ---

info "Creating directories..."
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/share/devmon"
mkdir -p "$HOME/.config/devmon/state"
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs/devmon"

# --- Install CLI scripts ---

info "Installing CLI scripts to ~/.local/bin/"
cp "$REPO_DIR/bin/devmon" "$HOME/.local/bin/devmon"
cp "$REPO_DIR/bin/devmon-cache-clean" "$HOME/.local/bin/devmon-cache-clean"
chmod +x "$HOME/.local/bin/devmon" "$HOME/.local/bin/devmon-cache-clean"

# --- Install config (don't overwrite existing) ---

if [[ -f "$HOME/.config/devmon/config.sh" ]]; then
    warn "Config already exists at ~/.config/devmon/config.sh (keeping yours)"
else
    info "Installing default config to ~/.config/devmon/config.sh"
    cp "$REPO_DIR/config/config.sh" "$HOME/.config/devmon/config.sh"
fi

# --- Build menu bar app ---

info "Building menu bar app from source..."
cp "$REPO_DIR/src/DevMonMenuBar.swift" "$HOME/.local/share/devmon/DevMonMenuBar.swift"

swiftc -O \
    -o "$HOME/.local/bin/devmon-menubar" \
    "$HOME/.local/share/devmon/DevMonMenuBar.swift" \
    -framework AppKit 2>&1 | grep -v "warning:" || true

chmod +x "$HOME/.local/bin/devmon-menubar"

# Create app bundle
mkdir -p "$HOME/.local/share/devmon/DevMon.app/Contents/MacOS"
cp "$REPO_DIR/app/Info.plist" "$HOME/.local/share/devmon/DevMon.app/Contents/Info.plist"
cp "$HOME/.local/bin/devmon-menubar" "$HOME/.local/share/devmon/DevMon.app/Contents/MacOS/DevMon"
touch "$HOME/.local/share/devmon/DevMon.app"

# Ad-hoc sign
xattr -cr "$HOME/.local/share/devmon/DevMon.app" 2>/dev/null || true
codesign --sign - --force --deep "$HOME/.local/share/devmon/DevMon.app" 2>/dev/null || true

info "Menu bar app built and signed"

# --- Install build helper ---

cat > "$HOME/.local/bin/devmon-build-menubar" << 'BUILDEOF'
#!/usr/bin/env bash
set -euo pipefail
SWIFT_FILE="$HOME/.local/share/devmon/DevMonMenuBar.swift"
OUTPUT="$HOME/.local/bin/devmon-menubar"
[[ ! -f "$SWIFT_FILE" ]] && echo "Error: Source not found at $SWIFT_FILE" && exit 1
echo "Building DevMon menu bar app..."
swiftc -O -o "$OUTPUT" "$SWIFT_FILE" -framework AppKit
chmod +x "$OUTPUT"
echo "Built: $OUTPUT"
mkdir -p "$HOME/.local/share/devmon/DevMon.app/Contents/MacOS"
cp "$OUTPUT" "$HOME/.local/share/devmon/DevMon.app/Contents/MacOS/DevMon"
touch "$HOME/.local/share/devmon/DevMon.app"
xattr -cr "$HOME/.local/share/devmon/DevMon.app" 2>/dev/null
codesign --sign - --force --deep "$HOME/.local/share/devmon/DevMon.app" 2>/dev/null
echo "App bundle updated and signed: ~/.local/share/devmon/DevMon.app"
BUILDEOF
chmod +x "$HOME/.local/bin/devmon-build-menubar"

# --- Install LaunchAgents ---

info "Installing LaunchAgents..."

for template in "$REPO_DIR"/launchd/*.template; do
    local_name="$(basename "$template" .template)"
    sed "s|__HOME__|$HOME|g" "$template" > "$HOME/Library/LaunchAgents/$local_name"
done

# --- Add ~/.local/bin to PATH if needed ---

if ! echo "$PATH" | tr ':' '\n' | grep -q "$HOME/.local/bin"; then
    warn "~/.local/bin is not in your PATH"

    SHELL_RC=""
    if [[ "$SHELL" == *"zsh"* ]]; then
        SHELL_RC="$HOME/.zshrc"
    elif [[ "$SHELL" == *"bash"* ]]; then
        SHELL_RC="$HOME/.bashrc"
    fi

    if [[ -n "$SHELL_RC" ]]; then
        printf '\n# DevMon\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$SHELL_RC"
        info "Added to $SHELL_RC — restart your shell or run: source $SHELL_RC"
    else
        warn "Add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
fi

# --- Load agents ---

info "Loading LaunchAgents..."
launchctl load "$HOME/Library/LaunchAgents/com.devmon.monitor.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.devmon.cache-clean.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.devmon.menubar.plist" 2>/dev/null || true

# --- Launch menu bar app ---

info "Starting menu bar app..."
open -a "$HOME/.local/share/devmon/DevMon.app" 2>/dev/null || true

# --- Done ---

printf "\n${BOLD}${GREEN}DevMon installed successfully!${NC}\n\n"
printf "  ${BOLD}Quick start:${NC}\n"
printf "    devmon status       Show memory pressure & orphaned processes\n"
printf "    devmon kill         Interactively kill dev processes\n"
printf "    devmon clean        Clean caches (--dry-run to preview)\n"
printf "    devmon pause        Pause automatic monitoring\n"
printf "    devmon log          Watch the live log\n"
printf "\n"
printf "  ${BOLD}Menu bar:${NC}  Look for the colored dot + percentage in your menu bar\n"
printf "  ${BOLD}Shortcut:${NC}  Cmd+Shift+M toggles the menu bar popover\n"
printf "\n"
printf "  ${BOLD}Config:${NC}    ~/.config/devmon/config.sh\n"
printf "  ${BOLD}Logs:${NC}      ~/Library/Logs/devmon/\n"
printf "\n"
