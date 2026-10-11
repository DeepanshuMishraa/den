#!/usr/bin/env bash
# Builds fully static Linux dend binaries (x86_64 and aarch64, musl) into
# dist/linux/, which Den uploads to remote hosts on first connect. Needs
# Docker (OrbStack works) and the project-local Zig from
# build-libghostty-vt.sh. Copies the binaries next to the debug and release
# Den builds too, so `swift build && .build/debug/Den` can install them.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
zig="$root/.tools/zig/zig"
swift_image="swift:6.4.0"
# From https://www.swift.org/api/v1/install/releases.json (swift-6.4.0-RELEASE).
sdk_url="https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
sdk_checksum="47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e"
arches=(x86_64 aarch64)

command -v docker >/dev/null || { echo "error: docker is missing; install OrbStack or Docker Desktop and start it" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "error: docker isn't running; start OrbStack or Docker Desktop and retry" >&2; exit 1; }
[[ -x "$zig" ]] || "$root/scripts/build-libghostty-vt.sh"
git -C "$root" submodule update --init vendor/ghostty

# libghostty-vt, statically, for each Linux architecture.
linux="$root/Frameworks/linux"
for arch in "${arches[@]}"; do
  if [[ ! -f "$linux/$arch/lib/libghostty-vt.a" ]]; then
    echo "Building libghostty-vt for $arch-linux-musl"
    (cd "$root/vendor/ghostty" && "$zig" build -Demit-lib-vt=true -Dtarget="$arch-linux-musl" -Doptimize=ReleaseFast --prefix "$linux/$arch")
  fi
done
# One module for both: the headers don't differ by architecture.
module="$linux/GhosttyVt"
rm -rf "$module"
mkdir -p "$module"
cp -R "$linux/${arches[0]}/include/ghostty" "$module/"
cat > "$module/module.modulemap" <<'MAP'
module GhosttyVt {
    umbrella header "ghostty/vt.h"
    link "ghostty-vt"
    export *
}
MAP

# Swift, in a Linux container with the static musl SDK (kept in a volume).
mkdir -p "$root/dist/linux"
docker run --rm \
  -v "$root":/src -w /src \
  -v den-swift-sdks:/root/.swiftpm \
  -e SDK_URL="$sdk_url" -e SDK_CHECKSUM="$sdk_checksum" \
  "$swift_image" bash -euo pipefail -c '
    swift sdk list | grep -q static-linux || swift sdk install "$SDK_URL" --checksum "$SDK_CHECKSUM"
    for arch in '"${arches[*]}"'; do
      flags=(-c release --swift-sdk "$arch-swift-linux-musl" --scratch-path .build/linux
        -Xcc -I/src/Frameworks/linux/GhosttyVt -Xlinker -L"/src/Frameworks/linux/$arch/lib" -Xlinker --strip-all)
      swift build "${flags[@]}" --product dend
      cp "$(swift build "${flags[@]}" --show-bin-path)/dend" "dist/linux/dend-linux-$arch"
    done'

for config in debug release; do
  bin="$root/.build/$config"
  [[ -d "$bin" ]] && cp "$root"/dist/linux/dend-linux-* "$bin/"
done
ls -lh "$root"/dist/linux/
