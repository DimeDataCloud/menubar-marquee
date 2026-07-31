#!/bin/bash
# Builds MenuBarMarquee.app. Needs Xcode Command Line Tools (`xcode-select --install`).
# End users do not run this — they get the prebuilt .app from Releases.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MenuBarMarquee"
BUNDLE_ID="cloud.dimedata.menubarmarquee"
OUT="build/${APP_NAME}.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found. Install the Xcode Command Line Tools:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling (universal: arm64 + x86_64)"
if ! swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  echo "    universal build unavailable, falling back to this machine's architecture"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
else
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
fi

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "$BIN" "${OUT}/Contents/MacOS/${APP_NAME}"
chmod +x "${OUT}/Contents/MacOS/${APP_NAME}"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Menu Bar Marquee</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Agent app: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not notarization — it just stops macOS from killing the
# binary outright on Apple silicon, and keeps the Accessibility grant stable
# across restarts instead of resetting on every launch.
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$OUT" >/dev/null 2>&1 || \
    echo "    (codesign failed — the app still runs, just re-grant Accessibility after updates)"
fi

echo "==> Built ${OUT}"
echo "    Install it with: ./install.sh"
