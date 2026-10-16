#!/usr/bin/env bash
# Builds and runs the dev Den (.build/debug/Den). It keeps its own support
# folder, socket and launchd job (DenPaths.isDevBuild), apart from any
# installed Den.app.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

[[ -d "$root/Frameworks/TermyEngine.xcframework" ]] || "$root/scripts/build-libtermy-engine.sh"

swift build --package-path "$root" --product Den
swift build --package-path "$root" --product dend
bin="$(swift build --package-path "$root" --show-bin-path)"

# SwiftPM links Sparkle with an rpath to PackageFrameworks but doesn't copy
# the framework there, so the binary fails to load without this.
fw="$(find "$root/.build/artifacts" -path "*Sparkle.xcframework/macos-arm64*/Sparkle.framework" -maxdepth 6 | head -1)"
if [[ -z "$fw" ]]; then
  echo "error: Sparkle.xcframework not found under .build/artifacts; run swift package resolve" >&2
  exit 1
fi
mkdir -p "$bin/PackageFrameworks"
rm -rf "$bin/PackageFrameworks/Sparkle.framework"
cp -R "$fw" "$bin/PackageFrameworks/"

# Run from a Den pane, DEN_SOCKET names that Den's dend; the dev app would
# attach to it (and offer to restart it) instead of starting its own.
exec env -u DEN_SOCKET -u DEN_PANE_ID -u DEN_SESSION_ID "$bin/Den" "$@"
