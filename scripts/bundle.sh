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

[[ -d "$root/Frameworks/ghostty-vt.xcframework" ]] || "$root/scripts/build-libghostty-vt.sh"

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
# App icon: den.icon (Icon Composer) compiles to Assets.car for macOS 26's
# layered icon plus den.icns for older systems. Needs Xcode's actool.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$root/den.icon" --compile "$app/Contents/Resources" --app-icon den \
    --platform macosx --minimum-deployment-target 15.0 \
    --output-partial-info-plist "$root/.build/den-icon-partial.plist" --errors >/dev/null
else
  echo "warning: Xcode's actool not found; Den.app ships without its icon" >&2
fi

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
  <key>SUEnableAutomaticChecks</key><false/>
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
