#!/bin/bash
# Build, optionally sign, and package a universal Hyperfocus release.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-release.sh VERSION [--unsigned]

Builds dist/Hyperfocus-VERSION.dmg. Signed mode requires SIGNING_IDENTITY.
Unsigned mode is intended only for CI compilation checks and cannot be published.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
VERSION="$1"
shift
UNSIGNED=0
if [[ ${1:-} == "--unsigned" ]]; then
    UNSIGNED=1
    shift
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo "Version must be a stable semantic version such as 1.2.3" >&2
    exit 2
}
if [[ $UNSIGNED -eq 0 ]]; then
    for variable in SIGNING_IDENTITY APP_STORE_CONNECT_API_KEY_PATH APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
        [[ -n ${!variable:-} ]] || { echo "$variable is required unless --unsigned is used" >&2; exit 2; }
    done
fi
for command in xcodebuild lipo hdiutil ditto; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/build/release-derived-data"
DIST="$ROOT/dist"
APP="$DERIVED_DATA/Build/Products/Release/Hyperfocus.app"
DMG="$DIST/Hyperfocus-$VERSION.dmg"
STAGING="$ROOT/build/release-dmg"
APP_ZIP="$ROOT/build/Hyperfocus-$VERSION-notarization.zip"

cleanup() {
    rm -rf "$STAGING"
    rm -f "$APP_ZIP"
}
trap cleanup EXIT
rm -rf "$DERIVED_DATA" "$STAGING"
mkdir -p "$DIST" "$STAGING"
rm -f "$DMG" "$APP_ZIP"

xcodebuild \
    -project "$ROOT/Hyperfocus.xcodeproj" \
    -scheme Hyperfocus \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    clean build

[[ -d "$APP" ]] || { echo "Expected app was not built: $APP" >&2; exit 1; }
EXECUTABLE="$APP/Contents/MacOS/Hyperfocus"
architectures="$(lipo -archs "$EXECUTABLE")"
for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || {
        echo "Release executable is missing $architecture: $architectures" >&2
        exit 1
    }
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || {
    echo "Built app version does not match $VERSION" >&2
    exit 1
}

if [[ $UNSIGNED -eq 0 ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"

    NOTARY_ARGS=(
        --key "$APP_STORE_CONNECT_API_KEY_PATH"
        --key-id "$APP_STORE_CONNECT_API_KEY_ID"
        --issuer "$APP_STORE_CONNECT_ISSUER_ID"
    )
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --wait "${NOTARY_ARGS[@]}"
    rm -f "$APP_ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
else
    codesign --force --deep --options runtime --sign - "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

ditto "$APP" "$STAGING/Hyperfocus.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Hyperfocus -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ $UNSIGNED -eq 0 ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
    xcrun notarytool submit "$DMG" --wait "${NOTARY_ARGS[@]}"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

printf '%s\n' "$DMG"
