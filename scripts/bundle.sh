#!/usr/bin/env bash
# Build omlxbar and assemble it into a runnable .app bundle.
#
#   ./scripts/bundle.sh              build + bundle into build/omlxbar.app
#   ./scripts/bundle.sh --install    also copy into /Applications and relaunch
#   ./scripts/bundle.sh --debug      bundle the debug build instead of release
#   ./scripts/bundle.sh --arch arm64 --version 1.2.3

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
ARCH=""
VERSION=""

usage() {
	cat <<'EOF'
usage: ./scripts/bundle.sh [--debug] [--install] [--arch arm64|x86_64] [--version X.Y.Z]
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install)
			INSTALL=1
			shift
			;;
		--debug)
			CONFIG=debug
			shift
			;;
		--arch)
			[ "$#" -ge 2 ] || { echo "--arch requires a value" >&2; usage >&2; exit 2; }
			ARCH="$2"
			shift 2
			;;
		--version)
			[ "$#" -ge 2 ] || { echo "--version requires a value" >&2; usage >&2; exit 2; }
			VERSION="$2"
			shift 2
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			echo "unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [ -n "$ARCH" ] && [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
	echo "unsupported architecture: $ARCH" >&2
	exit 2
fi

if [ -n "$VERSION" ] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "version must use X.Y.Z format: $VERSION" >&2
	exit 2
fi

APP_NAME=omlxbar
APP="build/${APP_NAME}.app"
DESIGNATED_REQUIREMENT='=designated => identifier "com.pushkin.omlxbar"'

echo "==> swift build -c ${CONFIG}"
BUILD_ARGS=(-c "$CONFIG")
if [ -n "$ARCH" ]; then
	BUILD_ARGS+=(--arch "$ARCH")
fi
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

if [ -n "$VERSION" ]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "${APP}/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "${APP}/Contents/Info.plist"
fi

# Keep a stable designated requirement across ad-hoc-signed releases. This is
# an operational identity for Service Management and Homebrew approval
# inheritance, not an Apple-verified publisher identity.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none --requirements "$DESIGNATED_REQUIREMENT" "$APP"
codesign --verify --deep --strict "$APP"

if [ "$INSTALL" -eq 1 ]; then
	echo "==> installing to /Applications"
	pkill -x "$APP_NAME" 2>/dev/null || true
	rm -rf "/Applications/${APP_NAME}.app"
	cp -R "$APP" "/Applications/${APP_NAME}.app"
	open "/Applications/${APP_NAME}.app"
	echo "installed and launched"
else
	echo "built ${APP} — run it with: open ${APP}"
fi
