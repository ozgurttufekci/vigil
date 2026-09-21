#!/usr/bin/env bash
#
# Runs the test suite.
#
# swift-testing ships fully wired up with Xcode. With only the Command Line Tools installed the
# framework is present, but its search paths and the companion interop dylib are not on the default
# rpath, so we add them explicitly. Once Xcode is installed this script transparently falls back to
# a plain `swift test`.
set -euo pipefail

cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
args=()

if [[ "$developer_dir" != *"Xcode.app"* ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    interop_lib="$developer_dir/Library/Developer/usr/lib"

    if [[ -d "$frameworks" ]]; then
        args+=(-Xswiftc -F -Xswiftc "$frameworks")
        args+=(-Xlinker -F -Xlinker "$frameworks")
        args+=(-Xlinker -rpath -Xlinker "$frameworks")
    fi
    if [[ -d "$interop_lib" ]]; then
        args+=(-Xlinker -rpath -Xlinker "$interop_lib")
    fi
fi

exec swift test ${args[@]+"${args[@]}"} "$@"
