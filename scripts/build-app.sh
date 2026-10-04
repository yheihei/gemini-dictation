#!/bin/bash
# Builds GeminiDictation.app with SwiftPM and signs it ad hoc.
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

# Ad hoc signature: enough to run locally. macOS ties microphone/Accessibility
# approval and the Keychain item's access list to this signature, so a rebuilt
# app may ask again (see README).
codesign --force --sign - --identifier io.github.yheihei.GeminiDictation "$app"
codesign --verify --strict "$app"

echo "Built $app"
