#!/usr/bin/env bash
# Verify a packaged omlxbar app before publishing it.

set -euo pipefail

if [ "$#" -ne 3 ]; then
	echo "usage: $0 <app-path> <version> <architecture>" >&2
	exit 2
fi

APP="$1"
VERSION="$2"
ARCH="$3"
PLIST="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/omlxbar"

[ -d "$APP" ] || { echo "app bundle not found: $APP" >&2; exit 1; }
[ -f "$PLIST" ] || { echo "Info.plist not found: $PLIST" >&2; exit 1; }
[ -x "$BIN" ] || { echo "executable not found: $BIN" >&2; exit 1; }

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MINIMUM_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
ACTUAL_ARCHS="$(lipo -archs "$BIN")"

[ "$SHORT_VERSION" = "$VERSION" ] || {
	echo "unexpected CFBundleShortVersionString: $SHORT_VERSION" >&2
	exit 1
}
[ "$BUILD_VERSION" = "$VERSION" ] || {
	echo "unexpected CFBundleVersion: $BUILD_VERSION" >&2
	exit 1
}
[ "$MINIMUM_SYSTEM" = "14.0" ] || {
	echo "unexpected LSMinimumSystemVersion: $MINIMUM_SYSTEM" >&2
	exit 1
}
[ "$ACTUAL_ARCHS" = "$ARCH" ] || {
	echo "unexpected executable architectures: $ACTUAL_ARCHS" >&2
	exit 1
}

codesign --verify --deep --strict "$APP"
echo "verified $APP: version=$VERSION arch=$ARCH macOS>=$MINIMUM_SYSTEM"
