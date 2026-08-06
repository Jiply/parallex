#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Parallex"
BUNDLE_ID="org.curvelabs.Parallex"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PARALLEX_ARCH="$(uname -m)"
ICON_GENERATOR="$BUILD_DIR/GenerateParallexIcon"

case "$MODE" in
  build|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|icon)
    ;;
  *)
    echo "usage: $0 [build|run|icon|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

mkdir -p "$MODULE_CACHE_DIR"

if [[ "$MODE" == "icon" ]]; then
  swiftc \
    -swift-version 5 \
    -target "$PARALLEX_ARCH-apple-macos14.0" \
    -module-cache-path "$MODULE_CACHE_DIR" \
    "$ROOT_DIR/Sources/ParallexIcon.swift" \
    "$ROOT_DIR/script/generate_icon.swift" \
    -o "$ICON_GENERATOR" \
    -framework AppKit
  "$ICON_GENERATOR" "$ROOT_DIR/Resources/$APP_NAME.icns"
  exit 0
fi

if [[ "$MODE" != "build" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target "$PARALLEX_ARCH-apple-macos14.0" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ROOT_DIR/Sources/ParallexApp.swift" \
  "$ROOT_DIR/Sources/CodexMonitor.swift" \
  "$ROOT_DIR/Sources/CodexProfileManager.swift" \
  "$ROOT_DIR/Sources/CodexScanner.swift" \
  "$ROOT_DIR/Sources/ParallexIcon.swift" \
  "$ROOT_DIR/Sources/StatusItemController.swift" \
  -o "$BUILD_DIR/$APP_NAME" \
  -framework AppKit \
  -framework Combine

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$ROOT_DIR/Resources/$APP_NAME.icns" "$APP_RESOURCES/$APP_NAME.icns"
cp "$ROOT_DIR/CODEX_SETUP_PROMPT.md" "$APP_RESOURCES/CODEX_SETUP_PROMPT.md"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_NAME.icns</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..40}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not remain running" >&2
    exit 1
    ;;
esac
