#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="NowPlaying"
APP_BUNDLE="${APP_NAME}.app"
BUILD_DIR="build"
RES_DIR="${BUILD_DIR}/${APP_BUNDLE}/Contents/Resources"
BIN_DIR="${BUILD_DIR}/${APP_BUNDLE}/Contents/MacOS"

rm -rf "${BUILD_DIR}"
mkdir -p "${BIN_DIR}" "${RES_DIR}"

echo "Compiling MediaRemoteAdapter.dylib…"
clang -dynamiclib -fobjc-arc -fvisibility=hidden -O2 \
    -framework Foundation -framework CoreFoundation \
    -o "${RES_DIR}/MediaRemoteAdapter.dylib" \
    Sources/MediaRemoteAdapter.m

echo "Copying adapter.pl…"
cp Resources/adapter.pl "${RES_DIR}/adapter.pl"
chmod +x "${RES_DIR}/adapter.pl"

echo "Copying AppIcon.icns…"
cp Resources/AppIcon.icns "${RES_DIR}/AppIcon.icns"

echo "Compiling Swift…"
swiftc -O \
    -framework Cocoa \
    -o "${BIN_DIR}/${APP_NAME}" \
    Sources/main.swift

cp Resources/Info.plist "${BUILD_DIR}/${APP_BUNDLE}/Contents/Info.plist"

# Pick a code-signing identity. Defaults to "dj"; override with e.g.
#   IDENTITY=MyDevCert ./build.sh
# If the requested identity isn't in the keychain, fall back to ad-hoc
# signing so a fresh clone still builds — at the cost of macOS re-prompting
# for Accessibility permission after each rebuild.
IDENTITY="${IDENTITY:-dj}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qE "\"${IDENTITY}\""; then
    echo "Warning: code-signing identity '${IDENTITY}' not found in keychain; falling back to ad-hoc signing." >&2
    echo "         (See README → 'Code signing for development' to make Accessibility permission persist.)" >&2
    IDENTITY="-"
fi

# Strip xattrs and sign. iCloud Drive races us by re-adding FinderInfo
# to the bundle, so retry a few times until codesign succeeds.
for attempt in 1 2 3 4 5; do
    xattr -cr "${BUILD_DIR}/${APP_BUNDLE}" 2>/dev/null || true
    xattr -d com.apple.FinderInfo "${BUILD_DIR}/${APP_BUNDLE}" 2>/dev/null || true
    dot_clean -m "${BUILD_DIR}/${APP_BUNDLE}" 2>/dev/null || true
    if codesign --force --deep --sign "${IDENTITY}" "${BUILD_DIR}/${APP_BUNDLE}" 2>/dev/null; then
        break
    fi
    if [[ $attempt -eq 5 ]]; then
        echo "codesign failed after 5 attempts" >&2
        exit 1
    fi
    sleep 0.3
done

echo "Built ${BUILD_DIR}/${APP_BUNDLE}"
echo "Run with: open ${BUILD_DIR}/${APP_BUNDLE}"
