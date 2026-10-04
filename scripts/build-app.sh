#!/bin/bash
# Builds build/GeminiDictation.app with SwiftPM and signs it ad hoc.
# Needs only the Xcode Command Line Tools. Nothing is installed outside this folder.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
app="build/GeminiDictation.app"

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
