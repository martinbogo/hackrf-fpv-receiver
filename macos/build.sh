#!/bin/bash
# Builds "FPV Receiver.app": a self-contained Apple Silicon app with libhackrf and libusb linked
# statically, so it runs without Homebrew or Python on the target Mac.
#   Requires: Xcode command line tools, `brew install hackrf` (for the static libraries at build time).
set -euo pipefail
cd "$(dirname "$0")"

BREW="$(brew --prefix)"
APP="build/FPV Receiver.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos14.0 \
    -import-objc-header Sources/Bridging.h -I "$BREW/include" \
    Sources/*.swift \
    "$BREW/lib/libhackrf.a" "$BREW/lib/libusb-1.0.a" \
    -framework IOKit -framework CoreFoundation -framework Security \
    -o "$APP/Contents/MacOS/FPV Receiver"

cp Info.plist "$APP/Contents/Info.plist"
swift make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../LICENSE ../THIRD_PARTY_NOTICES.md ../licenses/* "$APP/Contents/Resources/Licenses/"

codesign --force --sign - "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
(cd build && ditto -c -k --keepParent "FPV Receiver.app" "FPV-Receiver-$VERSION-macOS-arm64.zip")
echo "Built $APP and build/FPV-Receiver-$VERSION-macOS-arm64.zip"
otool -L "$APP/Contents/MacOS/FPV Receiver" | grep -v -E "/System/|/usr/lib/" | tail -n +2 || true
