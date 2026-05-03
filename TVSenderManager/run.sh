#!/usr/bin/env bash
# Build, assemble a TVSenderManager.app bundle, and launch it via Launch
# Services so the window reliably comes to the foreground on every macOS.
set -euo pipefail
cd "$(dirname "$0")"

# 1. Compile the executable.
swift build -c release

BIN=".build/release/TVSenderManager"
APP="TVSenderManager.app"

if [[ ! -x "$BIN" ]]; then
  echo "Build did not produce $BIN" >&2
  exit 1
fi

# 2. (Re)assemble the .app bundle next to the script.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"            "$APP/Contents/MacOS/TVSenderManager"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x             "$APP/Contents/MacOS/TVSenderManager"

# 3. Strip the quarantine attribute Gatekeeper would otherwise add when the
#    bundle gets copied around. Local builds shouldn't need that nag.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 4. Hand off to Launch Services. -W keeps the script attached to the app's
#    lifetime; -n forces a new instance even if one is already running.
exec /usr/bin/open -W -n "$APP"
