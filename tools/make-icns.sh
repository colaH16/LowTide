#!/bin/zsh
# 아이콘 원본을 다시 그리고 Resources/AppIcon.icns 로 패키징한다.
# 사용법: tools/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift tools/make-icon.swift Resources/AppIcon-source.png

ICONSET=$(mktemp -d)/AppIcon.iconset
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon-source.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon-source.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
