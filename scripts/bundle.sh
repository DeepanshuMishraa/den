#!/usr/bin/env bash
# Packages Den.app (app + bundled dend) into dist/.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"

[[ -d "$root/Frameworks/ghostty-vt.xcframework" ]] || "$root/scripts/build-libghostty-vt.sh"

swift build --package-path "$root" -c "$config" --product Den
swift build --package-path "$root" -c "$config" --product dend
bin="$(swift build --package-path "$root" -c "$config" --show-bin-path)"

app="$root/dist/Den.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Den" "$bin/dend" "$app/Contents/MacOS/"
# fsearch (vendor/fsearch, Rust) powers whole-disk path search. Without
# cargo the app still builds; the path picker then only browses folders.
if command -v cargo >/dev/null 2>&1 && [[ -f "$root/vendor/fsearch/Cargo.toml" ]]; then
  cargo build --release --quiet --manifest-path "$root/vendor/fsearch/Cargo.toml" --target-dir "$root/.build/fsearch"
  cp "$root/.build/fsearch/release/fsearch" "$app/Contents/MacOS/"
else
  echo "warning: cargo or vendor/fsearch missing; Den.app ships without fsearch (run git submodule update --init)" >&2
fi
# Linux dend builds that Den installs on remote hosts (scripts/build-dend-linux.sh).
# Resources, not MacOS: they're ELF files, which codesign can't sign as code.
if compgen -G "$root/dist/linux/dend-linux-*" >/dev/null; then
  cp "$root"/dist/linux/dend-linux-* "$app/Contents/Resources/"
else
  echo "warning: no dist/linux/dend-linux-*; Den.app can't set up Linux hosts (run scripts/build-dend-linux.sh)" >&2
fi
# SwiftPM resources (bundled fonts); Bundle.module finds them in Resources.
cp -R "$bin/Den_DenApp.bundle" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Den</string>
  <key>CFBundleDisplayName</key><string>Den</string>
  <key>CFBundleIdentifier</key><string>den.dipxsy.app</string>
  <key>CFBundleExecutable</key><string>Den</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

[[ -f "$app/Contents/MacOS/fsearch" ]] && codesign --force --sign - "$app/Contents/MacOS/fsearch" >/dev/null
codesign --force --sign - "$app/Contents/MacOS/dend" "$app" >/dev/null
echo "Built $app"
