#!/usr/bin/env bash
# Builds libtermy_engine (Termy's engine-only C library) from the pinned
# vendor/termy submodule with Cargo.
#
#   scripts/build-libtermy-engine.sh          macOS: Frameworks/TermyEngine.xcframework
#   scripts/build-libtermy-engine.sh linux    Linux musl: Frameworks/linux/<arch>/lib and
#                                             the CTermyEngine module in Frameworks/linux
#
# Linux targets need no musl linker: only the static library is used.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
termy="$root/vendor/termy"

command -v cargo >/dev/null || { echo "error: cargo is missing; install Rust from https://rustup.rs and retry" >&2; exit 1; }
git -C "$root" submodule update --init vendor/termy

if [[ "${1:-macos}" == linux ]]; then
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

(cd "$termy" && scripts/package-libtermy-engine.sh aarch64-apple-darwin)
rm -rf "$root/Frameworks/TermyEngine.xcframework"
mkdir -p "$root/Frameworks"
cp -R "$termy/dist/TermyEngine.xcframework" "$root/Frameworks/"
echo "Installed Frameworks/TermyEngine.xcframework"
