#!/bin/bash
# Installs MenuBarMarquee to ~/Applications and sets it to start at login.
# Uses the prebuilt app if one is present, otherwise builds from source.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MenuBarMarquee"
LABEL="cloud.dimedata.menubarmarquee"
DEST="${HOME}/Applications/${APP_NAME}.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

# Prefer a shipped binary (dist/), then a local build (build/), then compile.
if   [ -d "dist/${APP_NAME}.app" ];  then SRC="dist/${APP_NAME}.app"
elif [ -d "build/${APP_NAME}.app" ]; then SRC="build/${APP_NAME}.app"
else
  echo "==> No prebuilt app found — building from source"
  ./build.sh
  SRC="build/${APP_NAME}.app"
fi

echo "==> Stopping any running copy"
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> Installing to ${DEST}"
mkdir -p "${HOME}/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Downloaded zips carry a quarantine flag; without this macOS refuses to open
# the app and only offers "Move to Trash".
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Registering login item"
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>${DEST}/Contents/MacOS/${APP_NAME}</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"

echo
echo "Installed. The marquee is now scrolling in the centre of your menu bar."
echo
echo "  Settings + Quit:  the grid icon in your menu bar"
echo "  Uninstall:        ./uninstall.sh"
echo
echo "If it overlaps an app's menus, turn on Auto-Fit to App Menus in that menu,"
echo "or set a wider gap by hand (the value is saved, so this is a one-off):"
echo "  \"${DEST}/Contents/MacOS/${APP_NAME}\" --left 420 --right 460"
