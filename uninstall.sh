#!/bin/bash
# Removes MenuBarMarquee completely.
set -euo pipefail

APP_NAME="MenuBarMarquee"
LABEL="cloud.dimedata.menubarmarquee"
DEST="${HOME}/Applications/${APP_NAME}.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

echo "==> Stopping"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Removing login item"
rm -f "$PLIST"

echo "==> Removing app"
rm -rf "$DEST"

echo "==> Removing saved settings"
defaults delete "$LABEL" 2>/dev/null || true

echo "Done. Nothing left behind."
