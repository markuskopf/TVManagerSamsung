#!/usr/bin/env bash
# Build (release) and launch the macOS app.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
exec ./.build/release/TVSenderManager
