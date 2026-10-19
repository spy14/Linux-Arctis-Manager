#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/module-cache
ARCH=$(uname -m)
# Keep assertions enabled: do not compile this executable with -O.
xcrun swiftc -target "$ARCH-apple-macos13.0" -module-cache-path build/module-cache \
    Sources/Headset.swift Sources/Equalizer.swift Sources/Profiles.swift Tests/main.swift -o build/tests
build/tests "$@"
xcrun clang -target "$ARCH-apple-macos13.0" -isysroot "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    Sources/AudioRing.c Tests/audio_ring.c -o build/audio-ring-tests
build/audio-ring-tests
