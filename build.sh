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

echo "Compiling Swift…"
swiftc -O \
    -framework Cocoa \
    -o "${BIN_DIR}/${APP_NAME}" \
    Sources/main.swift

cp Resources/Info.plist "${BUILD_DIR}/${APP_BUNDLE}/Contents/Info.plist"

# Strip xattrs that codesign rejects (e.g. com.apple.provenance from iCloud sync)
xattr -cr "${BUILD_DIR}/${APP_BUNDLE}"

# Ad-hoc sign so macOS lets us launch it
codesign --force --sign - "${RES_DIR}/MediaRemoteAdapter.dylib"
codesign --force --deep --sign - "${BUILD_DIR}/${APP_BUNDLE}"

echo "Built ${BUILD_DIR}/${APP_BUNDLE}"
echo "Run with: open ${BUILD_DIR}/${APP_BUNDLE}"
