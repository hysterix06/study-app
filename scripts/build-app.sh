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

echo "→ Rendering icon"
python3 scripts/make_icon_svg.py >/dev/null
ICONWORK="$DIST/icon-work"
mkdir -p "$ICONWORK"
qlmanage -t -s 1024 -o "$ICONWORK" Resources/Icon/AppIcon.svg >/dev/null 2>&1
MASTER="$ICONWORK/AppIcon.svg.png"
ICONSET="$ICONWORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICONWORK/AppIcon.icns"
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
  <key>CFBundleIdentifier</key><string>com.studytracker.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Study Tracker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
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

echo "→ Signing (ad hoc)"
codesign --force --sign - "$APP/Contents/MacOS/study-mcp"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications"
  if pgrep -x StudyTracker >/dev/null; then osascript -e 'quit app "Study Tracker"' || true; sleep 1; fi
  ditto "$APP" "/Applications/Study Tracker.app"
  echo "Installed: /Applications/Study Tracker.app"
fi

echo "Done: $APP"
echo "      $DIST/study-tracker.mcpb"
