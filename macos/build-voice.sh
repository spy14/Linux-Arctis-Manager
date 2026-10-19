#!/bin/sh
set -eu
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
export MACOSX_DEPLOYMENT_TARGET=13.0
export CARGO_TARGET_DIR="$PWD/build/voice-target"
# Float32 stdin/stdout helper; links ONNX Runtime dynamically when a user enables AI.
"$CARGO" build --locked --release --manifest-path voice-engine/Cargo.toml
mkdir -p "build/Arctis Settings.app/Contents/MacOS"
cp build/voice-target/release/arctis-voice-engine "build/Arctis Settings.app/Contents/MacOS/"
codesign --force --sign - "build/Arctis Settings.app/Contents/MacOS/arctis-voice-engine"
codesign --force --sign - "build/Arctis Settings.app"
codesign --verify --deep --strict "build/Arctis Settings.app"
