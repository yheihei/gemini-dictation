#!/bin/bash
# Builds, notarizes and packages a distribution app. Does not publish to GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a saved notarytool Keychain profile}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "error: distribution requires a Developer ID Application identity" >&2
    exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
directory="build/releases/v$version"
app="$directory/GeminiDictation.app"
APP_PATH="$app" CONFIGURATION=release ./scripts/build-app.sh
signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application:"* || "$signature" != *"(runtime)"* ]]; then
    echo "error: app must have Developer ID Application signing and Hardened Runtime" >&2
    exit 1
fi

architecture="$(lipo -archs "$app/Contents/MacOS/GeminiDictation")"
case "$architecture" in
    arm64|x86_64) ;;
    "x86_64 arm64"|"arm64 x86_64") architecture=universal ;;
    *) echo "error: unexpected architecture: $architecture" >&2; exit 1 ;;
esac
archive="$directory/GeminiDictation-v$version-macos-$architecture.zip"
submission="$directory/notary-submission.json"

ditto -c -k --keepParent --norsrc "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$submission"
status="$(plutil -extract status raw "$submission")"
if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization returned $status; see $submission" >&2
    exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute --verbose=4 "$app"

# Repackage after stapling so the downloadable app carries its notarization ticket.
rm "$archive"
ditto -c -k --keepParent --norsrc "$app" "$archive"
(cd "$directory" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS.txt)
echo "Distribution archive: $archive"
