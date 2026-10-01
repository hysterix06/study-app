#!/bin/zsh
# Builds dist/Study Tracker.app (with the MCP server and Claude Desktop extension inside) and dist/study-tracker.mcpb.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="1.0.0"
BUILD="$(date +%Y%m%d%H%M)"
DIST="$ROOT/dist"
APP="$DIST/Study Tracker.app"

echo "→ Building release binaries"
swift build -c release --product StudyTracker
swift build -c release --product study-mcp
BIN="$(swift build -c release --show-bin-path)"

echo "→ Compiling icon"
python3 scripts/make_icon.py >/dev/null
ICONWORK="$DIST/icon-work"
rm -rf "$ICONWORK"
mkdir -p "$ICONWORK"
# A compiled .icon (Assets.car + CFBundleIconName) is what lets macOS 26+ mask, light and tint the icon itself; an
# .icns alone gets shrunk into a system-drawn frame. actool also writes an .icns fallback for older macOS.
xcrun actool Resources/Icon/AppIcon.icon --compile "$ICONWORK" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICONWORK/partial.plist" >/dev/null
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
MASTER="$ICONWORK/AppIcon-1024.png"
"$ICTOOL" Resources/Icon/AppIcon.icon --export-image --output-file "$MASTER" --platform macOS --rendition Default \
  --width 1024 --height 1024 --scale 1 >/dev/null
cp "$MASTER" Resources/Icon/AppIcon-1024.png

echo "→ Packaging the Claude Desktop extension (.mcpb)"
MCPB="$DIST/mcpb"
mkdir -p "$MCPB/server"
cp "$BIN/study-mcp" "$MCPB/server/study-mcp"
sips -z 512 512 "$MASTER" --out "$MCPB/icon.png" >/dev/null
cp Resources/MCPB/manifest.json "$MCPB/manifest.json"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$MCPB/manifest.json"
codesign --force --sign - "$MCPB/server/study-mcp"
(cd "$MCPB" && zip -q -r -X "$DIST/study-tracker.mcpb" manifest.json icon.png server)

echo "→ Assembling the app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/StudyTracker" "$APP/Contents/MacOS/StudyTracker"
cp "$BIN/study-mcp" "$APP/Contents/MacOS/study-mcp"
cp "$ICONWORK/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ICONWORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$DIST/study-tracker.mcpb" "$APP/Contents/Resources/study-tracker.mcpb"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Study Tracker</string>
  <key>CFBundleExecutable</key><string>StudyTracker</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.studytracker.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Study Tracker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.studytracker.app.route</string>
      <key>CFBundleURLSchemes</key><array><string>studytracker</string></array>
    </dict>
  </array>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Your data stays on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Study Tracker adds your classes, deadlines and planned study to a "Study Tracker" calendar so they appear on your iPhone and Watch.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Study Tracker adds your deadlines to a "Study Tracker" reminders list.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
</dict>
</plist>
PLIST

# An ad-hoc signature changes with every build, so the Keychain treats each build as a new app and asks for the
# Mac's password again. A real certificate keeps "Always Allow" working across rebuilds. SIGN_IDENTITY overrides.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then echo "→ Signing (ad hoc; expect Keychain prompts after each rebuild)"; else echo "→ Signing as $SIGN_IDENTITY"; fi
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/study-mcp"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications"
  if pgrep -x StudyTracker >/dev/null; then osascript -e 'quit app "Study Tracker"' || true; sleep 1; fi
  INSTALLED="/Applications/Study Tracker.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  ditto "$APP" "$INSTALLED"
  # The staged copy has the same bundle ID, so it would show up as a second app in Apps and Spotlight.
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true   # fails harmlessly if it was never registered
  rm -rf "$APP"
  # Finder and the Dock cache icons per bundle; re-register so a changed icon shows up without a logout.
  touch "$INSTALLED"
  "$LSREGISTER" -f "$INSTALLED"
  killall Dock 2>/dev/null || true
  APP="$INSTALLED"
fi

echo "Done: $APP"
echo "      $DIST/study-tracker.mcpb"
