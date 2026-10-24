#!/bin/bash
# Build Sapu with plain swiftc (works with Command Line Tools only; no Xcode needed).
# Usage: scripts/build.sh [debug|release]   → build/Sapu (GUI binary) and build/sapu-cli
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-release}"
OUT=build
mkdir -p "$OUT"
SDK="$(xcrun --show-sdk-path)"
TARGET=arm64-apple-macos14.0
FLAGS=(-sdk "$SDK" -target "$TARGET" -swift-version 5)
# Command Line Tools 16 ship a duplicate usr/include/swift/module.modulemap that breaks every
# Foundation import ("redefinition of module 'SwiftBridging'"). Hide it with a VFS overlay.
CLT_MAP=/Library/Developer/CommandLineTools/usr/include/swift
if [ -f "$CLT_MAP/module.modulemap" ] && [ -f "$CLT_MAP/bridging.modulemap" ]; then
  : > "$OUT/empty.modulemap"
  printf '{"version":0,"case-sensitive":"false","roots":[{"type":"directory","name":"%s","contents":[{"type":"file","name":"module.modulemap","external-contents":"%s"}]}]}' \
    "$CLT_MAP" "$PWD/$OUT/empty.modulemap" > "$OUT/vfs.yaml"
  FLAGS+=(-vfsoverlay "$OUT/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/vfs.yaml")
fi
if [ "$MODE" = release ]; then FLAGS+=(-O -whole-module-optimization); else FLAGS+=(-Onone -g); fi

echo "→ SapuCore"
swiftc "${FLAGS[@]}" -parse-as-library -module-name SapuCore -emit-library -static \
  -emit-module -emit-module-path "$OUT/SapuCore.swiftmodule" \
  -o "$OUT/libSapuCore.a" Sources/SapuCore/*.swift

echo "→ sapu-cli"
swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lSapuCore -module-name SapuCLI \
  -o "$OUT/sapu-cli" Sources/SapuCLI/*.swift

echo "→ Sapu (app)"
swiftc "${FLAGS[@]}" -parse-as-library -I "$OUT" -L "$OUT" -lSapuCore -module-name SapuApp \
  -o "$OUT/Sapu" Sources/SapuApp/*.swift

echo "✓ built $OUT/Sapu and $OUT/sapu-cli ($MODE)"
