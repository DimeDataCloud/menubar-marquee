#!/bin/bash
# Installs MenuBarMarquee to ~/Applications and sets it to start at login.
# Uses the prebuilt app if one is present, otherwise builds from source.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MenuBarMarquee"
LABEL="cloud.dimedata.menubarmarquee"
DEST="${HOME}/Applications/${APP_NAME}.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

# In the download, the .app sits right next to this script — no toolchain
# needed. Building from source is only the last resort, for repo clones.
if   [ -d "${APP_NAME}.app" ];       then SRC="${APP_NAME}.app"
elif [ -d "dist/${APP_NAME}.app" ];  then SRC="dist/${APP_NAME}.app"
elif [ -d "build/${APP_NAME}.app" ]; then SRC="build/${APP_NAME}.app"
elif [ -f "build.sh" ]; then
  echo "==> No prebuilt app here — building from source (needs Xcode tools)"
  ./build.sh
  SRC="build/${APP_NAME}.app"
else
  echo "error: ${APP_NAME}.app not found next to this script." >&2
  echo "       Re-download the zip and run install.sh from inside it." >&2
  exit 1
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
echo "Installed."
echo
echo "  One thing left: macOS will ask for Accessibility permission."
echo "  Approve it. The app uses it to find exactly where the frontmost app's"
echo "  menus end, so the strip lands in real free space instead of on top of"
echo "  them. Without it the marquee stays hidden — it will not guess."
echo
echo "  System Settings > Privacy & Security > Accessibility > MenuBarMarquee"
echo
echo "  Settings + Quit:  the grid icon in your menu bar"
echo "  Uninstall:        ./uninstall.sh"
