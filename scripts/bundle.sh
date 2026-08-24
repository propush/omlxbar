#!/usr/bin/env bash
# Build omlxbar and assemble it into a runnable .app bundle.
#
#   ./scripts/bundle.sh              build + bundle into build/omlxbar.app
#   ./scripts/bundle.sh --install    also copy into /Applications and relaunch
#   ./scripts/bundle.sh --debug      bundle the debug build instead of release

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
	case "$arg" in
		--install) INSTALL=1 ;;
		--debug) CONFIG=debug ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

APP_NAME=omlxbar
APP="build/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# An ad-hoc signature gives the app a stable identity, which SMAppService
# (Launch at Login) and the hotkey registration both rely on.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
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
