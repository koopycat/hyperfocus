#!/usr/bin/env bash
#
# generate-icons.sh
#
# Regenerates the smaller Hyperfocus macOS app-icon sizes from the designed
# 1024px master. This keeps every AppIcon.appiconset slot consistent without
# replacing the designed artwork with a placeholder.
#
# Tooling: uses `sips`, which ships with macOS.
#
# Usage:
#     ./scripts/generate-icons.sh
#
# Master source:
#     Hyperfocus/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
#
# Outputs:
#     Hyperfocus/Resources/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512}.png
#

set -euo pipefail

# MARK: - Configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/Hyperfocus/Resources/Assets.xcassets/AppIcon.appiconset"
MASTER_ICON="$OUTPUT_DIR/icon_1024.png"
SIZES=(16 32 64 128 256 512)

# MARK: - Sanity checks

if ! command -v sips >/dev/null 2>&1; then
    echo "error: 'sips' is required but was not found in PATH." >&2
    echo "       sips ships with macOS by default." >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "error: expected AppIcon.appiconset at:" >&2
    echo "       $OUTPUT_DIR" >&2
    echo "       Run this script from the project root, or create the" >&2
    echo "       directory first." >&2
    exit 1
fi

if [[ ! -f "$MASTER_ICON" ]]; then
    echo "error: expected designed 1024px master icon at:" >&2
    echo "       $MASTER_ICON" >&2
    exit 1
fi

# MARK: - Generate

echo "Regenerating Hyperfocus app icon sizes from the designed master..."
echo "  Output: $OUTPUT_DIR"
echo

for size in "${SIZES[@]}"; do
    out="$OUTPUT_DIR/icon_${size}.png"
    sips -z "$size" "$size" "$MASTER_ICON" --out "$out" >/dev/null
    printf "  ✓ icon_%d.png  (%dx%d)\n" "$size" "$size" "$size"
done

echo
echo "Done. Regenerated ${#SIZES[@]} app-icon sizes from icon_1024.png."
