#!/bin/sh
set -eu
cd "$(dirname "$0")"
sh build.sh
APP="build/Arctis Settings.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :LAMReleaseVersion' "$APP/Contents/Info.plist")
ARCH=$(uname -m)
ARCHIVE="Arctis-Settings-${VERSION}-macos-${ARCH}.zip"
mkdir -p build/release
# ditto preserves the bundle's executable permissions and macOS metadata.
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/release/$ARCHIVE"
cd build/release
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
printf 'Packaged: %s\n' "$ARCHIVE"
