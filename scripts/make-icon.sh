#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="$PWD/.build/icon-generation/PracticeRecorder.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" "$PWD/AppResources/PracticeRecorder.png"
iconutil -c icns "$ICONSET" -o AppResources/PracticeRecorder.icns
