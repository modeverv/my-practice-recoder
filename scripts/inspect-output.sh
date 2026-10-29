#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# swiftc needed for @main standalone async script; no third-party dependencies.
swiftc -parse-as-library scripts/inspect-output.swift -o .build/inspect-output
exec .build/inspect-output "$@"
