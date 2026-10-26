#!/bin/zsh
# 사용법:
#   ./build.sh            → build/LowTide.app (ad-hoc 서명, 로컬 테스트용)
#   ./build.sh install    → 위 빌드를 /Applications 에 설치하고 실행
#   ./build.sh release    → Developer ID 서명 + 공증 + staple → dist/LowTide-<버전>-arm64.zip
#
# release 환경변수:
#   SIGN_IDENTITY   Developer ID Application 인증서 SHA-1 또는 이름 (기본: 키체인의 Developer ID Application)
#   NOTARY_PROFILE  `xcrun notarytool store-credentials` 로 저장한 프로필 이름
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tile-launcher-notary}"

# Desktop(iCloud 동기화) 안에서는 xattr이 계속 붙어 codesign이 실패하므로 임시 폴더에서 조립·서명
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/LowTide.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  Sources/main.swift -o "$APP/Contents/MacOS/LowTide"

xattr -cr "$APP"
if [[ "$MODE" == "release" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [[ "$MODE" == "release" ]]; then
  ZIP="$STAGE/LowTide-$VERSION-arm64.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  # staple된 앱으로 다시 압축
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  mkdir -p dist
  cp "$ZIP" dist/
  echo "release: dist/LowTide-$VERSION-arm64.zip"
  exit 0
fi

rm -rf build/LowTide.app
mkdir -p build
ditto --norsrc --noextattr "$APP" build/LowTide.app
echo "built: build/LowTide.app"

if [[ "$MODE" == "install" ]]; then
  pkill -x LowTide || true
  rm -rf /Applications/LowTide.app
  ditto --norsrc --noextattr "$APP" /Applications/LowTide.app
  open /Applications/LowTide.app
  echo "installed: /Applications/LowTide.app"
fi
