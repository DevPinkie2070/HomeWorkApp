#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HomeWorkApp"
BUNDLE_ID="devplaceholder.zz4zkul6.homeworkapp"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
BUILD_APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BUNDLE="/Applications/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do
  kill "$pid" 2>/dev/null || true
done

xcodebuild \
  -project "$ROOT_DIR/HomeWorkApp.xcodeproj" \
  -scheme MyApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  build

if [ -d "$APP_BUNDLE" ]; then
  rm -rf "$APP_BUNDLE"
fi
ditto "$BUILD_APP_BUNDLE" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
