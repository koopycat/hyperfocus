#!/bin/bash
# Build Hyperfocus.app using only Command Line Tools (no Xcode required).
# Metal shaders are compiled at runtime from source.
set -euo pipefail

APP_NAME="Hyperfocus"
BUNDLE_ID="com.hyperfocus.app"
DEPLOYMENT_TARGET="12.3"
MARKETING_VERSION="1.0"
BUILD_VERSION="1"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$SRC_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_FILES=$(find "$SRC_DIR/$APP_NAME" -name '*.swift' | sort)

echo "=== Building $APP_NAME ==="
echo "SDK: $SDK_PATH"
echo "Target: macOS $DEPLOYMENT_TARGET"
echo ""

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Generate icons (placeholders)
echo "→ Generating app icons..."
bash "$SRC_DIR/scripts/generate-icons.sh"

# Compile Swift
echo "→ Compiling Swift ($(echo "$SWIFT_FILES" | wc -l) files)..."
swiftc \
    -target arm64-apple-macosx$DEPLOYMENT_TARGET \
    -sdk "$SDK_PATH" \
    -F "$SDK_PATH/System/Library/Frameworks" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Metal \
    -framework MetalKit \
    -framework ScreenCaptureKit \
    -framework CoreVideo \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework QuartzCore \
    -parse-as-library \
    -O \
    -o "$MACOS_DIR/$APP_NAME" \
    $SWIFT_FILES

echo "   ✓ Binary: $(du -h "$MACOS_DIR/$APP_NAME" | cut -f1)"

# Copy resources
echo "→ Copying resources..."
cp "$SRC_DIR/$APP_NAME/Resources/Info.plist" "$CONTENTS/Info.plist"

# Xcode expands these build-setting placeholders automatically. This direct
# swiftc build does not, so write concrete values before signing/launching.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$CONTENTS/Info.plist"

# Copy Metal shader source (compiled at runtime)
cp "$SRC_DIR/$APP_NAME/RenderPipeline/BlurDesatShaders.metal" "$RESOURCES_DIR/BlurDesatShaders.metal"

# Copy app icons
if [ -d "$SRC_DIR/$APP_NAME/Resources/Assets.xcassets/AppIcon.appiconset" ]; then
    cp "$SRC_DIR"/$APP_NAME/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$RESOURCES_DIR/" 2>/dev/null || true
fi

# Create PkgInfo
echo "APPL????" > "$CONTENTS/PkgInfo"

# Codesign (ad-hoc for development)
echo "→ Signing (ad-hoc)..."
if codesign --force --deep --options runtime --sign "Hyperfocus-Dev" "$APP_BUNDLE" 2>/dev/null; then
    echo "   ✓ Signed (Hyperfocus-Dev identity)"
elif codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null; then
    echo "   ✓ Signed (ad-hoc fallback)"
else
    echo "   ⚠ Signing skipped"
fi

echo ""
echo "=== Build Complete ==="
echo "App: $APP_BUNDLE"
echo "Run: open '$APP_BUNDLE'"
echo ""
echo "To distribute: codesign with Developer ID and notarize."
