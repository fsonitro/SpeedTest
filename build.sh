#!/bin/zsh
# Builds SpeedTest.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/SpeedTest.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SpeedTest"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpeedTest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SpeedTest 2>/dev/null || true
    rm -rf /Applications/SpeedTest.app
    cp -R "$APP" /Applications/
    open /Applications/SpeedTest.app
    echo "Installed to /Applications/SpeedTest.app"
fi
