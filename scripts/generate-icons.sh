#!/usr/bin/env bash
#
# generate-icons.sh
#
# Generates simple colored-square placeholder PNGs for the Hyperfocus
# macOS app icon, at every size macOS expects (16, 32, 64, 128, 256,
# 512, 1024). The result is a flat solid-color icon — useful as a
# development placeholder until a real designed asset is provided.
#
# Tooling: uses `sips` (always shipped with macOS) for resizing, and
# `python3` (also always shipped with macOS) to synthesize the seed
# 1x1 PNG in the brand color.
#
# Usage:
#     ./scripts/generate-icons.sh
#
# Outputs:
#     Hyperfocus/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png
#

set -euo pipefail

# MARK: - Configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/Hyperfocus/Resources/Assets.xcassets/AppIcon.appiconset"

# Brand color (Hyperfocus indigo). Used to generate the 1x1 seed PNG
# that sips then scales up to the target sizes.
BRAND_HEX="6420FF"

# Pixel sizes we need to ship. These cover all 10 required entries in
# the AppIcon.appiconset/Contents.json (1x and 2x for 16, 32, 128, 256,
# 512 point sizes).
SIZES=(16 32 64 128 256 512 1024)

# MARK: - Sanity checks

if ! command -v sips >/dev/null 2>&1; then
    echo "error: 'sips' is required but was not found in PATH." >&2
    echo "       sips ships with macOS by default." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "error: 'python3' is required but was not found in PATH." >&2
    echo "       python3 ships with macOS by default." >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "error: expected AppIcon.appiconset at:" >&2
    echo "       $OUTPUT_DIR" >&2
    echo "       Run this script from the project root, or create the" >&2
    echo "       directory first." >&2
    exit 1
fi

# MARK: - Generate

TMP_DIR="$(mktemp -d -t hyperfocus-icons.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Build a 1x1 opaque PNG of the brand color via Python. We use Python
# (always present on macOS) because synthesizing a colored PNG byte-
# for-byte from bash is error-prone, and base64-encoded PNGs only ever
# cover a single color.
python3 - "$BRAND_HEX" "$TMP_DIR/base.png" <<'PY'
import struct, sys, zlib

hex_color = sys.argv[1].lstrip('#')
if len(hex_color) != 6:
    sys.exit("expected 6-digit hex color, got: " + hex_color)
r, g, b = (int(hex_color[i:i+2], 16) for i in (0, 2, 4))

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)  # 1x1, 8-bit RGB
raw  = b"\x00" + bytes((r, g, b))                  # filter byte + pixel
idat = zlib.compress(raw, 9)

png  = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", ihdr)
png += chunk(b"IDAT", idat)
png += chunk(b"IEND", b"")

with open(sys.argv[2], "wb") as f:
    f.write(png)
PY

# Verify the base PNG actually has a valid PNG signature.
magic=$(head -c 8 "$TMP_DIR/base.png" | xxd -p)
if [[ "$magic" != "89504e470d0a1a0a" ]]; then
    echo "error: generated base PNG does not have a valid PNG signature." >&2
    echo "       Got: $magic" >&2
    exit 1
fi

echo "Generating Hyperfocus app icon placeholders (#$BRAND_HEX)..."
echo "  Output: $OUTPUT_DIR"
echo

# Clear out any previously generated icons so the directory stays tidy.
find "$OUTPUT_DIR" -maxdepth 1 -name 'icon_*.png' -delete

for size in "${SIZES[@]}"; do
    out="$OUTPUT_DIR/icon_${size}.png"
    sips -z "$size" "$size" "$TMP_DIR/base.png" --out "$out" >/dev/null
    printf "  ✓ icon_%d.png  (%dx%d)\n" "$size" "$size" "$size"
done

echo
echo "Done. Generated ${#SIZES[@]} placeholder icons."
echo "Replace these with designed artwork before shipping."
