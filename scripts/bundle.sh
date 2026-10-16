#!/usr/bin/env bash
# Packages Den.app (app + bundled dend) into dist/.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"
version="${DEN_VERSION:-1.0.0}"
# EdDSA public key the updater trusts (Info.plist SUPublicEDKey). CI passes
# the release key; empty locally, where the updater only runs in .app bundles
# built for release anyway.
sparkle_key="${DEN_SPARKLE_PUBLIC_KEY:-}"
sparkle_feed="https://github.com/DeepanshuMishraa/den/releases/latest/download/appcast.xml"

"$root/scripts/build-libtermy-engine.sh" --if-stale

swift build --package-path "$root" -c "$config" --product Den
swift build --package-path "$root" -c "$config" --product dend
bin="$(swift build --package-path "$root" -c "$config" --show-bin-path)"

app="$root/dist/Den.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Den" "$bin/dend" "$app/Contents/MacOS/"
# The den CLI is the Den executable run under the name `den`. A relative link
# in its own folder (MacOS/den would clash with Den on case-insensitive disks).
# Den links ~/.local/bin/den here on launch; dend puts this folder on panes' PATH.
mkdir -p "$app/Contents/Resources/bin"
ln -sf ../../MacOS/Den "$app/Contents/Resources/bin/den"
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
# Sparkle (SwiftPM binary target): embed the framework for the updater.
# symlinks (Versions/Current) must survive the copy, so plain cp -R. The
# framework lands next to the binary in some configs; otherwise take the
# arm64 slice straight from the xcframework SPM downloaded.
sparkle_fw="$(find "$bin" -maxdepth 3 -name "Sparkle.framework" | head -1)"
if [[ -z "$sparkle_fw" ]]; then
  sparkle_fw="$(find "$root/.build" -path "*Sparkle.xcframework/macos-arm64*/Sparkle.framework" | head -1)"
fi
if [[ -n "$sparkle_fw" ]]; then
  mkdir -p "$app/Contents/Frameworks"
  rm -rf "$app/Contents/Frameworks/Sparkle.framework"
  cp -R "$sparkle_fw" "$app/Contents/Frameworks/"
else
  echo "warning: Sparkle.framework not in $bin; in-app updates will be unavailable" >&2
fi
# SwiftPM resources (bundled fonts); Bundle.module finds them in Resources.
cp -R "$bin/Den_DenApp.bundle" "$app/Contents/Resources/"
# Build a legacy .icns from the .icon artwork. actool's Icon Composer
# compilation crashes on GitHub's macOS runner, so sips+iconutil render the
# committed PNG instead. The source is icon.json's image-name, so swapping
# artwork re-hooks automatically instead of breaking the bundle.
icon_src="$(jq -r '.groups[0].layers[0]."image-name"' "$root/den.icon/icon.json")"
[[ -f "$root/den.icon/Assets/$icon_src" ]] || { echo "error: missing icon artwork den.icon/Assets/$icon_src (check icon.json image-name)" >&2; exit 1; }
iconset="$root/.build/den.iconset"
mkdir -p "$iconset"
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$root/den.icon/Assets/$icon_src" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$root/den.icon/Assets/$icon_src" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output "$app/Contents/Resources/den.icns"
rm -rf "$iconset"
# Liquid Glass icon: compile the .icon package into Assets.car so macOS 26+
# renders its layers, glass and gradient (CFBundleIconName=den is already in
# the plist below). Best-effort: actool crashes on some CI runners, so a
# failure only warns and the flat .icns above remains the fallback.
icontmp="$root/.build/den-iconcompile"
mkdir -p "$icontmp"
if xcrun actool --output-format human-readable-text --notices --warnings \
    --target-device mac --minimum-deployment-target 15.0 --platform macosx \
    --compile "$icontmp" "$root/den.icon" >/dev/null 2>&1 \
    && [[ -f "$icontmp/Assets.car" ]]; then
  cp "$icontmp/Assets.car" "$app/Contents/Resources/"
else
  echo "warning: actool den.icon compilation failed; app ships flat .icns only" >&2
fi
rm -rf "$icontmp"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Den</string>
  <key>CFBundleDisplayName</key><string>Den</string>
  <key>CFBundleIdentifier</key><string>den.dipxsy.app</string>
  <key>CFBundleExecutable</key><string>Den</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>den</string>
  <key>CFBundleIconName</key><string>den</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SUFeedURL</key><string>$sparkle_feed</string>
  <key>SUPublicEDKey</key><string>$sparkle_key</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

# A stable identity keeps the Keychain's "Always Allow" for saved SSH
# passwords across rebuilds; an ad-hoc signature changes every build, so
# macOS asks again. DEN_SIGN_IDENTITY overrides; "-" forces ad-hoc.
identity="${DEN_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
identity="${identity:--}"
[[ "$identity" == "-" ]] && echo "warning: no Apple Development identity; signing ad-hoc (Keychain will ask again after each rebuild)" >&2
[[ -f "$app/Contents/MacOS/fsearch" ]] && codesign --force --sign "$identity" "$app/Contents/MacOS/fsearch" >/dev/null
# Sparkle's helpers must be signed before the framework and app that contain
# them (inside out, no --deep: it breaks the XPC services' signatures).
# Plain ad-hoc style, deliberately no `-o runtime`: the hardened runtime's
# library validation would stop an ad-hoc build from loading Sparkle at all.
fw="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$fw" ]]; then
  for inner in "$fw/Versions/B/XPCServices/Downloader.xpc" "$fw/Versions/B/XPCServices/Installer.xpc" \
               "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app"; do
    [[ -e "$inner" ]] && codesign --force --sign "$identity" "$inner" >/dev/null
  done
  codesign --force --sign "$identity" "$fw" >/dev/null
  # The binary's rpaths cover only its own folder; point it at Frameworks.
  # (install_name_tool breaks the signature, so this runs before signing.)
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Den"
fi
codesign --force --sign "$identity" "$app/Contents/MacOS/dend" "$app" >/dev/null
echo "Built $app"
