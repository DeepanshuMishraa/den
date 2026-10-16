#!/usr/bin/env bash
# Builds libtermy_engine (Termy's engine-only C library) from the pinned
# vendor/termy submodule with Cargo.
#
#   scripts/build-libtermy-engine.sh          macOS: Frameworks/TermyEngine.xcframework
#                                             for this Mac's architecture
#   scripts/build-libtermy-engine.sh --if-stale   the same, skipped when the
#                                             xcframework was built from the pinned vendor/termy
#   scripts/build-libtermy-engine.sh linux    Linux musl: Frameworks/linux/<arch>/lib and
#                                             the CTermyEngine module in Frameworks/linux
#
# Linux targets need no musl linker: only the static library is used.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
termy="$root/vendor/termy"
xcframework="$root/Frameworks/TermyEngine.xcframework"
# The vendor/termy commit the xcframework was built from.
stamp="$root/Frameworks/TermyEngine.revision"
pinned="$(git -C "$root" rev-parse HEAD:vendor/termy)"

if [[ "${1:-}" == --if-stale ]]; then
  if [[ -d "$xcframework" && "$(cat "$stamp" 2>/dev/null)" == "$pinned" ]]; then
    exit 0
  fi
  echo "Frameworks/TermyEngine.xcframework is missing or not built from vendor/termy $pinned; rebuilding"
  shift
fi

command -v cargo >/dev/null || { echo "error: cargo is missing; install Rust from https://rustup.rs and retry" >&2; exit 1; }
git -C "$root" submodule update --init vendor/termy

if [[ "${1:-macos}" == linux ]]; then
  command -v rustup >/dev/null || { echo "error: rustup is missing; the Linux build adds musl targets with it. Install Rust from https://rustup.rs and retry" >&2; exit 1; }
  arches=(x86_64 aarch64)
  linux="$root/Frameworks/linux"
  for arch in "${arches[@]}"; do
    target="$arch-unknown-linux-musl"
    rustup target list --installed | grep -qx "$target" || rustup target add "$target"
    echo "Building libtermy_engine for $target"
    (cd "$termy" && cargo build --locked --release -p termy_engine_ffi --lib --target "$target")
    mkdir -p "$linux/$arch/lib"
    cp "$termy/target/$target/release/libtermy_engine.a" "$linux/$arch/lib/"
  done
  # One module for both: the header doesn't differ by architecture.
  module="$linux/CTermyEngine"
  rm -rf "$module"
  mkdir -p "$module"
  cp "$termy/crates/engine_ffi/include/termy_engine.h" "$module/"
  cat > "$module/module.modulemap" <<'MAP'
module CTermyEngine {
    header "termy_engine.h"
    link "termy_engine"
    export *
}
MAP
  echo "Installed libtermy_engine.a for ${arches[*]} under Frameworks/linux"
  exit 0
fi

case "$(uname -m)" in
  arm64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) echo "error: no Rust target for this Mac's architecture ($(uname -m))" >&2; exit 1 ;;
esac
(cd "$termy" && scripts/package-libtermy-engine.sh "$target")
rm -rf "$xcframework"
mkdir -p "$root/Frameworks"
cp -R "$termy/dist/TermyEngine.xcframework" "$root/Frameworks/"
git -C "$termy" rev-parse HEAD > "$stamp"
echo "Installed Frameworks/TermyEngine.xcframework ($target)"
