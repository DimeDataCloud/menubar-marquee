#!/bin/bash
# Installs MenuBarMarquee to ~/Applications and sets it to start at login.
# Uses the prebuilt app if one is present, otherwise builds from source.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MenuBarMarquee"
LABEL="cloud.dimedata.menubarmarquee"
DEST="${HOME}/Applications/${APP_NAME}.app"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

REPO="DimeDataCloud/menubar-marquee"
RELEASE_URL="https://github.com/${REPO}/releases/latest/download/MenuBarMarquee.zip"

# Resolution order, cheapest first:
#   1. the .app shipped beside this script (the release zip)
#   2. a previous local build
#   3. download the prebuilt app  <- the no-Xcode path
#   4. compile from source        <- only if the download is unreachable
SRC=""
if   [ -d "${APP_NAME}.app" ];       then SRC="${APP_NAME}.app"
elif [ -d "dist/${APP_NAME}.app" ];  then SRC="dist/${APP_NAME}.app"
elif [ -d "build/${APP_NAME}.app" ]; then SRC="build/${APP_NAME}.app"
else
  echo "==> No prebuilt app here — fetching the latest release"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  # The repo is private, so try the authenticated route first. `gh` carries the
  # user's own credentials; plain curl cannot see a private release asset.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "    using your GitHub sign-in (gh)"
    gh release download latest --repo "$REPO" --pattern "MenuBarMarquee.zip" \
       --dir "$TMP" --clobber >/dev/null 2>&1 || true
  fi

  # Public fallback, for when the repo is opened up later.
  if [ ! -f "$TMP/MenuBarMarquee.zip" ]; then
    curl -fsSL "$RELEASE_URL" -o "$TMP/MenuBarMarquee.zip" 2>/dev/null || true
  fi

  if [ -f "$TMP/MenuBarMarquee.zip" ] && unzip -q "$TMP/MenuBarMarquee.zip" -d "$TMP"; then
    FOUND="$(find "$TMP" -maxdepth 3 -name "${APP_NAME}.app" -type d | head -1)"
    if [ -n "$FOUND" ]; then
      SRC="$FOUND"
      echo "    got the prebuilt universal app — no compiler needed"
    fi
  fi
fi

if [ -z "$SRC" ] && [ -f "build.sh" ]; then
  echo "    download unavailable — not signed in to GitHub, or no network"
  echo "    (sign in with:  gh auth login)"
  echo "==> Compiling from source instead — needs Xcode Command Line Tools"
  if ! command -v swift >/dev/null 2>&1; then
    echo >&2
    echo "error: no prebuilt app, and swift is not installed." >&2
    echo "       Either install the tools:  xcode-select --install" >&2
    echo "       or download the ready-made app from:" >&2
    echo "       https://github.com/DimeDataCloud/menubar-marquee/releases/latest" >&2
    exit 1
  fi
  ./build.sh
  SRC="build/${APP_NAME}.app"
fi

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo >&2
  echo "error: could not obtain ${APP_NAME}.app." >&2
  echo "       Sign in with 'gh auth login' and re-run, or download it from:" >&2
  echo "       https://github.com/${REPO}/releases/latest" >&2
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
