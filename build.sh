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

# A universal build needs the full Xcode SDK. With only the Command Line Tools
# it fails, so fall back to this machine's own architecture — that still runs
# perfectly well on this machine, which is all a local install needs.
#
# Errors are NOT swallowed here: a hidden compiler error is indistinguishable
# from "universal is unsupported", and that made a real failure unreadable.
BIN=""
echo "==> Compiling (trying universal: arm64 + x86_64)"
if swift build -c release --arch arm64 --arch x86_64; then
  CANDIDATE="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)/${APP_NAME}"
  [ -f "$CANDIDATE" ] && BIN="$CANDIDATE"
fi

if [ -z "$BIN" ]; then
  echo
  echo "==> Universal build unavailable — compiling for $(uname -m) only"
  echo "    (fine for running locally; full Xcode is needed for a universal binary)"
  swift build -c release
  CANDIDATE="$(swift build -c release --show-bin-path 2>/dev/null)/${APP_NAME}"
  [ -f "$CANDIDATE" ] && BIN="$CANDIDATE"
fi

# Last resort: SwiftPM has moved --show-bin-path's meaning between versions, so
# if the reported path is wrong, go find the binary.
if [ -z "$BIN" ]; then
  BIN="$(find .build -type f -name "$APP_NAME" -perm -u+x 2>/dev/null | head -1)"
fi

if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo >&2
  echo "error: compiled, but the ${APP_NAME} binary could not be located." >&2
  echo "       Looked under .build/. Please open an issue with the output above." >&2
  exit 1
fi
echo "==> Using binary: ${BIN}"

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
