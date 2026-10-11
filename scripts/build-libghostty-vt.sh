#!/usr/bin/env bash
# Builds libghostty-vt from the pinned vendor/ghostty submodule and copies the
# xcframework into Frameworks/. Uses a project-local Zig (.tools/zig) because
# Ghostty requires a specific Zig version.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
zig_version="0.16.0"
zig="$root/.tools/zig/zig"

if [[ ! -x "$zig" ]] || [[ "$("$zig" version)" != "$zig_version" ]]; then
  echo "Fetching Zig $zig_version into .tools/zig"
  rm -rf "$root/.tools/zig"
  mkdir -p "$root/.tools"
  arch="$(uname -m | sed 's/arm64/aarch64/')"
  curl -fsSL "https://ziglang.org/download/$zig_version/zig-$arch-macos-$zig_version.tar.xz" | tar xJ -C "$root/.tools"
  mv "$root/.tools/zig-$arch-macos-$zig_version" "$root/.tools/zig"
fi

git -C "$root" submodule update --init vendor/ghostty

(cd "$root/vendor/ghostty" && "$zig" build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast)

rm -rf "$root/Frameworks/ghostty-vt.xcframework"
mkdir -p "$root/Frameworks"
cp -R "$root/vendor/ghostty/zig-out/lib/ghostty-vt.xcframework" "$root/Frameworks/"
echo "Installed Frameworks/ghostty-vt.xcframework"
