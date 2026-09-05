#!/usr/bin/env bash
# Build VibeJuice.app from the Swift package and optionally launch it.
#   scripts/bundle.sh          build + open
#   scripts/bundle.sh --no-open
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
# BIN can point at an already built binary (Homebrew formula does this); otherwise build here.
if [[ -z "${BIN:-}" ]]; then
  swift build -c release 2>&1 | tail -3
  BIN="$(swift build -c release --show-bin-path)/VibeJuice"
fi
APP="build/VibeJuice.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeJuice"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VibeJuice</string>
  <key>CFBundleDisplayName</key><string>VibeJuice</string>
  <key>CFBundleIdentifier</key><string>dev.samuel.vibejuice</string>
  <key>CFBundleExecutable</key><string>VibeJuice</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>VibeJuice opens Terminal to start Claude Code or Codex with the selected account.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Stable identity if available (see scripts/make-signing-cert.sh), ad hoc otherwise.
CODESIGN_ID="${CODESIGN_ID:-VibeJuice Dev}"
if security find-identity -v -p codesigning | grep -q "\"$CODESIGN_ID\""; then
  codesign --force --sign "$CODESIGN_ID" --identifier dev.samuel.vibejuice "$APP" 2>/dev/null
  echo "signed with $CODESIGN_ID"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "signed ad hoc (run scripts/make-signing-cert.sh once to stop Keychain prompts)"
fi
echo "built $APP"

if [[ "${1:-}" != "--no-open" ]]; then
  pkill -x VibeJuice 2>/dev/null || true
  open "$APP"
fi
