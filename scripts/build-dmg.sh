#!/bin/bash
set -euo pipefail

# Build a distributable DMG for CUA
# Usage: ./scripts/build-dmg.sh

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CUA"
BUNDLE_ID="com.adiarora.cua"
VERSION="1.0.0"

BUILD_DIR="$PROJECT_DIR/.build/release"
STAGING_DIR="$PROJECT_DIR/.build/dmg-staging"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"

echo "=== Building $APP_NAME.dmg ==="

# Step 1: Release build
echo "[1/4] Building release binary..."
swift build -c release 2>&1 | grep -E "(Build complete|error:)" || true

if [ ! -f "$BUILD_DIR/$APP_NAME" ]; then
    echo "ERROR: Release binary not found at $BUILD_DIR/$APP_NAME"
    exit 1
fi

# Step 2: Create .app bundle
echo "[2/4] Creating app bundle..."
rm -rf "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon if it exists
if [ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Step 3: Ad-hoc code sign (allows running without developer cert)
echo "[3/4] Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || echo "Warning: codesign failed (app will still work with right-click → Open)"

# Step 4: Create DMG
echo "[4/4] Creating DMG..."
rm -f "$DMG_PATH"

# Create a temporary DMG, copy app + symlink to /Applications, then convert to compressed
TEMP_DMG="$PROJECT_DIR/.build/tmp-cua.dmg"
rm -f "$TEMP_DMG"

hdiutil create -size 200m -fs HFS+ -volname "$APP_NAME" "$TEMP_DMG" -quiet
MOUNT_DIR=$(hdiutil attach "$TEMP_DMG" -nobrowse | sed -n 's/.*\(\/Volumes\/.*\)/\1/p' | head -1)
echo "  Mounted at: $MOUNT_DIR"

cp -R "$APP_BUNDLE" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

# Set background and icon layout (best-effort)
echo '
tell application "Finder"
    tell disk "CUA"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 400}
        set theViewOptions to the icon view options of container window
        set icon size of theViewOptions to 96
        set arrangement of theViewOptions to not arranged
        set position of item "CUA.app" of container window to {150, 150}
        set position of item "Applications" of container window to {390, 150}
        close
    end tell
end tell
' | osascript 2>/dev/null || true

hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH" -quiet
rm -f "$TEMP_DMG"

# Clean up staging
rm -rf "$STAGING_DIR"

DMG_SIZE=$(du -h "$DMG_PATH" | awk '{print $1}')
echo ""
echo "=== Done! ==="
echo "DMG: $DMG_PATH ($DMG_SIZE)"
echo ""
echo "To install: open DMG, drag CUA to Applications."
echo "First launch: right-click CUA.app → Open (bypasses Gatekeeper)."
echo "Grant permissions when prompted: Screen Recording, Accessibility, Microphone."
