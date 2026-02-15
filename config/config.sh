#!/usr/bin/env bash
# DevMon Configuration
# Edit thresholds and whitelist to taste

# --- Memory Pressure Thresholds (percentage) ---
DEVMON_WARN_THRESHOLD=60
DEVMON_EMERGENCY_THRESHOLD=80

# --- Idle Thresholds (seconds) ---
# How long an orphaned process must exist before being killed
DEVMON_IDLE_NORMAL=1800      # 30 minutes
DEVMON_IDLE_EMERGENCY=600    # 10 minutes under memory pressure

# --- Port Scan Range ---
DEVMON_PORT_MIN=3000
DEVMON_PORT_MAX=9000

# --- Process Patterns ---
# Extended regex matching dev server processes
DEVMON_PROCESS_PATTERN='node|next-server|vite|webpack|esbuild|postcss|turbopack|ts-node|tsx'

# --- Whitelist ---
# Substrings matched against full command string; never kill these
DEVMON_WHITELIST=(
  "mongod"
  "context7-mcp"
  "claude"
  "Spotify"
  "code-helper"
  "copilot"
  ".vscode"
  "prettier"
  "eslint_d"
)

# --- Cache Cleanup Settings ---
# Used by devmon-cache-clean

DEVMON_CACHE_JETBRAINS_MAX_DAYS=7
DEVMON_CACHE_PLAYWRIGHT_MAX_DAYS=14
DEVMON_CACHE_NODE_MODULES_MAX_DAYS=30
DEVMON_CACHE_HOMEBREW_MAX_DAYS=14

# --- Logging ---
DEVMON_LOG_DIR="$HOME/Library/Logs/devmon"
DEVMON_LOG_MAX_SIZE=5242880    # 5MB before rotation
DEVMON_LOG_KEEP=3              # Keep 3 rotated logs

# --- State ---
DEVMON_STATE_DIR="$HOME/.config/devmon/state"

# --- Notifications ---
# Set to 0 to disable macOS notifications
DEVMON_NOTIFY=1
