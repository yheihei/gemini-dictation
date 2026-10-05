#!/bin/bash
# Builds GeminiDictation.app with SwiftPM. Defaults to ad hoc signing.
# Needs only the Xcode Command Line Tools. Nothing is installed outside this folder.
#
#   ./scripts/build-app.sh                                  # build/GeminiDictation.app
#   APP_PATH=build/next/GeminiDictation.app ./scripts/build-app.sh
#
# The script refuses to replace an app bundle that is running right now.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
app="${APP_PATH:-build/GeminiDictation.app}"
identity="${SIGNING_IDENTITY:--}"

if [[ "$app" != *.app ]]; then
    echo "error: APP_PATH must end with .app" >&2
    exit 1
fi
mkdir -p "$(dirname "$app")"
target="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")/Contents/MacOS/GeminiDictation"
for pid in $(pgrep -x GeminiDictation || true); do
    running="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    if [[ "$running" == "$target" ]]; then
        echo "error: $app is running (pid $pid). Quit it first, or set APP_PATH to another location." >&2
        exit 1
    fi
done

swift build -c "$configuration" --product GeminiDictation
binary="$(swift build -c "$configuration" --show-bin-path)/GeminiDictation"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/GeminiDictation"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Local builds use ad hoc signing; distribution builds use Hardened Runtime.
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - --identifier io.github.yheihei.GeminiDictation "$app"
else
    codesign --force --sign "$identity" --identifier io.github.yheihei.GeminiDictation \
        --options runtime --timestamp --entitlements Resources/GeminiDictation.entitlements "$app"
fi
codesign --verify --strict "$app"

echo "Built $app"
