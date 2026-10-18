#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/module-cache
ARCH=$(uname -m)
# Keep assertions enabled: do not compile this executable with -O.
xcrun swiftc -target "$ARCH-apple-macos13.0" -module-cache-path build/module-cache \
    Sources/Headset.swift Tests/main.swift -o build/tests
build/tests "$@"
