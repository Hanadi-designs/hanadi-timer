#!/bin/zsh
# Builds "Hanadi Timer.app". Everything it needs is in this folder.
#   ./build.sh                      → ~/Applications/Hanadi Timer.app
#   APP_DIR=/some/folder ./build.sh → /some/folder/Hanadi Timer.app
set -e
cd "${0:A:h}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Run:  xcode-select --install  then run ./build.sh again." >&2
  exit 1
fi

APP="${APP_DIR:-$HOME/Applications}/Hanadi Timer.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/hanadiTimer" main.swift notion.swift strings.swift
python3 make_sounds.py "$APP/Contents/Resources" >/dev/null

cp assets/logo.png "$APP/Contents/Resources/logo.png"
cp "assets/fonts/Raleway/Raleway[wght].ttf" "$APP/Contents/Resources/Raleway.ttf"
cp "assets/fonts/JetBrainsMono/JetBrainsMono[wght].ttf" "$APP/Contents/Resources/JetBrainsMono.ttf"
cp -R Resources/en.lproj Resources/ar.lproj "$APP/Contents/Resources/"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hanadi Timer</string>
  <key>CFBundleDisplayName</key><string>Hanadi Timer</string>
  <key>CFBundleIdentifier</key><string>com.hanadialotaibi.timer</string>
  <key>CFBundleExecutable</key><string>hanadiTimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ar</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Sign with a requirement that names the app, not this exact build, so the Keychain keeps trusting
# rebuilds of Hanadi Timer with the Notion token instead of asking again after every update.
codesign --force -s - -r='designated => identifier "com.hanadialotaibi.timer"' "$APP"
echo "Built: $APP"
