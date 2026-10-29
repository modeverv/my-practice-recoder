#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=15.0
./scripts/make-icon.sh
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
APP="$PWD/build/Practice Recorder.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PracticeRecorder" "$APP/Contents/MacOS/PracticeRecorder"
cp AppResources/Info.plist "$APP/Contents/Info.plist"
cp AppResources/PracticeRecorder.icns "$APP/Contents/Resources/PracticeRecorder.icns"
# Local ad-hoc signature. No certificate/account or sandbox required.
codesign --force --sign - --options runtime --entitlements AppResources/PracticeRecorder.entitlements "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s\n' "$APP"
