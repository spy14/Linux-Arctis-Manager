#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="build/Arctis Settings.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
ARCH=$(uname -m)
APP_VERSION=${APP_VERSION:-$(cat ../VERSION)}
export APP_VERSION
xcrun swiftc -target "$ARCH-apple-macos13.0" -O -module-cache-path build/module-cache -framework SwiftUI -framework IOKit Sources/Headset.swift Sources/App.swift -o "$APP/Contents/MacOS/ArctisSettings"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ArctisSettings</string>
<key>CFBundleIdentifier</key><string>org.linux-arctis-manager.macos</string>
<key>CFBundleName</key><string>Arctis Settings</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" <<'PY'
import os
import plistlib
import re
import sys

version = os.environ["APP_VERSION"].removeprefix("v")
if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
    raise SystemExit(f"Invalid app version: {version!r}")
path = sys.argv[1]
with open(path, "rb") as stream:
    info = plistlib.load(stream)
info["CFBundleShortVersionString"] = version.split("-", 1)[0]
info["CFBundleVersion"] = version.split("-", 1)[0]
info["LAMReleaseVersion"] = version
with open(path, "wb") as stream:
    plistlib.dump(info, stream)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
