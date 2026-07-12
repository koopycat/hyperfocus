#!/bin/bash
set -euo pipefail

# Build and run the RendererHarness test app.
# This is an end-to-end test of the Metal Deep-mode pipeline that runs
# without requiring Screen Recording permission.

SRC_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$SRC_DIR/tests/RendererHarness"
APP_DIR="$TEST_DIR/Harness.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$SRC_DIR/Hyperfocus/RenderPipeline/BlurDesatShaders.metal" "$RES_DIR/"

cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundleIdentifier</key><string>com.hyperfocus.RendererHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF

swiftc -O -D DEBUG \
    -o "$MACOS_DIR/Harness" \
    "$TEST_DIR/main.swift" \
    "$SRC_DIR/Hyperfocus/RenderPipeline/DeepFilter.swift" \
    "$SRC_DIR/Hyperfocus/RenderPipeline/MetalBlurRenderer.swift" \
    "$SRC_DIR/Hyperfocus/OverlayEngine/OverlayWindowController.swift" \
    -framework Cocoa -framework Metal -framework MetalPerformanceShaders \
    -framework QuartzCore -framework CoreVideo

echo "=== Running RendererHarness ==="
"$MACOS_DIR/Harness"
