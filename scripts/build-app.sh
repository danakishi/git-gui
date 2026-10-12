#!/bin/zsh
# Builds GitGui.app from the SwiftPM package.
#
#   scripts/build-app.sh            # debug build into .build/GitGui.app
#   scripts/build-app.sh release    # release build
#   scripts/build-app.sh run        # debug build and launch
#   scripts/build-app.sh release run
#   scripts/build-app.sh release universal   # arm64 + x86_64, for distribution

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
RUN=0
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    release) CONFIG=release ;;
    run) RUN=1 ;;
    universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

NAME=GitGui
BUNDLE_ID=com.danakishi.gitgui
APP=".build/$NAME.app"
BIN=$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)

swift build -c "$CONFIG" "${ARCHS[@]}" --product "$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"

# SwiftPM resource bundles, if any appear.
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
VERSION=${VERSION#v}   # tag v1.2.3 -> version 1.2.3
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for running locally.
codesign --force --sign - "$APP" >/dev/null

echo "Built: $APP ($CONFIG, $VERSION)"

if [[ $RUN == 1 ]]; then
  open "$APP"
fi
