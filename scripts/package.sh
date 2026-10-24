#!/bin/bash
# Build Sapu.app and Sapu-macOS-arm64.dmg (ad-hoc signed).
# Usage: scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
OUT=build
APP="$OUT/Sapu.app"

scripts/build.sh release

# Nothing ships unless the uninstall release check passes (Mole parity, every claim reviewed, no shared claims)
# and the self-tests pass. SAPU_REPLAY_ONLY=1 checks the saved recording instead of rerunning Mole (CI).
if [ "${SAPU_REPLAY_ONLY:-}" = "1" ]; then build/sapu-cli parity check; else scripts/release-check.sh; fi
build/sapu-cli selftest >/dev/null || { build/sapu-cli selftest | grep "✗"; echo "Self-tests failed; not packaging."; exit 1; }

# Icon (rendered once, then cached in Resources/).
if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ icon"
  mkdir -p Resources "$OUT/icon.iconset"
  FLAGS=(-sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0)
  [ -f "$OUT/vfs.yaml" ] && FLAGS+=(-vfsoverlay "$OUT/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/vfs.yaml")
  swiftc "${FLAGS[@]}" -o "$OUT/make-icon" scripts/make-icon.swift
  "$OUT/make-icon" "$OUT/icon-1024.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$OUT/icon-1024.png" --out "$OUT/icon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$OUT/icon-1024.png" --out "$OUT/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$OUT/icon.iconset" -o Resources/AppIcon.icns
fi

echo "→ Sapu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/Sapu" "$APP/Contents/MacOS/Sapu"
cp "$OUT/sapu-cli" "$APP/Contents/Resources/sapu-cli"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sapu</string>
  <key>CFBundleDisplayName</key><string>Sapu</string>
  <key>CFBundleIdentifier</key><string>app.sapu.Sapu</string>
  <key>CFBundleExecutable</key><string>Sapu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc sign"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "→ DMG"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$OUT/Sapu-macOS-arm64.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sapu" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT/Sapu-macOS-arm64.dmg"
rm -rf "$STAGE"
shasum -a 256 "$OUT/Sapu-macOS-arm64.dmg" | tee "$OUT/Sapu-macOS-arm64.dmg.sha256"
ls -lh "$OUT/Sapu-macOS-arm64.dmg"
echo "✓ $OUT/Sapu-macOS-arm64.dmg"
