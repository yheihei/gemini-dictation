#!/bin/bash
# Runs the unit tests. Works with either Xcode or the Command Line Tools alone.
# With only the Command Line Tools installed, SwiftPM does not find the Swift
# Testing framework by itself, so its location is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p 2>/dev/null || true)"
frameworks="$developer_dir/Library/Developer/Frameworks"
extra=()
if [[ -d "$frameworks/Testing.framework" ]]; then
    extra+=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
    )
    plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
    if [[ -d "$plugins" ]]; then
        extra+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
    fi
    interop="$developer_dir/Library/Developer/usr/lib"
    if [[ -f "$interop/lib_TestingInterop.dylib" ]]; then
        extra+=(-Xlinker -rpath -Xlinker "$interop")
    fi
fi

swift test ${extra[@]+"${extra[@]}"} "$@"
